import Foundation
import WorkdayCore
import XCTest
@testable import WorkdayMac

@MainActor final class LiveCaptionRouterTests: XCTestCase {
  private func row(_ id: String, _ text: String, _ span: Range<Int>, final: Bool = false) -> LiveLine {
    LiveLine(id: id, segment: 0, sentence: 0, text: text, isFinal: final,
             recognitionRange: span, stableCloudText: text)
  }

  func testOnlyLocalReadinessStartsDeadlineAndALateCloudCannotReplaceText() {
    var now = ContinuousClock.now
    let route = LiveCaptionRouter(now: { now })
    route.configure(enabled: true)
    route.setAvailable(true)
    var local = row("local", "号", 0..<540, final: true)
    local.isFinal = false
    local.bubblePhrase = .init(text: "", continuesPrevious: false)
    route.receiveLocal([local])
    now += .seconds(2)
    XCTAssertEqual(route.lines.first?.bubblePhrase?.text, "")
    local.isFinal = true
    local.bubblePhrase = .init(text: "号", continuesPrevious: false)
    route.receiveLocal([local])
    now += .milliseconds(140)
    route.receiveLocal([local])
    XCTAssertEqual(route.lines.first?.text, "")
    now += .milliseconds(11)
    route.receiveCloud([row("cloud", "好", 0..<540, final: true)])
    XCTAssertEqual(route.lines.first?.text, "号")
    XCTAssertNil(route.cloudSource(for: local.id))
    route.receiveLocal([])
  }

  func testTimelyCloudWinsOnSameAudioWithLocalReplayAndSpeakerIdentity() {
    var now = ContinuousClock.now
    let route = LiveCaptionRouter(now: { now })
    route.configure(enabled: true)
    route.setAvailable(true)
    var local = row("local", "队", 20..<600, final: true)
    local.voiceID = "local-speaker"
    route.receiveLocal([local])
    now += .milliseconds(149)
    route.receiveCloud([row("cloud", "对", 20..<600, final: true)])
    XCTAssertEqual(route.lines.first?.text, "对")
    XCTAssertEqual(route.lines.first?.id, local.id)
    XCTAssertEqual(route.lines.first?.voiceID, local.voiceID)
    route.receiveCloud([row("cloud", "队", 20..<600, final: true)])
    XCTAssertEqual(route.lines.first?.bubblePhrase?.text, "对")
    route.receiveLocal([])
  }

  func testAmbiguousOverlapAndAdjacentTurnCannotSupplySingleCharacter() {
    let local = row("local", "好", 1800..<2200, final: true)
    let inputs = [[row("other", "对", 1400..<1800, final: true)],
                  [row("merged", "我们走吧好", 0..<2400, final: true)],
                  [row("one", "好", 1740..<2180, final: true), row("two", "对", 1900..<2280, final: true)]]
    for cloud in inputs {
      let route = LiveCaptionRouter()
      route.configure(enabled: true)
      route.setAvailable(true)
      route.receiveCloud(cloud)
      route.receiveLocal([local])
      route.setAvailable(false)
      XCTAssertEqual(route.lines.first?.text, "好")
      XCTAssertNil(route.cloudSource(for: local.id))
    }
  }

  func testCloudOffAndFailureReleaseLocalImmediatelyAndResetCancelsPending() {
    let route = LiveCaptionRouter()
    let local = row("first", "好", 0..<400, final: true)
    route.receiveLocal([local])
    XCTAssertEqual(route.lines.first?.text, "好")
    route.configure(enabled: true)
    route.setAvailable(true)
    route.receiveCloud([row("cloud", "号", 0..<400, final: true)])
    XCTAssertEqual(route.lines.first?.text, "好")
    route.receiveCloud([])
    route.receiveLocal([])
    route.receiveLocal([row("second", "对", 0..<400, final: true)])
    XCTAssertEqual(route.lines.first?.text, "")
    route.setAvailable(false)
    XCTAssertEqual(route.lines.first?.text, "对")
  }

  func testCloudPartialAppendsAndAnInterruptedStreamPreservesTheVisiblePrefix() {
    let route = LiveCaptionRouter()
    route.configure(enabled: true)
    route.setAvailable(true)
    route.receiveCloud([row("cloud", "资料齐了", 0..<2000)])
    route.receiveLocal([row("local", "资聊齐了", 0..<2100)])
    // Three matching terminal characters are required for a longer draft.
    XCTAssertEqual(route.lines.first?.text, "")
    route.receiveLocal([row("local", "材料齐了", 0..<2100)])
    XCTAssertEqual(route.lines.first?.text, "资料齐了")
    route.receiveCloud([row("cloud", "资料齐了先开会", 0..<3200)])
    route.receiveLocal([row("local", "材料齐了先开会", 0..<3200)])
    XCTAssertEqual(route.lines.first?.text, "资料齐了先开会")
    route.setAvailable(false)
    route.receiveLocal([row("local", "材料齐了先开会再发邮件", 0..<4500)])
    XCTAssertEqual(route.lines.first?.text, "资料齐了先开会再发邮件")
    XCTAssertEqual(route.lines.first?.textSource, .mixed)
    route.receiveCloud([row("cloud", "资料齐了先开会稍后发邮件", 0..<4500, final: true)])
    XCTAssertEqual(route.lines.first?.text, "资料齐了先开会再发邮件")
  }

