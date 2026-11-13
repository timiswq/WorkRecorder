import AppKit
import QS668Core
import SwiftUI
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class LivePreviewTests: XCTestCase {
  @MainActor func testVoiceBubbleFollowsTranscriptWhenAppleAddsTheBeginningOfASentence() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stream = TestLiveStream()
    let live = LivePreview(makeLocalStream: { stream })
    let model = AppModel(libraryURL: root, localCaptions: live)
    model.preferences.captions.showInFullScreen = true
    model.desktop.start(model: model)
    defer { model.desktop.stop(); live.reset() }
    useTestVoice(model, live)
    let packets = Data(repeating: 72, count: 6400)
    live.append(packets)
    let tail = "现在是不是准备成录"
    let complete = "我就确定一下 ，" + tail + "。"
    func hypothesis(_ text: String, _ final: Bool) {
      stream.sendApple([ASRWord(text: text, startMs: 0, endMs: 3200)], final: final, range: 0..<3200)
    }
    hypothesis(tail, false)
    hypothesis(tail + "。", false)
    let panel = try XCTUnwrap(model.desktop.panel)
    let id = try XCTUnwrap(live.lines.first?.id)
    let voice = try XCTUnwrap(live.lines.first?.bubbleVoiceID)
    func check(_ expected: String, line: UInt = #line) throws {
      let bubble = try XCTUnwrap(panel.feedView.rootView.presentation.content.items.first, line: line)
      let record = try XCTUnwrap(model.captionHistory.records.first { $0.id == id }, line: line)
      XCTAssertEqual(record.text, expected, line: line)
      XCTAssertEqual(bubble.sourceLineID, record.id, line: line)
      XCTAssertEqual(bubble.text, record.text, line: line)
      XCTAssertEqual(CaptionTypography.visibleText(bubble, username: ""), record.text, line: line)
      XCTAssertEqual(bubble.speakerLabel, model.captionSpeaker(for: record).label.captionTitle(using: model.preferences.captions), line: line)
      XCTAssertEqual(bubble.voiceID, voice, line: line)
      XCTAssertEqual(live.lines.first?.bubblePackets, packets, line: line)
    }
    hypothesis(complete, true)
    try check(complete)
    stream.finishApple()
    XCTAssertTrue(try XCTUnwrap(live.lines.first).isFinal)
    try check(complete)
  }

  @MainActor func testApplePhrasesWithoutUsableVoiceStayOnlyInHistory() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stream = TestLiveStream()
    let live = configured(stream)
    let model = AppModel(libraryURL: root, localCaptions: live)
    model.preferences.captions.showInFullScreen = true
    model.desktop.start(model: model)
    defer { model.desktop.stop(); live.reset() }
    live.configure(enabled: true, service: AIService(key: "test-only"))
    useTestVoice(model, live)
    live.append(Data(repeating: 0, count: 10000))
    func partial(_ text: String, until end: Double) {
      stream.sendApple([ASRWord(text: text, startMs: 0, endMs: end)], final: false, range: 0..<end)
    }
    partial("会意", until: 160)
    partial("会议室", until: 220)
    partial("会议室里", until: 300)
    XCTAssertNil(model.desktop.panel)
    let clause = "会议室里" + String(repeating: "请先确认日期", count: 6) + "，"
    let next = "再发通知。"
    stream.sendApple([ASRWord(text: clause, startMs: 0, endMs: 3000),
                      ASRWord(text: next, startMs: 3000, endMs: 3400)], final: true, range: 0..<3400)
    XCTAssertEqual(live.lines.map(\.text), [clause, next])
    let host = try XCTUnwrap(model.desktop.panel?.feedView)
    XCTAssertEqual(host.rootView.presentation.content.items.map(\.text), [clause])
    stream.sendApple([ASRWord(text: "好", startMs: 4500, endMs: 4760)], final: true, range: 4500..<4760)
    XCTAssertEqual(host.rootView.presentation.content.items.map(\.text), [clause])
    XCTAssertEqual(model.captionHistory.records.map(\.text), [clause, next, "好"])
  }

  @MainActor func testAudioFramesReachBothStreamsWithoutInvalidatingTheWorkspace() throws {
    let cloudStream = TestLiveStream()
    let localStream = TestLiveStream()
    let model = AppModel(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                         live: configured(cloudStream), localCaptions: configured(localStream))
    defer { model.live.reset(); model.localCaptions.reset() }
    model.card.state.connected = true
    var parser = FrameParser()
    func frame(_ payload: [UInt8]) throws -> Frame {
      try XCTUnwrap(parser.push(Wire.frame(payload, seq: 0)).first)
    }
    let bytes = Array(UInt8(0)..<40)
    let packet = try frame([1, 1] + bytes)
    model.card.receive(packet, channel: "AE22")
    var changes = 0
    let subscription = model.objectWillChange.sink { changes += 1 }
    defer { subscription.cancel() }

    model.card.receive(try frame([1, 1]), channel: "AE22")
    for _ in 0..<50 { model.card.receive(packet, channel: "AE22") }
    let expected = Data(Array(repeating: bytes, count: 51).joined())
    XCTAssertEqual(cloudStream.audio, expected)
    XCTAssertEqual(localStream.audio, expected)
    XCTAssertEqual(model.live.receivedBytes, expected.count)
    XCTAssertEqual(changes, 0)

    model.card.receive(try frame([0, 4, 78]), channel: "AE22")
    XCTAssertEqual(model.card.state.battery, 78)
    XCTAssertGreaterThan(changes, 0)
  }

  @MainActor func testDisconnectBoundaryIsDeliveredOncePerConnectedSession() {
    let card = CardObserver()
    var boundaries = 0
    card.onStreamReset = { if case .disconnected = $0 { boundaries += 1 } }

    card.state.connected = true
    card.suspendForUSB(true)
    card.updateBluetoothState(.poweredOff)
    XCTAssertEqual(boundaries, 1)

    card.suspendForUSB(false)
    card.state.connected = true
    card.disconnect()
    card.disconnect()
    XCTAssertEqual(boundaries, 2)
  }

  @MainActor func testMissingAudioWindowsStayInTranscriptIncludingLateResults() throws {
    _ = NSApplication.shared
    let root = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    let stream = TestLiveStream()
    let live = configured(stream)
    let cloudStream = TestLiveStream()
    let cloud = configured(cloudStream)
    let model = AppModel(libraryURL: URL(fileURLWithPath: root).appendingPathComponent("caption-parity"),
                         live: cloud, localCaptions: live)
    model.preferences.captions.showInFullScreen = true
    model.card.state.connected = true
    model.desktop.start(model: model)
    defer { model.desktop.stop(); live.reset() }
    live.configure(enabled: true, service: AIService(key: "test-only"))
    cloud.configure(enabled: true, service: AIService(key: "test-only"))
    model.card.onAudio?(audio())
    cloudStream.onEvent?(.sentence(id: 19, text: "百炼主窗口", isFinal: false))
    XCTAssertNil(model.desktop.panel)
    stream.onEvent?(.sentence(id: 1, text: "周四", isFinal: false, startMs: 200))
    func check(_ text: [String], line: UInt = #line) {
      XCTAssertEqual(live.lines.map(\.text), text, line: line)
      let ids = Set(live.lines.map(\.id))
      XCTAssertEqual(Set(model.captionHistory.records.filter { ids.contains($0.id) }.map(\.text)), Set(text), line: line)
      XCTAssertFalse(model.captionHistory.records.contains { $0.text == "百炼主窗口" }, line: line)
      XCTAssertNil(model.desktop.panel, line: line)
    }
    stream.onEvent?(.sentence(id: 2, text: "下午", isFinal: false, startMs: 100))
    check(["周四", "下午"])
    stream.onEvent?(.sentence(id: 0, text: "确定时间。", isFinal: true))
    check(["确定时间。", "周四", "下午"])
    model.card.state.connected = false
    live.boundary(.disconnected)
    stream.onEvent?(.sentence(id: 2, text: "下午三点。", isFinal: true))
    check(["确定时间。", "周四", "下午三点。"])
    XCTAssertEqual(cloud.lines.map(\.text), ["百炼主窗口"])
    cloud.reset()
  }

  @MainActor func testCaptionsSubscribeToNewSpeechWithoutReplayingTranscriptHistory() async throws {
    _ = NSApplication.shared
    let root = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    let stream = TestLiveStream()
    var streamsStarted = 0
    let live = LivePreview(makeStream: { _ in
      streamsStarted += 1
      return stream
    })
    let model = AppModel(
      libraryURL: URL(fileURLWithPath: root).appendingPathComponent("raw-captions"), localCaptions: live)
    model.preferences.captions.showInFullScreen = true
    model.card.state.connected = true
    defer {
      model.desktop.stop()
      live.reset()
    }
    live.configure(enabled: true, service: AIService(key: "test-only"))
    useTestVoice(model, live)
    live.append(Data(repeating: 0, count: 24000))
    stream.onEvent?(.sentence(id: 0, text: "上次说过了。", isFinal: true, startMs: 0, endMs: 3000))
    XCTAssertEqual(live.lines.last?.text, "上次说过了。")
    model.desktop.start(model: model)
    stream.onEvent?(.sentence(id: 0, text: "上次就说过了。", isFinal: true, startMs: 0, endMs: 3000))
    XCTAssertNil(model.desktop.panel)

    stream.onEvent?(.sentence(id: 1, text: "嗯，周四，", isFinal: false, startMs: 3000, endMs: 6000))
    let host = try XCTUnwrap(model.desktop.panel?.feedView)
    XCTAssertEqual(host.rootView.presentation.content.items.map(\.text), ["嗯，周四，"])
    stream.onEvent?(.sentence(id: 1, text: "嗯，周四，哦不，周五。下一项", isFinal: false, startMs: 3000, endMs: 6000))
    let firstID = try XCTUnwrap(host.rootView.presentation.content.items.first?.id)
    stream.onEvent?(.sentence(id: 1, text: "周五。下一项也确认了。", isFinal: true, startMs: 3000, endMs: 6000))
    XCTAssertEqual(host.rootView.presentation.content.items.map(\.id), [firstID])
    XCTAssertEqual(host.rootView.presentation.content.items.map(\.text), ["周五。下一项也确认了。"])
    XCTAssertEqual(live.lines.last?.text, "周五。下一项也确认了。")
    XCTAssertEqual(streamsStarted, 1)

    model.desktop.snooze()
    stream.onEvent?(.sentence(id: 2, text: "隐藏的半句", isFinal: false, startMs: 6000, endMs: 9000))
    model.desktop.resume()
    stream.onEvent?(.sentence(id: 2, text: "隐藏的半句。重新开讲。", isFinal: true, startMs: 6000, endMs: 9000))
    // The panel keeps its outgoing content during the 220 ms fade.
    for _ in 0..<50 where model.desktop.panel?.isVisible == true {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(model.desktop.panel?.isVisible, false)
    stream.onEvent?(.sentence(id: 3, text: "重新开讲。", isFinal: false, startMs: 9000, endMs: 12000))
    XCTAssertEqual(host.rootView.presentation.content.items.map(\.text), ["重新开讲。"])
    live.boundary(.started)
    live.append(Data(repeating: 0, count: 24000))
    stream.onEvent?(.sentence(id: 0, text: "新录音", isFinal: false, startMs: 0, endMs: 3000))
    XCTAssertEqual(host.rootView.presentation.content.items.map(\.text), ["新录音"])
  }

  @MainActor func testPartialAppearsOnceItsTimedAudioYieldsAUsableVoice() throws {
    _ = NSApplication.shared
    let root = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    let stream = TestLiveStream()
    let live = LivePreview(makeStream: { _ in stream })
    let model = AppModel(
      libraryURL: URL(fileURLWithPath: root).appendingPathComponent("first-partial"), localCaptions: live)
    model.preferences.captions.showInFullScreen = true
    model.card.state.connected = true
    model.desktop.start(model: model)
    defer {
      model.desktop.stop()
      live.reset()
    }
    live.configure(enabled: true, service: AIService(key: "test-only"))
    useTestVoice(model, live)
    live.append(Data(repeating: 0, count: 12000))
    stream.onEvent?(.sentence(id: 4, text: "为", isFinal: false, startMs: 0, endMs: 200))
    XCTAssertNil(model.desktop.panel)
    stream.onEvent?(.sentence(id: 4, text: "为什么", isFinal: false, startMs: 0, endMs: 3000))
    let host = try XCTUnwrap(model.desktop.panel?.feedView)
    let first = try XCTUnwrap(host.rootView.presentation.content.items.first)
    XCTAssertEqual(first.text, "为什么")
    XCTAssertFalse(first.isFinal)
    stream.onEvent?(.sentence(id: 4, text: "为什么会这样", isFinal: false, startMs: 0, endMs: 4200))
    XCTAssertEqual(host.rootView.presentation.content.items.first?.text, "为什么会这样")
    XCTAssertEqual(host.rootView.presentation.content.items.first?.voiceID, first.voiceID)
    stream.onEvent?(.sentence(id: 4, text: "为什么会这样。", isFinal: true, startMs: 0, endMs: 4200))
    let final = try XCTUnwrap(host.rootView.presentation.content.items.first)
    XCTAssertEqual(final.id, first.id)
    XCTAssertNotEqual(final.voiceID, first.voiceID)
    XCTAssertEqual(final.text, "为什么会这样。")
    XCTAssertTrue(final.isFinal)
  }

  @MainActor func testFirstAudioStartsProcessingWithoutTwentySecondWait() {
    let stream = TestLiveStream()
    let live = LivePreview(makeStream: { _ in stream })
    live.configure(enabled: true, service: AIService(key: "test-only"))
    let initial = live.status
    live.append(audio())
    XCTAssertNotEqual(live.status, initial, "收到 0.4 秒音频即进入识别")
    XCTAssertEqual(live.phase, .connecting)
    XCTAssertEqual(stream.audio.count, 800)
    stream.onEvent?(.started)
    stream.onEvent?(.sentence(id: 0, text: "正在", isFinal: false))
    XCTAssertEqual(live.lines.map(\.text), ["正在"])
    XCTAssertFalse(live.lines[0].isFinal)
    live.reset()
  }
  @MainActor func testModelSelectionAppliesToNextConnectionAndAllowsTheCurrentTailToFinish() {
    var models: [LiveASRModel] = []
    var streams: [TestLiveStream] = []
    let live = LivePreview(makeStream: { config in
      models.append(config.selectedModel)
      let stream = TestLiveStream()
      streams.append(stream)
      return stream
    })
    defer { live.reset() }
    let service = AIService(key: "test-only")
    live.configure(enabled: true, service: service)
    live.append(audio())
    live.configure(enabled: true, service: service, model: .message)
    live.append(audio())
    XCTAssertEqual(models, [.streaming])
    live.boundary(.disconnected)
    XCTAssertTrue(streams[0].finished)
    streams[0].onEvent?(.sentence(id: 1, text: "最后一句", isFinal: true))
    streams[0].onEvent?(.finished)
    XCTAssertEqual(live.lines.map(\.text), ["最后一句"])
    live.append(audio())
    XCTAssertEqual(models, [.streaming, .message])
  }

  @MainActor func testPartialRevisionsReplaceOneSentenceAndFinalWins() {
    let stream = TestLiveStream()
    let live = configured(stream)
    live.append(audio())
    stream.onEvent?(.sentence(id: 1, text: "确认", isFinal: false))
    stream.onEvent?(.sentence(id: 1, text: "确认下周", isFinal: false))
    XCTAssertEqual(live.lines.map(\.text), ["确认下周"])
    stream.onEvent?(.sentence(id: 1, text: "确认下周交付。", isFinal: true))
    stream.onEvent?(.sentence(id: 1, text: "迟到的旧文本", isFinal: false))
    XCTAssertEqual(live.lines.map(\.text), ["确认下周交付。"])
    XCTAssertTrue(live.lines[0].isFinal)
    live.reset()
  }
  @MainActor func testPauseDrainsShortTailAndKeepsFinalText() {
    var now = Date(timeIntervalSince1970: 100)
    let stream = TestLiveStream()
    let live = LivePreview(clock: { now }, makeStream: { _ in stream })
    live.configure(enabled: true, service: AIService(key: "test-only"))
    live.append(audio())
    stream.onEvent?(.sentence(id: 0, text: "短句", isFinal: false))
    live.boundary(.paused)
    XCTAssertFalse(stream.finished)
    live.append(Data(audio().prefix(40)))
    now = now.addingTimeInterval(2)
    live.tick()
    XCTAssertTrue(stream.finished)
    XCTAssertEqual(stream.audio.count, 840)
    stream.onEvent?(.sentence(id: 0, text: "短句。", isFinal: true))
    stream.onEvent?(.finished)
    XCTAssertEqual(live.lines.map(\.text), ["短句。"])
    XCTAssertEqual(live.phase, .waiting)
    live.reset()
  }
  @MainActor func testNewRecordingRejectsLateOldResults() {
    var streams: [TestLiveStream] = []
    let live = LivePreview(makeStream: { _ in
      let s = TestLiveStream()
      streams.append(s)
      return s
    })
    live.configure(enabled: true, service: AIService(key: "test-only"))
    live.append(audio())
    let late = streams[0].onEvent
    live.boundary(.started)
    live.append(audio())
    late?(.sentence(id: 0, text: "旧录音", isFinal: true))
    streams[1].onEvent?(.sentence(id: 0, text: "新录音", isFinal: false))
    XCTAssertEqual(live.lines.map(\.text), ["新录音"])
    XCTAssertTrue(streams[0].cancelled)
    live.reset()
  }

  @MainActor func testLocalTailFinishesInPreviousHistoryWhileNextRecordingIsActive() async throws {
    var streams: [TestLiveStream] = []
    let live = LivePreview(makeLocalStream: {
      let stream = TestLiveStream()
      streams.append(stream)
      return stream
    })
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString)
    let model = AppModel(libraryURL: root, localCaptions: live)
    live.configure(enabled: true, service: nil)
    live.append(audio())
    streams[0].onEvent?(.sentence(id: 0, text: "改到周", isFinal: false))
    let initial = try XCTUnwrap(model.captionHistory.records.first)
    XCTAssertTrue(live.isAwaitingFinal(initial.id))
    live.boundary(.saving)
    live.boundary(.started)
    XCTAssertTrue(live.isAwaitingFinal(initial.id))
    XCTAssertTrue(streams[0].finished)
    XCTAssertFalse(streams[0].cancelled)
    live.append(audio())
    streams[1].onEvent?(.sentence(id: 0, text: "下一条", isFinal: false))
    streams[0].onEvent?(.sentence(id: 0, text: "改到周五", isFinal: true))
    streams[0].onEvent?(.finished)
    XCTAssertFalse(live.isAwaitingFinal(initial.id))
    XCTAssertEqual(live.lines.map(\.text), ["下一条"])
    await model.captionHistory.flush()
    let reopened = CaptionHistory(root: root)
    XCTAssertEqual(reopened.records.map(\.text), ["改到周五", "下一条"])
    XCTAssertEqual(reopened.records.first?.id, initial.id)
    XCTAssertEqual(reopened.records.first?.time.timeIntervalSince1970 ?? 0,
                   initial.time.timeIntervalSince1970, accuracy: 0.001)
    XCTAssertEqual(reopened.records.first?.isFinal, true)
    let incomplete = try XCTUnwrap(live.lines.last)
    streams[1].onEvent?(.failed(code: "local-speech", message: "识别已中断"))
    XCTAssertFalse(live.isAwaitingFinal(incomplete.id))
    XCTAssertEqual(model.captionHistory.records.last?.text, "下一条")
    XCTAssertEqual(model.captionHistory.records.last?.isFinal, false)
    await model.shutdown()
  }

  @MainActor func testUnsentLocalAudioIsReplayedOnceWithItsRecordingOffset() async {
    var now = Date()
    var attempts = 0
    let stream = TestLiveStream()
    let local = LivePreview(clock: { now }, makeLocalStream: {
      attempts += 1
      if attempts == 1 { throw WorkdayError.invalid("等待识别器") }
      return stream
    })
    local.configure(enabled: true, service: nil)
    local.append(audio(), recordingOffset: 4000)
    local.append(audio(), recordingOffset: 4800)
    now.addTimeInterval(4)
    local.append(audio(), recordingOffset: 5600)
    XCTAssertEqual(stream.audio, audio() + audio() + audio())
    XCTAssertEqual(local.receivedBytes, 2400)
    stream.onEvent?(.sentence(id: 0, text: "不用", isFinal: true, startMs: 0, endMs: 400))
    XCTAssertEqual(local.lines.first?.recordingRange, 4000..<4800)
    local.reset()
    await local.waitForSpeechActivityToStop()
  }

  @MainActor func testRotationCompletesPartialOpusPacketBeforeNextStream() {
    var streams: [TestLiveStream] = []
    let live = LivePreview(makeStream: { _ in
      let stream = TestLiveStream()
      streams.append(stream)
      return stream
    })
    live.configure(enabled: true, service: AIService(key: "test-only"))
    live.append(Data(repeating: 1, count: 1_200_007))
    live.append(Data(repeating: 2, count: 20))
    XCTAssertEqual(streams.count, 1)
    live.append(Data(repeating: 3, count: 53))
    XCTAssertTrue(streams[0].finished)
    XCTAssertEqual(streams[0].audio.count, 1_200_040)
    XCTAssertEqual(streams[0].audio.suffix(13), Data(repeating: 3, count: 13))
    XCTAssertEqual(streams[1].audio, Data(repeating: 3, count: 40))
    live.reset()
  }

  @MainActor func testSpeechPauseKeepsPartialBluetoothPacketAndClosesOnlyOnce() async throws {
    guard let fixture = ProcessInfo.processInfo.environment["WORKDAY_APPLE_SPEECH_EDGES"] else {
      throw XCTSkip("Requires synthetic card audio")
    }
    let packets = try Data(contentsOf: URL(fileURLWithPath: fixture))
    // This slice ends in the silence between the first and second utterance.
    var input = Data(packets.prefix(240 * 40))
    let silence = Data(input.suffix(40))
    for _ in 0..<150 { input.append(silence) }
    var streams: [TestLiveStream] = []
    let local = LivePreview(makeLocalStream: {
      let stream = TestLiveStream()
      streams.append(stream)
      return stream
    })
    local.configure(enabled: true, service: nil)
    local.append(input.prefix(7))
    var acknowledged = false
    for offset in stride(from: 7, to: input.count, by: 200) {
      local.append(Data(input[offset..<min(input.count, offset + 200)]))
      try await Task.sleep(for: .milliseconds(12))
      if !acknowledged, streams.first?.finished == true {
        streams.first?.onEvent?(.finished)
        acknowledged = true
      }
    }
    XCTAssertTrue(acknowledged)
    XCTAssertEqual(streams.count, 2)
    XCTAssertTrue(try XCTUnwrap(streams.first).audio.count.isMultiple(of: 40))
    XCTAssertEqual(streams.reduce(into: Data()) { $0.append($1.audio) }, input)
    XCTAssertFalse(streams.last?.finished ?? true)
    local.reset()
    await local.waitForSpeechActivityToStop()
  }
  @MainActor func testDisconnectPreservesTextAndSeparatesSentenceIDsOnResume() {
    var streams: [TestLiveStream] = []
    let live = LivePreview(makeStream: { _ in
      let s = TestLiveStream()
      streams.append(s)
      return s
    })
    live.configure(enabled: true, service: AIService(key: "test-only"))
    live.append(audio())
    streams[0].onEvent?(.sentence(id: 0, text: "断开前", isFinal: true))
    live.boundary(.disconnected)
    XCTAssertEqual(live.lines.count, 1)
    live.append(audio())
    streams[1].onEvent?(.sentence(id: 0, text: "重连后", isFinal: true))
    XCTAssertEqual(live.lines.map(\.text), ["断开前", "重连后"])
    XCTAssertEqual(Set(live.lines.map(\.id)).count, 2)
    live.reset()
  }
  @MainActor func testDisabledCloudDoesNotCreateConnection() {
    var created = 0
    let live = LivePreview(makeStream: { _ in
      created += 1
      return TestLiveStream()
    })
    live.configure(enabled: false, service: AIService(key: "test-only"))
    live.append(audio())
    live.configure(enabled: true, service: nil)
    live.append(audio())
    XCTAssertEqual(created, 0)
    XCTAssertEqual(live.receivedBytes, 0)
    live.reset()
  }
  @MainActor func testFailuresBackOffAndRequireManualRetryAfterThree() {
    var now = Date(timeIntervalSince1970: 100)
    var streams: [TestLiveStream] = []
    let live = LivePreview(
      clock: { now },
      makeStream: { _ in
        let s = TestLiveStream()
        streams.append(s)
        return s
      })
    live.configure(enabled: true, service: AIService(key: "test-only"))
    for count in 1...3 {
      live.append(audio())
      XCTAssertEqual(streams.count, count)
      streams.last?.onEvent?(.failed(code: "test", message: "模拟网络故障"))
      live.append(audio())
      XCTAssertEqual(streams.count, count)
      now = now.addingTimeInterval(10)
    }
    live.append(audio())
    XCTAssertEqual(streams.count, 3)
    XCTAssertTrue(live.canRetry)
    XCTAssertTrue(live.hasGap)
    live.retry()
    live.append(audio())
    XCTAssertEqual(streams.count, 4)
    live.reset()
  }
  @MainActor func testLongLiveTranscriptIsBoundedAndRetiredTextCannotReturn() {
    let stream = TestLiveStream()
    let live = configured(stream)
    live.append(audio())
    for i in 0..<150 { stream.onEvent?(.sentence(id: i, text: "第\(i)句", isFinal: true)) }
    stream.onEvent?(.sentence(id: 0, text: "过时内容", isFinal: false))
    XCTAssertEqual(live.lines.count, 100)
    XCTAssertEqual(live.lines.first?.text, "第50句")
    XCTAssertEqual(live.lines.last?.text, "第149句")
    live.reset()
  }
  @MainActor func testLongRecordingRotatesCloudTaskWithoutClearingText() {
    var streams: [TestLiveStream] = []
    let live = LivePreview(makeStream: { _ in
      let s = TestLiveStream()
      streams.append(s)
      return s
    })
    live.configure(enabled: true, service: AIService(key: "test-only"))
    let bytes = audio()
    for _ in 0..<1500 { live.append(bytes) }
    streams[0].onEvent?(.sentence(id: 0, text: "前十分钟", isFinal: true))
    live.append(bytes)
    XCTAssertEqual(streams.count, 2)
    XCTAssertTrue(streams[0].finished)
    XCTAssertEqual(live.lines.map(\.text), ["前十分钟"])
    streams[1].onEvent?(.sentence(id: 0, text: "接下来", isFinal: false))
    streams[0].onEvent?(.finished)
    XCTAssertEqual(live.lines.map(\.text), ["前十分钟", "接下来"])
    XCTAssertEqual(live.phase, .recognizing)
    live.reset()
  }
  @MainActor func testDisablingStopsUploadAndRejectsDelayedResponses() {
    let stream = TestLiveStream()
    let live = configured(stream)
    live.append(audio())
    stream.onEvent?(.sentence(id: 0, text: "保留已识别内容", isFinal: true))
    let late = stream.onEvent
    live.configure(enabled: false, service: nil)
    live.append(audio())
    late?(.sentence(id: 1, text: "迟到结果", isFinal: true))
    XCTAssertTrue(stream.cancelled)
    XCTAssertEqual(stream.audio.count, 800)
    XCTAssertEqual(live.lines.map(\.text), ["保留已识别内容"])
    XCTAssertEqual(live.phase, .disabled)
    live.reset()
  }
  @MainActor func testNetworkFailuresRecoverAfterCooldownButAuthenticationDoesNot() {
    var now = Date(timeIntervalSince1970: 100)
    var streams: [TestLiveStream] = []
    let live = LivePreview(
      clock: { now },
      makeStream: { _ in
        let stream = TestLiveStream()
        streams.append(stream)
        return stream
      })
    live.configure(enabled: true, service: AIService(key: "test-only"))
    for _ in 0..<3 {
      live.append(audio())
      streams.last?.onEvent?(.failed(code: "network", message: "断网"))
      now = now.addingTimeInterval(10)
    }
    now = now.addingTimeInterval(61)
    live.append(audio())
    XCTAssertEqual(streams.count, 4)
    streams.last?.onEvent?(.failed(code: "configuration", message: "密钥无效"))
    now = now.addingTimeInterval(3600)
    live.retryIfRecoverable()
    live.append(audio())
    XCTAssertEqual(streams.count, 4)
    live.reset()
  }
  @MainActor private func useTestVoice(_ model: AppModel, _ live: LivePreview) {
    func record(_ id: String, _ source: String, _: Data, _ seconds: Double) {
      do { try model.voices.recordLive(id: id, source: source, seconds: seconds, vector: [1, 0], countDuration: false) }
      catch { XCTFail(error.localizedDescription) }
      model.desktop.refresh()
    }
    live.onVoice = record
    live.onDraftVoice = record
  }
  @MainActor private func configured(_ stream: TestLiveStream) -> LivePreview {
    let live = LivePreview(makeStream: { _ in stream })
    live.configure(enabled: true, service: AIService(key: "test-only"))
    return live
  }
  private func audio() -> Data {
    var packet = Data(repeating: 0, count: 40)
    packet[0] = 0x48
    return (0..<20).reduce(into: Data()) { data, _ in data.append(packet) }
  }
}

@MainActor final class TestLiveStream: AppleBubbleStreaming {
  private var phrases = AppleCaptionPhrases()
  func bubblePhrase(for sentence: Int) -> AppleBubblePhrase? { phrases.bubblePhrases[sentence] }
  func sendApple(_ words: [ASRWord], final: Bool, range: Range<Double>) {
    for event in phrases.update(words, final: final, replacing: range) { onEvent?(event) }
  }
  func finishApple() {
    for event in phrases.finish() { onEvent?(event) }
  }
  var onEvent: ((ASREvent) -> Void)?
  var audio = Data()
  var finished = false
  var cancelled = false
  func start() {}
  func append(_ data: Data) { audio.append(data) }
  func finish() { finished = true }
  func cancel() { cancelled = true }
}
