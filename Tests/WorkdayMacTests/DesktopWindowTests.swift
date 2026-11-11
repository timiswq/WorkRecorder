import AppKit
import SwiftUI
import XCTest

@testable import WorkdayMac

final class DesktopWindowTests: XCTestCase {
  @MainActor func testPanelCannotBecomeKeyOrInterceptMouse() {
    _ = NSApplication.shared
    let panel = CaptionPanel()
    XCTAssertFalse(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
    XCTAssertTrue(panel.ignoresMouseEvents)
    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    XCTAssertFalse(panel.hidesOnDeactivate)
    panel.close()
  }

  func testPlacementStaysInSelectedSecondaryScreen() {
    let screen = CGRect(x: -1920, y: 140, width: 1920, height: 1055)
    let panel = CaptionPlacement.frame(in: screen)
    XCTAssertTrue(screen.contains(panel))
    XCTAssertEqual(panel.maxX, -16)
    XCTAssertEqual(panel.maxY, screen.maxY - 6)
    XCTAssertEqual(panel.width, 360)
    XCTAssertEqual(panel.height, 248)
  }

  @MainActor func testDifferentWidthCaptionsShareTheScreenRightInset() throws {
    _ = NSApplication.shared
    let screen = try XCTUnwrap(NSScreen.main).visibleFrame
    let panel = CaptionPanel()
    defer { panel.close() }
    let feed = CaptionFeedPresentation()
    feed.update([
      DesktopCaption(id: "short", text: "收到", isFinal: true),
      DesktopCaption(id: "long", text: "下午我们一起确认这段录音的效果。", isFinal: false),
    ], username: "发言", preview: false, animated: false)
    panel.contentView = NSHostingView(rootView: CaptionFeedView(presentation: feed))
    panel.setFrame(CaptionPlacement.frame(in: screen), display: false)

    let short = try XCTUnwrap(panel.anchor(for: "short"))
    let long = try XCTUnwrap(panel.anchor(for: "long"))
    XCTAssertLessThan(short.width, long.width)
    XCTAssertEqual(short.maxX, long.maxX, accuracy: 1)
    XCTAssertEqual(screen.maxX - long.maxX, 22, accuracy: 1)
  }

  func testFullScreenDistinguishesMaximizedWorkArea() {
    let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    XCTAssertTrue(CaptionPlacement.coversDisplay(window: display, display: display))
    XCTAssertFalse(
      CaptionPlacement.coversDisplay(
        window: CGRect(x: 0, y: 25, width: 1440, height: 830), display: display))
    XCTAssertFalse(
      CaptionPlacement.coversDisplay(
        window: CGRect(x: 1440, y: 0, width: 1440, height: 900), display: display))
  }

  @MainActor func testPreviewExpiresWithoutChangingFrontmostApplication() async throws {
    _ = NSApplication.shared
    let model = isolatedModel()
    model.preferences.captions.showInFullScreen = true
    // Do not start model services: no hardware, credentials, or cloud activity in this test.
    model.desktop.start(model: model)
    defer { model.desktop.stop() }
    let previousApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let keyWindow = NSApp.keyWindow
    model.desktop.preview(now: Date().addingTimeInterval(0.3 - CaptionPreview.duration))
    let panel = try XCTUnwrap(model.desktop.panel)
    XCTAssertTrue(panel.isVisible)
    XCTAssertFalse(panel.isKeyWindow)
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, previousApp)
    XCTAssertTrue(NSApp.keyWindow === keyWindow)
    try await Task.sleep(for: .milliseconds(1_200))
    XCTAssertFalse(panel.isVisible)
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, previousApp)
  }

  @MainActor func testPanelKeepsNewerRowsVisibleWhileOldestBubblesExit() async throws {
    _ = NSApplication.shared
    let model = isolatedModel()
    model.preferences.captions.showInFullScreen = true
    model.desktop.start(model: model)
    defer { model.desktop.stop() }
    let start = Date()
    let lines = (0..<4).map { index in
      LiveLine(id: "row-\(index)", segment: 0, sentence: index, text: "第\(index + 1)句", isFinal: true)
    }
    model.desktop.refresh(now: start, transcript: lines)
    let panel = try XCTUnwrap(model.desktop.panel)
    let host = try XCTUnwrap(panel.contentView as? NSHostingView<CaptionFeedView>)
    XCTAssertEqual(host.rootView.presentation.content.items.map(\.id), lines.map(\.id))
    for removed in 1...3 {
      model.desktop.refresh(now: start.addingTimeInterval(12 + Double(removed - 1) * 1.5))
      XCTAssertEqual(host.rootView.presentation.content.items.map(\.id), lines.dropFirst(removed).map(\.id))
      XCTAssertTrue(panel.isVisible)
      XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.01)
    }
    model.desktop.refresh(now: start.addingTimeInterval(16.5))
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertFalse(panel.isVisible)
  }

  @MainActor func testNativeMenuAndCaptionSnapshots() throws {
    guard ProcessInfo.processInfo.environment["WORKDAY_DESKTOP_SNAPSHOTS"] == "1" else { return }
    _ = NSApplication.shared
    let model = isolatedModel()
    model.preferences.captions.username = "青木"
    model.desktop.start(model: model)
    defer { model.desktop.stop() }
    for scheme in [ColorScheme.light, .dark] {
      let name = scheme == .dark ? "dark" : "light"
      let menu = NSHostingView(
        rootView: MenuBarPanel(model: model, desktop: model.desktop)
          .environment(\.colorScheme, scheme))
      menu.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      menu.setFrameSize(NSSize(width: 320, height: menu.fittingSize.height))
      try save(menu, named: "menu-\(name)")
      let settings = NSHostingView(
        rootView: DesktopCaptionSettings(model: model, desktop: model.desktop)
          .padding(20).background(Palette.background).environment(\.colorScheme, scheme))
      settings.appearance = menu.appearance
      settings.setFrameSize(NSSize(width: 720, height: settings.fittingSize.height))
      try save(settings, named: "caption-settings-\(name)")
      let presentation = CaptionFeedPresentation()
      presentation.update(
        CaptionPreview.items(at: 7), username: "青木", preview: false, animated: false)
      let caption = NSHostingView(
        rootView: CaptionFeedView(presentation: presentation)
          .background(Palette.background)
          .environment(\.colorScheme, scheme))
      caption.appearance = menu.appearance
      caption.setFrameSize(NSSize(width: 360, height: 248))
      try save(caption, named: "caption-\(name)")
      presentation.update(
        CaptionPreview.items(at: 0), username: "青木", preview: false, animated: false)
      try save(caption, named: "caption-single-\(name)")
      presentation.update(
        (0..<4).map {
          DesktopCaption(
            id: "long:\($0)",
            text: String(repeating: "先确认计划，", count: 9) + "最后检查这版的录音效果。",
            isFinal: true)
        }, username: "这是一个非常长的用户名用于确认布局", preview: false, animated: false)
      try save(caption, named: "caption-long-\(name)")
    }
  }

  @MainActor func testNewCaptionDuringFadeOutStaysVisible() async throws {
    _ = NSApplication.shared
    let model = isolatedModel()
    model.preferences.captions.showInFullScreen = true
    model.desktop.start(model: model)
    defer { model.desktop.stop() }
    model.desktop.preview()
    try await Task.sleep(for: .milliseconds(220))
    model.desktop.snooze()
    model.desktop.preview()
    // Frequent partial-result refreshes must not restart the fade-in each time.
    for _ in 0..<10 {
      model.desktop.refresh()
      try await Task.sleep(for: .milliseconds(30))
    }
    let panel = try XCTUnwrap(model.desktop.panel)
    XCTAssertTrue(panel.isVisible)
    XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.01)
    XCTAssertFalse(panel.isKeyWindow)
  }

  @MainActor func testPreviewUpdatesKeepTheSameHostingView() throws {
    _ = NSApplication.shared
    let model = isolatedModel()
    model.preferences.captions.showInFullScreen = true
    model.desktop.start(model: model)
    defer { model.desktop.stop() }
    let start = Date()
    model.desktop.preview(now: start)
    let panel = try XCTUnwrap(model.desktop.panel)
    let host = panel.contentView
    for elapsed in [2.0, 4.0, 7.0, 13.0] {
      model.desktop.refresh(now: start.addingTimeInterval(elapsed))
      XCTAssertTrue(panel.contentView === host)
    }
  }

  @MainActor func testChangingUsernameUpdatesExistingBubbles() {
    let presentation = CaptionFeedPresentation()
    let lines = CaptionPreview.items(at: 7)
    presentation.update(lines, username: "系统用户", preview: false, animated: false)
    presentation.update(lines, username: "青木", preview: false, animated: false)
    XCTAssertEqual(presentation.content.username, "青木")
    XCTAssertEqual(presentation.content.items, lines)
    presentation.update(lines, username: "青木", preview: true, animated: false)
    XCTAssertEqual(presentation.content.username, "青木")
    XCTAssertTrue(presentation.content.preview)
  }

  @MainActor private func isolatedModel() -> AppModel {
    let root = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    return AppModel(
      libraryURL: URL(fileURLWithPath: root).appendingPathComponent("desktop-no-services"))
  }

  @MainActor private func save(_ view: NSView, named name: String) throws {
    let root = try XCTUnwrap(ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"])
    view.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: URL(fileURLWithPath: root).appendingPathComponent("\(name).png"))
  }
}
