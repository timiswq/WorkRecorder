import Foundation
import QS668Core
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class InventoryPresentationTests: XCTestCase {
  private func frame(_ bytes: [UInt8]) -> Frame {
    var parser = FrameParser()
    return parser.push(Wire.frame(bytes, seq: 0))[0]
  }
  @MainActor func testConfirmedSavedUSBRecordingReturnsToPendingCount() {
    let model = AppModel(
      libraryURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
        UUID().uuidString))
    let name = "note20261110-090000.wav"
    model.preferences.boundID = "test-card"
    model.catalog.bindings["ble:test-card"] = "usb:test-card"
    model.usb.volumes = [
      USBVolume(id: "usb:test-card", url: URL(fileURLWithPath: "/not-a-device"), name: "Fixture")
    ]
    model.catalog.snapshots["usb:test-card"] = DeviceInventory(
      sourceID: "usb:test-card", entries: [InventoryEntry(name: name, duration: 10, bytes: 100)],
      observedAt: Date(), complete: true)
    model.card.state.connected = true
    model.card.state.apply(frame([3, 20, 1]))
    model.card.state.apply(frame([3, 24] + Array(name.utf8)))
    model.card.state.disconnect()
    model.usb.excludedStems = [InventoryEntry.stem(name)]
    XCTAssertEqual(model.pendingCount.total, 0)
    // User confirms the hardware has saved. No fresh BLE event is possible while USB is mounted.
    model.usb.excludedStems = []
    XCTAssertEqual(model.pendingCount.total, 1)
  }
  @MainActor func testCardActionFollowsUSBModeAndInventoryEvidence() {
    let model = AppModel(
      libraryURL: URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString))
    XCTAssertNil(model.cardSync.action)
    XCTAssertTrue(model.cardSync.instruction.contains("自动同步"))
    model.preferences.autoSync = false
    XCTAssertTrue(model.cardSync.instruction.contains("立即同步"))
    XCTAssertNil(model.cardSync.action)
    let volume = USBVolume(id: "usb:fixture", url: model.libraryURL, name: "Fixture")
    model.usb.volumes = [volume]
    XCTAssertEqual(model.cardSync.title, "正在读取录音卡")
    var inventory = DeviceInventory(
      sourceID: volume.id, entries: [], observedAt: Date(), complete: true)
    model.catalog.snapshots[volume.id] = inventory
    XCTAssertEqual(model.cardSync.title, "卡内暂无已保存的录音")
    let name = "note20261110-090000.wav"
    inventory.entries = [InventoryEntry(name: name, duration: 10, bytes: 100)]
    model.catalog.snapshots[volume.id] = inventory
    XCTAssertEqual(model.cardSync.action, .start)
    XCTAssertEqual(model.cardSync.title, "1 段待同步")
    model.usb.excludedStems = [InventoryEntry.stem(name)]
    XCTAssertEqual(model.cardSync.action, .confirm)
    model.usb.excludedStems = []
    model.usb.activeFilenameUnknown = true
    XCTAssertEqual(model.cardSync.action, .confirm)
    model.usb.activeFilenameUnknown = false
    model.usb.issue = "无法读取文件"
    XCTAssertEqual(model.cardSync.action, .retry)
    model.usb.issue = nil
    model.preferences.autoSync = true
    XCTAssertNil(model.cardSync.action)
    inventory.entries = [
      InventoryEntry(
        name: "note20261110-090000.opus", duration: 10,
        bytes: 100, isOpusOnly: true)
    ]
    model.catalog.snapshots[volume.id] = inventory
    XCTAssertTrue(model.cardSync.instruction.contains("OPUS"))
    model.usb.volumes = []
    XCTAssertTrue(model.cardSync.title.hasPrefix("上次发现"))
  }

  @MainActor func testManualRequestWaitsForStableFilesAndEndsAfterCopyOrDisconnect() async throws {
    let base = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    let root = URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString)
    let card = root.appendingPathComponent("Card")
    let directory = card.appendingPathComponent("record")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let uuid = try XCTUnwrap(card.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
    let volume = USBVolume(id: "usb:" + uuid, url: card, name: "Fixture")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root.appendingPathComponent("Library"))
    try await model.sync.load()
    model.preferences.autoSync = false
    model.usb.volumes = [volume]
    func scan(ready: Bool) {
      let files = USBMonitor.files(volume).files
      let inventory = DeviceInventory(
        sourceID: volume.id,
        entries: files.map { InventoryEntry(name: $0.name, duration: nil, bytes: $0.size) },
        observedAt: Date(), complete: true)
      model.usb.onScan?(USBScan(files: files, ready: ready ? files : [], inventories: [inventory]))
    }
    func settle() async throws {
      for _ in 0..<500 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
      XCTAssertFalse(model.isBusy)
    }
    let wav = AudioFiles.wav(pcm: Data(repeating: 0, count: 32_000))
    try wav.write(to: directory.appendingPathComponent("note20261110-090000.wav"))
    scan(ready: true)
    XCTAssertEqual(model.cardSync.action, .start)
    XCTAssertTrue(model.sync.ledger.entries.isEmpty)
    model.performCardSync(.start)
    scan(ready: false)
    XCTAssertNil(model.cardSync.action)
    XCTAssertFalse(model.preferences.autoSync)
    scan(ready: true)
    try await settle()
    scan(ready: true)
    XCTAssertEqual(model.recordings.count, 1)
    XCTAssertEqual(model.cardSync.title, "原件已保存在 Mac")
    XCTAssertTrue(model.manualSyncVolumes.isEmpty)

    try wav.write(to: directory.appendingPathComponent("note20261111-090000.wav"))
    scan(ready: true)
    XCTAssertEqual(model.cardSync.action, .start)
    model.performCardSync(.start)
    model.usb.volumes = []
    model.usb.onScan?(USBScan(files: [], ready: [], inventories: []))
    model.usb.volumes = [volume]
    scan(ready: true)
    XCTAssertEqual(model.cardSync.action, .start)
    XCTAssertEqual(model.sync.ledger.entries.count, 1)
    model.preferences.autoSync = true
    scan(ready: true)
    try await settle()
    XCTAssertEqual(model.recordings.count, 2)
    scan(ready: true)
    XCTAssertTrue(USBMonitor.files(volume).files.isEmpty)
    XCTAssertEqual(model.cardSync.title, "原件已保存在 Mac")

    let localFile = root.appendingPathComponent("本地音频.wav")
    try wav.write(to: localFile)
    let archive = model.sync.onArchived
    var sawImport = false
    model.sync.onArchived = { recording in
      sawImport = true
      XCTAssertEqual(model.importLabel, "正在导入 本地音频.wav")
      XCTAssertNil(model.sync.usbLabel)
      XCTAssertEqual(model.cardSync.title, "原件已保存在 Mac")
      await archive?(recording)
    }
    model.importFiles([(localFile, "manual")])
    try await settle()
    XCTAssertTrue(FileManager.default.fileExists(atPath: localFile.path))
    XCTAssertTrue(sawImport)
    await model.shutdown()
  }

  @MainActor func testUnrelatedCachedCardIsExcludedFromCurrentRecordingInventory() {
    let model = AppModel(
      libraryURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
        UUID().uuidString))
    let name = "note20261110-090000.wav"
    model.preferences.boundID = "bound-card"
    model.catalog.snapshots["usb:other-card"] = DeviceInventory(
      sourceID: "usb:other-card", entries: [InventoryEntry(name: name, duration: 10, bytes: 100)],
      observedAt: Date(), complete: true)
    model.card.state.connected = true
    model.card.state.apply(frame([3, 20, 1]))
    model.card.state.apply(frame([3, 24] + Array(name.utf8)))
    XCTAssertEqual(model.pendingCount.total, 0)
  }
}
