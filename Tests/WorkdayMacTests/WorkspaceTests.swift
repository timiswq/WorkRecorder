import AppKit
import SwiftUI
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class WorkspaceTests: XCTestCase {
  @MainActor func testSidebarReflectsDateChangesWithoutPublishingThemAgain() async throws {
    _ = NSApplication.shared
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root.appendingPathComponent("Library"))
    try await add("note20200101-090000.wav", to: model, at: root)
    await model.reload()
    let recording = try XCTUnwrap(model.recordings.first)
    let today = try XCTUnwrap(model.selectedDay)
    var publishedDays: [String?] = []
    let subscription = model.$selectedDay.dropFirst().sink { publishedDays.append($0) }
    defer { subscription.cancel() }

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1140, height: 760),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingController(rootView: ArchiveDates(model: model).frame(width: 280, height: 180))
    window.contentViewController = host

    func layout() async throws {
      host.view.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(100))
      host.view.layoutSubtreeIfNeeded()
    }
    func table(in view: NSView) -> NSTableView? {
      if let table = view as? NSTableView { return table }
      return view.subviews.lazy.compactMap { table(in: $0) }.first
    }
    try await layout()
    let dates = try XCTUnwrap(table(in: host.view))
    let todayRow = try XCTUnwrap(dates.selectedRowIndexes.first, "日期列表共有 \(dates.numberOfRows) 行")
    model.selectDay(recording.day)
    model.selectedDetail = .original(recording.id)
    try await layout()
    let historyRow = try XCTUnwrap(dates.selectedRowIndexes.first)
    XCTAssertNotEqual(historyRow, todayRow)
    model.showToday()
    try await layout()
    XCTAssertEqual(dates.selectedRow, todayRow)
    dates.selectRowIndexes(IndexSet(integer: historyRow), byExtendingSelection: false)
    XCTAssertEqual(model.selectedDay, today, "等待原生列表的选择回调结束后再更新工作区")
    try await layout()
    XCTAssertEqual(model.selectedDay, recording.day)
    XCTAssertEqual(model.selectedDetail, .original(recording.id))
    dates.deselectAll(nil)
    try await layout()
    XCTAssertEqual(dates.selectedRow, historyRow)
    XCTAssertEqual(publishedDays, [recording.day, today, recording.day])
  }

  @MainActor func testDayRetryDoesNotProcessAnotherDayOrChainIntoGlobalQueue() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = WorkspaceInference()
    let model = AppModel(libraryURL: root.appendingPathComponent("Library"), inference: service)
    try await add("note20261109-090000.wav", to: model, at: root)
    try await add("note20261110-090000.wav", to: model, at: root)
    await model.reload()
    model.retryProcessing(scope: .day("2026-11-09"))
    try await finish(model)
    let older = try XCTUnwrap(model.recordings.first { $0.day == "2026-11-09" })
    let newer = try XCTUnwrap(model.recordings.first { $0.day == "2026-11-10" })
    XCTAssertEqual(model.documents[older.id]?.phase, "complete")
    XCTAssertNil(model.documents[newer.id])
    XCTAssertNotNil(model.summaries["2026-11-09"])
    XCTAssertNil(model.summaries["2026-11-10"])
    let count = await service.transcriptionCount
    XCTAssertEqual(count, 1)
    let originalSummary = model.summaries["2026-11-09"]?.updatedAt
    model.retryProcessing()
    try await finish(model)
    XCTAssertEqual(model.documents[newer.id]?.phase, "complete")
    XCTAssertEqual(model.summaries["2026-11-09"]?.updatedAt, originalSummary)
    let finalCount = await service.transcriptionCount
    XCTAssertEqual(finalCount, 2)
    await model.shutdown()
  }

  @MainActor func testRecordingRetryOnlyProcessesChosenOriginal() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = WorkspaceInference()
    let model = AppModel(libraryURL: root.appendingPathComponent("Library"), inference: service)
    try await add("note20261110-090000.wav", to: model, at: root)
    try await add("note20261110-110000.wav", to: model, at: root)
    await model.reload()
    let selected = try XCTUnwrap(model.recordings.first)
    model.retryProcessing(scope: .recording(selected.id))
    try await finish(model)
    XCTAssertEqual(model.documents.count, 1)
    XCTAssertEqual(model.documents[selected.id]?.phase, "complete")
    XCTAssertEqual(model.summaries[selected.day]?.recordingIDs, [selected.id])
    let count = await service.transcriptionCount
    XCTAssertEqual(count, 1)
    await model.shutdown()
  }

  @MainActor func testRecordingRetryDuringAnotherRecordingResumesOnceFromCheckpoint() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = WorkspaceInference(holdTranscription: true)
    let model = AppModel(libraryURL: root.appendingPathComponent("Library"), inference: service)
    for day in ["08", "09", "10"] {
      try await add("note202611\(day)-090000.wav", to: model, at: root)
    }
    await model.reload()
    let active = model.recordings[0]
    let retry = model.recordings[1]
    let unrelated = model.recordings[2]
    var checkpoint = ProcessingDocument(recording: retry, model: service.transcriptionModel)
    checkpoint.phase = "failed"
    checkpoint.error = "AI 片段引用无效或重叠，尚未生成剪辑"
    checkpoint.completedChunks = 1
    checkpoint.transcript = [TranscriptLine(id: "0", start: 0, end: 1, text: "确认交付时间")]
    try await model.store.save(checkpoint, recording: retry)
    await model.reload()
    let previousError = "\(checkpoint.error!)\n录音：\(retry.originalName)"
    model.error = previousError
    model.retryProcessing(scope: .recording(active.id))
    for _ in 0..<500 {
      if await service.transcriptionCount == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(model.processingID, active.id)
    // Exercise the history-row button that was disabled while another file was processing.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 240),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingController(rootView: OriginalRecordingRow(model: model, recording: retry))
    window.contentViewController = host
    window.setContentSize(NSSize(width: 640, height: 240))
    host.view.layoutSubtreeIfNeeded()
    func buttons(in view: NSView) -> [NSButton] {
      if let button = view as? NSButton { return [button] }
      return view.subviews.flatMap { buttons(in: $0) }
    }
    let rowButtons = buttons(in: host.view)
    XCTAssertEqual(rowButtons.count, 1)
    let action = try XCTUnwrap(rowButtons.first)
    XCTAssertTrue(action.isEnabled)
    action.performClick(nil)
    try await Task.sleep(for: .milliseconds(50))
    host.view.layoutSubtreeIfNeeded()
    XCTAssertFalse(try XCTUnwrap(buttons(in: host.view).first).isEnabled)
    model.retryProcessing(scope: .recording(retry.id))
    XCTAssertEqual(model.queuedRecordingRetries, [retry.id])
    XCTAssertEqual(model.error, previousError)
    XCTAssertEqual(model.processingID, active.id)
    await service.releaseTranscription()
    try await finish(model)
    XCTAssertEqual(model.documents[active.id]?.phase, "complete")
    XCTAssertEqual(model.documents[retry.id]?.phase, "complete")
    XCTAssertTrue(model.queuedRecordingRetries.isEmpty)
    XCTAssertNil(model.error)
    XCTAssertEqual(model.summaries[retry.day]?.recordingIDs, [retry.id])
    XCTAssertNil(model.documents[unrelated.id])
    let transcribed = await service.transcriptionCount
    let organized = await service.organizationCount
    XCTAssertEqual(transcribed, 1)
    XCTAssertEqual(organized, 2)
    await model.shutdown()
  }

  @MainActor func testFailedSummaryRetryButtonQueuesOnceWhileAnotherDateIsBusy() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let day = "2026-11-11"
    let service = WorkspaceInference(failSummaryOnce: day)
    let model = AppModel(libraryURL: root.appendingPathComponent("Library"), inference: service)
    try await add("note20261111-090000.wav", to: model, at: root)
    try await add("note20261111-210000.wav", to: model, at: root)
    try await add("note20261110-090000.wav", to: model, at: root)
    let previous = DaySummary(day: day, overview: "上次成功的摘要", recordingIDs: [])
    try await model.store.save(previous)
    await model.reload()
    model.selectDay(day)
    let initial = try XCTUnwrap(model.recordings.first { $0.originalName == "note20261111-090000.wav" })
    model.retryProcessing(scope: .recording(initial.id))
    try await finish(model)
    XCTAssertTrue(model.summaryErrors[day]?.contains("HTTP 400") == true)
    XCTAssertEqual(model.summaries[day]?.overview, previous.overview)

    let other = try XCTUnwrap(model.recordings.first { $0.day != day })
    await service.blockTranscription()
    model.retryProcessing(scope: .recording(other.id))
    for _ in 0..<500 {
      if model.processingID == other.id { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(model.processingID, other.id)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 220),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingController(rootView: DaySummaryView(model: model))
    window.contentViewController = host
    window.setContentSize(NSSize(width: 500, height: 220))
    host.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(model.selectedDay, day)
    func buttons(in view: NSView) -> [NSButton] {
      if let button = view as? NSButton { return [button] }
      return view.subviews.flatMap { buttons(in: $0) }
    }
    let actions = buttons(in: host.view)
    XCTAssertEqual(actions.count, 1)
    let action = try XCTUnwrap(actions.first)
    XCTAssertTrue(action.isEnabled)
    action.performClick(nil)
    XCTAssertEqual(model.queuedSummaryRetries, [day])
    model.retryProcessing(scope: .summary(day))
    XCTAssertEqual(model.queuedSummaryRetries, [day])

    await service.releaseTranscription()
    try await finish(model)
    XCTAssertNil(model.processingSummaryDay)
    XCTAssertTrue(model.queuedSummaryRetries.isEmpty)
    XCTAssertNil(model.summaryErrors[day])
    XCTAssertTrue(model.summaryIsCurrent(day))
    let saved = try await model.store.summary(day: day)
    XCTAssertEqual(saved?.overview, "验证摘要")
    XCTAssertEqual(saved?.recordingIDs.count, 1)
    let transcribed = await service.transcriptionCount
    let requests = await service.summaryDays.filter { $0 == day }
    XCTAssertEqual(transcribed, 2, "重试摘要不能启动新的录音转写")
    XCTAssertEqual(requests.count, 2, "一次失败和一次有效重试")
    await model.shutdown()
  }

  @MainActor func testOpeningSettingsPreservesDateDetailAndPlayback() {
    let model = AppModel(
      libraryURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
        UUID().uuidString))
    model.selectDay("2026-11-09")
    model.selectedDetail = .conversation("first")
    model.player.selectionID = "playing"
    model.player.position = 42
    model.requestSettings(.recognition)
    XCTAssertEqual(model.selectedDay, "2026-11-09")
    XCTAssertEqual(model.selectedDetail, .conversation("first"))
    XCTAssertEqual(model.settingsSection, .recognition)
    model.showToday()
    XCTAssertEqual(model.selectedDay, WorkdayDate.day(Date()))
    model.selectDay("2026-11-09")
    XCTAssertEqual(model.selectedDetail, .conversation("first"))
    XCTAssertEqual(model.player.selectionID, "playing")
    XCTAssertEqual(model.player.position, 42)
  }

  @MainActor func testUnconfiguredRetryRequestsRecognitionWithoutLeavingSelectedDay() {
    let model = AppModel(
      libraryURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
        UUID().uuidString))
    model.selectDay("2026-11-09")
    let request = model.settingsRequest
    model.retryProcessing(scope: .day("2026-11-09"))
    XCTAssertNotEqual(model.settingsRequest, request)
    XCTAssertEqual(model.settingsSection, .recognition)
    XCTAssertEqual(model.selectedDay, "2026-11-09")
    XCTAssertFalse(model.isBusy)
  }

  func testDateLabelsDistinguishYears() {
    XCTAssertEqual(WorkspaceDate.title("2026-11-10", today: "2026-11-10"), "今天")
    XCTAssertEqual(WorkspaceDate.title("2026-11-09", today: "2026-11-10"), "昨天")
    XCTAssertEqual(WorkspaceDate.title("2025-11-09", today: "2026-11-10"), "2025年11月9日")
    XCTAssertEqual(WorkspaceDate.title("日期未知"), "日期未知")
  }

  func testUserReadbackStopsFollowingUntilLatestIsReached() {
    var position = LiveReadingPosition()
    XCTAssertTrue(position.followsLatest)
    position.update(bottom: 900, viewport: 210)
    XCTAssertFalse(position.followsLatest)
    position.update(bottom: 230, viewport: 210)
    XCTAssertTrue(position.followsLatest)
    position.update(bottom: 900, viewport: 210)
    position.resume()
    XCTAssertTrue(position.followsLatest)
  }

  @MainActor private func finish(_ model: AppModel) async throws {
    for _ in 0..<500 {
      if !model.isBusy { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(model.isBusy)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(model.isBusy)
  }
  private func makeRoot() throws -> URL {
    let root = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
        ?? NSTemporaryDirectory()
    )
    .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
  @MainActor private func add(_ name: String, to model: AppModel, at root: URL) async throws {
    let file = root.appendingPathComponent(name)
    try AudioFiles.wav(pcm: Data(repeating: 0, count: 64000)).write(to: file)
    _ = try await model.store.importAudio(file, sourceID: "fixture")
  }
}

private actor WorkspaceInference: InferenceServing {
  nonisolated let transcriptionModel = "local-test"
  var transcriptionCount = 0
  var organizationCount = 0
  private var holdTranscription: Bool
  private var failSummaryOnce: String?
  private(set) var summaryDays: [String] = []
  init(holdTranscription: Bool = false, failSummaryOnce: String? = nil) {
    self.holdTranscription = holdTranscription
    self.failSummaryOnce = failSummaryOnce
  }
  func blockTranscription() { holdTranscription = true }
  func releaseTranscription() { holdTranscription = false }
  func transcribe(audio: Data, format: String, chunk: Int, offset: Double, duration: Double)
    async throws -> [TranscriptLine]
  {
    transcriptionCount += 1
    while holdTranscription { try await Task.sleep(for: .milliseconds(10)) }
    return [TranscriptLine(id: "0", start: 0, end: 1, text: "确认交付时间")]
  }
  func organize(lines: [TranscriptLine]) async throws -> [ConversationProposal] {
    organizationCount += 1
    return [ConversationProposal(title: "交付时间", summary: "确认交付", firstID: "0", lastID: "0")]
  }
  func summarize(day: String, conversations: [Conversation], recordingIDs: [String]) async throws
    -> DaySummary
  {
    summaryDays.append(day)
    if failSummaryOnce == day {
      failSummaryOnce = nil
      throw WorkdayError.invalid("整理全天事项失败（HTTP 400）")
    }
    return DaySummary(day: day, overview: "验证摘要", recordingIDs: recordingIDs)
  }
}
