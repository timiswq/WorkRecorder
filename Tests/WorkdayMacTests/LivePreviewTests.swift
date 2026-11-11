import AppKit
import QS668Core
import SwiftUI
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class LivePreviewTests: XCTestCase {
  @MainActor func testDesktopShowsTheSameSegmentsAsTheTranscriptEvenWithLateResults() throws {
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
    let host = try XCTUnwrap(model.desktop.panel?.contentView as? NSHostingView<CaptionFeedView>)
    func check(_ text: [String], line: UInt = #line) {
      XCTAssertEqual(live.lines.map(\.text), text, line: line)
      XCTAssertEqual(host.rootView.presentation.content.items.map(\.text), text, line: line)
      XCTAssertEqual(host.rootView.presentation.content.items.map(\.id), live.lines.map(\.id), line: line)
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
    live.append(audio())
    stream.onEvent?(.sentence(id: 0, text: "上次说过了。", isFinal: true))
    XCTAssertEqual(live.lines.last?.text, "上次说过了。")
    model.desktop.start(model: model)
    stream.onEvent?(.sentence(id: 0, text: "上次就说过了。", isFinal: true))
    XCTAssertNil(model.desktop.panel)

    stream.onEvent?(.sentence(id: 1, text: "嗯，周四，", isFinal: false))
    let host = try XCTUnwrap(model.desktop.panel?.contentView as? NSHostingView<CaptionFeedView>)
    XCTAssertEqual(host.rootView.presentation.content.items.map(\.text), ["嗯，周四，"])
    stream.onEvent?(.sentence(id: 1, text: "嗯，周四，哦不，周五。下一项", isFinal: false))
    let firstID = try XCTUnwrap(host.rootView.presentation.content.items.first?.id)
    stream.onEvent?(.sentence(id: 1, text: "周五。下一项也确认了。", isFinal: true))
    XCTAssertEqual(host.rootView.presentation.content.items.map(\.id), [firstID])
    XCTAssertEqual(host.rootView.presentation.content.items.map(\.text), ["周五。下一项也确认了。"])
    XCTAssertEqual(live.lines.last?.text, "周五。下一项也确认了。")
    XCTAssertEqual(streamsStarted, 1)

    model.desktop.snooze()
    stream.onEvent?(.sentence(id: 2, text: "隐藏的半句", isFinal: false))
    model.desktop.resume()
    stream.onEvent?(.sentence(id: 2, text: "隐藏的半句。重新开讲。", isFinal: true))
    // The panel keeps its outgoing content during the 220 ms fade.
    for _ in 0..<50 where model.desktop.panel?.isVisible == true {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(model.desktop.panel?.isVisible, false)
    stream.onEvent?(.sentence(id: 3, text: "重新开讲。", isFinal: false))
    XCTAssertEqual(host.rootView.presentation.content.items.map(\.text), ["重新开讲。"])
    live.boundary(.started)
    live.append(audio())
    stream.onEvent?(.sentence(id: 0, text: "新录音", isFinal: false))
    XCTAssertEqual(host.rootView.presentation.content.items.map(\.text), ["新录音"])
  }

  @MainActor func testFirstPartialIsVisibleInsideTheRecognitionCallback() throws {
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
    live.append(audio())
    stream.onEvent?(.started)
    stream.onEvent?(.sentence(id: 4, text: "为", isFinal: false))
    // No timer tick, run-loop turn, explicit refresh, or final result between these checks.
    let panel = try XCTUnwrap(model.desktop.panel)
    XCTAssertTrue(panel.isVisible)
    XCTAssertEqual(panel.alphaValue, 1)
    let host = try XCTUnwrap(panel.contentView as? NSHostingView<CaptionFeedView>)
    let first = try XCTUnwrap(host.rootView.presentation.content.items.first)
    XCTAssertEqual(first.text, "为")
    XCTAssertFalse(first.isFinal)
    stream.onEvent?(.sentence(id: 4, text: "为什么", isFinal: false))
    XCTAssertEqual(host.rootView.presentation.content.items.map(\.id), [first.id])
    XCTAssertEqual(host.rootView.presentation.content.items.first?.text, "为什么")
    stream.onEvent?(.sentence(id: 4, text: "为什么这样。继续", isFinal: false))
    let published = host.rootView.presentation.content.items
    XCTAssertEqual(published.map(\.id), [first.id])
    XCTAssertEqual(published.map(\.isFinal), [false])
    stream.onEvent?(.sentence(id: 5, text: "下一段", isFinal: false))
    let ids = host.rootView.presentation.content.items.map(\.id)
    stream.onEvent?(.sentence(id: 4, text: "为什么会这样。继续测试。", isFinal: true))
    XCTAssertEqual(live.lines.first?.text, "为什么会这样。继续测试。")
    let bubbles = host.rootView.presentation.content.items
    XCTAssertEqual(bubbles.map(\.text), ["为什么会这样。继续测试。", "下一段"])
    XCTAssertEqual(bubbles.map(\.id), ids)
    XCTAssertEqual(bubbles.map(\.isFinal), [true, false])
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

@MainActor private final class TestLiveStream: LiveASRStreaming {
  var onEvent: ((ASREvent) -> Void)?
  var audio = Data()
  var finished = false
  var cancelled = false
  func start() {}
  func append(_ data: Data) { audio.append(data) }
  func finish() { finished = true }
  func cancel() { cancelled = true }
}
