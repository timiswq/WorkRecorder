import AppKit
import QS668Core
import SwiftUI
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class DesktopWindowTests: XCTestCase {
  @MainActor func testMenuPanelCannotCollapseWhenTheStatusWindowProposesMinimalHeight() {
    _ = NSApplication.shared
    let model = isolatedModel()
    let host = NSHostingController(rootView: MenuBarPanel(model: model, desktop: model.desktop))
    for proposedHeight in [0.0, 1.0, 10.0, 650.0] {
      let size = host.sizeThatFits(in: NSSize(width: 340, height: proposedHeight))
      XCTAssertEqual(size.width, 340, accuracy: 1)
      XCTAssertGreaterThanOrEqual(size.height, 250,
        "打开菜单时至少应能显示标题、设备状态和操作入口，不能压成白条")
      XCTAssertLessThanOrEqual(size.height, 650)
    }
  }

  @MainActor func testFullScreenQueriesFollowCaptionVisibilityAndReuseRecentResults() throws {
    _ = NSApplication.shared
    guard NSScreen.screens.first != nil else { throw XCTSkip("需要显示器以验证字幕所在屏幕") }
    let model = AppModel(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    model.preferences.captions.enabled = true
    model.localCaptions.configure(enabled: true, service: nil)
    var checks = 0
    let desktop = DesktopCompanion { _ in checks += 1; return true }
    desktop.start(model: model)
    defer { desktop.stop() }
    let now = Date()
    desktop.refresh(now: now)
    XCTAssertEqual(checks, 0)

    let line = try withVoice(LiveLine(id: "one", segment: 0, sentence: 0, text: "正在测试", isFinal: false), in: model)
    for step in 0..<20 {
      desktop.refresh(now: now.addingTimeInterval(Double(step) / 100), transcript: [line])
    }
    XCTAssertEqual(checks, 1)
    XCTAssertNil(desktop.panel, "全屏期间收到的字幕应保持隐藏")
    desktop.refresh(now: now.addingTimeInterval(0.6), transcript: [line])
    XCTAssertEqual(checks, 2)
    desktop.snooze()
    desktop.refresh(now: now.addingTimeInterval(1.2), transcript: [line])
    XCTAssertEqual(checks, 2)
  }

  @MainActor func testPanelCannotBecomeKeyOrInterceptMouse() {
    _ = NSApplication.shared
    let panel = CaptionPanel(frame: .zero, feed: CaptionFeedView(presentation: CaptionFeedPresentation()))
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
    XCTAssertEqual(panel.height, 352)
  }

  @MainActor func testDifferentWidthCaptionsShareTheScreenRightInset() throws {
    _ = NSApplication.shared
    let screen = try XCTUnwrap(NSScreen.main).visibleFrame
    let feed = CaptionFeedPresentation()
    feed.update([
      DesktopCaption(id: "short", text: "收到", isFinal: true),
      DesktopCaption(id: "long", text: "下午我们一起确认这段录音的效果。", isFinal: false),
    ], username: "发言", preview: false, animated: false)
    let panel = CaptionPanel(frame: CaptionPlacement.frame(in: screen), feed: CaptionFeedView(presentation: feed))
    defer { panel.close() }

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

  @MainActor func testWideBodyGivesTheNameSpareRoomWithoutWideningShortCaptions() throws {
    _ = NSApplication.shared
    let feed = CaptionFeedPresentation()
    let longName = "上海研发项目协调陈晨"
    let wide = "今天核对会议时间，再确认周五要交付的文件。"
    func row(_ id: String, _ name: String, _ text: String) -> DesktopCaption {
      .init(id: id, text: text, isFinal: true, speakerLabel: name,
            identityControls: .confirm, receivedAt: Date(timeIntervalSince1970: 0))
    }
    let rows = [row("long", longName, wide), row("one", "林", wide), row("short", longName, "好。")]
    feed.update(rows, username: "", preview: false, animated: false)
    let frame = CaptionPlacement.frame(in: try XCTUnwrap(NSScreen.main).visibleFrame)
    let panel = CaptionPanel(frame: frame, feed: CaptionFeedView(presentation: feed))
    defer { panel.close() }
    func buttonOffset(_ row: DesktopCaption) throws -> CGFloat {
      let bubble = try XCTUnwrap(panel.anchor(for: row.id))
      let action = try XCTUnwrap(panel.anchor(for: row.actionAnchor))
      XCTAssertTrue(bubble.contains(action))
      return action.minX - bubble.minX
    }
    let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    let expected = ((longName as NSString).size(withAttributes: [.font: font]).width
                    - ("林" as NSString).size(withAttributes: [.font: font]).width)
    XCTAssertEqual(try buttonOffset(rows[0]) - buttonOffset(rows[1]), expected, accuracy: 2)
    XCTAssertLessThan(try buttonOffset(rows[2]), try buttonOffset(rows[0]))
  }

  @MainActor func testReflowCannotArmAnotherSentenceUnderAStationaryPointer() throws {
    _ = NSApplication.shared
    let model = isolatedModel()
    model.preferences.captions.showInFullScreen = true
    model.desktop.start(model: model)
    defer { model.desktop.stop() }
    let first = LiveLine(id: "first", segment: 0, sentence: 0, text: "下午三点开会。", isFinal: true)
    let second = LiveLine(id: "second", segment: 0, sentence: 1, text: "明天九点交稿。", isFinal: true)
    let firstRow = try withVoice(first, in: model), secondRow = try withVoice(second, in: model)
    model.desktop.refresh(transcript: [firstRow], pointer: .zero)
    let panel = try XCTUnwrap(model.desktop.panel)
    let host = panel.feedView
    let firstCaption = try XCTUnwrap(host.rootView.presentation.content.items.first)
    let button = try XCTUnwrap(panel.anchor(for: firstCaption.actionAnchor))
    let pointer = NSPoint(x: button.midX, y: button.midY)
    model.desktop.refresh(pointer: pointer)
    XCTAssertNotNil(model.desktop.voiceActions[first.id])
    model.desktop.refresh(transcript: [firstRow, secondRow], pointer: pointer)
    let secondCaption = try XCTUnwrap(host.rootView.presentation.content.items.last)
    XCTAssertTrue(try XCTUnwrap(panel.anchor(for: secondCaption.actionAnchor)).contains(pointer))
    for _ in 0..<2 {
      model.desktop.refresh(pointer: pointer)
      XCTAssertTrue(model.desktop.voiceActions.isEmpty)
      XCTAssertNil(model.desktop.closeButton)
    }
    model.desktop.refresh(pointer: NSPoint(x: pointer.x + 1, y: pointer.y))
    XCTAssertTrue(model.desktop.voiceActions.isEmpty, "指针轻微抖动不能把标注转给新来的句子")
    model.desktop.refresh(pointer: .zero)
    model.desktop.refresh(pointer: pointer)
    XCTAssertEqual(Set(model.desktop.voiceActions.keys), [second.id])
  }

  @MainActor func testPreviewReturnsOnlyLiveCaptionsWhoseDeadlineHasNotPassed() throws {
    _ = NSApplication.shared
    let model = isolatedModel()
    model.preferences.captions.showInFullScreen = true
    model.desktop.start(model: model)
    defer { model.desktop.stop() }
    let start = Date()
    let end = start.addingTimeInterval(CaptionPreview.duration)
    let old = (0..<2).map {
      LiveLine(id: "old-\($0)", segment: 0, sentence: $0, text: "已经过期。", isFinal: true)
    }
    let recent = LiveLine(id: "recent", segment: 0, sentence: 2, text: "请带上合同。", isFinal: true)
    let oldRows = try old.map { try withVoice($0, in: model) }
    model.desktop.refresh(now: start, transcript: oldRows)
    model.desktop.preview(now: start)
    let host = try XCTUnwrap(model.desktop.panel?.feedView)
    model.desktop.refresh(now: end.addingTimeInterval(-1), transcript: oldRows + [try withVoice(recent, in: model)])
    XCTAssertTrue(host.rootView.presentation.content.preview)
    XCTAssertFalse(host.rootView.presentation.content.items.contains { $0.id == recent.id })
    model.desktop.refresh(now: end)
    XCTAssertFalse(host.rootView.presentation.content.preview)
    XCTAssertEqual(host.rootView.presentation.content.items.map(\.id), [recent.id])
  }

  @MainActor func testPreviewExpiresWithoutChangingFrontmostApplication() async throws {
    _ = NSApplication.shared
    let model = isolatedModel()
    model.preferences.captions.showInFullScreen = true
    // Do not start model services: no hardware, credentials, or cloud activity in this test.
    model.desktop.start(model: model)
    defer { model.desktop.stop() }
    let focus = BackgroundFocusProbe()
    defer { focus.stop() }
    let keyWindow = NSApp.keyWindow
    model.desktop.preview(now: Date().addingTimeInterval(0.3 - CaptionPreview.duration))
    let panel = try XCTUnwrap(model.desktop.panel)
    XCTAssertTrue(panel.isVisible)
    XCTAssertFalse(panel.isKeyWindow)
    XCTAssertFalse(focus.activatedTestApplication)
    XCTAssertTrue(NSApp.keyWindow === keyWindow)
    try await Task.sleep(for: .milliseconds(1_200))
    XCTAssertFalse(panel.isVisible)
    XCTAssertFalse(focus.activatedTestApplication)
  }

  @MainActor func testClosingLastPreviewBubblePersistsUntilANewPreview() async throws {
    _ = NSApplication.shared
    let model = isolatedModel()
    let desktop = model.desktop
    model.preferences.captions.showInFullScreen = true
    desktop.start(model: model)
    defer { desktop.stop() }
    let start = Date()
    desktop.preview(now: start)
    let panel = try XCTUnwrap(desktop.panel)
    let feed = panel.feedView.rootView.presentation
    let first = try XCTUnwrap(feed.content.items.first)
    let bubble = try XCTUnwrap(panel.anchor(for: first.id))
    desktop.refresh(pointer: .zero)
    desktop.refresh(pointer: NSPoint(x: bubble.midX, y: bubble.midY))
    let close = try XCTUnwrap(desktop.closeButton)
    XCTAssertTrue(desktop.voiceActions.isEmpty)
    close.button.performClick(nil)
    try await Task.sleep(for: .milliseconds(350))
    XCTAssertFalse(panel.isVisible)
    XCTAssertNil(desktop.closeButton)
    desktop.refresh(now: start.addingTimeInterval(4))
    XCTAssertFalse(feed.content.items.isEmpty)
    XCTAssertFalse(feed.content.items.contains { $0.id == first.id })
    desktop.preview()
    XCTAssertEqual(feed.content.items.first?.id, first.id)
  }

  @MainActor func testClickingBubbleDismissesOnlyThatSentenceAndKeepsItsHistory() async throws {
    _ = NSApplication.shared
    let model = isolatedModel()
    model.preferences.captions.showInFullScreen = true
    model.desktop.start(model: model)
    defer { model.desktop.stop() }
    let focus = BackgroundFocusProbe()
    defer { focus.stop() }
    let lines = try (0..<2).map {
      try withVoice(LiveLine(id: "click-\($0)", segment: 0, sentence: $0,
                            text: "第\($0 + 1)句字幕。", isFinal: true), in: model)
    }
    for line in lines { model.captionHistory.accept(line, evidenceID: line.voiceID) }
    let history = model.captionHistory.records
    model.desktop.refresh(transcript: lines, pointer: .zero)
    let panel = try XCTUnwrap(model.desktop.panel)
    let feed = panel.feedView.rootView.presentation
    let surface = try dismissSurface(for: lines[0].id, in: panel)
    let bubble = try XCTUnwrap(panel.anchor(for: lines[0].id))
    XCTAssertEqual(surface.frame.minX, bubble.minX, accuracy: 1)
    XCTAssertEqual(surface.frame.maxX, bubble.maxX, accuracy: 1)
    XCTAssertEqual(surface.frame.minY, bubble.minY, accuracy: 1)
    XCTAssertEqual(surface.frame.maxY, bubble.maxY, accuracy: 1)
    XCTAssertFalse(surface.canBecomeKey)
    let body = NSPoint(x: bubble.midX, y: bubble.minY + 10)
    try await assertClickTarget(surface, at: body)
    try click(surface, at: body)
    XCTAssertEqual(feed.content.items.map(\.id), ["click-1"])
    XCTAssertEqual(model.captionHistory.records, history)
    XCTAssertFalse(surface.isVisible)
    XCTAssertNil(surface.parent)

    var revised = lines
    revised[0].text = "关闭以后收到的修订。"
    model.desktop.refresh(transcript: revised, pointer: .zero)
    XCTAssertEqual(feed.content.items.map(\.id), ["click-1"])
    let next = try dismissSurface(for: lines[1].id, in: panel)
    let header = NSPoint(x: next.frame.minX + 8, y: next.frame.maxY - 10)
    try click(next, at: header, count: 2)
    XCTAssertEqual(feed.content.items.map(\.id), ["click-1"], "双击的第二下不能误关补位的字幕")
    try click(next, at: header)
    XCTAssertFalse(next.isVisible)
    XCTAssertNil(next.parent)
    XCTAssertEqual(model.captionHistory.records, history)
    XCTAssertFalse(focus.activatedTestApplication)
  }

  @MainActor func testIdentityButtonsKeepWorkingWithoutDismissingTheBubble() throws {
    _ = NSApplication.shared
    let model = isolatedModel()
    model.preferences.captions.showInFullScreen = true
    model.desktop.start(model: model)
    defer { model.desktop.stop() }
    let line = try withVoice(LiveLine(id: "identity-click", segment: 0, sentence: 0,
                                     text: "确认一下发言人。", isFinal: false), in: model)
    model.desktop.refresh(transcript: [line], pointer: .zero)
    let panel = try XCTUnwrap(model.desktop.panel)
    let feed = panel.feedView.rootView.presentation
    let surface = try dismissSurface(for: line.id, in: panel)
    for title in ["是我", "不是我"] {
      let caption = try XCTUnwrap(feed.content.items.first)
      let anchor = try XCTUnwrap(panel.anchor(for: caption.actionAnchor))
      let pointer = NSPoint(x: anchor.midX, y: anchor.midY)
      model.desktop.refresh(pointer: .zero)
      model.desktop.refresh(pointer: pointer)
      let actions = try XCTUnwrap(model.desktop.voiceActions[line.id])
      // Even before the hover button is armed, its reserved area must never close the sentence.
      try click(surface, at: pointer)
      XCTAssertEqual(feed.content.items.map(\.id), [line.id])
      let button = try XCTUnwrap(actions.contentView?.subviews.first as? NSButton)
      XCTAssertEqual(button.title, title)
      button.performClick(nil)
      XCTAssertEqual(feed.content.items.map(\.id), [line.id])
      XCTAssertEqual(feed.content.items.first?.isMine, title == "是我")
      XCTAssertTrue(feed.content.items.first?.markedHere == true)
    }
  }

  @MainActor func testNativeIdentityControlStaysAboveTheBubbleClickSurface() async throws {
    _ = NSApplication.shared
    let presentation = CaptionFeedPresentation()
    let caption = DesktopCaption(id: "native-click", text: "测试点击区域。", isFinal: true,
                                 identityControls: .confirm)
    presentation.update([caption], username: "发言人", preview: false, animated: false)
    let panel = CaptionPanel(frame: CaptionPlacement.frame(in: try XCTUnwrap(NSScreen.main).visibleFrame),
                             feed: CaptionFeedView(presentation: presentation))
    let target = CaptionDismissPanel(captionID: caption.id)
    let actions = CaptionVoiceActions(turn: caption.id, controls: .confirm, sentence: caption.text)
    defer { actions.detach(); target.detach(); panel.close() }
    panel.orderFrontRegardless()
    let bubble = try XCTUnwrap(panel.anchor(for: caption.id))
    let identity = try XCTUnwrap(panel.anchor(for: caption.actionAnchor))
    target.show(in: panel, bubble: bubble, identityFrame: identity)
    actions.show(in: panel, at: identity)
    try await assertClickTarget(actions, at: NSPoint(x: identity.midX, y: identity.midY))
    try await assertClickTarget(target, at: NSPoint(x: bubble.midX, y: bubble.minY + 10))
    let gap = NSPoint(x: panel.frame.minX + 2, y: panel.frame.minY + 2)
    let hit = NSWindow.windowNumber(at: gap, belowWindowWithWindowNumber: 0)
    XCTAssertFalse([panel.windowNumber, target.windowNumber, actions.windowNumber].contains(hit))
  }

  @MainActor func testHidingBubblesImmediatelyRemovesTheirClickSurfaces() throws {
    _ = NSApplication.shared
    let model = isolatedModel()
    model.preferences.captions.showInFullScreen = true
    model.desktop.start(model: model)
    defer { model.desktop.stop() }
    model.desktop.preview()
    let panel = try XCTUnwrap(model.desktop.panel)
    let id = try XCTUnwrap(panel.feedView.rootView.presentation.content.items.first?.id)
    let surface = try dismissSurface(for: id, in: panel)
    model.desktop.snooze()
    XCTAssertFalse(surface.isVisible)
    XCTAssertNil(surface.parent)
    XCTAssertTrue(panel.childWindows?.isEmpty != false, "淡出过程中不能留下透明的鼠标拦截区域")
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
    model.desktop.refresh(now: start, transcript: try lines.map { try withVoice($0, in: model) })
    let panel = try XCTUnwrap(model.desktop.panel)
    let host = panel.feedView
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

  @MainActor func testLiveCaptionPanelKeepsItsFrameDuringAnimatedExpiryAndDraftUpdates() async throws {
    _ = NSApplication.shared
    let model = isolatedModel()
    model.preferences.captions.showInFullScreen = true
    model.desktop.start(model: model)
    defer { model.desktop.stop() }
    let start = Date()
    var lines = (0..<4).map { index in
      LiveLine(id: "live-\(index)", segment: 0, sentence: index,
               text: "先核对会议时间。", isFinal: index < 3, receivedAt: start)
    }
    lines = try lines.map { try withVoice($0, in: model) }
    model.desktop.refresh(now: start, transcript: [lines[0]], pointer: .zero)
    let panel = try XCTUnwrap(model.desktop.panel)
    try await Task.sleep(for: .milliseconds(50))
    let frame = panel.frame
    let resize = XCTNSNotificationExpectation(name: NSWindow.didResizeNotification, object: panel)
    resize.isInverted = true
    model.desktop.refresh(now: start.addingTimeInterval(5), transcript: lines, pointer: .zero)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(frame.contains(try XCTUnwrap(panel.anchor(for: lines[0].id))))
    XCTAssertEqual(panel.contentMinSize, .zero)

    let expiry = start.addingTimeInterval(12)
    model.desktop.refresh(now: expiry, pointer: .zero)
    for text in ["下午", "下午三点开会，", "下午三点开会，请带上本周的记录。"] {
      lines[3].text = text
      model.desktop.refresh(now: expiry, transcript: lines, pointer: .zero)
      try await Task.sleep(for: .milliseconds(40))
      XCTAssertEqual(panel.frame, frame)
    }
    await fulfillment(of: [resize], timeout: 0.25)
    XCTAssertEqual(panel.frame, frame)
    XCTAssertTrue(frame.contains(try XCTUnwrap(panel.anchor(for: lines[3].id))))
  }

  @MainActor func testUSBMenuFollowsTheMountedCardAndRequiredAction() throws {
    _ = NSApplication.shared
    let model = isolatedModel()
    model.preferences.autoSync = false
    model.desktop.start(model: model)
    defer { model.desktop.stop() }
    let volume = USBVolume(id: "usb:b", url: model.libraryURL, name: "录音卡 B")
    model.usb.volumes = [volume]
    model.catalog.snapshots[volume.id] = DeviceInventory(sourceID: volume.id, entries: [
      InventoryEntry(name: "note.wav", duration: 10, bytes: 100)
    ], observedAt: Date(), complete: true)
    XCTAssertEqual(model.cardSync.action, .start)
    let manual = try menuSnapshot(model)
    model.preferences.boundID = "a"
    model.preferences.boundName = "另一张蓝牙卡 A"
    XCTAssertEqual(try menuSnapshot(model), manual, "蓝牙绑定不能改变 USB 来源")
    model.usb.volumes = [USBVolume(id: volume.id, url: volume.url, name: "已改名的磁盘")]
    XCTAssertNotEqual(try menuSnapshot(model), manual, "面板应显示实际卷名")
    model.usb.volumes = [volume]
    model.usb.activeFilenameUnknown = true
    XCTAssertEqual(model.cardSync.action, .confirm)
    XCTAssertNotEqual(try menuSnapshot(model), manual, "需在卡上保存和待手动同步应有不同的提示")
  }

  @MainActor func testMenuStillRendersTheSentenceWhenPausedOrTranscriptionFails() throws {
    _ = NSApplication.shared
    let stream = TestLiveStream()
    let now = Date()
    let live = LivePreview(clock: { now }, makeStream: { _ in stream })
    let model = isolatedModel(localCaptions: live)
    model.card.state.connected = true
    model.desktop.start(model: model)
    defer { model.desktop.stop(); live.reset() }
    live.configure(enabled: true, service: AIService(key: "test-only"))
    var parser = FrameParser()
    func sample(_ text: String) throws -> (paused: Data, failed: Data) {
      let previous = model.menuRecentSpeech?.line.id
      model.card.onStreamReset?(.started)
      XCTAssertEqual(model.menuRecentSpeech?.line.id, previous)
      live.append(Data(repeating: 0, count: 40))
      stream.onEvent?(.sentence(id: 0, text: text, isFinal: true))
      model.card.state.apply(try XCTUnwrap(parser.push(Wire.frame([3, 20, 3], seq: 0)).first))
      model.card.onStreamReset?(.paused)
      let paused = try menuSnapshot(model)
      model.card.state.apply(try XCTUnwrap(parser.push(Wire.frame([3, 20, 1], seq: 0)).first))
      model.card.onStreamReset?(.resumed)
      stream.onEvent?(.failed(code: "network", message: "测试连接中断"))
      XCTAssertTrue(live.canRetry)
      return (paused, try menuSnapshot(model))
    }
    let first = try sample("周四确认。")
    let second = try sample("下周再看样稿。")
    XCTAssertNotEqual(first.paused, second.paused, "暂停时面板仍应区分两句不同的原话")
    XCTAssertNotEqual(first.failed, second.failed, "同一时间与错误下，面板仍应显示原句")
  }

  @MainActor func testLateSentenceCutAppendsUnreadWordsToTheVisibleBubble() throws {
    _ = NSApplication.shared
    let model = isolatedModel()
    model.preferences.captions.showInFullScreen = true
    model.desktop.start(model: model)
    defer { model.desktop.stop() }

    let start = Date()
    var first = LiveLine(id: "first", segment: 0, sentence: 0, text: "明天继续", isFinal: false, receivedAt: start,
                         bubblePhrase: .init(text: "明天继续", continuesPrevious: false))
    model.desktop.refresh(transcript: [try withVoice(first, in: model)])
    let initial = try XCTUnwrap(model.desktop.panel?.feedView.rootView.presentation.content.items.first)
    first.text = "明天，"
    first.isFinal = true
    let second = LiveLine(id: "second", segment: 0, sentence: 1, text: "继续开会", isFinal: true, receivedAt: start.addingTimeInterval(3),
                          bubblePhrase: .init(text: "开会", continuesPrevious: true, carriedText: "继续"))
    model.desktop.refresh(transcript: try [first, second].map { try withVoice($0, in: model) })
    let feed = try XCTUnwrap(model.desktop.panel?.feedView.rootView.presentation)
    XCTAssertEqual(feed.content.items.map(\.text), ["明天继续开会"])
    let result = try XCTUnwrap(feed.content.items.first)
    XCTAssertEqual(result.id, initial.id)
    XCTAssertEqual(result.receivedAt, initial.receivedAt)
    XCTAssertEqual(result.phrases.first, initial.phrases.first)
    XCTAssertEqual(result.sourceLineID, second.id)
  }

  @MainActor func testRetractedDraftAndFullFinalKeepOneBubbleAndOneHistoryRecord() throws {
    _ = NSApplication.shared
    let model = isolatedModel()
    model.preferences.captions.showInFullScreen = true
    model.desktop.start(model: model)
    defer { model.desktop.stop() }

    let start = Date()
    let prefix = "还会出现说了一半，结果没有出现了和文字"
    let full = prefix + "的小现象。"
    var first = LiveLine(id: "draft", segment: 0, sentence: 0, text: prefix, isFinal: false,
                         recognitionRange: 0..<6400, receivedAt: start)
    first = try withVoice(first, in: model)
    model.captionHistory.accept(first, evidenceID: first.bubbleVoiceID)
    model.desktop.refresh(transcript: [first])
    let feed = try XCTUnwrap(model.desktop.panel?.feedView.rootView.presentation)
    let initial = try XCTUnwrap(feed.content.items.first)
    first.text = ""
    first.isFinal = true
    first.draftVoice = nil
    model.captionHistory.accept(first, evidenceID: nil)
    model.desktop.refresh(transcript: [first])
    XCTAssertEqual(feed.content.items.map(\.text), [prefix])
    let final = try withVoice(LiveLine(id: "whole", segment: 0, sentence: 1,
                                       text: full.replacingOccurrences(of: "一半，", with: "一半 ，"), isFinal: true,
                                       recognitionRange: 0..<8700, receivedAt: start.addingTimeInterval(3)), in: model)
    model.captionHistory.accept(final, evidenceID: final.voiceID)
    model.desktop.refresh(transcript: [first, final])
    model.desktop.refresh(transcript: [first, final])
    let bubble = try XCTUnwrap(feed.content.items.first)
    XCTAssertEqual(feed.content.items.map(\.text), [full])
    XCTAssertEqual(bubble.id, initial.id)
    XCTAssertEqual(bubble.receivedAt, start)
    XCTAssertEqual(bubble.phrases.first, initial.phrases.first)
    XCTAssertEqual(bubble.phrases.last?.text, "的小现象。")
    XCTAssertEqual(bubble.sourceLineID, final.id)
    XCTAssertEqual(model.captionHistory.records.map(\.id), [final.id])
  }

  @MainActor func testNativeClickSurfacesFollowTheMovingStackAndDetachAtDismissal() async throws {
    _ = NSApplication.shared
    let model = isolatedModel()
    model.preferences.captions.showInFullScreen = true
    model.desktop.start(model: model)
    defer { model.desktop.stop() }
    let first = try withVoice(LiveLine(id: "older", segment: 0, sentence: 0, text: "我先确认。", isFinal: true), in: model)
    let next = try withVoice(LiveLine(id: "newer", segment: 0, sentence: 1, text: "稍后发给大家。", isFinal: true), in: model)
    model.desktop.refresh(transcript: [first], pointer: .zero)
    let panel = try XCTUnwrap(model.desktop.panel)
    let oldSurface = try dismissSurface(for: first.id, in: panel)
    model.desktop.refresh(transcript: [first, next], pointer: .zero)
    for _ in 0..<6 {
      try await Task.sleep(for: .milliseconds(24))
      for id in [first.id, next.id] {
        let rect = try XCTUnwrap(panel.anchor(for: id)).integral
        let surface = try dismissSurface(for: id, in: panel)
        XCTAssertEqual(surface.frame.minY, rect.minY, accuracy: 1)
        XCTAssertEqual(surface.frame.height, rect.height, accuracy: 1)
      }
    }
    model.desktop.refresh(transcript: [next], pointer: .zero)
    XCTAssertFalse(oldSurface.isVisible)
    XCTAssertNil(oldSurface.parent)
  }

  @MainActor func testInterruptedRowExitReversesAndReducedMotionSettlesImmediately() async throws {
    let feed = CaptionFeedPresentation()
    var caption = DesktopCaption(id: "stable", text: "", isFinal: false, isSoundFeedback: true)
    feed.update([caption], username: "", preview: false, animated: false)
    caption.text = "明天继续"
    caption.isSoundFeedback = false
    feed.update([caption], username: "", preview: false, reduceMotion: true)
    XCTAssertEqual(feed.rows.first?.expansion.value(at: feed.frameTime), 1)
    feed.update([], username: "", preview: false, reduceMotion: false)
    try await Task.sleep(for: .milliseconds(40))
    feed.update([caption], username: "", preview: false, reduceMotion: false)
    let returning = try XCTUnwrap(feed.rows.first?.presence)
    XCTAssertGreaterThan(returning.from, 0)
    XCTAssertLessThan(returning.from, 1)
    XCTAssertEqual(returning.to, 1)
    XCTAssertEqual(feed.rows.map(\.id), [caption.id])
    feed.update([], username: "", preview: false, reduceMotion: true)
    XCTAssertTrue(feed.rows.isEmpty)
  }

  @MainActor func testNativeCaptionTransitionSequence() async throws {
    _ = NSApplication.shared
    let feed = CaptionFeedPresentation()
    let meter = LiveAudioMeter()
    let panel = CaptionPanel(frame: CaptionPlacement.frame(in: try XCTUnwrap(NSScreen.main).visibleFrame),
                             feed: CaptionFeedView(presentation: feed, meter: meter))
    panel.orderBack(nil)
    defer { panel.close() }
    let start = Date()
    var pages = CaptionPages()
    let cue = DesktopCaption(id: "speech", text: "", isFinal: false, receivedAt: start, isSoundFeedback: true)
    var sentence = DesktopCaption(id: cue.id, text: "我们先确认", isFinal: false, sourceLineID: "speaker", receivedAt: start)
    let directory = ProcessInfo.processInfo.environment["WORKDAY_CAPTION_MOTION_FRAMES"].map { URL(fileURLWithPath: $0) }
    if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    func present(_ rows: [DesktopCaption], animated: Bool = true) {
      feed.update(rows, username: "发言人", preview: false, animated: animated)
    }
    func spoken() -> DesktopCaption {
      var item = pages.pages[0]
      item.identityControls = .confirm
      item.speakerLabel = "陈晨"
      return item
    }
    let packets = try ProcessInfo.processInfo.environment["WORKDAY_APPLE_SPEECH_EDGES"].map {
      try Data(contentsOf: URL(fileURLWithPath: $0))
    }
    var widths: [CGFloat] = []
    var rightEdge: CGFloat?
    let clock = ContinuousClock()
    let origin = clock.now
    for frame in 0...105 {
      try await clock.sleep(until: origin + .milliseconds(frame * 33))
      let offset = frame * 120
      if let packets, frame < 45, offset + 120 <= packets.count {
        meter.append(packets.subdata(in: offset..<offset + 120), offset: offset)
      }
      switch frame {
      case 0: present([cue], animated: false)
      case 17, 31, 45:
        if frame == 31 { sentence.text += "周五下午的交付时间，" }
        if frame == 45 { sentence.text += "再把结果发给大家。"; sentence.isFinal = true }
        pages.receive(sentence, now: Date())
        present([spoken()])
      case 62:
        let reply = DesktopCaption(id: "reply", text: "好的，周五见。", isFinal: true, speakerLabel: "林悦",
                                   identityControls: .confirm, receivedAt: start)
        present([spoken(), reply])
      case 81: present(Array(feed.content.items.suffix(1)))
      case 99: present([])
      default: break
      }
      if let directory {
        try png(panel.feedView).write(to: directory.appendingPathComponent(String(format: "%03d.png", frame)))
      }
      if (16...29).contains(frame) {
        let rect = try XCTUnwrap(panel.anchor(for: cue.id))
        if let rightEdge { XCTAssertEqual(rect.maxX, rightEdge, accuracy: 1) }
        rightEdge = rect.maxX
        widths.append(rect.width)
      }
      if frame == 43 { XCTAssertEqual(feed.content.items.map(\.text), [sentence.text]) }
      if frame == 58 { XCTAssertEqual(feed.content.items.first?.phrases.first?.text, "我们先确认") }
    }
    let compact = try XCTUnwrap(widths.first), expanded = try XCTUnwrap(widths.last)
    XCTAssertGreaterThan(expanded, compact + 100)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      XCTAssertTrue(widths.contains { $0 > compact + 1 && $0 < expanded - 1 }, "收音提示应从同一右边缘连续展开")
    }
    XCTAssertTrue(feed.content.items.isEmpty)
  }

  @MainActor func testOnlyNewPhrasePixelsFadeInOnTheNativePanel() async throws {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { throw XCTSkip("系统已启用减弱动态效果") }
    _ = NSApplication.shared
    let feed = CaptionFeedPresentation()
    var pages = CaptionPages()
    var row = DesktopCaption(id: "fade", text: "我们周五下午", isFinal: false)
    pages.receive(row, now: Date().addingTimeInterval(-2))
    feed.update(pages.pages, username: "发言人", preview: false, animated: false)
    let screen = try XCTUnwrap(NSScreen.main)
    let panel = CaptionPanel(frame: CaptionPlacement.frame(in: screen.visibleFrame), feed: CaptionFeedView(presentation: feed))
    panel.orderBack(nil)
    defer { panel.close() }
    let host = panel.feedView
    try await Task.sleep(for: .milliseconds(80))
    let before = try png(host)

    // Schedule the release just ahead of the test clock so the first snapshot is reliably before onset.
    let onset = Date().addingTimeInterval(0.4)
    row.text += "三点开会"
    pages.receive(row, now: onset)
    feed.update(pages.pages, username: "发言人", preview: false, animated: false)
    let waiting = try png(host)
    XCTAssertEqual(before, waiting, "已有短语的位置和亮度应保持一致")
    try await Task.sleep(for: .milliseconds(750))
    let finished = try png(host)
    XCTAssertNotEqual(waiting, finished, "没有后续识别回调时，新短语也必须完成淡入")
    if ProcessInfo.processInfo.environment["WORKDAY_DESKTOP_SNAPSHOTS"] == "1",
       let output = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] {
      let root = URL(fileURLWithPath: output)
      try before.write(to: root.appendingPathComponent("phrase-before.png"))
      try finished.write(to: root.appendingPathComponent("phrase-after.png"))
    }
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
      menu.setFrameSize(NSSize(width: 340, height: menu.fittingSize.height))
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
        CaptionPreview.items(at: 0.8), username: "青木", preview: false, animated: false)
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
    let host = panel.feedView
    for elapsed in [2.0, 4.0, 7.0, 13.0] {
      model.desktop.refresh(now: start.addingTimeInterval(elapsed))
      XCTAssertTrue(model.desktop.panel?.feedView === host)
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

  @MainActor private func dismissSurface(for id: String, in panel: CaptionPanel) throws -> NSWindow {
    try XCTUnwrap(panel.childWindows?.first {
      $0.identifier?.rawValue == "workday.caption-dismiss.\(id)"
    }, "每条已显示气泡都应有可直接点击的关闭区域")
  }

  @MainActor private func click(_ window: NSWindow, at point: NSPoint, count: Int = 1) throws {
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = try XCTUnwrap(NSEvent.mouseEvent(
        with: type, location: window.convertPoint(fromScreen: point), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0))
      window.sendEvent(event)
    }
  }

  @MainActor private func assertClickTarget(
    _ window: NSWindow, at point: NSPoint, file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    window.displayIfNeeded()
    for _ in 0..<20 {
      if NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == window.windowNumber { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    let hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
    if hit != window.windowNumber,
       let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(hit)) as? [[String: Any]])?.first,
       info[kCGWindowOwnerName as String] as? String == "Window Server",
       let level = info[kCGWindowLayer as String] as? Int, level >= Int(CGShieldingWindowLevel()) {
      throw XCTSkip("Window Server 系统遮罩覆盖点击位置；后台测试不关闭遮罩或抢占前台。窗口命中验收待无遮挡桌面验证。")
    }
    XCTAssertEqual(hit, window.windowNumber,
                   "鼠标点击应由对应气泡或身份按钮接收", file: file, line: line)
  }

  @MainActor private func withVoice(_ line: LiveLine, in model: AppModel) throws -> LiveLine {
    var line = line
    let database = try VoiceLibrary(root: model.store.root)
    let evidence = "live:" + line.id
    try database.record(id: evidence, source: "fixture", live: true, seconds: 3, voice: [1, 0])
    if line.isFinal { line.voiceID = evidence }
    else { line.draftVoice = .init(id: evidence, range: 0..<6000, packets: Data(repeating: 0, count: 6000)) }
    return line
  }

  @MainActor private func isolatedModel(localCaptions: LivePreview? = nil) -> AppModel {
    let root = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    return AppModel(
      libraryURL: URL(fileURLWithPath: root).appendingPathComponent("desktop-no-services").appendingPathComponent(UUID().uuidString),
      localCaptions: localCaptions)
  }

  @MainActor private func save(_ view: NSView, named name: String) throws {
    let root = try XCTUnwrap(ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"])
    try png(view).write(to: URL(fileURLWithPath: root).appendingPathComponent("\(name).png"))
  }

  @MainActor private func menuSnapshot(_ model: AppModel) throws -> Data {
    model.desktop.refresh()
    let host = NSHostingView(rootView: MenuBarPanel(model: model, desktop: model.desktop))
    host.setFrameSize(NSSize(width: 340, height: host.fittingSize.height))
    return try png(host)
  }

  @MainActor private func png(_ view: NSView) throws -> Data {
    view.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
  }
}
