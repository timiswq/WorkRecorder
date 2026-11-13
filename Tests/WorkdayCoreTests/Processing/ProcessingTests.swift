import XCTest

@testable import WorkdayCore

final class ProcessingTests: XCTestCase {
  func testTimestampMappingAndSpeakerScope() throws {
    let response = Data(
      #"{"output":{"text":"你好。","sentences":[{"sentence_id":1,"sentence_end":true,"begin_time":100,"end_time":1400,"text":"你好。","speaker_id":0}]}}"#
        .utf8)
    let lines = try AIService.parseTranscript(response, chunk: 2, offset: 240, duration: 120)
    XCTAssertEqual(lines.count, 1)
    XCTAssertEqual(lines.first?.start ?? 0, 240.1, accuracy: 0.001)
    XCTAssertEqual(lines.first?.end ?? 0, 241.4, accuracy: 0.001)
    XCTAssertEqual(lines.first?.id, "2:1")
    XCTAssertEqual(lines.first?.speaker, "第 3 段 · 发言人 1")
  }
  func testMissingOrInvalidTimestampsCannotProduceClipEvidence() {
    for response in [
      #"{"output":{"text":"重要任务","sentence":{"text":"重要任务"}}}"#,
      #"{"output":{"text":"重要任务","sentence":{"sentence_id":1,"begin_time":10000,"end_time":999999,"text":"重要任务"}}}"#,
    ] {
      XCTAssertThrowsError(
        try AIService.parseTranscript(Data(response.utf8), chunk: 0, offset: 0, duration: 120))
    }
  }
  func testAIOnlyReferencesKnownOrderedSentences() {
    let lines = [
      TranscriptLine(id: "0", start: 0, end: 2, text: "讨论进度"),
      TranscriptLine(id: "1", start: 3, end: 5, text: "明天交付"),
    ]
    XCTAssertThrowsError(
      try AIService.validate(
        [ConversationProposal(title: "任务", summary: "", firstID: "missing", lastID: "1")],
        lines: lines))
    XCTAssertThrowsError(
      try AIService.validate(
        [ConversationProposal(title: "任务", summary: "", firstID: "1", lastID: "0")], lines: lines))
    XCTAssertNoThrow(
      try AIService.validate(
        [ConversationProposal(title: "任务", summary: "讨论交付", firstID: "0", lastID: "1")],
        lines: lines))
  }
  func testEmptyTranscriptIsExplicitSilenceOnly() throws {
    XCTAssertEqual(
      try AIService.parseTranscript(
        Data(#"{"output":{"text":"","sentences":[]}}"#.utf8), chunk: 0, offset: 0, duration: 120),
      [])
    XCTAssertThrowsError(
      try AIService.parseTranscript(
        Data(#"{"output":{}}"#.utf8), chunk: 0, offset: 0, duration: 120))
    XCTAssertThrowsError(
      try AIService.parseTranscript(
        Data(#"{"output":{"text":"","sentences":[{"text":"不能丢掉这句话"}]}}"#.utf8), chunk: 0, offset: 0,
        duration: 120))
  }
}
