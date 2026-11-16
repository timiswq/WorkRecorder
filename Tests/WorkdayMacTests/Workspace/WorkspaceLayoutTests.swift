import AppKit
import SwiftUI
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class WorkspaceLayoutTests: XCTestCase {
  @MainActor func testUnifiedDayBarKeepsExcerptScopeAndSourceDate() async throws {
    let (root, model) = try await library()
    defer { model.player.stop(); try? FileManager.default.removeItem(at: root) }
    model.selectDay("2026-11-10")
    let record = try XCTUnwrap(model.dayRecordings.first)
    let url = model.libraryURL.appendingPathComponent(record.folder).appendingPathComponent(record.originalFile)
    model.player.load(url: url, id: "excerpt:fixture", recordingID: record.id,
      title: "逐句回听", position: 0.2, playbackRange: 0.2...0.8)
    model.selectDay("2026-11-09")
    XCTAssertEqual(model.reviewPlaybackDay, "2026-11-10")
    XCTAssertEqual(try XCTUnwrap(model.reviewPlaybackClock), 9 * 3600 + 0.2, accuracy: 0.01)
    model.seekReviewPlayback(9 * 3600 + 0.5, on: "2026-11-10")
    XCTAssertEqual(model.player.selectionID, "excerpt:fixture")
    XCTAssertEqual(model.player.playbackRange, 0.2...0.8)
    XCTAssertNil(model.player.route)
    model.seekReviewPlayback(12 * 3600, on: "2026-11-10")
    XCTAssertEqual(model.player.dayClock, 14 * 3600, accuracy: 0.01)
    XCTAssertEqual(model.selectedDay, "2026-11-09")
    XCTAssertFalse(model.player.playing)
  }

  @MainActor func testPlaybackSpeedAppliesAcrossDaySpans() async throws {
    let (root, model) = try await library()
    defer { model.player.stop(); try? FileManager.default.removeItem(at: root) }
    model.selectDay("2026-11-10")
    model.player.setExcerptRate(1.5)
    model.player.startDay(model.workspace.audio, recordings: model.dayRecordings,
      root: model.libraryURL, autoplay: false)
    XCTAssertEqual(model.player.playbackRate, 1.5)
    model.player.step(1)
    XCTAssertEqual(model.player.playbackRate, 1.5)
    let bounds = model.workspace.audio.navigationRange
    let first = try XCTUnwrap(model.workspace.audio.spans.first)
    XCTAssertEqual(model.workspace.audio.navigationIndex(clock: first.clockEnd, recordingID: first.recordingID), 0,
      "单段播至末尾时，下一段按钮仍应指向后续录音")
    XCTAssertLessThanOrEqual(bounds.lowerBound, 9 * 3600)
    XCTAssertGreaterThanOrEqual(bounds.upperBound, 14 * 3600 + 1)
    XCTAssertGreaterThanOrEqual(bounds.upperBound - bounds.lowerBound, 1800)
  }

  @MainActor func testCompactPlaybackProgressSkipsGapsWithoutChangingBrowsingDay() async throws {
    let (root, model) = try await library()
    defer {
      model.player.stop()
      try? FileManager.default.removeItem(at: root)
    }
    model.selectDay("2026-11-10")
    let route = model.workspace.audio
    model.player.startDay(
      route, recordings: model.dayRecordings, root: model.libraryURL, autoplay: false)
    model.selectDay("2026-11-09")

    XCTAssertEqual(route.clock(atElapsed: 1), 14 * 3600)
    XCTAssertEqual(route.clock(atElapsed: -1), 9 * 3600)
    XCTAssertEqual(route.clock(atElapsed: 100), 14 * 3600 + 1)
    XCTAssertNil(route.clock(atElapsed: .nan))
    model.seekDayProgress(1.25)
    XCTAssertEqual(model.selectedDay, "2026-11-09")
    XCTAssertEqual(model.player.route?.day, "2026-11-10")
    XCTAssertEqual(model.player.dayClock, 14 * 3600 + 0.25, accuracy: 0.01)
    XCTAssertFalse(model.player.playing)

    model.seekDayAudio(9 * 3600 + 0.5, on: "2026-11-09")
    XCTAssertEqual(model.player.route?.day, "2026-11-09")
    XCTAssertEqual(model.player.dayClock, 9 * 3600 + 0.5, accuracy: 0.01)
    XCTAssertFalse(model.player.playing)
    model.selectDay("2026-11-10")
    model.playDay()  // The page header offers this explicit action while another day is loaded.
    XCTAssertEqual(model.player.route?.day, "2026-11-10")
    XCTAssertTrue(model.player.playing)
  }

  @MainActor func testPlaybackHeadingKeepsSourceDateWhenBrowsingAnotherDay() async throws {
    let (root, model) = try await library()
    defer {
      model.player.stop()
      try? FileManager.default.removeItem(at: root)
    }
    model.selectDay("2026-11-10")
    let record = try XCTUnwrap(model.dayRecordings.first)
    let url = model.libraryURL.appendingPathComponent(record.folder).appendingPathComponent(
      record.originalFile)
    model.player.load(url: url, id: record.id, recordingID: record.id, title: record.originalName)
    model.selectDay("2026-11-09")
    XCTAssertEqual(model.playbackHeading, "原件回听 · 2026-11-10")

    model.player.load(
      url: url, id: "excerpt:fixture", recordingID: record.id,
      title: "逐句回听", playbackRange: 0...0.5)
    XCTAssertEqual(model.playbackHeading, "逐句回听 · 2026-11-10")
    model.player.load(
      url: url, id: "excerpt:fixture", recordingID: record.id,
      title: "回听这段对话", playbackRange: 0...0.5)
    XCTAssertEqual(model.playbackHeading, "对话回听 · 2026-11-10")
  }

  @MainActor func testNativeResizablePanesAndMinimumWindowKeepSelectionWithoutTakingFocus()
    async throws
  {
    _ = NSApplication.shared
    let focus = BackgroundFocusProbe()
    defer { focus.stop() }
    let (root, model) = try await library()
    defer {
      model.player.stop()
      try? FileManager.default.removeItem(at: root)
    }
    model.selectDay("2026-11-10")
    let original = try XCTUnwrap(model.dayRecordings.first)
    model.selectedDetail = .original(original.id)
    let window = NSWindow(
      contentRect: NSRect(x: -16000, y: -16000, width: 1140, height: 760),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingController(rootView: RootView(model: model))
    window.contentViewController = host
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    func layout(_ width: CGFloat, _ height: CGFloat, name: String) async throws {
      window.setContentSize(NSSize(width: width, height: height))
      host.view.setFrameSize(NSSize(width: width, height: height))
      host.view.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(150))
      host.view.layoutSubtreeIfNeeded()
      if ProcessInfo.processInfo.environment["WORKDAY_LAYOUT_SNAPSHOTS"] == "1",
        let output = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
      {
        let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
          .write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
      }
      XCTAssertFalse(focus.activatedTestApplication)
    }
    try await layout(1140, 760, name: "layout-day-wide")
    func paneFrames() -> [NSRect] {
      views(host.view).compactMap { $0 as? NSScrollView }
        .map { $0.convert($0.bounds, to: host.view) }
        .filter { $0.height > 200 && $0.width > 250 }
        .sorted { $0.minX < $1.minX }
    }
    let left = try XCTUnwrap(paneFrames().first)
    XCTAssertGreaterThanOrEqual(paneFrames().count, 2)
    XCTAssertGreaterThanOrEqual(left.minY, 50, "列表应保留自己的日期页头")
    XCTAssertLessThan(paneFrames()[1].minY, 80,
      "详情从自身标题开始，不应再叠加列表日期页头的高度")
    let split = try XCTUnwrap(views(host.view).compactMap { $0 as? NSSplitView }.first)
    split.setPosition(split.subviews[0].frame.width + 70, ofDividerAt: 0)
    split.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(80))
    host.view.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(
      abs(try XCTUnwrap(paneFrames().first).width - left.width), 20,
      "原生分栏的位置变化应改变正文宽度，而不是只绘制一条分隔线")
    XCTAssertEqual(model.selectedDay, "2026-11-10")
    XCTAssertEqual(model.selectedDetail, .original(original.id))
    try await layout(1320, 820, name: "layout-day-resized")
    XCTAssertTrue(paneFrames().allSatisfy { $0.width >= 319 })
    try await layout(690, 510, name: "layout-day-minimum")
    XCTAssertEqual(model.selectedDetail, .original(original.id))
    model.showOriginals(for: model.selectedDay)
    model.libraryRecordingID = original.id
    try await layout(1140, 760, name: "layout-originals-wide")
    XCTAssertGreaterThanOrEqual(paneFrames().count, 2)
    try await layout(690, 510, name: "layout-originals-minimum")
    XCTAssertEqual(model.libraryRecordingID, original.id)
  }

  @MainActor private func library() async throws -> (URL, AppModel) {
    let base = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    let root = URL(fileURLWithPath: base).appendingPathComponent("layout-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(libraryURL: root.appendingPathComponent("Library"))
    for stamp in ["20261109-090000", "20261110-090000", "20261110-140000"] {
      let source = root.appendingPathComponent("note" + stamp + ".wav")
      try AudioFiles.wav(pcm: Data(repeating: 0, count: 32_000)).write(to: source)
      _ = try await model.store.importAudio(source, sourceID: "layout-fixture")
    }
    await model.reload()
    model.loading = false
    return (root, model)
  }
}
