import AppKit
import Foundation
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class DayProcessingTests: XCTestCase {
  @MainActor func testStartLoadsArchivedRecordingsOnceAndStopsCleanly() async throws {
    _ = NSApplication.shared
    let root = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
        ?? NSTemporaryDirectory()
    ).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root.appendingPathComponent("Library"))
    let file = root.appendingPathComponent("note20261110-090000.wav")
    try AudioFiles.wav(pcm: Data(repeating: 0, count: 64000)).write(to: file)
    _ = try await model.store.importAudio(file, sourceID: "usb:test")
    model.start()
    model.start()
    for _ in 0..<500 {
      if !model.loading { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(model.loading)
    XCTAssertEqual(model.recordings.count, 1)
    XCTAssertEqual(model.selectedDay, WorkdayDate.day(Date()))
    await model.shutdown()
    XCTAssertFalse(model.isBusy)
  }
  @MainActor func testAdditionalFileRefreshesSummaryWithinSameAppSession() async throws {
    let root = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
        ?? NSTemporaryDirectory()
    ).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = DayInference()
    let model = AppModel(libraryURL: root.appendingPathComponent("Library"), inference: service)
    for hour in [9, 11] {
      let file = root.appendingPathComponent(String(format: "note20261110-%02d0000.wav", hour))
      try AudioFiles.wav(pcm: Data(repeating: 0, count: 64000)).write(to: file)
      _ = try await model.store.importAudio(file, sourceID: "usb:test")
      await model.reload()
      XCTAssertFalse(model.summaryIsCurrent("2026-11-10"))
      model.scheduleProcessing()
      for _ in 0..<1000 {
        if !model.isBusy { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertFalse(model.isBusy)
      XCTAssertTrue(model.summaryIsCurrent("2026-11-10"))
    }
    XCTAssertEqual(model.summaries["2026-11-10"]?.recordingIDs.count, 2)
    model.selectDay("2026-11-10")
    XCTAssertEqual(model.dayConversations.count, 2)
    let calls = await service.summaryCalls
    XCTAssertEqual(calls, 2)
    await model.shutdown()
  }
  @MainActor func testSummaryReturnedAfterNewFileIsNotCommittedAsCurrent() async throws {
    let root = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
        ?? NSTemporaryDirectory()
    ).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = DayInference(holdFirst: true)
    let model = AppModel(libraryURL: root.appendingPathComponent("Library"), inference: service)
    func add(_ hour: Int) async throws {
      let file = root.appendingPathComponent(String(format: "note20261110-%02d0000.wav", hour))
      try AudioFiles.wav(pcm: Data(repeating: 0, count: 64000)).write(to: file)
      _ = try await model.store.importAudio(file, sourceID: "usb:test")
      await model.reload()
    }
    try await add(9)
    model.scheduleProcessing()
    for _ in 0..<1000 {
      if await service.summaryCalls > 0 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try await add(11)
    await service.release()
    for _ in 0..<1000 {
      if !model.isBusy { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(model.isBusy)
    XCTAssertEqual(model.summaries["2026-11-10"]?.recordingIDs.count, 2)
    XCTAssertTrue(model.summaryIsCurrent("2026-11-10"))
    await model.shutdown()
  }

}

private actor DayInference: InferenceServing {
  nonisolated let transcriptionModel = "local-fixture"
  var summaryCalls = 0
  private var holdFirst: Bool
  init(holdFirst: Bool = false) { self.holdFirst = holdFirst }
  func release() { holdFirst = false }
  func transcribe(audio: Data, format: String, chunk: Int, offset: Double, duration: Double)
    async throws -> [TranscriptLine]
  {
    [TranscriptLine(id: "0", start: 0, end: 1, text: "确认交付进度")]
  }
  func organize(lines: [TranscriptLine]) async throws -> [ConversationProposal] {
    [ConversationProposal(title: "进度", summary: "确认交付进度", firstID: "0", lastID: "0")]
  }
  func summarize(day: String, conversations: [Conversation], recordingIDs: [String]) async throws
    -> DaySummary
  {
    summaryCalls += 1
    while holdFirst && summaryCalls == 1 { try await Task.sleep(for: .milliseconds(10)) }
    return DaySummary(day: day, overview: "本地验证", recordingIDs: recordingIDs)
  }
}
