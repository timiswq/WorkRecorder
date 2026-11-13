import Foundation
import XCTest

@testable import WorkdayCore

final class ConversationBoundaryTests: XCTestCase {
  func testContiguousDialogueCanBeRejoinedAcrossAnalysisBatches() async throws {
    let lines = [
      TranscriptLine(id: "a", start: 0, end: 10, text: "讨论交付"),
      TranscriptLine(id: "b", start: 11, end: 20, text: "继续讨论交付"),
    ]
    let parts = [
      ConversationProposal(title: "上半段", summary: "", firstID: "a", lastID: "a"),
      ConversationProposal(title: "下半段", summary: "", firstID: "b", lastID: "b"),
    ]
    let merged = try await ConversationBoundary.reconcile(
      parts, before: "a", after: "b", lines: lines, service: BoundaryInference())
    XCTAssertEqual(merged.count, 1)
    XCTAssertEqual(merged.first?.firstID, "a")
    XCTAssertEqual(merged.first?.lastID, "b")
    let separated = [lines[0], TranscriptLine(id: "b", start: 200, end: 210, text: "另一场沟通")]
    let kept = try await ConversationBoundary.reconcile(
      parts, before: "a", after: "b", lines: separated, service: BoundaryInference())
    XCTAssertEqual(kept, parts)
    let invalidMerge = try await ConversationBoundary.reconcile(
      parts, before: "a", after: "b", lines: lines, service: BoundaryInference(lastID: "absent"))
    XCTAssertEqual(invalidMerge, parts)
  }
}
private struct BoundaryInference: InferenceServing {
  let transcriptionModel = "fixture"
  var lastID = "b"
  func transcribe(audio: Data, format: String, chunk: Int, offset: Double, duration: Double)
    async throws -> [TranscriptLine]
  { [] }
  func organize(lines: [TranscriptLine]) async throws -> [ConversationProposal] {
    [ConversationProposal(title: "交付讨论", summary: "继续讨论交付", firstID: "a", lastID: lastID)]
  }
  func summarize(day: String, conversations: [Conversation], recordingIDs: [String]) async throws
    -> DaySummary
  { DaySummary(day: day, overview: "", recordingIDs: recordingIDs) }
}
