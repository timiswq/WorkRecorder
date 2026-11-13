import AppKit
import Foundation
import QS668Core
import SQLite3
import SwiftUI
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class VoiceRecognitionTests: XCTestCase {
  private func temporaryRoot() throws -> URL {
    let base = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    return URL(fileURLWithPath: base).appendingPathComponent("voice-tests/" + UUID().uuidString)
  }

  @MainActor func testRankingIsTentativeAndExplicitReferenceSurvivesRestart() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try VoiceLibrary(root: root)
    let a: [Float] = [1, 0, 0]
    let b: [Float] = [0, 1, 0]
    try db.record(id: "first", source: "a", live: true, seconds: 15, voice: a)
    try db.record(id: "guest", source: "b", live: false, seconds: 20, voice: b)
    XCTAssertEqual(try db.label("guest")?.title, "可能是我")
    XCTAssertFalse(db.confirmed)
    try db.record(id: "a-usb", source: "a", live: false, seconds: 10, voice: a)
    try db.record(id: "guest", source: "b", live: false, seconds: 100, voice: b)
    XCTAssertEqual(try db.label("guest")?.title, "可能是我")
    // Explicitly choose a less frequent speaker. The louder/longer guest never becomes the owner.
    try db.confirm("first")
    try db.record(id: "later", source: "c", live: false, seconds: 3, voice: [0.95, 0, 0.31225])
    try db.record(id: "weak", source: "c", live: false, seconds: 4, voice: [0.55, 0, 0.835])
    try db.record(id: "silence", source: "c", live: false, seconds: 4, voice: nil)
    let reopened = try VoiceLibrary(root: root)
    XCTAssertEqual(try reopened.label("later")?.title, "我")
    XCTAssertNotEqual(try reopened.label("weak")?.title, "我")
    XCTAssertNil(try reopened.label("silence"))
    XCTAssertNotEqual(try reopened.label("guest")?.title, "我")
    try reopened.undoConfirmation()
    let group = try XCTUnwrap(reopened.label("guest")?.group)
    try reopened.reject(group)
    XCTAssertFalse(try XCTUnwrap(reopened.label("guest")).canConfirm)
    XCTAssertEqual(try reopened.label("first")?.title, "可能是我")
    try reopened.name(group, "同事")
    XCTAssertEqual(try reopened.label("guest")?.title, "同事")
    XCTAssertFalse(try VoiceLibrary(root: root).confirmed)
    XCTAssertThrowsError(try reopened.name(group, "我"))
    try reopened.name(group, "")
    try reopened.restore(group)
    XCTAssertEqual(try reopened.label("guest")?.title, "可能是我")
    XCTAssertEqual(try db.label("guest")?.title, "可能是我")
  }

  @MainActor func testAudioBoundariesExcludePartialStaleAndMixedCaptions() {
    let stream = VoiceTestStream()
    let live = LivePreview(makeStream: { _ in stream })
    var extracted: [Data] = []
    live.onVoice = { _, _, packets, _ in extracted.append(packets) }
    live.configure(enabled: true, service: AIService(key: "local-test"))
    live.append(Data(repeating: 0, count: 270_000))
    let recent = Data(repeating: 72, count: 6000)
    live.append(recent)
    stream.onEvent?(.sentence(id: 0, text: "过期", isFinal: true, startMs: 0, endMs: 3000))
    stream.onEvent?(.sentence(id: 1, text: "当前", isFinal: false, startMs: 135000, endMs: 138000))
    XCTAssertTrue(extracted.isEmpty)
    stream.onEvent?(.sentence(id: 1, text: "当前。", isFinal: true, startMs: 135000, endMs: 138000))
    XCTAssertEqual(extracted, [recent])
    stream.onEvent?(.sentence(id: 1, text: "当前。", isFinal: true, startMs: 135000, endMs: 138000))
    XCTAssertEqual(extracted.count, 1)
    stream.onEvent?(.sentence(id: 1, text: "修订时段", isFinal: true, startMs: 134000, endMs: 138000))
    XCTAssertNil(live.lines.last?.voiceID)
    XCTAssertEqual(extracted.count, 1)
    live.reset()
    stream.onEvent?(.sentence(id: 2, text: "上一段", isFinal: true, startMs: 0, endMs: 3000))
    XCTAssertEqual(extracted.count, 1)

    var feed = DesktopCaptionState()
    let a = LiveLine(id: "a", segment: 0, sentence: 0, text: "早上", isFinal: true)
    let b = LiveLine(id: "b", segment: 0, sentence: 1, text: "好。新的句子。", isFinal: true)
    feed.update(lines: [a, b], canPresent: true, now: Date())
    XCTAssertEqual(feed.items.map(\.sourceLineID), ["a", "b"])
  }

  @MainActor func testUnknownNumbersFollowSpeakersAndManualMarksSurviveLateEvidence() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try VoiceLibrary(root: root)
    let voices = VoiceRecognition(root: root)
    let local = voices.captionSpeaker(lineID: "short", evidenceID: nil)
    XCTAssertEqual(local.label.title, "未知发言人")
    voices.setExcluded(true, for: local.id)
    try db.record(id: "a1", source: "card", live: true, seconds: 3, voice: [1, 0])
    try db.record(id: "b1", source: "card", live: true, seconds: 4, voice: [0, 1])
    try db.record(id: "a2", source: "card", live: true, seconds: 3, voice: [1, 0])
    let preferences = CaptionPreferences(username: "小林")
    func title(_ line: String, _ evidence: String) -> String {
      voices.captionSpeaker(lineID: line, evidenceID: evidence).label.captionTitle(using: preferences)
    }
    XCTAssertEqual(title("short", "a1"), "未知发言人")
    XCTAssertEqual(title("other", "a2"), "未知发言人 1")
    XCTAssertEqual(title("another", "b1"), "未知发言人 2")
    XCTAssertEqual(CaptionTypography.displayName("未知发言人 123"), "未知发言人 123")
    voices.setExcluded(false, for: local.id)
    XCTAssertEqual(title("short", "a1"), "未知发言人 1")
    voices.confirm("a1", captionLineID: "short")
    XCTAssertEqual(title("other", "a2"), "小林")
    voices.confirm("b1", captionLineID: "another")
    XCTAssertEqual(title("another", "b1"), "小林")
    XCTAssertEqual(title("next", "b1"), "小林")
    let reopened = VoiceRecognition(root: root)
    let marked = reopened.captionSpeaker(lineID: "another", evidenceID: "b1")
    XCTAssertTrue(marked.label.isMine)
    reopened.undoConfirmation(for: marked.id)
    XCTAssertEqual(title("another", "b1"), "未知发言人 2")
    XCTAssertEqual(title("other", "a2"), "小林")
  }

  @MainActor func testCorrectionCalibratesHeldOutVoiceAndUndoRestoresPreviousProfile() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try VoiceLibrary(root: root)
    let voices = VoiceRecognition(root: root)
    let samples: [(String, [Float])] = [
      ("original", [1, 0, 0]), ("correction", [0.55, 0.835165, 0]),
      ("held-out", [0.56, 0.828493, 0]), ("guest", [0, 0, 1])
    ]
    for (id, voice) in samples {
      try db.record(id: id, source: "first", live: true, seconds: 3, voice: voice)
    }
    voices.confirm("original")
    XCTAssertEqual(voices.sampleCount, 1)
    XCTAssertEqual(voices.label("held-out")?.isMine, false)
    voices.confirm("correction")
    voices.confirm("correction")
    XCTAssertEqual(voices.sampleCount, 2)
    XCTAssertEqual(voices.label("held-out")?.canAddSample, true)
    XCTAssertEqual(voices.label("guest")?.isMine, false)
    try db.record(id: "next", source: "next", live: false, seconds: 4, voice: [0.57, 0.821645, 0])
    let reopened = VoiceRecognition(root: root)
    XCTAssertEqual(reopened.sampleCount, 2)
    XCTAssertEqual(reopened.label("next")?.isMine, true)
    reopened.setExcluded(true, for: "held-out")
    XCTAssertTrue(try XCTUnwrap(reopened.label("held-out")).excluded)
    XCTAssertFalse(try XCTUnwrap(reopened.label("next")).isMine)
    reopened.setExcluded(false, for: "held-out")
    XCTAssertTrue(try XCTUnwrap(reopened.label("next")).isMine)
    reopened.undoConfirmation(for: "correction")
    XCTAssertEqual(reopened.sampleCount, 1)
    XCTAssertEqual(voices.label("next")?.isMine, false)
    XCTAssertEqual(voices.label("held-out")?.isMine, false)
    XCTAssertEqual(voices.label("original")?.isMine, true)
    reopened.undo()
    XCTAssertEqual(VoiceRecognition(root: root).sampleCount, 0)
  }

  @MainActor func testFalsePositiveCorrectionCompetesWithOwnerWithoutRejectingTheGroup() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try VoiceLibrary(root: root)
    let voices = VoiceRecognition(root: root)
    try db.record(id: "owner", source: "mic", live: true, seconds: 3, voice: [1, 0])
    try db.record(id: "incorrect", source: "mic", live: true, seconds: 3, voice: [0.8, 0.6])
    voices.confirm("owner")
    XCTAssertTrue(try XCTUnwrap(voices.label("incorrect")).canAddSample)
    voices.setCaptionMark(lineID: "bubble", mine: false, evidence: "incorrect")
    voices.setCaptionMark(lineID: "bubble", mine: false, evidence: "incorrect")
    XCTAssertEqual(voices.negativeSampleCount, 1)
    let reopened = VoiceRecognition(root: root)
    try db.record(id: "another guest turn", source: "file", live: false, seconds: 4, voice: [0.78, 0.62578])
    try db.record(id: "another owner turn", source: "file", live: false, seconds: 4, voice: [0.995, 0.099875])
    XCTAssertTrue(try XCTUnwrap(reopened.label("caption:bubble")).isNegativeSample)
    XCTAssertFalse(try XCTUnwrap(reopened.label("another guest turn")).isMine)
    XCTAssertTrue(try XCTUnwrap(reopened.label("another owner turn")).isMine)
    XCTAssertEqual(reopened.label("owner")?.sampleID, "owner")
    reopened.setExcluded(false, for: "incorrect")
    XCTAssertTrue(try XCTUnwrap(voices.label("another guest turn")).isMine)
    XCTAssertEqual(voices.label("caption:bubble"), .forUtterance())
    voices.setExcluded(true, for: "incorrect")
    voices.clearNegativeSamples()
    XCTAssertEqual(voices.sampleCount, 1)
    XCTAssertEqual(voices.negativeSampleCount, 0)
    XCTAssertTrue(try XCTUnwrap(voices.label("incorrect")).excluded)
    XCTAssertTrue(try XCTUnwrap(voices.label("another guest turn")).isMine)
  }

  @MainActor func testLegacyIdentityAndTraceableConfirmationsMigrateOnlyOnce() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    do {
      let db = try VoiceLibrary(root: root)
      try db.record(id: "original", source: "old", live: true, seconds: 3, voice: [1, 0])
      try db.record(id: "file:confirmed", source: "old", live: false, seconds: 3, voice: [0, 1])
    }
    var handle: OpaquePointer?
    let path = root.appendingPathComponent("Sync/voice-campplus-v1.sqlite").path
    XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
    let setup = sqlite3_exec(handle, """
      DROP TABLE owner_samples;
      CREATE TABLE identity(id INTEGER PRIMARY KEY CHECK(id=1), turn TEXT NOT NULL REFERENCES turns(id));
      INSERT INTO identity VALUES(1,'original');
      INSERT INTO utterance_marks VALUES('file:confirmed',1),('caption:unlinked',1),('caption:other',0);
      """, nil, nil, nil)
    sqlite3_close(handle)
    XCTAssertEqual(setup, SQLITE_OK)
    let migrated = VoiceRecognition(root: root)
    XCTAssertEqual(migrated.sampleCount, 2)
    XCTAssertEqual(migrated.label("original")?.sampleID, "original")
    XCTAssertEqual(migrated.label("file:confirmed")?.sampleID, "file:confirmed")
    XCTAssertEqual(migrated.label("caption:unlinked"), .forUtterance(mine: true))
    XCTAssertEqual(migrated.label("caption:other"), .forUtterance(mine: false))
    XCTAssertEqual(migrated.negativeSampleCount, 0)
    migrated.undo()
    XCTAssertEqual(VoiceRecognition(root: root).sampleCount, 0)
  }

  @MainActor func testBubbleShowsOnlyTheOppositeActionOnHoverAndKeepsCorrections() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = NSApplication.shared
    let stream = VoiceTestStream()
    let live = LivePreview(makeLocalStream: { stream })
    let app = AppModel(libraryURL: root, localCaptions: live)
    app.preferences.captions.showInFullScreen = true
    app.desktop.start(model: app)
    defer { app.desktop.stop(); live.reset() }
    func record(_ id: String, _ source: String, _: Data, _ seconds: Double) {
      do { try app.voices.recordLive(id: id, source: source, seconds: seconds, vector: [1, 0], countDuration: true) }
      catch { XCTFail(error.localizedDescription) }
    }
    live.onVoice = record
    live.append(Data(repeating: 0, count: 6000))
    stream.onEvent?(.sentence(id: 0, text: "123", isFinal: false))
    XCTAssertNil(app.desktop.panel)
    stream.onEvent?(.sentence(id: 0, text: "12345", isFinal: true, startMs: 0, endMs: 3000))
    let line = try XCTUnwrap(live.lines.first)
    let target = try XCTUnwrap(line.voiceID)
    func bubbleTitle() throws -> String? {
      app.desktop.refresh()
      let host = try XCTUnwrap(app.desktop.panel?.feedView)
      return host.rootView.presentation.content.items.first?.speakerLabel
    }
    app.desktop.refresh(pointer: .zero)
    XCTAssertTrue(app.desktop.voiceActions.isEmpty)
    XCTAssertEqual(try bubbleTitle(), "未知发言人 1")
    let first = try await buttons(target, in: app)
    XCTAssertEqual(buttonTitles(in: first), ["是我"])
    try click("是我", in: first.contentView)
    XCTAssertEqual(try bubbleTitle(), CaptionPreferences().resolvedUsername())
    app.preferences.captions.username = "小林"
    XCTAssertEqual(try bubbleTitle(), "小林")
    XCTAssertEqual(app.voices.sampleCount, 1)
    let mine = try await buttons(target, in: app)
    XCTAssertEqual(buttonTitles(in: mine), ["不是我"])
    try click("不是我", in: mine.contentView)
    XCTAssertEqual(try bubbleTitle(), "非本人")
    XCTAssertEqual(app.voices.negativeSampleCount, 1)
    XCTAssertEqual(VoiceRecognition(root: root).label(target)?.excluded, true)
    let excluded = try await buttons(target, in: app)
    XCTAssertEqual(buttonTitles(in: excluded), ["是我"])
    try click("是我", in: excluded.contentView)
    XCTAssertEqual(try bubbleTitle(), "小林")
    XCTAssertEqual(app.menuRecentSpeech?.speaker?.isMine, true)
    app.desktop.refresh(pointer: .zero)
    XCTAssertTrue(app.desktop.voiceActions.isEmpty)
    await app.shutdown()
  }

  @MainActor func testCloseButtonRetiresOnlyItsDraftWhileRecognitionContinues() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = NSApplication.shared
    let stream = VoiceTestStream()
    let live = LivePreview(makeLocalStream: { stream })
    let app = AppModel(libraryURL: root, localCaptions: live)
    let desktop = app.desktop
    app.preferences.captions.showInFullScreen = true
    desktop.start(model: app)
    defer { desktop.stop(); live.reset() }
    let capture: (String, String, Data, Double) -> Void = { id, source, _, seconds in
      do { try app.voices.recordLive(id: id, source: source, seconds: seconds, vector: [1, 0], countDuration: false) }
      catch { XCTFail(error.localizedDescription) }
    }
    live.onVoice = capture
    live.onDraftVoice = capture
    live.append(Data(repeating: 0, count: 18000))
    stream.onEvent?(.sentence(id: 0, text: "上一句。", isFinal: true, startMs: 0, endMs: 3000))
    stream.onEvent?(.sentence(id: 1, text: "核对中", isFinal: false, startMs: 3000, endMs: 6000))
    desktop.refresh()
    let draft = try XCTUnwrap(live.lines.last)
    let panel = try XCTUnwrap(desktop.panel)
    let feed = panel.feedView.rootView.presentation
    desktop.refresh(pointer: .zero)
    XCTAssertNil(desktop.closeButton)
    let bubble = try XCTUnwrap(panel.anchor(for: draft.id))
    desktop.refresh(pointer: NSPoint(x: bubble.midX, y: bubble.midY))
    let close = try XCTUnwrap(desktop.closeButton)
    let identity = try XCTUnwrap(desktop.voiceActions[draft.id])
    XCTAssertEqual(close.captionID, draft.id)
    XCTAssertTrue(close.isVisible)
    XCTAssertFalse(close.canBecomeKey)
    XCTAssertEqual(close.frame.midX, bubble.maxX - 2, accuracy: 1)
    XCTAssertEqual(close.frame.midY, bubble.maxY - 3, accuracy: 1)
    XCTAssertEqual(bubble.maxX - identity.frame.maxX, 12, accuracy: 1,
                   "短句标题行只保留原有内边距")
    XCTAssertFalse(close.frame.intersects(identity.frame))
    XCTAssertTrue(panel.ignoresMouseEvents)
    desktop.refresh(pointer: .zero)
    XCTAssertNil(desktop.closeButton)
    close.button.performClick(nil)
    XCTAssertEqual(feed.content.items.count, 2, "移走指针后，旧按钮不能关闭气泡")
    desktop.refresh(pointer: NSPoint(x: bubble.midX, y: bubble.midY))
    let active = try XCTUnwrap(desktop.closeButton)
    let outerEdge = NSPoint(x: active.frame.maxX - 0.5, y: active.frame.midY)
    XCTAssertFalse(panel.frame.contains(outerEdge))
    desktop.refresh(pointer: outerEdge)
    XCTAssertTrue(desktop.closeButton === active)
    active.button.performClick(nil)
    active.button.performClick(nil)
    XCTAssertEqual(feed.content.items.map(\.text), ["上一句。"])
    stream.onEvent?(.sentence(id: 1, text: "核对完成。", isFinal: true, startMs: 3000, endMs: 6000))
    stream.onEvent?(.sentence(id: 2, text: "下一句。", isFinal: true, startMs: 6000, endMs: 9000))
    desktop.refresh()
    XCTAssertEqual(feed.content.items.map(\.text), ["上一句。", "下一句。"])
    XCTAssertEqual(live.lines.map(\.text), ["上一句。", "核对完成。", "下一句。"])
    await app.shutdown()
  }

  @MainActor func testPublicSpeechThroughLiveAudioConfirmationAndArchive() async throws {
    guard let path = ProcessInfo.processInfo.environment["WORKDAY_PUBLIC_SPEECH"] else {
      throw XCTSkip("Set WORKDAY_PUBLIC_SPEECH to the public speaker example fixtures")
    }
    let fixtures = URL(fileURLWithPath: path)
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stream = VoiceTestStream()
    let live = LivePreview(makeStream: { _ in stream })
    let app = AppModel(libraryURL: root, localCaptions: live)
    _ = NSApplication.shared
    app.preferences.boundName = "QS668 录音卡"
    app.preferences.captions.username = "小林"
    app.preferences.captions.showInFullScreen = true
    app.card.state.connected = true
    app.desktop.start(model: app)
    defer {
      app.desktop.stop()
      live.reset()
    }
    live.configure(enabled: true, service: AIService(key: "test-only"))
    func emit(_ name: String, number: Int) throws -> String {
      let raw = try Data(contentsOf: fixtures.appendingPathComponent(name + ".opusraw"))
      let start = live.receivedSeconds
      live.append(raw)
      stream.onEvent?(
        .sentence(
          id: number, text: "自然对话。", isFinal: true, startMs: start * 1000,
          endMs: live.receivedSeconds * 1000))
      return try XCTUnwrap(live.lines.last?.voiceID)
    }
    func awaitLabel(_ key: String) async throws -> VoiceLabel {
      for _ in 0..<300 {
        if let label = app.voices.label(key) { return label }
        if let error = app.voices.error {
          XCTFail(error)
          break
        }
        try await Task.sleep(for: .milliseconds(25))
      }
      return try XCTUnwrap(app.voices.label(key), "未得到可用声纹 " + key)
    }
    let first = try emit("fangjun-sr-2", number: 0)
    let suggestion = try await awaitLabel(first)
    XCTAssertEqual(suggestion.title, "可能是我")
    let guest = try emit("leijun-test-sr-2", number: 1)
    _ = try await awaitLabel(guest)
    let firstActions = try await buttons(first, in: app)
    XCTAssertFalse(firstActions.canBecomeKey)
    XCTAssertEqual(app.desktop.panel?.ignoresMouseEvents, true)
    try click("是我", in: firstActions.contentView)
    XCTAssertTrue(app.voices.confirmed)
    XCTAssertFalse(app.voices.label(guest)?.isMine ?? true)
    let remaining = try await buttons(guest, in: app)
    XCTAssertEqual(buttonTitles(in: remaining), ["是我"])
    XCTAssertEqual(app.desktop.voiceActions.count, 1)
    let guestGroup = try XCTUnwrap(app.voices.label(guest)?.group)
    let next = try emit("fangjun-test-sr-1", number: 2)
    let later = try await awaitLabel(next)
    XCTAssertTrue(later.isMine)
    _ = try await buttons(next, in: app)
    let feed = try XCTUnwrap(app.desktop.panel?.feedView)
    XCTAssertEqual(feed.rootView.presentation.content.items.map(\.speakerLabel),
                   ["小林", "未知发言人 \(guestGroup)", "小林"])
    if ProcessInfo.processInfo.environment["WORKDAY_DESKTOP_SNAPSHOTS"] == "1",
       let root = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] {
      var parser = FrameParser()
      for payload: [UInt8] in [[3, 20, 1], [0, 4, 76], [3, 22, 4, 2, 0, 0, 0, 0]] {
        app.card.state.apply(try XCTUnwrap(parser.push(Wire.frame(payload, seq: 0)).first))
      }
      app.desktop.refresh()
      XCTAssertEqual(app.desktop.status.kind, .recording)
      XCTAssertEqual(app.menuRecentSpeech?.speaker?.isMine, true)
      let menu = NSHostingView(rootView: MenuBarPanel(model: app, desktop: app.desktop))
      menu.setFrameSize(NSSize(width: 320, height: menu.fittingSize.height))
      menu.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(menu.bitmapImageRepForCachingDisplay(in: menu.bounds))
      menu.cacheDisplay(in: menu.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        .write(to: URL(fileURLWithPath: root).appendingPathComponent("menu-recording.png"))
      for (turn, filename) in [(guest, "bubble-hover-other"), (next, "bubble-hover-self")] {
        let action = try await buttons(turn, in: app)
        let panel = try XCTUnwrap(app.desktop.panel)
        let close = try XCTUnwrap(app.desktop.closeButton)
        let bounds = panel.frame.union(close.frame).insetBy(dx: -3, dy: -3).integral
        let composed = NSImage(size: bounds.size)
        composed.lockFocus()
        for window in [panel as NSWindow, action as NSWindow, close as NSWindow] {
          if let view = window.contentView,
             let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let layer = NSImage(size: view.bounds.size)
            layer.addRepresentation(bitmap)
            layer.draw(in: window.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY),
                       from: .zero, operation: .sourceOver, fraction: 1)
          }
        }
        composed.unlockFocus()
        let image = try XCTUnwrap(composed.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) })
        try XCTUnwrap(image.representation(using: .png, properties: [:]))
          .write(to: URL(fileURLWithPath: root).appendingPathComponent(filename + ".png"))
      }
    }
    let expiry = Date().addingTimeInterval(60)
    app.desktop.refresh(now: expiry)
    XCTAssertFalse(app.desktop.voiceActions.values.contains { $0.turnID == first })
    app.desktop.refresh(now: expiry.addingTimeInterval(1.5))
    XCTAssertFalse(app.desktop.voiceActions.values.contains { $0.turnID == guest })
    app.desktop.refresh(now: expiry.addingTimeInterval(3))
    XCTAssertTrue(app.desktop.voiceActions.isEmpty)
    app.voices.name(guestGroup, "林老师")
    XCTAssertEqual(app.voices.label(guest)?.title, "林老师")
    XCTAssertEqual(app.voices.label(next)?.title, "我")
    XCTAssertEqual(VoiceRecognition(root: root).label(guest)?.title, "林老师")
    let guestAgain = try emit("leijun-test-sr-2", number: 3)
    let named = try await awaitLabel(guestAgain)
    XCTAssertEqual(named.title, "林老师")
    app.desktop.refresh(pointer: .zero)
    XCTAssertTrue(app.desktop.voiceActions.isEmpty)
    XCTAssertEqual(feed.rootView.presentation.content.items.last?.identityControls, .confirm)
    XCTAssertEqual(feed.rootView.presentation.content.items.last?.speakerLabel, "林老师")
    let extra = try emit("fangjun-test-sr-1", number: 4)
    let extraLabel = try await awaitLabel(extra)
    XCTAssertTrue(extraLabel.isMine)
    let inferred = try await buttons(extra, in: app)
    XCTAssertEqual(app.voices.sampleCount, 1)
    XCTAssertEqual(buttonTitles(in: inferred), ["不是我"])
    try click("不是我", in: inferred.contentView)
    XCTAssertEqual(feed.rootView.presentation.content.items.last?.speakerLabel, "非本人")
    XCTAssertEqual(app.voices.negativeSampleCount, 1)
    let marked = try await buttons(extra, in: app)
    try click("是我", in: marked.contentView)
    XCTAssertEqual(app.voices.negativeSampleCount, 0)
    XCTAssertEqual(app.voices.sampleCount, 2)
    let corrected = try await buttons(extra, in: app)
    XCTAssertEqual(buttonTitles(in: corrected), ["不是我"])
    try click("不是我", in: corrected.contentView)
    XCTAssertEqual(app.voices.sampleCount, 1)
    XCTAssertEqual(app.voices.negativeSampleCount, 1)
    let undo = try await buttons(extra, in: app)
    let control = try XCTUnwrap(undo.contentView?.subviews.first as? NSButton)
    let menu = try XCTUnwrap(control.menu)
    menu.performActionForItem(at: 0)
    XCTAssertEqual(app.voices.negativeSampleCount, 0)
    let wav = fixtures.appendingPathComponent("fangjun-test-sr-1.wav")
    let duration = try AudioFiles.duration(wav)
    let recording = try await app.store.importAudio(wav, sourceID: "usb:test")
    let line = TranscriptLine(id: "0:1", start: 0, end: duration, text: "自然对话")
    var oldDocument = ProcessingDocument(recording: recording, model: "fixture")
    oldDocument.transcript = [line]
    oldDocument.phase = "complete"
    try await app.store.save(oldDocument, recording: recording)
    await app.reload()
    let archived = try await awaitLabel(VoiceRecognition.key(recording, line))
    XCTAssertTrue(archived.isMine)
    XCTAssertTrue(VoiceRecognition(root: root).confirmed)
    await app.shutdown()
  }

  @MainActor func testPublicDraftFeedbackPersistsExactPacketsAndRecognizesAnotherUtterance() async throws {
    guard let path = ProcessInfo.processInfo.environment["WORKDAY_PUBLIC_SPEECH"] else {
      throw XCTSkip("Requires the public speaker example fixtures")
    }
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixtures = URL(fileURLWithPath: path)
    let audio = try Data(contentsOf: fixtures.appendingPathComponent("fangjun-sr-2.opusraw"))
    let nextAudio = try Data(contentsOf: fixtures.appendingPathComponent("fangjun-test-sr-1.opusraw"))
    let guestAudio = try Data(contentsOf: fixtures.appendingPathComponent("leijun-test-sr-2.opusraw"))
    let stream = VoiceTestStream()
    let local = LivePreview(makeLocalStream: { stream })
    let app = AppModel(libraryURL: root, localCaptions: local)
    app.preferences.captions.showInFullScreen = true
    app.desktop.start(model: app)
    defer { app.desktop.stop(); local.reset() }
    local.append(audio)
    let end = local.receivedSeconds * 1000
    stream.onEvent?(.sentence(id: 0, text: "同一个人说的第一句", isFinal: false, startMs: 0, endMs: end))
    let draft = try XCTUnwrap(local.lines.first?.draftVoice)
    let actions = try await buttons(draft.id, in: app)
    try click("是我", in: actions.contentView)
    XCTAssertEqual(app.captionSpeaker(for: try XCTUnwrap(local.lines.first)).label.sampleID, draft.id)
    stream.onEvent?(.sentence(id: 0, text: "同一个人说的第一句。", isFinal: true, startMs: 0, endMs: end))
    await app.voices.waitForStoppedTasks()
    XCTAssertEqual(app.captionSpeaker(for: try XCTUnwrap(local.lines.first)).label.sampleID, draft.id)
    let db = try VoiceLibrary(root: root)
    XCTAssertEqual(try db.sampleAudio(draft.id), audio)
    local.append(guestAudio)
    stream.onEvent?(.sentence(id: 1, text: "另一个人", isFinal: true,
                              startMs: end, endMs: local.receivedSeconds * 1000))
    let guest = try XCTUnwrap(local.lines.last?.voiceID)
    let guestActions = try await buttons(guest, in: app)
    let menu = try XCTUnwrap((guestActions.contentView?.subviews.first as? NSButton)?.menu)
    XCTAssertEqual(menu.items.map(\.title), ["不是我"])
    menu.performActionForItem(at: 0)
    XCTAssertEqual(try db.sampleAudio(guest), guestAudio)
    await app.shutdown()
    let reopened = VoiceRecognition(root: root)
    reopened.observeLive(id: "next", source: "another-session", packets: nextAudio, seconds: Double(nextAudio.count) / 2000)
    await reopened.waitForStoppedTasks()
    XCTAssertTrue(try XCTUnwrap(reopened.label("next")).isMine)
    XCTAssertEqual(reopened.negativeSampleCount, 1)
    XCTAssertTrue(try XCTUnwrap(reopened.label(guest)).isNegativeSample)
  }

  @MainActor func testUsableUngroupedVoiceCanBeLearnedAndCorrectedAtomically() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try VoiceLibrary(root: root)
    let packets = Data(repeating: 72, count: 6000)
    for (id, vector): (String, [Float]) in [
      ("a", [1, 0]), ("b", [0, 1]), ("ambiguous", [0.707107, 0.707107]), ("later", [0.705, 0.709])
    ] {
      try db.record(id: id, source: "card", live: true, seconds: 3, voice: vector)
    }
    XCTAssertNil(try db.localGroup(for: "ambiguous"))
    XCTAssertTrue(try db.hasLiveVoice("ambiguous"))
    try db.setCaptionMark("caption:row", mine: true, evidence: "ambiguous", packets: packets)
    let reopened = try VoiceLibrary(root: root)
    XCTAssertTrue(try XCTUnwrap(reopened.label("later")).isMine)
    XCTAssertEqual(try reopened.sampleAudio("ambiguous"), packets)
    XCTAssertThrowsError(try reopened.setCaptionMark("caption:row", mine: false, evidence: "missing", packets: packets))
    XCTAssertEqual(reopened.sampleCount, 1)
    try reopened.setCaptionMark("caption:row", mine: false, evidence: "ambiguous", packets: packets)
    XCTAssertEqual(reopened.sampleCount, 0)
    XCTAssertEqual(reopened.negativeSampleCount, 1)
    XCTAssertEqual(try reopened.sampleAudio("ambiguous"), packets)
    try reopened.undoNotMine("caption:row")
    XCTAssertNil(try reopened.sampleAudio("ambiguous"))
    try db.name(try XCTUnwrap(db.localGroup(for: "a")), "同事")
    try db.record(id: "misgrouped", source: "card", live: true, seconds: 3, voice: [0.90, 0.43589])
    try db.record(id: "similar", source: "card", live: true, seconds: 3, voice: [0.89, 0.45596])
    XCTAssertEqual(try db.label("similar")?.savedName, "同事")
    try db.setCaptionMark("caption:other", mine: true, evidence: "misgrouped", packets: packets)
    XCTAssertTrue(try XCTUnwrap(db.label("similar")).isMine)
    XCTAssertEqual(try db.label("a")?.savedName, "同事")
    for (id, vector): (String, [Float]) in [("nan", [.nan]), ("zero", [0, 0])] {
      try db.record(id: id, source: "card", live: true, seconds: 3, voice: vector)
      XCTAssertFalse(try db.hasLiveVoice(id))
    }
  }

  @MainActor func testDraftConfirmationLearnsExactLocalAudioWhenCloudIsAlsoActive() async throws {
    guard let path = ProcessInfo.processInfo.environment["WORKDAY_PUBLIC_SPEECH"] else {
      throw XCTSkip("Requires the public speaker example fixtures")
    }
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stream = VoiceTestStream()
    let local = LivePreview(makeLocalStream: { stream })
    let app = AppModel(libraryURL: root, localCaptions: local)
    app.preferences.captions.enabled = true
    // Exercise the local audio capture policy used with an active cloud transcript.
    local.onVoice = nil
    local.retainConfirmationAudio = true
    let fixtures = URL(fileURLWithPath: path)
    func draft(_ file: String, number: Int) throws -> (line: String, start: Double) {
      let start = local.receivedSeconds * 1000
      local.append(try Data(contentsOf: fixtures.appendingPathComponent(file + ".opusraw")))
      stream.onEvent?(.sentence(id: number, text: "第一句", isFinal: false))
      let line = try XCTUnwrap(local.lines.last?.id)
      XCTAssertTrue(app.confirmCaption(line))
      return (line, start)
    }
    let first = try draft("fangjun-sr-2", number: 0)
    XCTAssertEqual(app.voices.sampleCount, 0)
    stream.onEvent?(.sentence(id: 0, text: "第一句。", isFinal: true,
                              startMs: first.start, endMs: local.receivedSeconds * 1000))
    for _ in 0..<120 {
      if app.voices.sampleCount == 1 { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertEqual(app.voices.sampleCount, 1)
    XCTAssertEqual(app.captionSpeaker(for: first.line).label.sampleID, "live:" + first.line)
    let revoked = try draft("leijun-test-sr-2", number: 1)
    app.voices.undoConfirmation(for: "caption:" + revoked.line)
    stream.onEvent?(.sentence(id: 1, text: "另一位。", isFinal: true,
                              startMs: revoked.start, endMs: local.receivedSeconds * 1000))
    app.voices.resolvePendingCaptions(in: local)
    await app.voices.waitForStoppedTasks()
    XCTAssertEqual(app.voices.sampleCount, 1)
    XCTAssertFalse(app.captionSpeaker(for: revoked.line).label.isMine)
    await app.shutdown()
  }

  @MainActor func testCorrectingBorrowedCloudLabelUsesOnlyLocalPhraseAudio() async throws {
    guard let path = ProcessInfo.processInfo.environment["WORKDAY_PUBLIC_SPEECH"] else {
      throw XCTSkip("Requires the public speaker example fixtures")
    }
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try VoiceLibrary(root: root)
    let fixtures = URL(fileURLWithPath: path)
    let ownerAudio = try Data(contentsOf: fixtures.appendingPathComponent("fangjun-sr-2.opusraw"))
    let guestAudio = try Data(contentsOf: fixtures.appendingPathComponent("leijun-test-sr-2.opusraw"))
    let encoded = try await SpeakerEncoder().live(packets: ownerAudio)
    let owner = try XCTUnwrap(encoded)
    try db.record(id: "owner", source: "reference", live: true, seconds: 4, voice: owner)
    try db.confirm("owner")
    let cloudStream = VoiceTestStream()
    let localStream = VoiceTestStream()
    let local = LivePreview(makeLocalStream: { localStream })
    let cloud = LivePreview(makeLocalStream: { cloudStream })
    let app = AppModel(libraryURL: root, live: cloud, localCaptions: local)
    app.preferences.captions.enabled = true
    local.onVoice = nil
    local.retainConfirmationAudio = true
    cloud.configure(enabled: true, service: nil)
    // Simulate a wider cloud turn that has been attributed to the wrong person.
    cloud.onVoice = { id, source, _, seconds in
      do { try db.record(id: id, source: source, live: true, seconds: seconds, voice: owner) }
      catch { XCTFail(error.localizedDescription) }
    }
    cloud.append(guestAudio)
    local.append(guestAudio)
    let end = local.receivedSeconds * 1000
    cloudStream.onEvent?(.sentence(id: 0, text: "同一段", isFinal: true, startMs: 0, endMs: end))
    let covering = try XCTUnwrap(cloud.lines.first?.voiceID)
    localStream.onEvent?(.sentence(id: 0, text: "短句", isFinal: true, startMs: 0, endMs: 400))
    let short = try XCTUnwrap(local.lines.first?.id)
    XCTAssertTrue(app.correctCaption(short, expectedTurn: covering))
    XCTAssertEqual(app.captionSpeaker(for: short).label.title, "不是我")
    XCTAssertEqual(app.voices.negativeSampleCount, 0)
    localStream.onEvent?(.sentence(id: 1, text: "其余的话", isFinal: true, startMs: 400, endMs: end))
    let line = try XCTUnwrap(local.lines.last)
    XCTAssertTrue(app.captionSpeaker(for: line.id).label.isMine)
    XCTAssertTrue(app.correctCaption(line.id, expectedTurn: covering))
    for _ in 0..<120 {
      if app.voices.negativeSampleCount == 1 { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(try XCTUnwrap(app.voices.label(line.voiceID)).isNegativeSample)
    XCTAssertTrue(try XCTUnwrap(app.voices.label(covering)).isMine)
    XCTAssertEqual(app.voices.negativeSampleCount, 1)
    XCTAssertEqual(app.voices.sampleCount, 1)
    await app.shutdown()
  }

  @MainActor private func buttons(_ turn: String, in app: AppModel) async throws -> CaptionVoiceActions {
    for _ in 0..<80 {
      app.desktop.refresh()
      if let panel = app.desktop.panel,
         let item = panel.feedView.rootView.presentation.content.items.last(where: { $0.voiceID == turn }),
         let frame = panel.anchor(for: item.id) {
        app.desktop.refresh(pointer: NSPoint(x: frame.midX, y: frame.midY))
      }
      if let (bubble, actions) = app.desktop.voiceActions.first(where: { $0.value.turnID == turn }
      ),
        actions.isVisible, let area = app.desktop.panel?.anchor(for: bubble)
      {
        XCTAssertTrue(
          area.insetBy(dx: -0.5, dy: -0.5).contains(actions.frame),
          "Buttons must be inside their own bubble")
        return actions
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    throw NSError(
      domain: "VoiceRecognitionTests", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "没有找到对应气泡内的标注按钮"])
  }
  @MainActor private func buttonTitles(in panel: CaptionVoiceActions) -> [String] {
    (panel.contentView?.subviews ?? []).compactMap { ($0 as? NSButton)?.title }
  }
  @MainActor private func click(_ title: String, in view: NSView?) throws {
    func find(_ v: NSView) -> NSButton? {
      if let button = v as? NSButton, button.title == title { return button }
      for child in v.subviews { if let button = find(child) { return button } }
      return nil
    }
    let button = try XCTUnwrap(view.flatMap(find), title)
    XCTAssertTrue(button.isEnabled)
    button.performClick(nil)
  }
}

@MainActor private final class VoiceTestStream: LiveASRStreaming {
  var onEvent: ((ASREvent) -> Void)?
  func start() {}
  func append(_ data: Data) {}
  func finish() {}
  func cancel() {}
}
