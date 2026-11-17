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
      let peer = Process()
      let output = Pipe()
      peer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
      peer.arguments = [wifiFixture("tcp_peer.py").path, scenario]
      peer.standardOutput = output
      try peer.run()
      defer { if peer.isRunning { peer.terminate() } }
      let port = try XCTUnwrap(
        UInt16(
          String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
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
}

private final class TestBluetooth: WiFiSyncBluetooth {
  var preferredKind: RecorderKind = .wifi
  var boundID: String? = "fixture-card"
  var wifiBusy = false, holdReconnect = false
  var onWiFiState: ((UInt8) -> Void)?
  var onHotspot: ((HotspotCredentials) -> Void)?
  var onSocket: (() -> Void)?
  var onWiFiLost: (() -> Void)?
  var raw: UInt8 = 0
  var releases = 0
  var onRelease: () -> Void = {}
  func queryWiFiState() { onWiFiState?(raw) }
  func openWiFiHotspot(for id: String) {
    XCTAssertEqual(boundID, id)
    onSocket?()
    onHotspot?(try! HotspotCredentials(Array("Test_AP00112345678".utf8)))
  }
  func releaseForWiFi() {
    releases += 1
    onRelease()
    onWiFiLost?()
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
      let peer = Process()
      let output = Pipe()
      peer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
      peer.arguments = [wifiFixture("tcp_peer.py").path, scenario]
      peer.standardOutput = output
      try peer.run()
      defer { if peer.isRunning { peer.terminate() } }
      port = try XCTUnwrap(
        UInt16(
          String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
      let complete = expectation(description: scenario)
      sync.onArchiveChange = { complete.fulfill() }
      model.syncRecorder(selected)
      await fulfillment(of: [complete], timeout: 8)
      peer.waitUntilExit()
      XCTAssertEqual(peer.terminationStatus, 0)
      XCTAssertTrue(sync.result.contains(scenario == "sync" ? "新增 1 段" : "已有 1 段"), sync.result)
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
