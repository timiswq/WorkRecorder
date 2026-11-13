import AppKit
import QS668Core
import XCTest

@testable import WorkdayCore
@testable import WorkdayMac

final class DockBadgeTests: XCTestCase {
  @MainActor func testCachedPendingOriginalAppearsWithoutAWindowAndClearsAfterSaving() async throws
  {
    _ = NSApplication.shared
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root)
    let tile = NSDockTile()
    tile.badgeLabel = "旧数量"
    let controller = DockBadgeController(model: model, tile: tile)
    defer { controller.stop() }
    XCTAssertNil(tile.badgeLabel, "启动时应清理上一轮角标")
    let name = "note20261113-155022.wav"
    model.catalog.snapshots["usb:fixture"] = .init(
      sourceID: "usb:fixture",
      entries: [
        .init(name: name, duration: 60, bytes: 200)
      ], observedAt: Date().addingTimeInterval(-3600), complete: true)
    try await expect(tile, label: "1")
    model.showLiveCaptions()
    model.processingID = "organizing-another-recording"
    try await expect(tile, label: "1")
    model.recordings = [
      Recording(
        id: "r", startedAt: nil, importedAt: Date(), originalName: name,
        folder: "Records/r", originalFile: "original.wav", sha256: "hash", bytes: 200,
        duration: 60, sourceID: "usb:fixture")
    ]
    try await expect(tile, label: nil)
    await model.shutdown()
  }

  @MainActor func testRecordingProcessingAndContentUpdatesNeverBecomeDockBadges() async throws {
    _ = NSApplication.shared
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root)
    let tile = NSDockTile()
    let controller = DockBadgeController(model: model, tile: tile)
    defer { controller.stop() }
    model.processingID = "r"
    model.recordDayUpdate(DaySummary(day: "2026-11-13", overview: "有更新", recordingIDs: []))
    model.card.state.connected = true
    var parser = FrameParser()
    model.card.state.apply(parser.push(Wire.frame([3, 20, 1], seq: 0))[0])
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertNil(tile.badgeLabel)
    await model.shutdown()
  }

  @MainActor func testIncompleteCountSaveConfirmationAndStopStayInSyncWithSidebar() async throws {
    _ = NSApplication.shared
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root)
    let source = "usb:fixture"
    model.usb.volumes = [.init(id: source, url: root, name: "Fixture")]
    model.catalog.snapshots[source] = .init(
      sourceID: source,
      entries: [
        .init(name: "note20261113-090000.wav", duration: 1, bytes: 100),
        .init(name: "note20261113-100000.wav", duration: 1, bytes: 100),
      ], observedAt: Date(), complete: false)
    let tile = NSDockTile()
    let controller = DockBadgeController(model: model, tile: tile)
    defer { controller.stop() }
    XCTAssertEqual(tile.badgeLabel, "≥2")
    model.usb.activeFilenameUnknown = true
    try await expect(tile, label: nil)
    model.usb.activeFilenameUnknown = false
    try await expect(tile, label: "≥2")
    model.catalog.snapshots[source]?.complete = true
    try await expect(tile, label: "2")
    controller.stop()
    XCTAssertNil(tile.badgeLabel)
    model.catalog.snapshots[source]?.entries.removeLast()
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertNil(tile.badgeLabel, "停止观察后不能重新挂回旧角标")
    await model.shutdown()
  }

  private func makeRoot() -> URL {
    URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
        ?? NSTemporaryDirectory()
    )
    .appendingPathComponent("dock-" + UUID().uuidString)
  }

  @MainActor private func expect(
    _ tile: NSDockTile, label: String?, file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    for _ in 0..<100 {
      if tile.badgeLabel == label { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(tile.badgeLabel, label, file: file, line: line)
  }
}
