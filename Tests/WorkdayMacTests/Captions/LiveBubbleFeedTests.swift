import XCTest
@testable import WorkdayCore

@testable import WorkdayMac

final class LiveBubbleFeedTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 100)

  func testSpeakerEvidenceStartsANewBubbleOnlyForWordsNotYetShown() {
    var feed = DesktopCaptionState()
    func phrase(_ id: Int, _ text: String) -> LiveLine {
      var row = line(id, text, final: true)
      row.bubblePhrase = AppleBubblePhrase(text: text, continuesPrevious: id > 0)
      return row
    }
    let first = phrase(0, "我们先定时间，"), second = phrase(1, "再发通知。"), reply = phrase(2, "对")
    feed.update(lines: [first, second], canPresent: true, now: now)
    XCTAssertEqual(feed.items.map(\.id), [first.id])
    feed.update(lines: [first, second, reply], canPresent: true, now: now) { _, _ in true }
    XCTAssertEqual(feed.items.map(\.id), [first.id, reply.id])
    XCTAssertEqual(feed.items.map(\.text), ["我们先定时间，再发通知。", "对"])
    feed.update(lines: [first, second, reply], canPresent: true, now: now)
    XCTAssertEqual(feed.items.map(\.sourceLineID), [second.id, reply.id])
  }

  func testResegmentedCaptionRecoversOnlyUnreadWordsWhenThePrecedingRowIsUnavailable() {
    let initial = line(0, "明天继")
    var left = line(0, "明天", final: true)
    left.bubblePhrase = .init(text: "明天继续", continuesPrevious: false)
    var right = line(1, "继续开会", final: true)
    right.bubblePhrase = .init(text: "开会", continuesPrevious: true, carriedText: "继续")
    func apply(_ lines: [LiveLine], eligible: Set<String>, to state: inout DesktopCaptionState) {
      let rows = state.rows(for: lines, speakersDiffer: { _, _ in false }) { line, _ in
        eligible.contains(line.id) ? line.bubblePhrase?.text ?? line.text : nil
      }
      state.update(rows: rows, canPresent: true, now: now)
    }
    var shown = DesktopCaptionState()
    apply([initial], eligible: [initial.id], to: &shown)
    apply([left, right], eligible: [right.id], to: &shown)
    XCTAssertEqual(shown.items.map(\.text), ["明天继续开会"])
    XCTAssertEqual(shown.items.map(\.id), [initial.id])

    var neverShown = DesktopCaptionState()
    apply([left, right], eligible: [right.id], to: &neverShown)
    XCTAssertEqual(neverShown.items.map(\.text), ["继续开会"])
    XCTAssertEqual(neverShown.items.map(\.id), [right.id])
  }

  func testRepeatedWordsOnSeparateAudioDoNotJoinARetractedDraft() {
    var state = DesktopCaptionState()
    var left = line(0, "好的")
    left.recognitionRange = 0..<600
    state.update(lines: [left], canPresent: true, now: now)
    left.text = ""
    left.isFinal = true
    var right = line(1, "好的，我们开始。", final: true)
    right.recognitionRange = 2000..<4000
    state.update(lines: [left, right], canPresent: true, now: now)
    XCTAssertEqual(state.items.map(\.text), ["好的", "好的，我们开始。"])
  }

  func testLateFinalSuffixCanUseTheSecondLineOfACompactBubble() throws {
    var state = DesktopCaptionState()
    let first = line(0, "一起讨论", final: true)
    state.update(lines: [first], canPresent: true, now: now)
    let initial = try XCTUnwrap(state.items.first?.phrases.first)
    state.update(lines: [line(0, "一起讨论进度。", final: true)], canPresent: true, now: now.addingTimeInterval(1))
    XCTAssertEqual(state.items.map(\.text), ["一起讨论进度。"])
    XCTAssertEqual(state.items.first?.phrases.first, initial)
    XCTAssertEqual(state.items.first?.phrases.last?.line, 1)
  }

  func testSubstantiveContinuationAndLateFinalAfterTenSeconds() {
    var feed = DesktopCaptionState()
    let draft = line(0, "今天")
    feed.update(lines: [draft], canPresent: true, now: now)
    feed.refresh(canPresent: true, now: now.addingTimeInterval(11))
    XCTAssertTrue(feed.items.isEmpty)
    let extended = line(0, "今天先核对交付日期")
    feed.update(lines: [extended], canPresent: true, now: now.addingTimeInterval(12))
    XCTAssertEqual(feed.items.map(\.id), [draft.id])
    feed.refresh(canPresent: true, now: now.addingTimeInterval(23))
    let final = line(0, "今天先核对交付日期，约在周五。", final: true)
    feed.update(lines: [final], canPresent: true, now: now.addingTimeInterval(24))
    XCTAssertEqual(feed.items.map(\.text), [final.text])
  }

  func testLateCorrectionCannotRewriteEitherVisibleBubble() {
    var feed = DesktopCaptionState()
    let meeting = line(0, "开会")
    let testing = line(1, "再测试")
    feed.update(lines: [meeting], canPresent: true, now: now)
    feed.update(lines: [meeting, testing], canPresent: true, now: now)
    let ids = [meeting.id, testing.id]
    XCTAssertEqual(feed.items.map(\.id), ids)
    feed.update(lines: [line(0, "开完会。", final: true), testing], canPresent: true, now: now)
    feed.update(lines: [line(0, "开完会。", final: true), line(1, "再测试。明天看结果")], canPresent: true, now: now)
    XCTAssertEqual(feed.items.map(\.id), ids)
    XCTAssertEqual(feed.items.map(\.sourceLineID), ids)
    XCTAssertEqual(feed.items.map(\.text), ["开会", "再测试。明天看结果"])
    XCTAssertEqual(feed.items.map(\.isFinal), [true, false])
    feed.update(lines: [line(0, "开完会了。", final: true), line(1, "再测试。明天看结果")], canPresent: true, now: now)
    XCTAssertEqual(feed.items.map(\.id), ids)
    XCTAssertEqual(feed.items.first?.text, "开会")
  }

  func testRepunctuationAcrossSnapshotsKeepsTheEntireSegmentInOneBubble() {
    var feed = DesktopCaptionState()
    for (text, expected) in [("看 0.3.2", "看 0.3.2"), ("看 0.3.2。开始测试。", "看 0.3.2。开始测试。"),
                             ("看 0.3.2，开始测试？下一项", "看 0.3.2。开始测试。")] {
      let snapshot = line(0, text)
      feed.update(lines: [snapshot], canPresent: true, now: now)
      XCTAssertEqual(feed.items.map(\.id), [snapshot.id])
      XCTAssertEqual(feed.items.map(\.text), [expected])
    }
  }

  func testFinalRetractionLeavesTheReadWordsVisible() {
    var feed = DesktopCaptionState()
    let next = line(1, "下一段")
    feed.update(lines: [line(0, "旧稿"), next], canPresent: true, now: now)
    feed.update(lines: [line(0, "。"), next], canPresent: true, now: now)
    XCTAssertEqual(feed.items.map(\.text), ["旧稿", "下一段"])
    feed.update(lines: [line(0, "", final: true), next], canPresent: true, now: now)
    feed.update(lines: [line(0, "迟到的草稿"), next], canPresent: true, now: now)
    XCTAssertEqual(feed.items.map(\.text), ["旧稿", next.text])
  }

  func testEmptyAppleDraftKeepsTheVisiblePageAndItsPosition() {
    var feed = DesktopCaptionState()
    let next = line(1, "再确认")
    feed.update(lines: [line(0, "继续"), next], canPresent: true, now: now)
    feed.update(lines: [line(0, ""), next], canPresent: true, now: now)
    XCTAssertEqual(feed.items.map(\.text), ["继续", next.text])
    let corrected = line(0, "开始继续，继续，下一个好了。", final: true)
    feed.update(lines: [corrected, next], canPresent: true, now: now)
    XCTAssertEqual(feed.items.map(\.id), [corrected.id, next.id])
    XCTAssertEqual(feed.items.map(\.text), ["继续", next.text])
  }

  func testHiddenDraftCannotLeakThroughLaterRevisionsOfTheNextChunk() {
    var feed = DesktopCaptionState()
    let hidden = line(0, "隐藏的半句")
    feed.update(lines: [hidden], canPresent: false, now: now)
    feed.update(lines: [hidden, line(1, "下一句")], canPresent: true, now: now)
    feed.update(lines: [hidden, line(1, "下一句修改。")], canPresent: true, now: now)
    XCTAssertEqual(feed.items.map(\.text), ["下一句修改。"])
  }

  func testLateCorrectionsCannotReviveAnExpiredBubble() {
    var feed = DesktopCaptionState()
    feed.update(lines: [line(0, "开会")], canPresent: true, now: now)
    let later = now.addingTimeInterval(11)
    feed.update(lines: [line(0, "开会。")], canPresent: true, now: later)
    XCTAssertTrue(feed.items.isEmpty)
    let next = line(1, "继续")
    feed.update(lines: [line(0, "开会。"), next], canPresent: true, now: later)
    feed.update(lines: [line(0, "开会。", final: true), next], canPresent: true, now: later)
    XCTAssertEqual(feed.items.map(\.id), [next.id])
  }

  func testNewSentencesBecomeSeparateBubblesAndPartialUpdatesStayInPlace() {
    var feed = DesktopCaptionState()
    feed.update(lines: [line(0, "先整理需求")], canPresent: true, now: now)
    feed.update(lines: [line(0, "先整理需求。", final: true), line(1, "再看")], canPresent: true, now: now)
    let ids = feed.items.map(\.id)
    feed.update(
      lines: [line(0, "先整理需求。", final: true), line(1, "再看看实际效果")], canPresent: true, now: now)
    XCTAssertEqual(feed.items.map(\.id), ids)
    XCTAssertEqual(feed.items.map(\.text), ["先整理需求。", "再看看实际效果"])
  }

  func testBatchArrivalShowsLatestFourAndEvictedSentenceCannotReturn() {
    var feed = DesktopCaptionState()
    var lines = (0..<8).map { line($0, "第\($0)句。", final: true) }
    feed.update(lines: lines, canPresent: true, now: now)
    XCTAssertEqual(feed.items.map(\.text), (4..<8).map { "第\($0)句。" })
    let ids = feed.items.map(\.id)
    lines[0] = line(0, "迟到的修订。", final: true)
    feed.update(lines: lines, canPresent: true, now: now.addingTimeInterval(1))
    XCTAssertEqual(feed.items.map(\.id), ids)
  }

  func testBubblesExpireIndependentlyWithoutReplayingHistory() {
    var feed = DesktopCaptionState()
    let first = line(0, "第一句。", final: true)
    let second = line(1, "第二句。", final: true)
    feed.update(lines: [first], canPresent: true, now: now)
    feed.update(lines: [first, second], canPresent: true, now: now.addingTimeInterval(5))
    feed.update(lines: [first, second], canPresent: true, now: now.addingTimeInterval(13))
    XCTAssertEqual(feed.items.map(\.text), ["第二句。"])
    feed.update(lines: [first, second], canPresent: true, now: now.addingTimeInterval(18))
    XCTAssertTrue(feed.items.isEmpty)
    feed.update(
      lines: [line(0, "第一句修订。", final: true), second], canPresent: true,
      now: now.addingTimeInterval(19))
    XCTAssertTrue(feed.items.isEmpty)
  }

  func testCoalescedTimeoutsRemoveOneOldestBubblePerInterval() {
    var feed = DesktopCaptionState()
    let lines = (0..<4).map { line($0, "第\($0)句", final: true) }
    feed.update(lines: lines, canPresent: true, now: now)
    // The first tick was delayed. A transcript notification and a timer can
    // both refresh the panel in the same turn of the run loop.
    let late = now.addingTimeInterval(25)
    for removed in 1...4 {
      let tick = late.addingTimeInterval(Double(removed - 1) * 1.5)
      feed.refresh(canPresent: true, now: tick)
      feed.update(lines: lines, canPresent: true, now: tick)
      feed.refresh(canPresent: true, now: tick.addingTimeInterval(1.49))
      XCTAssertEqual(feed.items.map(\.id), lines.dropFirst(removed).map(\.id))
    }
  }

  func testNewerBubbleWaitsForOlderRevisedTextAndNewSpeechAppearsDuringExit() {
    var feed = DesktopCaptionState()
    let first = line(0, "第一句")
    let second = line(1, "第二句")
    feed.update(lines: [first, second], canPresent: true, now: now)
    let corrected = line(0, "第一句补全了。", final: true)
    feed.update(lines: [corrected, second], canPresent: true, now: now.addingTimeInterval(8))
    feed.refresh(canPresent: true, now: now.addingTimeInterval(10))
    XCTAssertEqual(feed.items.map(\.text), [corrected.text, second.text])
    let new = line(2, "刚开始说")
    feed.update(lines: [corrected, second, new], canPresent: true, now: now.addingTimeInterval(20))
    XCTAssertEqual(feed.items.map(\.id), [second.id, new.id])
    feed.refresh(canPresent: true, now: now.addingTimeInterval(21.5))
    XCTAssertEqual(feed.items.map(\.id), [new.id])
  }

  func testHiddenBatchIsConsumedAndOnlyNewSentenceAppearsAfterResume() {
    var feed = DesktopCaptionState()
    let old = (0..<8).map { line($0, "旧句\($0)") }
    feed.update(lines: old, canPresent: false, now: now)
    feed.update(lines: old, canPresent: true, now: now)
    XCTAssertTrue(feed.items.isEmpty)
    feed.update(lines: old + [line(8, "新的工作内容")], canPresent: true, now: now)
    XCTAssertEqual(feed.items.map(\.text), ["新的工作内容"])
  }

  func testLateOlderSentenceAndCloudRotationKeepChronology() {
    var feed = DesktopCaptionState()
    let recent = line(5, "当前进度。")
    feed.update(lines: [recent], canPresent: true, now: now)
    feed.update(lines: [line(4, "迟到旧句"), recent], canPresent: true, now: now)
    XCTAssertEqual(feed.items.map(\.text), ["迟到旧句", "当前进度。"])
    let next = LiveLine(id: "new-session:0", segment: 1, sentence: 0, text: "下一阶段", isFinal: false)
    feed.update(lines: [recent, next], canPresent: true, now: now)
    XCTAssertEqual(feed.items.map(\.text), ["当前进度。", "下一阶段"])
  }

  func testPreviewBuildsAFeedAndEventuallyDisappears() {
    XCTAssertEqual(CaptionPreview.items(at: 0).count, 1)
    let continuous = CaptionPreview.items(at: 1.5)
    XCTAssertEqual(continuous.map(\.text), ["先开会。再核对时间。"])
    let paused = CaptionPreview.items(at: 2.6)
    XCTAssertEqual(paused.map(\.text), ["先开会。再核对时间。", "已收到声音"])
    XCTAssertEqual(paused.first?.id, continuous.first?.id)
    let long = CaptionPreview.items(at: 4.8)
    XCTAssertEqual(long.count, 3)
    XCTAssertEqual(long[1].id, paused[1].id)
    XCTAssertTrue(long.dropFirst().map(\.text).joined().hasSuffix("发给大家。接着发通知。"))
    XCTAssertEqual(CaptionPreview.items(at: 7).count, 4)
    XCTAssertTrue(CaptionPreview.items(at: CaptionPreview.duration).isEmpty)
  }

  func testLatePartialCannotChangeFinalBubbleOrExtendItsLifetime() {
    var feed = DesktopCaptionState()
    let final = line(0, "这句已经确认。", final: true)
    feed.update(lines: [final], canPresent: true, now: now)
    let stale = line(0, "这句")
    feed.update(lines: [stale], canPresent: true, now: now.addingTimeInterval(5))
    XCTAssertEqual(feed.items.first?.text, final.text)
    XCTAssertEqual(feed.items.first?.isFinal, true)
    feed.update(lines: [stale], canPresent: true, now: now.addingTimeInterval(12))
    XCTAssertTrue(feed.items.isEmpty)
  }

  private func line(_ number: Int, _ text: String, final: Bool = false) -> LiveLine {
    LiveLine(id: "session:\(number)", segment: 0, sentence: number, text: text, isFinal: final)
  }
}
