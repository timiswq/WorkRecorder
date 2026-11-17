import Foundation
import QS668Core
import WorkdayCore
import XCTest

@testable import WorkdayMac

@MainActor final class USBSelectionTests: XCTestCase {
  @MainActor private struct Pair {
    let root: URL
    let a: USBVolume
    let b: USBVolume
    let filename = "note20261117-090000.wav"
    let model: AppModel

    init(useRealIDForB: Bool = false) async throws {
      let env = ProcessInfo.processInfo.environment
      let run = UUID().uuidString
      root = URL(fileURLWithPath: env["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()).appendingPathComponent(run)
      func makeVolume(at folder: URL, sample: UInt8) throws -> USBVolume {
        let record = folder.appendingPathComponent("record")
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: true)
        let wav = record.appendingPathComponent("note20261117-090000.wav")
        try AudioFiles.wav(pcm: Data(repeating: sample, count: 32_000)).write(to: wav)
        let uuid = try XCTUnwrap(folder.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        return USBVolume(id: "usb:" + uuid, url: folder, name: "Recorder")
      }
      // With a supplied pair, exercise two mounted filesystems with distinct real UUIDs.
      // Ordinary test runs use two directories and a simulated identity for the second mount.
      let base = env["WORKDAY_TEST_USB_PAIR"].map { URL(fileURLWithPath: $0) }
      let left = base?.appendingPathComponent("A/" + run) ?? root.appendingPathComponent("A")
      let right = base?.appendingPathComponent("B/" + run) ?? root.appendingPathComponent("B")
      let first = try makeVolume(at: left, sample: 1)
      let other = try makeVolume(at: right, sample: 2)
      if base != nil { XCTAssertNotEqual(first.id, other.id) }
      let shared = first.id == other.id
      a = shared && useRealIDForB ? USBVolume(id: "usb:simulated-A", url: left, name: first.name) : first
      b = shared && !useRealIDForB ? USBVolume(id: "usb:simulated-B", url: right, name: other.name) : other
      model = AppModel(libraryURL: root.appendingPathComponent("Library"))
      try await model.sync.load()
      model.preferences.boundID = "card-A"
      model.catalog.bindings["ble:card-A"] = a.id
    }

    func file(_ volume: USBVolume) -> URL { volume.url.appendingPathComponent("record/" + filename) }

    func plug(_ volumes: [USBVolume]) async {
      let now = Date()
      await model.usb.scanMountedVolumes(volumes, at: now)
      await model.usb.scanMountedVolumes(volumes, at: now.addingTimeInterval(7))
      for _ in 0..<500 where model.isBusy { try? await Task.sleep(for: .milliseconds(10)) }
      XCTAssertFalse(model.isBusy)
    }

    func finish() async {
      await model.shutdown()
      for url in [a.url, b.url, root] { try? FileManager.default.removeItem(at: url) }
    }
  }

  func testBrowsingPreservesBluetoothAndOnlyExplicitSelectionActivatesDisk() async throws {
    let pair = try await Pair(useRealIDForB: true)
    let model = pair.model
    model.preferences.autoSync = false
    model.card.name = "FW925"
    model.card.state.connected = true
    model.card.onWiFiBound?("wifi-A", "FW925")
    model.card.receiveWiFiState(0, battery: 64)
    let oldTarget = try XCTUnwrap(model.recorderSyncTarget)
    XCTAssertEqual(oldTarget, .wifi("wifi-A"))
    model.card.receiveWiFiState(1, battery: 64)
    await pair.plug([pair.b])
    XCTAssertNil(model.recorderSyncTarget)
    var disconnects = 0
    model.card.onStreamReset = { if $0 == .disconnected { disconnects += 1 } }
    model.showRecorderPicker()
    model.showsRecorderPicker = false
    XCTAssertEqual(disconnects, 0)
    XCTAssertEqual(model.deviceStatus(at: Date()).deviceName, "FW925")
    XCTAssertNil(model.recorderSyncTarget)
    model.card.receiveWiFiState(0, battery: 64)
    XCTAssertEqual(model.recorderSyncTarget, oldTarget)
    model.chooseRecorder(pair.a) // Missing disk cannot disconnect the current card.
    XCTAssertEqual(disconnects, 0)
    model.chooseRecorder(pair.b)
    XCTAssertEqual(disconnects, 1)
    XCTAssertEqual(model.usb.volumes, [pair.b])
    for _ in 0..<200 where model.sync.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    let target = try XCTUnwrap(model.recorderSyncTarget)
    XCTAssertEqual(target, .usb(pair.b.id))
    let status = model.deviceStatus(at: Date())
    XCTAssertEqual(status.namedTitle, "Recorder · USB 已连接")
    XCTAssertNil(status.battery)
    model.syncRecorder(oldTarget)
    model.syncRecorder(.usb(pair.a.id))
    XCTAssertTrue(model.manualSyncVolumes.isEmpty)
    model.usb.activeFilenameUnknown = true
    model.syncRecorder(target)
    XCTAssertTrue(model.manualSyncVolumes.isEmpty)
    model.usb.activeFilenameUnknown = false
    model.syncRecorder(target)
    XCTAssertEqual(model.manualSyncVolumes, [pair.b.id])
    await pair.plug([])
    XCTAssertEqual(model.deviceStatus(at: Date()).namedTitle, "Recorder · 未连接")
    XCTAssertNil(model.recorderSyncTarget)
    XCTAssertNil(model.statusPresentation(at: Date()).hardwareAction)
    let saved = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(model.preferences))
    XCTAssertEqual(saved.usbOnlyVolumeName, pair.b.name)
    await pair.finish()
  }

