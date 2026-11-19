import Combine
import WiFiRecorderCore
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class WiFiTransferTests: XCTestCase {
  @MainActor func testRealSocketsResumeCancelAndTailRecovery() async throws {
    for scenario in ["resume", "cancel", "early", "limit", "stalled"] {
      let fm = FileManager.default
      let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? fm.removeItem(at: root) }
      let (peer, port) = try startPeer(scenario)
      defer { if peer.isRunning { peer.terminate() } }
      let bytes = Data((0..<20000).map { UInt8(($0 * 31 + 7) % 256) })
      let item = try RecordingEntry(
        [0] + Array("20261116123456".utf8) + Wire.beBytes(UInt64(bytes.count)))
      let store = DownloadStore(root: root)
      if scenario == "resume" {
        let sink = try store.begin(device: "test", file: item, resume: true)
        _ = try sink.accept(Array(bytes.prefix(2048)))
        sink.close()
      }
      let client = TransferClient(root: root)
      defer { client.disconnect() }
      let done = expectation(description: scenario)
      let shouldFail = ["limit", "stalled"].contains(scenario)
      client.onDownloadStart = { offset, size in
        XCTAssertEqual(size, UInt64(bytes.count))
        if scenario == "resume" { XCTAssertEqual(offset, 2048) }
      }
      client.onFiles = { rows in
        XCTAssertEqual(rows, [item])
        client.download(item)
      }
      var cancelled = false
      client.onProgress = { n, _ in
        if scenario == "cancel", !cancelled, n == 4096 {
          cancelled = true
          client.cancelDownload {
            client.connect(deviceID: "test", host: "127.0.0.1", port: port, wifiOnly: false)
          }
        }
      }
      client.onDownloaded = { url in
        XCTAssertFalse(shouldFail)
        XCTAssertEqual(try? Data(contentsOf: url), bytes)
        client.disconnect()
        done.fulfill()
      }
      client.onFailure = { message in
        XCTAssertTrue(shouldFail, message)
        XCTAssertNil(store.completed(device: "test", file: item))
        let part = store.url(device: "test", file: item, partial: true)
        XCTAssertEqual((try? Data(contentsOf: part))?.count, scenario == "limit" ? 3072 : 1024)
        done.fulfill()
      }
      client.connect(deviceID: "test", host: "127.0.0.1", port: port, wifiOnly: false)
      await fulfillment(of: [done], timeout: 12)
      client.disconnect()
      peer.waitUntilExit()
      XCTAssertEqual(peer.terminationStatus, 0, scenario)
      // Closures installed by the test capture the client.
      client.onFiles = { _ in }
      client.onProgress = { _, _ in }
      client.onDownloaded = { _ in }
    }
  }

  private func startPeer(_ scenario: String) throws -> (Process, UInt16) {
    let peer = Process()
    let output = Pipe()
    peer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    peer.arguments = [wifiFixture("tcp_peer.py").path, scenario]
    peer.standardOutput = output
    try peer.run()
    let portText = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let port = UInt16(portText)
    if port == nil, peer.isRunning { peer.terminate() }
    return (peer, try XCTUnwrap(port, "The TCP peer did not report a listening port."))
  }
}

private final class TestBluetooth: WiFiSyncBluetooth {
  var preferredKind: RecorderKind = .wifi
  var boundID: String? = "fixture-card"
  var wifiBusy = false, holdReconnect = false
  var onWiFiState: ((UInt8) -> Void)?
  var onHotspot: ((HotspotCredentials) -> Void)?
  var onSocket: (() -> Void)?
  var onWiFiLost: (() -> Void)?
  var onWiFiFilePacket: ((Packet) -> Void)?
  var raw: UInt8 = 0
  var reportsSocketReady = true
  var cleanupFiles: [RecordingEntry] = []
  var removesRequestedFiles = true
  var deleteRequests: [RecordingEntry] = []
  var onDelete: () -> Void = {}
  var releases = 0
  var onRelease: () -> Void = {}
  func queryWiFiState() { onWiFiState?(raw) }
  func openWiFiHotspot(for id: String) {
    XCTAssertEqual(boundID, id)
    hotspotRequests += 1
    if reportsSocketReady { onSocket?() }
    onHotspot?(try! HotspotCredentials(Array("Test_AP00112345678".utf8)))
  }
  func releaseForWiFi() {
    releases += 1
    onRelease()
    onWiFiLost?()
  }
  var listRequests = 0
  var hotspotRequests = 0
  @MainActor func readWiFiFileList(for id: String, duringSync: Bool) async throws -> [RecordingEntry] {
    guard id == boundID && raw == 0 else { throw WorkdayError.invalid("设备未就绪") }
    listRequests += 1
    return cleanupFiles
  }
  func deleteWiFiFile(_ file: RecordingEntry, from id: String) -> Bool {
    XCTAssertEqual(id, boundID)
    onDelete()
    deleteRequests.append(file)
    if removesRequestedFiles { cleanupFiles.removeAll { $0 == file } }
    onWiFiFilePacket?(Packet(13, [0]))
    return true
  }
}

