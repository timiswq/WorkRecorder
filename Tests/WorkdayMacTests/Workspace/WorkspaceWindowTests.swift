import AppKit
import QS668Core
import SwiftUI
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class WorkspaceWindowTests: XCTestCase {
  @MainActor func testScrollObserverDefersPositionUntilAfterLayout() async {
    _ = NSApplication.shared
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 1000))
    scroll.documentView = content
    let observer = ScrollGestureView()
    content.addSubview(observer)
    var positions: [Bool] = []
    observer.onPosition = { positions.append($0) }
    observer.attach()

    func drainMainQueue() async {
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
      }
    }
    let center = NotificationCenter.default
    let begin = NSScrollView.willStartLiveScrollNotification
    let end = NSScrollView.didEndLiveScrollNotification
    center.post(name: end, object: NSScrollView())
    await drainMainQueue()
    XCTAssertTrue(positions.isEmpty)

    center.post(name: begin, object: scroll)
    XCTAssertTrue(positions.isEmpty)
    await drainMainQueue()
    XCTAssertEqual(positions, [false])
    positions.removeAll()

    scroll.contentView.scroll(to: .zero)
    center.post(name: end, object: scroll)
    center.post(name: end, object: scroll)
    XCTAssertTrue(positions.isEmpty, "AppKit 通知可能在 SwiftUI 布局期间同步发出")
    // In this unflipped document the top is at the maximum Y.
    scroll.contentView.scroll(to: NSPoint(x: 0, y: content.bounds.maxY))
    await drainMainQueue()
    XCTAssertEqual(positions, [true], "合并通知并读取布局完成后的位置")

    center.post(name: end, object: scroll)
    observer.detach()
    observer.attach()
    await drainMainQueue()
    XCTAssertEqual(positions, [true], "重新挂载后应丢弃旧回调")
    observer.detach()
    center.post(name: begin, object: scroll)
    await drainMainQueue()
    XCTAssertEqual(positions, [true])
  }

  @MainActor func testDraggingEitherCaptionRangeHandleInAnOffscreenWindow() async throws {
    _ = NSApplication.shared
    let frame = NSRect(x: 0, y: 0, width: 700, height: 100)
    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let clock = CaptionWindow(now: CaptionWindow.minute(Date()))
    final class State: ObservableObject { @Published var range: ClosedRange<Date>? }
    struct Fixture: View {
      @ObservedObject var state: State
      let clock: CaptionWindow
      var body: some View {
        CaptionTimeRuler(window: clock, records: [], selected: state.range) { state.range = $0 }
          .frame(maxHeight: .infinity, alignment: .top)
      }
    }
    let state = State()
    let host = NSHostingView(rootView: Fixture(state: state, clock: clock))
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -16000, y: -16000))
    window.orderBack(nil) // Direct events to a mapped window, outside the visible desktop.
    window.displayIfNeeded()
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    func drag(from x: CGFloat, to target: CGFloat) async throws {
      for (n, step) in [(NSEvent.EventType.leftMouseDown, x), (.leftMouseDragged, target), (.leftMouseUp, target)].enumerated() {
        let point = host.convert(NSPoint(x: step.1, y: 55), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: step.0, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: n, clickCount: 1, pressure: step.0 == .leftMouseUp ? 0 : 1))
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(35))
      }
    }
    try await drag(from: 31, to: 189)
    let first = try XCTUnwrap(state.range)
    XCTAssertEqual(first.lowerBound, clock.start.addingTimeInterval(6 * 3600))
    XCTAssertEqual(first.upperBound, clock.now)
    try await drag(from: 669, to: 511)
    let second = try XCTUnwrap(state.range)
    XCTAssertEqual(second.lowerBound, first.lowerBound)
    XCTAssertEqual(second.upperBound, clock.start.addingTimeInterval(18 * 3600 - 60))
    // Pull the start past the end; expanding the right grip must still be possible.
    try await drag(from: 189, to: 586)
    XCTAssertEqual(state.range, second.upperBound...second.upperBound)
    try await drag(from: 511, to: 669)
    XCTAssertEqual(state.range, second.upperBound...clock.now)
    // The same gesture from the track creates two new bounds, including a right-to-left drag.
    let six = clock.start.addingTimeInterval(6 * 3600)
    let twelve = clock.start.addingTimeInterval(12 * 3600)
    try await drag(from: 192, to: 350)
    XCTAssertEqual(state.range, six...twelve)
    try await drag(from: 429, to: 271)
    XCTAssertEqual(state.range, six.addingTimeInterval(3 * 3600)...twelve.addingTimeInterval(3 * 3600))
    let beforeClick = state.range
    try await drag(from: 350, to: 350)
    XCTAssertEqual(state.range, beforeClick)
  }

  @MainActor func testMainWindowNativeFixtures() async throws {
    guard ProcessInfo.processInfo.environment["WORKDAY_WORKSPACE_SNAPSHOTS"] == "1",
      let library = ProcessInfo.processInfo.environment["WORKDAY_FIXTURE_LIBRARY"],
      let output = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
    else { throw XCTSkip("按需执行原生工作区隔离样张与滚动验证") }
    _ = NSApplication.shared
    let focus = BackgroundFocusProbe()
    defer { focus.stop() }
    let stream = WorkspaceLiveStream()
    var receipt = Date()
    let live = LivePreview(clock: { receipt }, makeLocalStream: { stream })
    let model = AppModel(libraryURL: URL(fileURLWithPath: library), localCaptions: live)
    model.desktop.start(model: model)
    defer { model.desktop.stop() }
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
    if let raw = model.workspace.activities.first(where: \.isRaw) {
      model.selectedDetail = .conversation(raw.id)
      try await capture("workspace-unorganized-inspector", 1320, 820)
      model.selectedDetail = nil
    }
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
    model.card.state.connected = true
    model.card.name = "CB08"
    var parser = FrameParser()
    model.card.state.apply(try XCTUnwrap(parser.push(Wire.frame([0, 4, 78], seq: 0)).first))
    let recordingStatus = try XCTUnwrap(parser.push(Wire.frame([3, 20, 1], seq: 1)).first)
    model.card.state.apply(recordingStatus)
    let elapsed = try XCTUnwrap(parser.push(Wire.frame([3, 22, 56, 4, 0, 0, 0, 0], seq: 2)).first)
    model.card.state.apply(elapsed)
    try await capture("workspace-today-recording")
    model.recordings = recordings
    model.selectDay("2026-11-10")
    try await capture("workspace-hardware-history")
    model.area = .live
    model.card.state.apply(try XCTUnwrap(parser.push(Wire.frame([3, 5], seq: 3)).first))
    try await capture("workspace-hardware-paused", 690, 510, dark: true)
    model.card.name = String(repeating: "会议室录音卡 · ", count: 8) + "CB08"
    try await capture("workspace-hardware-long-name", 690, 510)
    try await capture("workspace-hardware-long-name-wide")
    model.card.name = "CB08"
    model.recordings = []
    model.showToday()
    model.card.state.apply(recordingStatus, at: Date().addingTimeInterval(-60))
    try await capture("workspace-today-stale")
    model.card.state.disconnect()
    model.selectDay("2026-11-01")
    try await capture("workspace-history-empty", 900, 640)
    model.showToday()
    model.area = .device
    model.preferences.boundID = "fixture"
    model.preferences.boundName = "CB08"
    model.card.updateBluetoothState(.poweredOff)
    try await capture("workspace-hardware-bluetooth-off", 690, 510)
    model.card.updateBluetoothState(.unauthorized)
    try await capture("workspace-hardware-permission", 690, 510)
    model.card.updateBluetoothState(.poweredOn)
    let volume = USBVolume(id: "usb:fixture", url: model.libraryURL, name: "同步测试卡")
    let entries = (1...9).map {
      InventoryEntry(name: String(format: "note20261110-%02d0000.wav", $0), duration: 10, bytes: 100)
    }
    model.catalog.snapshots[volume.id] = DeviceInventory(
      sourceID: volume.id, entries: entries, observedAt: Date(), complete: true)
    model.usb.volumes = [volume]
    model.preferences.autoSync = false
    try await capture("workspace-sync-manual", 900, 640)
    try await capture("workspace-card-minimum", 690, 510)
    model.showToday()
    try await capture("workspace-today-pending", 900, 640)
    model.area = .device
    model.preferences.autoSync = true
    model.usb.volumes = []
    model.preferences.boundID = "fixture"
    model.card.state.connected = true
    model.card.state.apply(try XCTUnwrap(parser.push(Wire.frame([3, 20, 2], seq: 1)).first))
    model.catalog.snapshots["ble:fixture"] = DeviceInventory(
      sourceID: "ble:fixture", entries: entries, observedAt: Date(), complete: true)
    try await capture("workspace-sync-bluetooth", 900, 640)
    model.card.state.disconnect()
    model.catalog = DeviceCatalog()
    model.recordings = recordings
    model.selectDay("2026-11-10")
    model.showOriginals(for: model.selectedDay)
    try await capture("workspace-day-originals", 690, 510)
    let savedDocuments = model.documents
    let savedSummaries = model.summaries
    model.documents = [:]
    model.summaries = [:]
    model.area = .day
    try await capture("workspace-originals-before-summary", 900, 640)
    model.documents = savedDocuments
    model.summaries = savedSummaries
    if let clip = model.dayConversations.first {
      let start = try XCTUnwrap(clip.wallStart)
      let clock = start.timeIntervalSince(WorkdayTimeline.calendar.startOfDay(for: start))
      model.player.startDay(model.workspace.audio, recordings: model.dayRecordings,
                            root: model.libraryURL, clock: clock, autoplay: false)
      model.selectDay("2026-11-09")
      XCTAssertEqual(model.player.route?.day, "2026-11-10")
      XCTAssertNotNil(model.playbackActivity)
      try await capture("workspace-browsing-during-replay", 900, 640)
      model.showPlaybackDay()
      XCTAssertEqual(model.selectedDay, "2026-11-10")
      XCTAssertEqual(model.selectedDetail, .conversation(try XCTUnwrap(model.playbackActivity).id))
      model.player.stop()
    }
    model.area = .live
    model.preferences.cloudEnabled = true
    model.hasKey = true
    model.preferences.captions.enabled = true
    var packet = Data(repeating: 0, count: 40)
    packet[0] = 0x48
    live.append((0..<20).reduce(into: Data()) { data, _ in data.append(packet) })
    stream.onEvent?(.started)
    model.card.state.connected = true
    model.card.state.apply(recordingStatus)
    let minute = CaptionWindow.minute(Date())
    let windowStart = CaptionWindow(now: Date()).start
    let midnight = WorkdayTimeline.calendar.startOfDay(for: minute)
    receipt = windowStart.addingTimeInterval(midnight.timeIntervalSince(windowStart) / 2)
    stream.onEvent?(.sentence(id: 0, text: "昨天确认了会议时间。", isFinal: true))
    let sample = [(-130, "我们再核对一下交付时间。"), (-52, "周五下午三点。"),
                  (-35, "好，先把样品送到前台。"), (0, "我来联系快递。")]
    for (number, item) in sample.enumerated() {
      receipt = minute.addingTimeInterval(Double(item.0))
      stream.onEvent?(.sentence(id: number + 1, text: item.1, isFinal: true,
                                startMs: Double(number * 100), endMs: Double(number * 100 + 80)))
    }
    try await capture("字幕-默认跟随")
    XCTAssertNil(model.selectedCaption)
    let transcriptScroll = try XCTUnwrap(views(host.view).compactMap { $0 as? NSScrollView }.first)
    func buttons(in view: NSView) -> [NSButton] {
      views(view).compactMap { $0 as? NSButton }.filter { !($0 is NSPopUpButton) }
    }
    let rowButtons = buttons(in: transcriptScroll)
    XCTAssertTrue(rowButtons.contains { !$0.isEnabled }, "无音频的行应保留置灰的回听按钮")
    let playable = try XCTUnwrap(rowButtons.first { $0.isEnabled }, "未选中字幕时也应能直接回听")
    playable.performClick(nil)
    XCTAssertNotNil(model.player.captionID)
    XCTAssertEqual(model.player.captionID, model.selectedCaption?.id)
    model.player.stop()
    model.captionPosition = .latest
    let first = try XCTUnwrap(model.captionHistory.records.last)
    model.selectCaption(first)
    try await capture("字幕-选中第一条")
    XCTAssertEqual(model.captionPosition, .latest)
    func contentFrame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: host.view) }
    func rangePickers() -> [NSDatePicker] {
      views(host.view).compactMap { $0 as? NSDatePicker }.sorted { contentFrame($0).midX < contentFrame($1).midX }
    }
    XCTAssertEqual(rangePickers().count, 2, "起止时间应默认显示在列表上方")
    func edit(_ picker: NSDatePicker, to time: Date) async throws {
      picker.dateValue = time
      _ = picker.sendAction(picker.action, to: picker.target)
      try await Task.sleep(for: .milliseconds(100))
    }
    let start = minute.addingTimeInterval(-120), end = minute.addingTimeInterval(-60)
    try await edit(try XCTUnwrap(rangePickers().first), to: start)
    try await edit(try XCTUnwrap(rangePickers().last), to: end)
    try await capture("字幕-时间段筛选")
    XCTAssertEqual(model.captionPosition.selectedRange, start...end)
    let utterance = try XCTUnwrap(model.captionHistory.records.first { $0.text == "周五下午三点。" })
    model.selectCaption(utterance)
    try await capture("字幕-选句回听")
    XCTAssertNotNil(utterance.replay)
    let blank = minute.addingTimeInterval(-600)
    try await edit(try XCTUnwrap(rangePickers().first), to: blank)
    try await edit(try XCTUnwrap(rangePickers().last), to: blank)
    XCTAssertEqual(model.captionPosition.selectedRange, blank...blank)
    try await capture("字幕-空白时段")
    let jumpButtons = buttons(in: transcriptScroll).filter(\.isEnabled)
      .sorted { contentFrame($0).midX < contentFrame($1).midX }
    XCTAssertEqual(jumpButtons.count, 2)
    let previous = try XCTUnwrap(model.captionHistory.records.last { $0.time < blank })
    let next = try XCTUnwrap(model.captionHistory.records.first { $0.time >= blank.addingTimeInterval(60) })
    try XCTUnwrap(jumpButtons.first).performClick(nil)
    XCTAssertEqual(model.selectedCaption?.id, previous.id)
    XCTAssertNil(model.player.captionID)
    model.selectCaptionRange(blank...blank, in: CaptionWindow(now: Date()))
    try await Task.sleep(for: .milliseconds(120))
    let nextButton = try XCTUnwrap(buttons(in: transcriptScroll).filter(\.isEnabled)
      .max { contentFrame($0).midX < contentFrame($1).midX })
    nextButton.performClick(nil)
    XCTAssertEqual(model.selectedCaption?.id, next.id)
    XCTAssertNil(model.player.captionID)
    model.captionPosition = .latest
    XCTAssertEqual(rangePickers().count, 2)
    XCTAssertEqual(model.captionPosition, .latest)
    try await Task.sleep(for: .milliseconds(80))

    live.boundary(.started)
    live.append(packet)
    receipt = Date()
    for index in 1...100 {
      stream.onEvent?(
        .sentence(id: index, text: "第 \(index) 句：我们确认今天的讨论结果，接下来核对项目安排与交付时间。", isFinal: true))
    }
    XCTAssertEqual(live.lines.count, 100)
    try await capture("workspace-live-narrow", 900, 640)
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    var liveScroll = try XCTUnwrap(
      views(host.view).compactMap { $0 as? NSScrollView }.first {
        $0.contentView.bounds.height > 180 && ($0.documentView?.frame.height ?? 0) > 1000
      }, "实时文字必须提供独立的原生滚动区域")
    func distanceFromTop() throws -> CGFloat {
      let document = try XCTUnwrap(liveScroll.documentView)
      return document.isFlipped ? document.visibleRect.minY - document.bounds.minY
        : document.bounds.maxY - document.visibleRect.maxY
    }
    XCTAssertEqual(try distanceFromTop(), 0, accuracy: 2, "默认从最新一行开始阅读")
    NotificationCenter.default.post(
      name: NSScrollView.willStartLiveScrollNotification, object: liveScroll)
    liveScroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
    liveScroll.reflectScrolledClipView(liveScroll.contentView)
    try await Task.sleep(for: .milliseconds(100))
    NotificationCenter.default.post(
      name: NSScrollView.didEndLiveScrollNotification, object: liveScroll)
    XCTAssertEqual(model.captionPosition, .scrolling)
    let heldLead = try XCTUnwrap(model.captionLeadID(at: Date()))
    let heldPosition = liveScroll.contentView.bounds.minY
    func visibleSentence() -> String? {
      let viewport = liveScroll.accessibilityFrame()
      func elements(_ element: Any) -> [any NSAccessibilityProtocol] {
        guard let accessible = element as? any NSAccessibilityProtocol else { return [] }
        return [accessible] + (accessible.accessibilityChildren() ?? []).flatMap(elements)
      }
      return elements(liveScroll).compactMap { element -> (String, NSRect)? in
        let text = element.accessibilityLabel() ?? (element.accessibilityValue() as? String) ?? ""
        let frame = element.accessibilityFrame()
        guard element.accessibilityRole() == .staticText, text.hasPrefix("第 "), frame.intersects(viewport), frame.height > 0 else { return nil }
        return (text, frame)
      }.sorted { $0.1.maxY > $1.1.maxY }.first?.0
    }
    let firstVisibleSentence = try XCTUnwrap(visibleSentence(), "原生可访问性树应能定位可见首句")
    stream.onEvent?(.sentence(id: 101, text: "新增一句：回看旧文字时保持当前阅读位置。", isFinal: true))
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(live.lines.count, 100)
    XCTAssertEqual(model.captionHistory.records.count, 106)
    XCTAssertEqual(model.captionLeadID(at: Date()), heldLead, "回看中的首句应保留原字号，避免新句导致重排")
    XCTAssertEqual(
      liveScroll.contentView.bounds.minY, heldPosition, accuracy: 2,
      "新增文字不能移动正在回看的内容")
    XCTAssertEqual(model.captionHistory.unreadCount(in: CaptionWindow(now: Date())), 1)
    try await capture("workspace-live-reading", 900, 640)
    let readingWindow = CaptionWindow(now: Date())
    let visibleIDs = readingWindow.visible(in: model.captionHistory.readingRecords).map(\.id)
    XCTAssertNil(model.selectedCaption)
    let unselectedAnchor = try XCTUnwrap(model.captionReadingAnchor)
    model.area = .device
    try await Task.sleep(for: .milliseconds(140))
    model.showLiveCaptions()
    try await Task.sleep(for: .milliseconds(350))
    liveScroll = try XCTUnwrap(views(host.view).compactMap { $0 as? NSScrollView }.first)
    XCTAssertEqual(model.captionReadingAnchor, unselectedAnchor)
    // LazyVStack can change estimated heights above the viewport when it is recreated.
    // Compare the actual visible sentence, not document coordinates from the previous instance.
    XCTAssertEqual(try XCTUnwrap(visibleSentence()), firstVisibleSentence)
    try await capture("caption-return-reading", 900, 640)
    let restoredOffset = liveScroll.contentView.bounds.minY
    let previouslyVisible = try XCTUnwrap(model.captionHistory.records.first { $0.text.hasPrefix("第 90 句") })
    model.selectCaption(previouslyVisible)
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertTrue(liveScroll.isDescendant(of: host.view), "选中发言应保留现有滚动视图")
    XCTAssertEqual(readingWindow.visible(in: model.captionHistory.readingRecords).map(\.id),
                   visibleIDs, "选中发言应保留每一条记录及其顺序")
    XCTAssertEqual(liveScroll.contentView.bounds.minY, restoredOffset, accuracy: 2, "选中发言应保持当前阅读位置")
    try await capture("caption-select-reading", 900, 640)
    let anchor = try XCTUnwrap(model.captionReadingAnchor, "纯滚动也应记录可见的发言")
    let historyEnd = CaptionWindow.minute(receipt)
    let adjusted = historyEnd.addingTimeInterval(-120)...historyEnd
    model.selectCaptionRange(adjusted, in: readingWindow)
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(model.captionReadingAnchor, anchor)
    XCTAssertEqual(model.selectedCaption?.id, previouslyVisible.id)
    XCTAssertEqual(liveScroll.contentView.bounds.minY, restoredOffset, accuracy: 3)
    model.area = .device
    try await Task.sleep(for: .milliseconds(140))
    model.showLiveCaptions()
    try await Task.sleep(for: .milliseconds(350))
    liveScroll = try XCTUnwrap(views(host.view).compactMap { $0 as? NSScrollView }.first)
    XCTAssertEqual(model.captionPosition.selectedRange, adjusted)
    XCTAssertEqual(model.selectedCaption?.id, previouslyVisible.id)
    XCTAssertEqual(model.captionReadingAnchor, anchor, "设备详情返回后应恢复原先可见的句子")
    XCTAssertEqual(try XCTUnwrap(visibleSentence()), firstVisibleSentence, "可见首句应相同")
    try await capture("caption-return-range-reading", 900, 640)
    let listFrame = contentFrame(liveScroll)
    let pickerY = contentFrame(try XCTUnwrap(rangePickers().first)).midY
    let returnToLive = try XCTUnwrap(buttons(in: host.view).first { button in
      let frame = contentFrame(button)
      return !button.isDescendant(of: liveScroll) && frame.midX > listFrame.minX
        && frame.midX < listFrame.midX && abs(frame.midY - pickerY) < 45
    })
    returnToLive.performClick(nil)
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(model.captionPosition, .latest)
    XCTAssertEqual(model.captionHistory.unreadCount(in: readingWindow), 0)
    XCTAssertEqual(try distanceFromTop(), 0, accuracy: 2, "回到最新应回到列表顶部")
    try await capture("字幕-回到最新", 900, 640)
    receipt = Date()
    stream.onEvent?(.sentence(id: 102, text: "我们先核对新版包装上的型号和交付日期，随后联系仓库安排发货。请把负责人的姓名也记下来，明天上午确认收件地址后，我们再把更新后的时间同步给大家。", isFinal: false))
    try await capture("字幕-最低宽度草稿", 690, 510, dark: true)
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
    XCTAssertFalse(focus.activatedTestApplication)
  }
}

@MainActor private final class WorkspaceLiveStream: LiveASRStreaming {
  var onEvent: ((ASREvent) -> Void)?
  func start() {}
  func append(_ data: Data) {}
  func finish() {}
  func cancel() {}
}