  func testBluetoothARecordingIgnoresUSBFromB() async throws {
    let pair = try await Pair()
    let model = pair.model
    model.card.state.connected = true
    model.card.onBound?("card-A", "Recorder")
    var parser = FrameParser()
    model.card.state.apply(parser.push(Wire.frame([3, 20, 1], seq: 0))[0])
    model.receiveInventory(.init(sourceID: "ble:card-A", entries: [
      .init(name: "note20261116-090000.wav", duration: 1, bytes: 100)
    ], observedAt: Date(), complete: true))
    let originalB = try Data(contentsOf: pair.file(pair.b))
    var disconnects = 0
    model.card.onStreamReset = { _ in disconnects += 1 }
    await pair.plug([pair.b])
    model.retrySync()
    var audio: [Data] = []
    model.card.onAudio = { audio.append($0) }
    model.card.receive(parser.push(Wire.frame([1, 1, 5, 6], seq: 1))[0], channel: "AE22")
    XCTAssertEqual(audio, [Data([5, 6])])
    XCTAssertEqual(model.pendingSyncBadge, 1)
    model.selectUSB(pair.b, associateWithBoundCard: false)
    XCTAssertEqual(model.deviceStatus(at: Date()).kind, .recording)
    XCTAssertTrue(model.card.state.connected)
    XCTAssertEqual(disconnects, 0)
    XCTAssertEqual(model.preferences.selectedRecorderID, "card-A")
    XCTAssertTrue(model.usb.volumes.isEmpty)
    XCTAssertNil(model.catalog.snapshots[pair.b.id])
    XCTAssertTrue(model.sync.ledger.entries.isEmpty)
    XCTAssertEqual(try Data(contentsOf: pair.file(pair.b)), originalB)
    await pair.finish()
  }

  func testNoBluetoothAcceptsUSBFromAAndImportsOnlyA() async throws {
    let pair = try await Pair()
    let model = pair.model
    XCTAssertFalse(model.card.state.connected)
    let hashA = try Files.hash(pair.file(pair.a))
    let hashB = try Files.hash(pair.file(pair.b))
    await pair.plug([pair.a])
    XCTAssertEqual(model.usb.volumes, [pair.a])
    XCTAssertEqual(model.recordings.map(\.sourceID), [pair.a.id])
    XCTAssertEqual(model.recordings.first?.sha256, hashA)
    XCTAssertFalse(FileManager.default.fileExists(atPath: pair.file(pair.a).path))
    await pair.plug([pair.b, pair.a])
    XCTAssertEqual(model.usb.volumes, [pair.a])
    XCTAssertNil(model.catalog.snapshots[pair.b.id])
    XCTAssertEqual(model.sync.ledger.entries.map(\.file.sourceID), [pair.a.id])
    XCTAssertEqual(try Files.hash(pair.file(pair.b)), hashB)
    await pair.finish()
  }

