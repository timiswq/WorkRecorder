import AppKit
import SwiftUI
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class ProcessingPresentationTests: XCTestCase {
  @MainActor func testRunningQueuedAndManualDaysMatchTheActualExecutionPlan() async throws {
    let (root, model, service) = try await library()
    defer { model.pauseProcessing(); try? FileManager.default.removeItem(at: root) }
    model.selectDay("2026-11-13")
    XCTAssertEqual(model.dayOverviewState(for: "2026-11-13"), .pending(2))
    XCTAssertEqual(model.statusPresentation(at: Date()).activities.first { $0.id == "processing" }?.state, .needsAction)
    try await capture(model, name: "processing-manual")
    model.requestDayProcessing("2026-11-13")
    for _ in 0..<300 where model.processingID == nil { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(model.dayOverviewState(for: "2026-11-13"), .processingRecordings("正在转写录音"))
    XCTAssertNil(model.dayOverviewState(for: "2026-11-13").actionTitle)
    try await capture(model, name: "processing-running")
    XCTAssertEqual(model.dayOverviewState(for: "2026-11-14"), .blocked(1))
    model.requestDayProcessing("2026-11-14")
    model.requestDayProcessing("2026-11-14")
    XCTAssertEqual(model.queuedRecordingRetries.count, 1, "重复点击不能重复提交任务")
    XCTAssertEqual(model.dayOverviewState(for: "2026-11-14"), .queuedRecordings(1))
    XCTAssertNil(model.dayOverviewState(for: "2026-11-14").actionTitle)
    model.selectDay("2026-11-14")
    try await capture(model, name: "processing-queued")
    await service.release()
    for _ in 0..<1000 where model.processingIsRunning { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(model.processingIsRunning)
    XCTAssertTrue(model.summaryIsCurrent("2026-11-13"))
    XCTAssertTrue(model.summaryIsCurrent("2026-11-14"), "队列中的日期完成录音后也须生成概述")
    let untouched = model.recordings.first { $0.day == "2026-11-15" }
    XCTAssertNotNil(untouched)
    XCTAssertNil(untouched.flatMap { model.documents[$0.id] }, "不能启动未授权日期的工作")
    XCTAssertTrue(model.scheduledRecordingIDs.isEmpty)
    XCTAssertTrue(model.scheduledSummaryDays.isEmpty)
    await model.shutdown()
  }

  @MainActor func testPausedRequiresExplicitResumeAndPendingNeedsConfiguration() async throws {
    let (root, model, _) = try await library()
    defer { model.pauseProcessing(); try? FileManager.default.removeItem(at: root) }
    model.selectDay("2026-11-13")
    model.pauseProcessing()
    XCTAssertEqual(model.dayOverviewState(for: "2026-11-13"), .paused)
    XCTAssertEqual(model.dayOverviewState(for: "2026-11-13").actionTitle, "继续处理")
    try await capture(model, name: "processing-paused")
    let noService = AppModel(libraryURL: root.appendingPathComponent("OtherLibrary"))
    noService.recordings = model.recordings
    noService.selectDay("2026-11-13")
    noService.loading = false
    XCTAssertEqual(noService.dayOverviewState(for: "2026-11-13"), .unconfigured)
    let record = try XCTUnwrap(noService.recordings.first)
    XCTAssertEqual(noService.recordingProcessingState(record), .needsSetup)
    try await capture(noService, name: "processing-setup")
    model.requestDayProcessing("2026-11-13")
    for _ in 0..<300 where model.processingID == nil { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(model.dayOverviewState(for: "2026-11-13"), .processingRecordings("正在转写录音"))
    model.pauseProcessing()
    XCTAssertEqual(model.dayOverviewState(for: "2026-11-13"), .pausing)
    XCTAssertNil(model.dayOverviewState(for: "2026-11-13").actionTitle)
    for _ in 0..<300 where model.processingIsRunning { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(model.dayOverviewState(for: "2026-11-13"), .paused)
    await model.shutdown()
    await noService.shutdown()
  }

  @MainActor private func library() async throws -> (URL, AppModel, PresentationInference) {
    let base = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    let root = URL(fileURLWithPath: base).appendingPathComponent("processing-presentation-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = PresentationInference()
    let model = AppModel(libraryURL: root.appendingPathComponent("Library"), inference: service)
    model.preferences.autoOrganize = false
    for stamp in ["20261113-090000", "20261113-100000", "20261114-090000", "20261115-090000"] {
      let file = root.appendingPathComponent("note" + stamp + ".wav")
      try AudioFiles.wav(pcm: Data(repeating: 0, count: 64000)).write(to: file)
      _ = try await model.store.importAudio(file, sourceID: "fixture")
    }
    await model.reload()
    model.loading = false
    return (root, model, service)
  }

  @MainActor private func capture(_ model: AppModel, name: String) async throws {
    guard ProcessInfo.processInfo.environment["WORKDAY_PROCESSING_SNAPSHOTS"] == "1",
      let output = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] else { return }
    _ = NSApplication.shared
    let focus = BackgroundFocusProbe()
    defer { focus.stop() }
    let window = NSWindow(contentRect: NSRect(x: -16000, y: -16000, width: 1140, height: 760),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingController(rootView: RootView(model: model))
    window.contentViewController = host
    host.view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(120))
    host.view.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
    host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      .write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
    XCTAssertFalse(focus.activatedTestApplication)
  }
}

private actor PresentationInference: InferenceServing {
  nonisolated let transcriptionModel = "local-fixture"
  private var held = true
  func release() { held = false }
  func transcribe(audio: Data, format: String, chunk: Int, offset: Double, duration: Double) async throws -> [TranscriptLine] {
    while held { try await Task.sleep(for: .milliseconds(10)) }
    return [TranscriptLine(id: "0", start: 0, end: 1, text: "讨论发布范围")]
  }
  func organize(lines: [TranscriptLine]) async throws -> [ConversationProposal] {
    [ConversationProposal(title: "发布范围", summary: "讨论发布范围", firstID: "0", lastID: "0")]
  }
  func summarize(day: String, conversations: [Conversation], recordingIDs: [String]) async throws -> DaySummary {
    DaySummary(day: day, overview: "讨论了发布范围。", recordingIDs: recordingIDs)
  }
}
