import Foundation
import XCTest

@testable import WorkdayCore

final class DayActivityTests: XCTestCase {
  private func record(_ id: String, _ start: String, duration: Double) -> Recording {
    Recording(
      id: id, startedAt: ISO8601DateFormatter().date(from: start), importedAt: Date(),
      originalName: id, folder: "", originalFile: "original.wav", sha256: id, bytes: 1,
      duration: duration, sourceID: "fixture")
  }

  func testReplayMappingAcrossMidnightPauseOverlapAndUnknownDate() throws {
    var first = record("a", "2026-11-10T23:59:58+08:00", duration: 12)
    first.pauses = [.init(offset: 4, duration: 13)]
    let other = record("b", "2026-11-11T00:00:01+08:00", duration: 4)
    var unknown = first
    unknown.startedAt = nil
    let route = DayAudioTimeline(day: "2026-11-11", recordings: [unknown, other, first])
    XCTAssertEqual(route.spans.map(\.recordingID), ["a", "b", "a"])
    XCTAssertEqual(route.spans.map(\.sourceStart), [2, 1, 4])
    XCTAssertEqual(route.spans.map(\.clockStart), [0, 2, 15])
    XCTAssertEqual(route.duration, 13)
    let alternate = DayAudioTimeline(
      day: "2026-11-11", recordings: [first, other], preferredRecordingID: other.id)
    XCTAssertEqual(alternate.spans[1].recordingID, other.id)
    XCTAssertEqual(alternate.spans[1].sourceStart, 0)
    XCTAssertEqual(alternate.duration, route.duration)
    XCTAssertEqual(route.locate(clock: 8)?.offset, 4)
    XCTAssertEqual(route.locate(clock: 86400)?.offset, 12)
    XCTAssertTrue(DayAudioTimeline(day: "日期未知", recordings: [unknown]).spans.isEmpty)
  }

  func testDailyEditorCombinesSourcesRescuesShortAppointmentAndExcludesGreeting() throws {
    let a = record("a", "2026-11-11T09:00:00+08:00", duration: 60)
    let b = record("b", "2026-11-11T09:01:00+08:00", duration: 60)
    func document(_ record: Recording) -> ProcessingDocument {
      var doc = ProcessingDocument(recording: record, model: "fixture")
      doc.phase = "complete"
      doc.transcript = [.init(id: "q", start: 1, end: 8, text: "确认首版范围。")]
      doc.conversations = [
        Conversation(
          id: record.id, recordingID: record.id, title: "版本评审",
          summary: "确认范围", start: 1, end: 8, lineIDs: ["q"], audioFile: "clip.wav",
          sha256: "fixture", decisions: [], tasks: [])
      ]
      return doc
    }
    var second = document(b)
    second.transcript += [
      .init(id: "s", start: 20, end: 23, text: "明天三点演示。"),
      .init(id: "u", start: 30, end: 31, text: "早上好。"),
    ]
    let clips = WorkdayTimeline.evidence(
      day: "2026-11-11", recordings: [b, a],
      documents: ["a": document(a), "b": second])
    XCTAssertEqual(clips.count, 4)
    XCTAssertEqual(DayActivity.timeline(clips, saved: nil).map(\.conversationIDs), [["a", "b"]])
    let group = DayActivityProposal(kind: .event, title: "版本评审", summary: "确认首版范围", parts: [1, 2])
    let decision = DayActivityProposal(kind: .moment, title: "约定演示", summary: "明天三点", parts: [3])
    let saved = try DayActivityProposal.resolve([decision, group], against: clips)
    let timeline = DayActivity.timeline(clips, saved: saved)
    XCTAssertEqual(timeline.map(\.kind), [.event, .moment])
    XCTAssertEqual(timeline[1].conversationIDs, [clips[2].id])
    XCTAssertEqual(clips[2].audioFile, "original.wav")
    XCTAssertEqual(clips[2].lineIDs, ["s"])
    XCTAssertThrowsError(try DayActivityProposal.resolve([group, group], against: clips))
    XCTAssertThrowsError(try DayActivityProposal.resolve([decision], against: clips))
    var wrongQuote = group
    wrongQuote.quotes = [.init(part: 1, line: "s")]
    XCTAssertThrowsError(try DayActivityProposal.resolve([wrongQuote], against: clips))
    let old = DaySummary(day: "2026-11-11", overview: "原有摘要", recordingIDs: ["a", "b"])
    let restored = try JSONDecoder().decode(DaySummary.self, from: JSONEncoder().encode(old))
    XCTAssertNil(restored.activities)
  }
}
