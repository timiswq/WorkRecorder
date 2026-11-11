import AppKit
import QS668Core
import SwiftUI
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class WorkspaceWindowTests: XCTestCase {
  @MainActor func testScrollObserverOnlyTracksItsOwnLiveScrolling() {
    _ = NSApplication.shared
    let scroll = NSScrollView()
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 1000))
    scroll.documentView = content
    let observer = ScrollGestureView()
    content.addSubview(observer)
    var began = 0
    var ended = 0
    observer.onBegin = { began += 1 }
    observer.onEnd = { ended += 1 }
    observer.attach()
    NotificationCenter.default.post(
      name: NSScrollView.willStartLiveScrollNotification, object: NSScrollView())
    XCTAssertEqual(began, 0)
    NotificationCenter.default.post(
      name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    XCTAssertEqual(began, 1)
    XCTAssertEqual(ended, 1)
    observer.detach()
    NotificationCenter.default.post(
      name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    XCTAssertEqual(began, 1)
  }

  @MainActor func testMainWindowNativeFixtures() async throws {
    guard ProcessInfo.processInfo.environment["WORKDAY_WORKSPACE_SNAPSHOTS"] == "1",
      let library = ProcessInfo.processInfo.environment["WORKDAY_FIXTURE_LIBRARY"],
      let output = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
    else { throw XCTSkip("按需执行原生工作区隔离样张与滚动验证") }
    _ = NSApplication.shared
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let stream = WorkspaceLiveStream()
    let live = LivePreview(makeStream: { _ in stream })
    let model = AppModel(libraryURL: URL(fileURLWithPath: library), live: live)
    await model.reload()
    model.loading = false
    model.preferences.captions.username = "示例用户"
    model.selectDay("2026-11-10")
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1140, height: 760),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.title = "工作留声 · 隔离验证"
    let host = NSHostingController(rootView: RootView(model: model))
    window.contentViewController = host
    defer {
      window.close()
      live.reset()
    }

    func capture(
      _ name: String, _ width: CGFloat = 1140, _ height: CGFloat = 760, dark: Bool = false
    ) async throws {
      model.preferences.theme = dark ? "dark" : "light"
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      window.setContentSize(NSSize(width: width, height: height))
      host.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
      host.view.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(220))
      host.view.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
      host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        .write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
    }
    try await capture("workspace-day-light")
    try await capture("workspace-day-narrow", 900, 640)
    if let clip = model.dayConversations.first {
      model.selectConversation(clip)
      try await capture("workspace-detail-wide", 1320, 820)
      try await capture("workspace-detail-narrow", 900, 640)
      model.selectedDetail = nil
    }
    try await capture("workspace-day-dark", dark: true)
    model.showToday()
    try await capture("workspace-today-ready")
    let recordings = model.recordings
    model.recordings = []
    try await capture("workspace-today-empty")
    model.area = .library
    model.libraryTab = .device
    let volume = USBVolume(id: "usb:fixture", url: model.libraryURL, name: "同步测试卡")
    let entries = (1...9).map {
      InventoryEntry(name: String(format: "note20261110-%02d0000.wav", $0), duration: 10, bytes: 100)
    }
    model.catalog.snapshots[volume.id] = DeviceInventory(
      sourceID: volume.id, entries: entries, observedAt: Date(), complete: true)
    model.usb.volumes = [volume]
    model.preferences.autoSync = false
    try await capture("workspace-sync-manual", 900, 640)
    model.preferences.autoSync = true
    model.usb.volumes = []
    model.preferences.boundID = "fixture"
    model.card.state.connected = true
    var parser = FrameParser()
    model.card.state.apply(try XCTUnwrap(parser.push(Wire.frame([3, 20, 2], seq: 1)).first))
    model.catalog.snapshots["ble:fixture"] = DeviceInventory(
      sourceID: "ble:fixture", entries: entries, observedAt: Date(), complete: true)
    try await capture("workspace-sync-bluetooth", 900, 640)
    model.card.state.disconnect()
    model.catalog = DeviceCatalog()
    model.recordings = recordings
    model.area = .live
    model.preferences.cloudEnabled = true
    model.hasKey = true
    live.configure(enabled: true, service: AIService(key: "synthetic-only"))
    var packet = Data(repeating: 0, count: 40)
    packet[0] = 0x48
    live.append((0..<20).reduce(into: Data()) { data, _ in data.append(packet) })
    stream.onEvent?(.started)
    for index in 1...100 {
      stream.onEvent?(
        .sentence(id: index, text: "第 \(index) 句：我们确认今天的讨论结果，接下来核对项目安排与交付时间。", isFinal: true))
    }
    XCTAssertEqual(live.lines.count, 100)
    try await capture("workspace-live-narrow", 900, 640)
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    let liveScroll = try XCTUnwrap(
      views(host.view).compactMap { $0 as? NSScrollView }.first {
        $0.contentView.bounds.height > 180 && ($0.documentView?.frame.height ?? 0) > 1000
      }, "实时文字必须提供独立的原生滚动区域")
    NotificationCenter.default.post(
      name: NSScrollView.willStartLiveScrollNotification, object: liveScroll)
    liveScroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
    liveScroll.reflectScrolledClipView(liveScroll.contentView)
    try await Task.sleep(for: .milliseconds(100))
    NotificationCenter.default.post(
      name: NSScrollView.didEndLiveScrollNotification, object: liveScroll)
    let heldPosition = liveScroll.contentView.bounds.minY
    stream.onEvent?(.sentence(id: 101, text: "新增一句：回看旧文字时保持当前阅读位置。", isFinal: true))
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(live.lines.count, 100)
    XCTAssertEqual(
      liveScroll.contentView.bounds.minY, heldPosition, accuracy: 2,
      "新增文字不能把正在回看的用户拉回底部")
    try await capture("workspace-live-reading", 900, 640)
    // Switch to an independently rendered settings surface; no settings or credentials are saved.
    model.settingsSection = .recognition
    let settings = NSHostingView(rootView: SettingsView(model: model))
    settings.frame = NSRect(x: 0, y: 0, width: 740, height: 670)
    settings.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(settings.bitmapImageRepForCachingDisplay(in: settings.bounds))
    settings.cacheDisplay(in: settings.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      .write(
        to: URL(fileURLWithPath: output).appendingPathComponent(
          "workspace-settings-recognition.png"))
    XCTAssertEqual(front, NSWorkspace.shared.frontmostApplication?.processIdentifier)
  }
}

@MainActor private final class WorkspaceLiveStream: LiveASRStreaming {
  var onEvent: ((ASREvent) -> Void)?
  func start() {}
  func append(_ data: Data) {}
  func finish() {}
  func cancel() {}
}