private final class TestNetwork: WiFiHotspotJoining {
  var permissionChanged: (Bool) -> Void = { _ in }
  var joins = 0, restores = 0
  func join(
    _ credentials: HotspotCredentials, completion: @escaping (Result<String, Error>) -> Void
  ) {
    joins += 1
    completion(.success("lo0"))
  }
  func restore(completion: @escaping (String) -> Void) {
    restores += 1
    completion("测试网络已恢复")
  }
  func cancel() {}
  func requestLocationPermission() {}
}

extension WiFiTransferTests {
  @MainActor func testBluetoothCountMatchesOnlyVerifiedArchivesForTheSelectedCard() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ArchiveStore(root: root)
    let card = TestBluetooth()
    let network = TestNetwork()
    let sync = WiFiRecordingSync(store: store, card: card, wifi: network)
    let selected = try XCTUnwrap(card.boundID)
    let bytes = try Data(contentsOf: wifiFixture("silence.bin"))
    let items = try ["20261116123456", "20261116123500"].map {
      try RecordingEntry([0] + Array($0.utf8) + Wire.beBytes(UInt64(bytes.count)))
    }
    var selectedOriginal: URL?
    for (device, item) in [(selected, items[0]), ("other-card", items[1])] {
      let sink = try DownloadStore(root: store.wifiInbox).begin(device: device, file: item, resume: false)
      _ = try sink.accept(Array(bytes))
      _ = try sink.accept([2])
      let row = try await store.archiveWiFiFile(sink.destination)
      if device == selected {
        selectedOriginal = root.appendingPathComponent(row.folder).appendingPathComponent("device.bin")
      }
    }
    card.cleanupFiles = items + [items[0]]
    var listed: [Int] = []
    let first = try await sync.bluetoothRecordingCount(for: selected) { listed.append($0) }
    XCTAssertEqual(listed, [2])
    XCTAssertEqual(first, CardRecordingCount(discovered: 2, complete: true, pending: 1))