  func testNoBluetoothIgnoresBUntilManuallySelected() async throws {
    let pair = try await Pair(useRealIDForB: true)
    let model = pair.model
    XCTAssertFalse(model.card.state.connected)
    let hashB = try Files.hash(pair.file(pair.b))
    await pair.plug([pair.b])
    model.retrySync()
    XCTAssertEqual(model.usb.detectedVolumes, [pair.b])
    XCTAssertTrue(model.usb.volumes.isEmpty)
    XCTAssertTrue(model.currentInventories.isEmpty)
    XCTAssertTrue(model.sync.ledger.entries.isEmpty)
    XCTAssertTrue(model.manualSyncVolumes.isEmpty)
    XCTAssertEqual(try Files.hash(pair.file(pair.b)), hashB)
    XCTAssertEqual(model.preferences.selectedRecorderID, "card-A")
    model.preferences.autoSync = false
    model.selectUSB(pair.b, associateWithBoundCard: false)
    XCTAssertEqual(model.usb.volumes, [pair.b])
    XCTAssertNil(model.preferences.selectedRecorderID)
    let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(model.preferences))
    XCTAssertEqual(restored.usbOnlyVolumeID, pair.b.id)
    await pair.plug([pair.a])
    XCTAssertTrue(model.usb.volumes.isEmpty)
    await pair.finish()
  }

  func testNewBluetoothSelectionReleasesPreviouslyActiveUSB() async throws {
    let pair = try await Pair()
    let model = pair.model
    model.preferences.autoSync = false
    await pair.plug([pair.a])
    XCTAssertEqual(model.usb.volumes, [pair.a])
    // Manual Bluetooth selection releases USB suspension before the new link becomes ready.
    model.card.suspendForUSB(false)
    model.card.state.connected = true
    model.card.onBound?("card-B", "Recorder")
    await pair.plug([pair.a])
    XCTAssertTrue(model.card.state.connected)
    XCTAssertEqual(model.preferences.selectedRecorderID, "card-B")
    XCTAssertTrue(model.usb.volumes.isEmpty)
    XCTAssertTrue(model.currentInventories.isEmpty)
    XCTAssertTrue(model.sync.ledger.entries.isEmpty)
    await pair.finish()
  }

  func testDuplicateVolumeIDBlocksBothAutomaticAndManualSync() async throws {
    let pair = try await Pair()
    let model = pair.model
    let duplicate = USBVolume(id: pair.a.id, url: pair.b.url, name: pair.b.name)
    await pair.plug([pair.a, duplicate])
    XCTAssertTrue(model.usb.volumes.isEmpty)
    XCTAssertFalse(model.chooseRecorder(pair.a))
    XCTAssertNil(model.recorderSyncTarget)
    XCTAssertTrue(model.sync.ledger.entries.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: pair.file(pair.a).path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: pair.file(pair.b).path))
    await pair.finish()
  }

  func testFirstUSBRequiresExplicitAssociationAndCannotStealAnotherCardsBinding() async throws {
    let pair = try await Pair()
    let model = pair.model
    model.catalog.bindings = ["ble:card-B": pair.b.id]
    model.preferences.autoSync = false
    await pair.plug([pair.b, pair.a])
    XCTAssertTrue(model.usb.volumes.isEmpty)
    model.selectUSB(pair.b, associateWithBoundCard: true)
    XCTAssertNil(model.catalog.bindings["ble:card-A"])
    model.selectUSB(pair.a, associateWithBoundCard: true)
    XCTAssertEqual(model.usb.volumes, [pair.a])
    XCTAssertEqual(model.catalog.bindings["ble:card-A"], pair.a.id)
    await pair.finish()
  }
}
