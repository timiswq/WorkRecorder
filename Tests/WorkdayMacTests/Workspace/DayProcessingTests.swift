import AppKit
import Foundation
import SwiftUI
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

  @MainActor func testDaySummaryFailureHasOneScopedRetryAndDisappearsAfterSuccess() async throws {
    let base = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    let root = URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = DayInference(failFirstSummary: true)
    let model = AppModel(libraryURL: root.appendingPathComponent("Library"), inference: service)
    model.preferences.autoOrganize = false
    for stamp in ["20261113-090000", "20261114-090000"] {
      let file = root.appendingPathComponent("note" + stamp + ".wav")
      try AudioFiles.wav(pcm: Data(repeating: 0, count: 64000)).write(to: file)
      _ = try await model.store.importAudio(file, sourceID: "fixture")
    }
    await model.reload()
    let day = "2026-11-13"
    model.requestDayProcessing(day)
    for _ in 0..<500 where model.processingIsRunning { try await Task.sleep(for: .milliseconds(10)) }

    func activities() -> [StatusActivity] { model.statusPresentation(at: Date()).activities }
    let failed = try XCTUnwrap(activities().first { $0.day == day })
    XCTAssertEqual(activities().map(\.day), ["2026-11-14", day])
    XCTAssertTrue(failed.title.hasSuffix("录音已转写，概述生成失败"))
    XCTAssertTrue(failed.detail.contains("请求超时"))
    XCTAssertEqual(failed.actionLabel, "重试概述")
    XCTAssertEqual(failed.action, .summary(day))
    XCTAssertEqual(MenuBarTaskSummary(model.statusPresentation(at: Date())).destination, .day(day))

    let focus = BackgroundFocusProbe()
    defer { focus.stop() }
    let host = NSHostingView(rootView: AppActivityList(model: model).padding(18).frame(width: 360)
      .background(Color.white).environment(\.colorScheme, .light))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.setFrameOrigin(NSPoint(x: -16000, y: -16000))
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    let buttons = nativeActionButtons(in: host)
    XCTAssertEqual(buttons.map(\.title).sorted(), ["开始转写", "重试概述"].sorted())
    if ProcessInfo.processInfo.environment["WORKDAY_STATUS_SNAPSHOTS"] == "1" {
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        .write(to: URL(fileURLWithPath: base).appendingPathComponent("day-processing-tasks.png"))
    }
    try XCTUnwrap(buttons.first { $0.title == "重试概述" }).performClick(nil)
    XCTAssertEqual(activities().first { $0.day == day }?.state, .waiting)
    XCTAssertNil(activities().first { $0.day == day }?.action)
    for _ in 0..<500 where model.processingIsRunning { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(activities().map(\.day), ["2026-11-14"])
    XCTAssertTrue(model.summaryIsCurrent(day))
    let transcriptions = await service.transcriptionCalls
    XCTAssertEqual(transcriptions, 1)
    XCTAssertFalse(focus.activatedTestApplication)
    await model.shutdown()
  }

  @MainActor func testQueuedSummaryRetryStopsAskingForTheSameAction() async {
    let base = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    let root = URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root, inference: DayInference())
    let day = "2026-11-13"
    model.summaryErrors[day] = "上次总结失败"
    model.retryProcessing(scope: .summary(day))
    let row = model.statusPresentation(at: Date()).activities.first { $0.day == day }
    XCTAssertEqual(row?.state, .waiting)
    XCTAssertNil(row?.action, "已经排队的任务不应继续要求重试")
    await model.shutdown()
  }
}

private actor DayInference: InferenceServing {
  nonisolated let transcriptionModel = "local-fixture"
  var summaryCalls = 0
  private(set) var transcriptionCalls = 0
  private let failFirstSummary: Bool
  private var holdFirst: Bool
  init(holdFirst: Bool = false, failFirstSummary: Bool = false) {
    self.holdFirst = holdFirst
    self.failFirstSummary = failFirstSummary
  }
  func release() { holdFirst = false }
  func transcribe(audio: Data, format: String, chunk: Int, offset: Double, duration: Double)
    async throws -> [TranscriptLine]
  {
    transcriptionCalls += 1
    return [TranscriptLine(id: "0", start: 0, end: 1, text: "确认交付进度")]
  }
  func organize(lines: [TranscriptLine]) async throws -> [ConversationProposal] {
    [ConversationProposal(title: "进度", summary: "确认交付进度", firstID: "0", lastID: "0")]
  }
  func summarize(day: String, conversations: [Conversation], recordingIDs: [String]) async throws
    -> DaySummary
  {
    summaryCalls += 1
    if failFirstSummary && summaryCalls == 1 { throw WorkdayError.invalid("请求超时。") }
    while holdFirst && summaryCalls == 1 { try await Task.sleep(for: .milliseconds(10)) }
    return DaySummary(day: day, overview: "本地验证", recordingIDs: recordingIDs)
  }
}