    var damaged = bytes
    damaged[0] ^= 1
    try damaged.write(to: XCTUnwrap(selectedOriginal))
    let afterDamage = try await sync.bluetoothRecordingCount(for: selected)
    XCTAssertEqual(afterDamage.pending, 2)
    card.cleanupFiles = []
    let empty = try await sync.bluetoothRecordingCount(for: selected)
    XCTAssertEqual(empty, CardRecordingCount(discovered: 0, complete: true, pending: 0))
    card.raw = 1
    do {
      _ = try await sync.bluetoothRecordingCount(for: selected)
      XCTFail("An active recording cannot supply an idle inventory.")
    } catch {}
    do {
      _ = try await sync.bluetoothRecordingCount(for: "other-card")
      XCTFail("Only the selected peripheral can supply a count.")
    } catch is CancellationError {}
    XCTAssertEqual(card.listRequests, 3)
    XCTAssertEqual(card.hotspotRequests, 0)
    XCTAssertEqual(network.joins, 0)
    XCTAssertEqual(card.deleteRequests, [])
    XCTAssertEqual(sync.phase, .idle)
  }

  @MainActor func testBluetoothListReplaysCapturedRepliesThroughTheirEndMarkers() async throws {
    let capture = try String(contentsOf: wifiFixture("notifications.hex"), encoding: .utf8)
    let reader = BluetoothRecordingList()
    var parser = BLEParser()
    var reply: [[UInt8]] = []
    var counts: [Int] = []
    for line in capture.split(separator: "\n") {
      let data = Data(line.split(separator: " ").compactMap { UInt8($0, radix: 16) })
      for frame in parser.feed(data) where frame.key == 10 {
        reply.append(frame.payload)
        if frame.payload.first == 2 {
          let files = try await reader.read {
            reply.forEach(reader.accept)
            return true
          }
          counts.append(files.count)
          reply.removeAll()
        }
      }
    }
    XCTAssertEqual(counts, [5, 5, 5, 6])
  }

  @MainActor func testUnfinishedBluetoothListCannotPublishAPartialOrConsumeTheNextReply() async throws {
    let reader = BluetoothRecordingList()
    let item = [0] + Array("20261116123456".utf8) + Wire.beBytes(100)
    do {
      _ = try await reader.read(timeout: .milliseconds(40)) {
        reader.accept(item)
        return true
      }
      XCTFail("A partial list must time out.")
    } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
    do {
      _ = try await reader.read {
        XCTFail("The first reply has not ended.")
        return true
      }
      XCTFail("An unfinished reply must not become an empty list.")
    } catch { XCTAssertTrue(error.localizedDescription.contains("上次清单")) }
    reader.accept([2])

    let sent = expectation(description: "page requested the inventory")
    let previousPage = Task {
      try await reader.read {
        reader.accept(item)
        sent.fulfill()
        return true
      }
    }
    await fulfillment(of: [sent], timeout: 2)
    previousPage.cancel()
    do {
      _ = try await previousPage.value
      XCTFail("A dismissed page cannot publish its result.")
    } catch is CancellationError {}
    reader.accept([2])
    let reopened = try await reader.read {
      reader.accept([2])
      return true
    }
    XCTAssertEqual(reopened, [])
  }

  @MainActor func testInterruptedBluetoothListRejectsEndAndDeviceSwitchDiscardsCounts() async throws {
    let reader = BluetoothRecordingList()
    do {
      _ = try await reader.read {
        reader.invalidate("录音状态已改变")
        reader.accept([2])
        return true
      }
      XCTFail("An invalidated reply cannot confirm an empty card.")
    } catch { XCTAssertEqual(error.localizedDescription, "录音状态已改变") }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let card = TestBluetooth()
    let sync = WiFiRecordingSync(store: ArchiveStore(root: root), card: card, wifi: TestNetwork())
    do {
      _ = try await sync.bluetoothRecordingCount(for: try XCTUnwrap(card.boundID)) { _ in
        card.boundID = "replacement-card"
      }
      XCTFail("A reply for the previous device cannot populate its replacement.")
    } catch is CancellationError {}
  }

  @MainActor func testFailedLocalArchiveDoesNotCountADownloadAsSaved() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (peer, port) = try startPeer("invalid")
    defer { if peer.isRunning { peer.terminate() } }
    let store = ArchiveStore(root: root)
    let card = TestBluetooth()
    let sync = WiFiRecordingSync(store: store, card: card, wifi: TestNetwork()) { client, id, _ in
      client.connect(deviceID: id, host: "127.0.0.1", port: port, wifiOnly: false)
    }
    sync.attach()
    let finished = expectation(description: "invalid download remains available for retry")
    sync.onArchiveChange = { finished.fulfill() }
    sync.start(id: "fixture-card")
    await fulfillment(of: [finished], timeout: 8)
    let pending = try await store.pendingWiFiFiles()
    XCTAssertEqual(pending.count, 1)
    XCTAssertEqual(sync.failedImports, 1)
    XCTAssertEqual(sync.outcome.saved, 0)
    await sync.shutdown()
    peer.waitUntilExit()
    XCTAssertEqual(peer.terminationStatus, 0)
  }

  @MainActor func testCleanupFailureKeepsTheNewArchiveCountAndPendingAction() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (peer, port) = try startPeer("sync")
    defer { if peer.isRunning { peer.terminate() } }
    let store = ArchiveStore(root: root)
    let card = TestBluetooth()
    let bytes = try Data(contentsOf: wifiFixture("silence.bin"))
    card.cleanupFiles = [try RecordingEntry(
      [0] + Array("20261116123456".utf8) + Wire.beBytes(UInt64(bytes.count)))]
    card.removesRequestedFiles = false
    let sync = WiFiRecordingSync(store: store, card: card, wifi: TestNetwork()) { client, id, _ in
      client.connect(deviceID: id, host: "127.0.0.1", port: port, wifiOnly: false)
    }
    sync.cleanupEnabled = true
    sync.attach()
    let finished = expectation(description: "archive survives incomplete cleanup")
    sync.onArchiveChange = { finished.fulfill() }
    sync.start(id: "fixture-card")
    await fulfillment(of: [finished], timeout: 8)
    XCTAssertEqual(sync.outcome.saved, 1)
    XCTAssertEqual(sync.pendingCleanup, 1)
    XCTAssertTrue(sync.outcome.copies?.contains("1 段副本待清理") == true)
    await sync.shutdown()
    peer.waitUntilExit()
    XCTAssertEqual(peer.terminationStatus, 0)
  }

  @MainActor func testHistoricalArchiveIsRereadAndVerifiedBeforeCardCleanup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (peer, port) = try startPeer("sync")
    defer { if peer.isRunning { peer.terminate() } }
    let store = ArchiveStore(root: root)
    let card = TestBluetooth()
    let wifi = TestNetwork()
    let bytes = try Data(contentsOf: wifiFixture("silence.bin"))
    let item = try RecordingEntry(
      [0] + Array("20261116123456".utf8) + Wire.beBytes(UInt64(bytes.count)))
    let sink = try DownloadStore(root: store.wifiInbox).begin(
      device: "fixture-card", file: item, resume: false)
    _ = try sink.accept(Array(bytes))
    _ = try sink.accept([2])
    let original = try await store.archiveWiFiFile(sink.destination)
    try FileManager.default.removeItem(at: sink.destination)
    try bytes.prefix(100).write(to: sink.partial)
    card.cleanupFiles = [item]
    card.onDelete = {
      XCTAssertEqual(wifi.restores, 1)
      let raw = root.appendingPathComponent(original.folder).appendingPathComponent("device.bin")
      XCTAssertEqual(try? Data(contentsOf: raw), bytes)
    }
    let sync = WiFiRecordingSync(store: store, card: card, wifi: wifi) { client, id, _ in
      client.connect(deviceID: id, host: "127.0.0.1", port: port, wifiOnly: false)
    }
    sync.cleanupEnabled = true
    sync.attach()
    let finished = expectation(description: "complete archive and clean the same card")
    sync.onArchiveChange = { finished.fulfill() }
    sync.start(id: "fixture-card")
    await fulfillment(of: [finished], timeout: 8)
    await sync.shutdown()
    XCTAssertEqual(card.deleteRequests, [item], sync.result)
    XCTAssertEqual(sync.outcome.saved, 0)
    XCTAssertEqual(sync.outcome.copies, "已删除 1 段卡内副本。")
    XCTAssertEqual(sync.pendingCleanup, 0)
    let archived = try await store.load()
    XCTAssertEqual(archived.map(\.id), [original.id])
    peer.waitUntilExit()
    XCTAssertEqual(peer.terminationStatus, 0)
  }

  @MainActor func testCleanupRequiresAnIntactArchiveAndCardReadback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ArchiveStore(root: root)
    let card = TestBluetooth()
    let bytes = try Data(contentsOf: wifiFixture("silence.bin"))
    let item = try RecordingEntry(
      [0] + Array("20261116123456".utf8) + Wire.beBytes(UInt64(bytes.count)))
    let sink = try DownloadStore(root: store.wifiInbox).begin(
      device: "fixture-card", file: item, resume: false)
    _ = try sink.accept(Array(bytes))
    _ = try sink.accept([2])
    let original = try await store.archiveWiFiFile(sink.destination)
    let archived = root.appendingPathComponent(original.folder).appendingPathComponent("device.bin")
    var corrupt = bytes
    corrupt[0] ^= 1
    try corrupt.write(to: archived)
    card.cleanupFiles = [item]
    let cleanup = WiFiCardCleanup(card: card, store: store)
    card.onWiFiState = { [weak cleanup] in cleanup?.accept(Packet(5, [$0])) }
    card.onWiFiFilePacket = { [weak cleanup] in cleanup?.accept($0) }
    do {
      try await cleanup.remove([(item, original)], from: "fixture-card") { _ in }
      XCTFail("A corrupted local original must prevent cleanup.")
    } catch {
      XCTAssertTrue(card.deleteRequests.isEmpty)
      XCTAssertEqual(card.cleanupFiles, [item])
    }
    try bytes.write(to: archived)
    card.removesRequestedFiles = false
    do {
      try await cleanup.remove([(item, original)], from: "fixture-card") { _ in }
      XCTFail("A delete reply alone does not prove the recording is gone.")
    } catch {
      XCTAssertEqual(card.deleteRequests, [item])
      XCTAssertEqual(cleanup.removed, 0)
      XCTAssertEqual(card.cleanupFiles, [item])
    }
  }

  @MainActor func testSyncContinuesWhenCardDisconnectsBluetoothAfterListing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (peer, port) = try startPeer("sync")
    defer { if peer.isRunning { peer.terminate() } }

    let store = ArchiveStore(root: root)
    let card = TestBluetooth()
    card.reportsSocketReady = false
    let wifi = TestNetwork()
    let sync = WiFiRecordingSync(store: store, card: card, wifi: wifi) { client, id, _ in
      client.connect(deviceID: id, host: "127.0.0.1", port: port, wifiOnly: false)
    }
    sync.attach()
    // The card drops BLE between delivering the list and receiving the first download request.
    let listed = sync.$pending.first { $0 == 1 }.sink { _ in
      card.onWiFiLost?()
      XCTAssertTrue(card.holdReconnect)
    }
    defer { listed.cancel() }
    let complete = expectation(description: "archive the file after Bluetooth disconnects")
    sync.onArchiveChange = { complete.fulfill() }
    sync.start(id: "fixture-card")
    await fulfillment(of: [complete], timeout: 8)
    let records = try await store.load()
    XCTAssertEqual(records.count, 1, sync.result)
    XCTAssertEqual(sync.pending, 0)
    XCTAssertEqual(wifi.restores, 1)
    XCTAssertFalse(card.holdReconnect)
    await sync.shutdown()
    peer.waitUntilExit()
    XCTAssertEqual(peer.terminationStatus, 0)
  }

  @MainActor func testOneClickChecksIdleRestoresNetworkAndPublishesOnlyOnce() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ArchiveStore(root: root)
    let card = TestBluetooth()
    let wifi = TestNetwork()
    var port: UInt16 = 0
    let model = AppModel(libraryURL: root, makeWiFiSync: { archive in
      WiFiRecordingSync(store: archive, card: card, wifi: wifi) { client, id, _ in
        client.connect(deviceID: id, host: "127.0.0.1", port: port, wifiOnly: false)
      }
    })
    model.preferences.cleanCardAfterSync = false
    let sync = model.wifiSync
    model.card.onWiFiBound?("fixture-card", "FW925")
    let selected = try XCTUnwrap(model.recorderSyncTarget)
    XCTAssertEqual(model.recorderSidebarTitle, "录音卡")
    card.onRelease = { [unowned model] in
      XCTAssertEqual(model.recorderSidebarTitle, "FW925")
    }
    XCTAssertEqual(selected, .wifi("fixture-card"))
    model.syncRecorder(.wifi("other-card"))
    XCTAssertFalse(sync.busy)
    card.raw = 7
    let blocked = expectation(description: "require fresh idle state")
    sync.onArchiveChange = { blocked.fulfill() }
    model.syncRecorder(selected)
    await fulfillment(of: [blocked], timeout: 4)
    XCTAssertEqual(wifi.joins, 0)
    XCTAssertFalse(card.wifiBusy)
    card.raw = 0
    for scenario in ["sync", "repeat"] {
      let (peer, listeningPort) = try startPeer(scenario)
      defer { if peer.isRunning { peer.terminate() } }
      port = listeningPort
      let complete = expectation(description: scenario)
      sync.onArchiveChange = { complete.fulfill() }
      model.syncRecorder(selected)
      await fulfillment(of: [complete], timeout: 8)
      peer.waitUntilExit()
      XCTAssertEqual(peer.terminationStatus, 0)
      XCTAssertTrue(sync.result.contains(scenario == "sync" ? "新增 1 段" : "已有 1 段"), sync.result)
      XCTAssertEqual(sync.outcome.saved, scenario == "sync" ? 1 : 0)
      XCTAssertEqual(sync.outcome.copies, "卡内副本已保留。")
      XCTAssertTrue(sync.result.contains("测试网络已恢复"))
      let records = try await store.load()
      XCTAssertEqual(records.count, 1)
      XCTAssertEqual(records.first?.duration, 0.32)
      XCTAssertEqual(sync.pending, 0)
      XCTAssertEqual(model.recorderSidebarTitle, "录音卡")
      await sync.shutdown()
    }
    XCTAssertEqual(card.releases, 2)
    XCTAssertEqual(wifi.joins, 2)
    XCTAssertEqual(wifi.restores, 2)
  }
}