  func testDifferentNumberFormatsCannotDuplicateTheCloudPrefixWhenNetworkDrops() {
    let route = LiveCaptionRouter()
    route.configure(enabled: true)
    route.setAvailable(true)
    route.receiveCloud([row("remote", "明天", 0..<1600)])
    route.receiveLocal([row("local", "明天", 0..<2000)])
    route.receiveLocal([row("local", "明天下午 3:00", 0..<4000)])
    route.receiveCloud([row("remote", "明天下午3", 0..<3600)])
    route.setAvailable(false)
    route.receiveLocal([row("local", "明天下午 3:00开会", 0..<5200, final: true)])
    XCTAssertEqual(route.lines.first?.bubblePhrase?.text, "明天下午3:00开会")
  }

  func testDroppedAcknowledgementDoesNotPreventRecoveryOfUnreadLocalTail() {
    let route = LiveCaptionRouter()
    route.configure(enabled: true)
    route.setAvailable(true)
    route.receiveCloud([row("remote", "大家", 0..<900)])
    route.receiveLocal([row("local", "大家", 0..<1000)])
    route.receiveLocal([row("local", "大家能到吗？我先把", 0..<5000)])
    route.receiveCloud([row("remote", "大家能到吗？好，我先把", 0..<4800)])
    route.setAvailable(false)
    route.receiveLocal([row("local", "大家能到吗？我先把时间发给大家", 0..<7000, final: true)])
    XCTAssertEqual(route.lines.first?.bubblePhrase?.text, "大家能到吗？好，我先把时间发给大家")
  }

  func testCloudRepunctuationPreservesIntentionalRepeatedReply() {
    var draft = AppleCaptionPhrases.BubbleDraft()
    draft.update(text: "我先整理一下对", final: false)
    draft.update(text: "我先整理一下对收到", final: false)
    XCTAssertTrue(draft.text.hasSuffix("对"))
    draft.update(text: "我先整理一下，对，收到", final: true)
    XCTAssertEqual(draft.text.filter { !$0.isPunctuation }, "我先整理一下对收到")
    var repeated = AppleCaptionPhrases.BubbleDraft()
    repeated.update(text: "我先整理一下对", final: false)
    repeated.update(text: "我先整理一下对对收到", final: false)
    repeated.update(text: "我先整理一下，对，对，收到", final: true)
    XCTAssertEqual(repeated.text.filter { !$0.isPunctuation }, "我先整理一下对对收到")
  }

  func testOnlyTheSelectedCloudSentenceCanCompleteAnUnmatchedTail() {
    var now = ContinuousClock.now
    let route = LiveCaptionRouter(now: { now })
    route.configure(enabled: true)
    route.setAvailable(true)
    route.receiveCloud([row("cloud", "明天", 0..<1600)])
    route.receiveLocal([row("local", "明天", 0..<1900)])
    route.receiveLocal([row("local", "明天去开会", 0..<5100)])
    route.receiveCloud([row("cloud", "明天请交资料", 0..<5000)])
    route.receiveLocal([row("local", "明天去开会星期三", 0..<8000, final: true)])
    now += .milliseconds(151)
    route.receiveLocal([row("local", "明天去开会星期三", 0..<8000, final: true)])
    XCTAssertEqual(route.lines.first?.text, "明天去开会星期三")
    XCTAssertEqual(route.lines.first?.textSource, .local)
    XCTAssertEqual(route.lines.first?.bubblePhrase?.text, "明天请交资料")
    route.receiveCloud([row("cloud", "明天请交资料给同事", 0..<8000, final: true)])
    XCTAssertEqual(route.lines.first?.bubblePhrase?.text, "明天请交资料给同事")
    XCTAssertEqual(route.lines.first?.textSource, .cloud)
  }

  func testAppModelUsesTheSameSelectedReplyForDesktopAndHistory() async throws {
    let output = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    let directory = URL(fileURLWithPath: output).appendingPathComponent(UUID().uuidString)
    let apple = TestLiveStream(), remote = TestLiveStream()
    let local = LivePreview(makeLocalStream: { apple })
    let cloud = LivePreview(makeStream: { _ in remote })
    let model = AppModel(libraryURL: directory, live: cloud, localCaptions: local)
    model.preferences.cloudEnabled = true
    model.configureCaptions(service: AIService(key: "test-only"))
    model.card.onStreamReset?(.started)
    var packet = Data(repeating: 0, count: 40)
    packet[0] = 0x48
    model.card.onAudio?((0..<20).reduce(into: Data()) { data, _ in data.append(packet) })
    remote.onEvent?(.sentence(id: 7, text: "好", isFinal: true, startMs: 20, endMs: 370))
    apple.onEvent?(.sentence(id: 0, text: "号", isFinal: true, startMs: 20, endMs: 370))
    XCTAssertEqual(model.localCaptions.lines.first?.text, "号")
    XCTAssertEqual(model.captionSelection.lines.first?.bubblePhrase?.text, "好")
    XCTAssertEqual(model.captionHistory.records.first?.text, "好")
    XCTAssertEqual(model.captionHistory.records.first?.textSource, .cloud)
    XCTAssertEqual(model.captionHistory.records.first?.id, model.localCaptions.lines.first?.id)
    XCTAssertNotNil(model.captionHistory.records.first?.replay)
    await model.shutdown()
  }

  func testDeadlinePublishesWithoutFurtherRecognitionCallbacks() async throws {
    let route = LiveCaptionRouter()
    route.configure(enabled: true)
    route.setAvailable(true)
    route.receiveLocal([row("local", "对", 0..<400, final: true)])
    let deadline = ContinuousClock.now + .seconds(1)
    while route.lines.first?.text == "", ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(route.lines.first?.text, "对")
  }
}
