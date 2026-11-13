import Foundation
import XCTest

@testable import WorkdayCore

final class TimelineTests: XCTestCase {
  func record(_ name: String, at: String, duration: Double) -> Recording {
    Recording(
      id: name, startedAt: ISO8601DateFormatter().date(from: at), importedAt: Date(),
      originalName: name, folder: "", originalFile: "original.wav", sha256: "hash", bytes: 1,
      duration: duration, sourceID: "usb:card")
  }
  func testMidnightSlicesKeepAudioOffsetsAndDoNotInventPausedTime() {
    var r = record("night", at: "2026-11-10T23:59:00+08:00", duration: 180)
    var slices = WorkdayTimeline.slices(r, start: 0, end: 180)
    XCTAssertEqual(slices.map(\.day), ["2026-11-10", "2026-11-11"])
    XCTAssertEqual(slices.map(\.start), [0, 60])
    XCTAssertEqual(slices.map(\.end), [60, 180])
    r.pauses = [RecordingPause(offset: 30, duration: 120)]
    slices = WorkdayTimeline.slices(r, start: 0, end: 180)
    XCTAssertEqual(slices.map(\.day), ["2026-11-10", "2026-11-11"])
    XCTAssertEqual(slices.map(\.start), [0, 30])
    XCTAssertEqual(slices.map(\.end), [30, 180])
  }
  func testUnknownDateDoesNotBecomeImportDate() {
    var r = record("unknown", at: "2026-11-10T10:00:00+08:00", duration: 20)
    r.startedAt = nil
    XCTAssertEqual(WorkdayTimeline.days(r), ["日期未知"])
  }
  func testClipPaddingAcrossMidnightDoesNotCreateAnEmptyDayEntry() {
    let r = record("night", at: "2026-11-10T23:59:58+08:00", duration: 5)
    var doc = ProcessingDocument(recording: r, model: "fixture")
    doc.transcript = [TranscriptLine(id: "a", start: 1, end: 2, text: "确认交付。")]
    doc.conversations = [
      Conversation(id: "clip", recordingID: r.id, title: "交付", summary: "确认交付。", start: 0.65,
        end: 2.5, lineIDs: ["a"], audioFile: "clip.wav", sha256: "hash", decisions: [], tasks: [])
    ]
    let docs = [r.id: doc]
    XCTAssertEqual(WorkdayTimeline.conversations(day: "2026-11-10", recordings: [r], documents: docs).count, 1)
    XCTAssertTrue(WorkdayTimeline.conversations(day: "2026-11-11", recordings: [r], documents: docs).isEmpty)
  }
  func testDaySummaryFingerprintChangesWithNewRecordingAndReprocessedContent() {
    let a = record("a", at: "2026-11-10T09:00:00+08:00", duration: 20)
    let b = record("b", at: "2026-11-10T10:00:00+08:00", duration: 20)
    var doc = ProcessingDocument(recording: a, model: "test")
    doc.phase = "complete"
    let initial = WorkdayTimeline.fingerprint(
      day: "2026-11-10", recordings: [a], documents: [a.id: doc])
    XCTAssertNotEqual(
      initial,
      WorkdayTimeline.fingerprint(day: "2026-11-10", recordings: [a, b], documents: [a.id: doc]))
    doc.transcript = [TranscriptLine(id: "0", start: 0, end: 1, text: "新增内容")]
    XCTAssertNotEqual(
      initial,
      WorkdayTimeline.fingerprint(day: "2026-11-10", recordings: [a], documents: [a.id: doc]))
  }
  func testInterleavedRecordingsSortByConversationTimeNotFileOrder() {
    let a = record("a", at: "2026-11-10T09:00:00+08:00", duration: 7200)
    let b = record("b", at: "2026-11-10T09:30:00+08:00", duration: 60)
    func doc(_ r: Recording, start: Double) -> ProcessingDocument {
      var d = ProcessingDocument(recording: r, model: "test")
      d.phase = "complete"
      d.conversations = [
        Conversation(
          id: r.id, recordingID: r.id, title: r.id, summary: "", start: start, end: start + 10,
          lineIDs: [], audioFile: "clip.wav", sha256: "hash", decisions: [], tasks: [])
      ]
      return d
    }
    let clips = WorkdayTimeline.conversations(
      day: "2026-11-10", recordings: [a, b],
      documents: [a.id: doc(a, start: 3600), b.id: doc(b, start: 0)])
    XCTAssertEqual(clips.map(\.recordingID), ["b", "a"])
  }
}

final class PauseTrackerTests: XCTestCase {
  func testPauseUsesConfirmedAudioOffsetAndDisconnectCannotInventGap() {
    var tracker = PauseTracker()
    let t = Date(timeIntervalSince1970: 1000)
    tracker.pause(name: "note20261110-090000", offset: 20, at: t)
    tracker.confirmOffset(22)
    let result = tracker.resume(name: "note20261110-090000", at: t.addingTimeInterval(90))
    XCTAssertEqual(result, RecordingPause(offset: 22, duration: 90))
    tracker.pause(name: "a", offset: 1, at: t)
    tracker.cancel()
    XCTAssertNil(tracker.resume(name: "a", at: t.addingTimeInterval(90)))
  }
}
