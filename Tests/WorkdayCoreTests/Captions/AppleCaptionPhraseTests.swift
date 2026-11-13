import QS668Core
import XCTest
@testable import WorkdayCore

final class AppleCaptionPhraseTests: XCTestCase {
  private func word(_ text: String, _ start: Double, _ end: Double) -> ASRWord {
    ASRWord(text: text, startMs: start, endMs: end)
  }

  func testBubbleKeepsReadPrefixThroughRetractionAndLegacyFinalCorrection() {
    var phrases = AppleCaptionPhrases()
    func update(_ text: String, final: Bool = false) -> String? {
      _ = phrases.update([word(text, 0, 500)], final: final)
      return phrases.bubblePhrases[0]?.text
    }
    XCTAssertEqual(update("周四"), "")
    XCTAssertEqual(update("周四下午"), "周四")
    XCTAssertEqual(update("周"), "周四")
    XCTAssertEqual(update("周四下午见"), "周四")
    XCTAssertEqual(update("周五下午见。", final: true), "周四下午见。")
    XCTAssertEqual(phrases.finish().first,
      .sentence(id: 0, text: "周五下午见。", isFinal: true, startMs: 0, endMs: 500))
  }

  func testLatePauseDoesNotDuplicateWordsAlreadyReleasedIntoTheBubble() {
    var phrases = AppleCaptionPhrases()
    let left = word("明天", 0, 250), right = word("继续", 400, 600), tail = word("开会", 600, 800)
    _ = phrases.update([left, right], final: false, replacing: 0..<600)
    _ = phrases.update([left, right, tail], final: false, replacing: 0..<800)
    XCTAssertEqual(phrases.bubblePhrases[0]?.text, "明天继续")
    _ = phrases.update([word("明天，", 0, 250), right, tail], final: true, pauses: [300], replacing: 0..<800)
    XCTAssertEqual(phrases.bubblePhrases[0]?.text, "明天继续")
    XCTAssertEqual(phrases.bubblePhrases[1]?.text, "开会")
    XCTAssertEqual(phrases.bubblePhrases[1]?.continuesPrevious, true)
  }

  func testPunctuationInsertedBeforeTheReadPositionDoesNotRepeatTheNextWord() {
    var phrases = AppleCaptionPhrases()
    let prefix = "我先把时间发给大家对我们提前十分钟"
    let punctuated = "我先把时间发给大家。对我们提前十分钟"
    for text in [prefix, prefix + "到会议室", punctuated + "到会议室把资", punctuated + "到会议室把资料"] {
      _ = phrases.update([word(text, 0, 1000)], final: false, replacing: 0..<1000)
    }
    _ = phrases.update([word(punctuated + "到会议室把资料准备好", 0, 1500)], final: true, replacing: 0..<1500)
    XCTAssertEqual(phrases.bubblePhrases[0]?.text, prefix + "到会议室把资料准备好")
  }

  func testFinalHypothesisRepairsBothEdgesOfPreviouslyDisplayedBubbles() {
    var phrases = AppleCaptionPhrases()
    let early = [word("继续", 200, 450), word("下一", 1900, 2100)]
    _ = phrases.update(early, final: false)
    let corrected = [word("开始继续", 0, 450), word("，继续", 480, 800),
                     word("，下一个", 1900, 2250), word("好了。", 2250, 2500)]
    XCTAssertEqual(phrases.update(corrected, final: true), [
      .sentence(id: 0, text: "开始继续，继续", isFinal: true, startMs: 0, endMs: 800),
      .sentence(id: 1, text: "，下一个好了。", isFinal: false, startMs: 1900, endMs: 2500),
    ])
    XCTAssertEqual(phrases.finish(), [
      .sentence(id: 1, text: "，下一个好了。", isFinal: true, startMs: 1900, endMs: 2500)
    ])
  }

  func testShortPunctuationAndRecognizerFinalsShareOneBubbleUntilAudioPause() {
    var phrases = AppleCaptionPhrases()
    _ = phrases.update([word("先记。", 0, 300)], final: true)
    let together = phrases.update([word("继续。", 1099, 1500)], final: true)
    XCTAssertEqual(together, [.sentence(id: 0, text: "先记。继续。", isFinal: false, startMs: 0, endMs: 1500)])
    let afterPause = phrases.update([word("下一项", 2300, 2800)], final: false)
    XCTAssertEqual(afterPause, [
      .sentence(id: 0, text: "先记。继续。", isFinal: true, startMs: 0, endMs: 1500),
      .sentence(id: 1, text: "下一项", isFinal: false, startMs: 2300, endMs: 2800),
    ])
    XCTAssertEqual(phrases.finish(), [.sentence(id: 1, text: "下一项", isFinal: true, startMs: 2300, endMs: 2800)])
  }

  func testTimedRevisionsKeepWordsOutsideTheReplacedInterval() {
    var phrases = AppleCaptionPhrases()
    _ = phrases.update([word("开始", 0, 200)], final: false, replacing: 0..<200)
    _ = phrases.update([word("继", 200, 400)], final: false, replacing: 200..<400)
    _ = phrases.update([word("好了", 400, 600)], final: false, replacing: 400..<600)
    XCTAssertEqual(phrases.update([word("继续", 200, 400)], final: false, replacing: 200..<400), [
      .sentence(id: 0, text: "开始继续好了", isFinal: false, startMs: 0, endMs: 600)
    ])
    XCTAssertEqual(phrases.update([], final: false, replacing: 200..<400), [
      .sentence(id: 0, text: "开始好了", isFinal: false, startMs: 0, endMs: 600)
    ])
    XCTAssertEqual(phrases.finish(), [
      .sentence(id: 0, text: "开始好了", isFinal: true, startMs: 0, endMs: 600)
    ])
  }

