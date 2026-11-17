import AppKit
import Foundation
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class CaptionFileReviewTests: XCTestCase {
  @MainActor func testCloudFinalUpdatesTheOriginalRowAcrossRecordingBoundary() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stub = ReviewStub()
    let old = TestLiveStream(), next = TestLiveStream()
    var streams = [old, next]
    let local = LivePreview(makeLocalStream: { streams.removeFirst() })
    let cloud = LivePreview(makeStream: { _ in XCTFail("Sentence review must never open the live socket"); return TestLiveStream() })
    let model = AppModel(libraryURL: root, live: cloud, localCaptions: local, fileReviewer: stub)
    let service = AIService(key: "fixture")
    model.preferences.cloudEnabled = true
    model.preferences.liveModel = .segment
    model.configureCaptions(service: service)
    model.card.onAudio?(packets())
    old.onEvent?(.sentence(id: 0, text: "本机先显示", isFinal: false, startMs: 40, endMs: 400))
    XCTAssertEqual(model.captionSelection.lines.first?.text, "本机先显示")
    let oldID = try XCTUnwrap(model.captionHistory.records.first?.id)
    model.card.onStreamReset?(.started)
    model.card.onAudio?(packets())
    old.onEvent?(.sentence(id: 0, text: "上一条录音", isFinal: true, startMs: 40, endMs: 400))
    next.onEvent?(.sentence(id: 0, text: "这条录音", isFinal: true, startMs: 80, endMs: 500))
    try await until { model.captionHistory.records.allSatisfy { if case .complete = $0.fileReview { return true }; return false } }
    let rows = model.captionHistory.records
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows.first?.id, oldID)
    XCTAssertEqual(rows.map { $0.transcript.text }, ["云端 1", "云端 2"])
    XCTAssertEqual(rows.map { $0.transcript.source }, [.cloud, .cloud])
    XCTAssertEqual(rows.map(\.text), ["上一条录音", "这条录音"])
    XCTAssertEqual(model.menuRecentSpeech?.line.transcript.text, "云端 2")
    XCTAssertEqual(model.captionSelection.lines.map(\.text), ["这条录音"])
    XCTAssertEqual(cloud.phase, .disabled)
    let audioBefore = try await model.captionHistory.replayAudio(for: rows[0])
    await model.shutdown()
    let reopened = CaptionHistory(root: root)
    XCTAssertEqual(reopened.records, rows)
    XCTAssertEqual(reopened.records.map { $0.transcript.source }, [.cloud, .cloud])
    let audioAfter = try await reopened.replayAudio(for: rows[0])
    XCTAssertEqual(audioBefore, audioAfter)
  }

  @MainActor func testCloudReviewUpdatesOnlyHistoryAndPreservesVisibleDismissedAndExpiredBubbles() async throws {
    _ = NSApplication.shared
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stub = ReviewStub(holdFirst: true)
    let stream = TestLiveStream()
    let local = LivePreview(makeLocalStream: { stream })
    let model = AppModel(libraryURL: root, localCaptions: local, fileReviewer: stub)
    model.preferences.cloudEnabled = true
    model.preferences.liveModel = .segment
    model.preferences.captions.showInFullScreen = true
    model.configureCaptions(service: AIService(key: "fixture"))
    model.desktop.start(model: model)
    defer { model.desktop.stop(); local.reset() }
    local.onVoice = { id, source, _, seconds in
      do { try model.voices.recordLive(id: id, source: source, seconds: seconds, vector: [1, 0], countDuration: false) }
      catch { XCTFail(error.localizedDescription) }
    }
    model.card.onAudio?(packets(count: 450))
    for i in 0..<3 {
      stream.onEvent?(.sentence(id: i, text: "初稿 \(i + 1)", isFinal: true,
                                startMs: Double(i * 3000), endMs: Double((i + 1) * 3000)))
    }
    try await until { model.desktop.panel?.feedView.rootView.presentation.content.items.filter { $0.voiceID != nil }.count == 3 }
    let feed = try XCTUnwrap(model.desktop.panel?.feedView.rootView)
    let original = feed.presentation.content.items
    let records = model.captionHistory.records
    XCTAssertEqual(records.map { $0.transcript.text }, original.map(\.text))
    XCTAssertEqual(records.map { $0.transcript.source }, [.local, .local, .local])
    feed.dismiss?(original[1].id)
    model.desktop.refresh(now: Date().addingTimeInterval(30))
    XCTAssertEqual(feed.presentation.content.items.map(\.id), [original[2].id])

    await stub.releaseFirst()
    try await until { model.captionHistory.records.last?.transcript.text == "云端 3" }
    model.desktop.refresh()
    let revised = try XCTUnwrap(feed.presentation.content.items.first)
    XCTAssertEqual(feed.presentation.content.items.map(\.id), [original[2].id])
    XCTAssertEqual(revised, original[2])
    XCTAssertEqual(revised.receivedAt, original[2].receivedAt)
    let updated = model.captionHistory.records
    XCTAssertEqual(updated.map(\.id), records.map(\.id))
    XCTAssertEqual(updated.map(\.time), records.map(\.time))
    XCTAssertEqual(updated.map { $0.transcript.text }, ["云端 1", "云端 2", "云端 3"])
    XCTAssertEqual(updated.map { $0.transcript.source?.title }, Array(repeating: "云端转写", count: 3))
    XCTAssertEqual(model.menuRecentSpeech?.line.transcript.text, "云端 3")
    feed.correct?(revised, .confirm)
    let evidence = try XCTUnwrap(revised.voiceID)
    XCTAssertEqual(try VoiceLibrary(root: root).sampleAudio(evidence), local.lines.last?.bubblePackets)
    await model.shutdown()
  }

  @MainActor func testLateFileResultCannotOverwriteANewerTimeRangeAndNoEarlierAudioIsSubmitted() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stub = ReviewStub(holdFirst: true)
    let stream = TestLiveStream()
    let local = LivePreview(makeLocalStream: { stream })
    let model = AppModel(libraryURL: root, localCaptions: local, fileReviewer: stub)
    let service = AIService(key: "fixture")
    model.preferences.liveModel = .segment
    model.card.onAudio?(packets()) // 600 ms before opting in
    model.preferences.cloudEnabled = true
    model.configureCaptions(service: service)
    model.card.onAudio?(packets())
    stream.onEvent?(.sentence(id: 0, text: "选择前已开始", isFinal: true, startMs: 420, endMs: 720))
    XCTAssertNil(model.captionHistory.records.first?.fileReview)
    stream.onEvent?(.sentence(id: 1, text: "第一版", isFinal: true, startMs: 740, endMs: 840))
    try await until { await stub.submissions == 1 }
    stream.onEvent?(.sentence(id: 1, text: "新边界", isFinal: true, startMs: 760, endMs: 1120))
    await stub.releaseFirst()
    try await until { model.captionHistory.records.last?.fileReview == .complete("云端 2") }
    XCTAssertEqual(model.captionSelection.lines.last?.text, "新边界")
    XCTAssertEqual(model.captionHistory.records.last?.transcript.text, "云端 2")
    XCTAssertNil(model.captionHistory.records.first?.fileReview)
    await model.shutdown()
  }

  @MainActor func testNetworkFailureKeepsLocalAndRetryUsesPersistedAudio() async throws {
    let root = try testRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stub = ReviewStub(failFirstRequest: true)
    let config = LiveASRConfiguration(key: "fixture", model: .segment)
    let history = CaptionHistory(root: root)
    history.configureReview(config, reviewer: stub)
    let replay = try XCTUnwrap(CaptionReplay(audio: packets(), startMs: 30, endMs: 210))
    let local = LiveLine(id: "test", segment: 1, sentence: 0, text: "对", isFinal: true,
                         receivedAt: Date(), replay: replay, fileReviewEligible: true)
    history.accept(local, evidenceID: "local-speaker")
    try await until { history.records.first?.fileReview == .failed(taskID: nil) }
    XCTAssertEqual(history.records.first?.transcript.text, "对")
    XCTAssertEqual(history.records.first?.transcript.source, .local)
    await history.flush()
    history.configureReview(nil, reviewer: nil)
    let reopened = CaptionHistory(root: root)
    reopened.configureReview(config, reviewer: stub)
    reopened.retryReview(try XCTUnwrap(reopened.records.first))
    try await until { reopened.records.first?.fileReview == .complete("云端 2") }
    reopened.accept(local, evidenceID: "corrected-speaker")
    XCTAssertEqual(reopened.records.first?.transcript.text, "云端 2")
    XCTAssertEqual(reopened.records.first?.evidenceID, "corrected-speaker")
    let submissions = await stub.submissions
    XCTAssertEqual(submissions, 2)
    await reopened.flush()
  }

  private func packets(count: Int = 30) -> Data {
    var data = Data()
    for _ in 0..<count { data.append(0x48); data.append(Data(repeating: 0, count: 39)) }
    return data
  }

  private func testRoot() throws -> URL {
    URL(fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString)
  }

  @MainActor private func until(_ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<200 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for the file review worker")
  }
}

private actor ReviewStub: CaptionFileTranscribing {
  var submissions = 0
  private var holdFirst: Bool
  private var failFirstRequest: Bool

  init(holdFirst: Bool = false, failFirstRequest: Bool = false) {
    self.holdFirst = holdFirst
    self.failFirstRequest = failFirstRequest
  }
  func releaseFirst() { holdFirst = false }

  func transcribeCaption(wav: Data) async throws -> String {
    guard wav.starts(with: Data("RIFF".utf8)), wav.count > 44 else { throw URLError(.cannotDecodeContentData) }
    submissions += 1
    let index = submissions
    if failFirstRequest {
      failFirstRequest = false
      throw URLError(.networkConnectionLost)
    }
    while index == 1 && holdFirst { try await Task.sleep(for: .milliseconds(5)) }
    return "云端 " + String(index)
  }
}
