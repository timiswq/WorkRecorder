import Foundation
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class SyncCoordinatorTests: XCTestCase {
  @MainActor func testNewFilesDuringCopyAndRestartDoNotLoseOrDuplicateRecordings() async throws {
    let root = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
        ?? NSTemporaryDirectory()
    ).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ArchiveStore(root: root.appendingPathComponent("Library"))
    let sync = SyncCoordinator(store: store)
    try await sync.load()
    var files: [SyncFile] = []
    for i in 0..<3 {
      let url = root.appendingPathComponent(String(format: "note20261110-%02d0000.wav", 9 + i))
      try AudioFiles.wav(pcm: Data(repeating: UInt8(i), count: 32000)).write(to: url)
      let stamp = try FileStamp(url)
      files.append(
        SyncFile(sourceID: "usb:test", path: url.path, size: stamp.size, modified: stamp.modified))
    }
    sync.offer([files[0]])
    sync.offer(Array(files.dropFirst()))
    for _ in 0..<1000 {
      if !sync.isBusy { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(sync.isBusy)
    let records = try await store.load()
    XCTAssertEqual(records.count, 3)
    XCTAssertEqual(Set(records.map(\.day)), ["2026-11-10"])
    XCTAssertEqual(sync.ledger.entries.filter { $0.recordingID != nil }.count, 3)
    let restarted = SyncCoordinator(store: store)
    try await restarted.load()
    restarted.offer(files)
    for _ in 0..<1000 {
      if !restarted.isBusy { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let reloaded = try await store.load()
    XCTAssertEqual(reloaded.count, 3)
    XCTAssertEqual(restarted.completedThisRun, 0)
  }
  @MainActor func testFailedFileDoesNotBlockOtherFilesAndCanBeRetried() async throws {
    let root = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
        ?? NSTemporaryDirectory()
    ).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root.appendingPathComponent("Library"))
    let store = model.store
    let sync = model.sync
    let volume = USBVolume(id: "usb:test", url: root, name: "测试卡")
    model.usb.volumes = [volume]
    var copying: DesktopStatus?
    sync.onArchived = { [weak model] _ in
      guard let model else { return }
      copying = model.deviceStatus(at: Date())
      if model.sync.error != nil {
        let action = model.statusPresentation(at: Date()).attention.first?.action
        XCTAssertEqual(action, .sync(.retry), "其他文件保存期间仍能处理失败项")
        if let action { model.performStatusAction(action) }
        XCTAssertNil(model.sync.error, "点击重试应真正提交重试请求")
      }
    }
    XCTAssertEqual(model.deviceStatus(at: Date()).title, "USB 文件连接")
    try await sync.load()
    let broken = root.appendingPathComponent("note20261110-090000.wav")
    let good = root.appendingPathComponent("note20261110-110000.wav")
    let wav = AudioFiles.wav(pcm: Data(repeating: 0, count: 32000))
    try wav.prefix(50).write(to: broken)
    try wav.write(to: good)
    func candidate(_ url: URL) throws -> SyncFile {
      let stamp = try FileStamp(url)
      return SyncFile(
        sourceID: "usb:test", path: url.path, size: stamp.size, modified: stamp.modified)
    }
    sync.offer(try [candidate(broken), candidate(good)])
    for _ in 0..<1000 {
      if !sync.isBusy { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let first = try await store.load()
    XCTAssertEqual(first.count, 1)
    XCTAssertEqual(copying?.kind, .usb)
    XCTAssertEqual(copying?.warning, false)
    XCTAssertEqual(model.deviceStatus(at: Date()).title, "USB 文件连接")
    XCTAssertFalse(model.deviceStatus(at: Date()).warning)
    XCTAssertEqual(model.statusPresentation(at: Date()).attention.first?.action, .sync(.retry))
    model.usb.volumes = [USBVolume(id: "usb:other", url: root, name: "另一张卡")]
    XCTAssertFalse(model.deviceStatus(at: Date()).warning)
    model.usb.volumes = [volume]
    XCTAssertTrue(sync.ledger.entries.contains { $0.error != nil && $0.recordingID == nil })
    try wav.write(to: broken)
    sync.offer([try candidate(broken)])
    for _ in 0..<1000 {
      if !sync.isBusy { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let second = try await store.load()
    XCTAssertEqual(second.count, 2)
    XCTAssertEqual(model.deviceStatus(at: Date()).title, "USB 文件连接")
    XCTAssertEqual(sync.ledger.entries.filter { $0.recordingID != nil }.count, 2)
  }
  func testUSBScanKeepsGoodFilesAndReportsUnsupportedOrUnfinishedOnes() throws {
    let root = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
        ?? NSTemporaryDirectory()
    ).appendingPathComponent(UUID().uuidString)
    let directory = root.appendingPathComponent("record")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try AudioFiles.wav(pcm: Data(repeating: 0, count: 32000)).write(
      to: directory.appendingPathComponent("note20261110-090000.wav"))
    try Data(repeating: 1, count: 2000).write(
      to: directory.appendingPathComponent("note20261110-090000.opus"))
    try Data(repeating: 1, count: 2000).write(
      to: directory.appendingPathComponent("note20261110-100000.opus"))
    try Data().write(to: directory.appendingPathComponent("note20261110-110000.wav"))
    let uuid = try XCTUnwrap(root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
    let result = USBMonitor.files(USBVolume(id: "usb:" + uuid, url: root, name: "test"))
    XCTAssertEqual(result.files.count, 2)
    XCTAssertEqual(result.files.filter(\.supported).count, 1)
    XCTAssertEqual(result.files.first?.companionSize, 2000)
    XCTAssertEqual(result.errors.count, 1)
  }

}