  func testShorterFinalReplacesTheWholeMatchingAppleHypothesis() {
    var phrases = AppleCaptionPhrases()
    _ = phrases.update([word("开始", 0, 200), word("吧", 400, 600)], final: false, replacing: 0..<600)
    _ = phrases.update([word("开始。", 0, 230)], final: true, replacing: 0..<300, finalizedThrough: 300)
    XCTAssertEqual(phrases.finish(), [
      .sentence(id: 0, text: "开始。", isFinal: true, startMs: 0, endMs: 230)
    ])
  }

  func testPointTimedTailIsRevisedOnceAndSurvivesAdjacentAppleResult() {
    var phrases = AppleCaptionPhrases()
    _ = phrases.update([word("开始", 0, 180), word("好", 200, 200)],
                       final: false, replacing: 0..<200)
    _ = phrases.update([word("开始", 0, 180), word("好了", 200, 200)],
                       final: true, replacing: 0..<200, finalizedThrough: 200)
    _ = phrases.update([word("继续", 200, 400)], final: true, replacing: 200..<400, finalizedThrough: 400)
    XCTAssertEqual(phrases.finish(), [
      .sentence(id: 0, text: "开始好了继续", isFinal: true, startMs: 0, endMs: 400)
    ])
  }

  func testFinalWithShiftedStartDoesNotRepeatTheFirstWord() {
    var phrases = AppleCaptionPhrases()
    _ = phrases.update([word("开", 0, 160), word("始", 200, 400)],
                       final: false, replacing: 0..<450)
    _ = phrases.update([word("开始", 180, 450)], final: true,
                       replacing: 180..<500, finalizedThrough: 500)
    XCTAssertEqual(phrases.finish(), [.sentence(id: 0, text: "开始", isFinal: true, startMs: 180, endMs: 450)])
  }

  func testTimedFinalCanRetokenizeALongBubbleWithoutMovingItsTailAcrossTheCut() {
    var phrases = AppleCaptionPhrases()
    let prefix = String(repeating: "讲", count: 36)
    _ = phrases.update([word(prefix + "。", 0, 4000), word("下", 4000, 4300)],
                       final: false, replacing: 0..<4300)
    let revised = [word(prefix, 0, 3100), word("好了。", 3100, 4000), word("下一段", 4000, 4600)]
    XCTAssertEqual(phrases.update(revised, final: true, replacing: 0..<4600, finalizedThrough: 4600), [
      .sentence(id: 0, text: prefix + "好了。", isFinal: true, startMs: 0, endMs: 4000),
      .sentence(id: 1, text: "下一段", isFinal: false, startMs: 4000, endMs: 4600)
    ])
  }

  func testBackfilledPeriodDoesNotSplitAlreadyDisplayedWords() {
    var phrases = AppleCaptionPhrases()
    let long = String(repeating: "讲", count: 36)
    _ = phrases.update([word(long, 0, 3000), word("接着说", 3000, 3400)], final: false)
    let revised = phrases.update([word(long + "。", 0, 3000), word("接着说", 3000, 3400)], final: false)
    XCTAssertEqual(revised, [.sentence(id: 0, text: long + "。接着说", isFinal: false, startMs: 0, endMs: 3400)])
  }

  func testLongTimedRunWithAnInternalPeriodPreservesAllText() {
    var phrases = AppleCaptionPhrases()
    let long = String(repeating: "讲", count: 36)
    let result = phrases.update([word(long + " 3.14。新的工作", 0, 5000)], final: true)
    let texts = result.compactMap { event -> String? in
      if case .sentence(_, let text, _, _, _, _) = event { return text }
      return nil
    }
    XCTAssertEqual(texts, [long + " 3.14。", "新的工作"])
  }

  func testLongSpeechWaitsForSentenceEndAndTheNextWord() {
    let prefix = String(repeating: "讲", count: 36)
    var phrases = AppleCaptionPhrases()
    _ = phrases.update([word(prefix, 0, 3000), word("继续", 3050, 3250)], final: false)
    let a = word(prefix + "继续。", 0, 3250)
    _ = phrases.update([a], final: false)
    let b = word("然后", 3300, 3500)
    XCTAssertEqual(phrases.update([a, b], final: false), [
      .sentence(id: 1, text: b.text, isFinal: false, startMs: 3300, endMs: 3500),
    ])
    XCTAssertEqual(phrases.update([a, word("然后测试。", 3300, 4000)], final: true),
      [.sentence(id: 0, text: a.text, isFinal: true, startMs: 0, endMs: 3250),
       .sentence(id: 1, text: "然后测试。", isFinal: false, startMs: 3300, endMs: 4000)])
  }

  func testLongChineseClauseKeepsBothSidesOfACommaInOrder() {
    let first = String(repeating: "甲", count: 36) + "，"
    var phrases = AppleCaptionPhrases()
    let events = phrases.update([word(first + "周五再确认", 0, 4500)], final: true)
    let text = events.compactMap { event -> String? in
      if case .sentence(_, let text, _, _, _, _) = event { return text }
      return nil
    }
    XCTAssertEqual(text, [first, "周五再确认"])
  }
}
