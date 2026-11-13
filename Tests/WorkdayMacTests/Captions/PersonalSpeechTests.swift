import AppKit
import XCTest
@testable import WorkdayCore
@testable import WorkdayMac

final class PersonalSpeechTests: XCTestCase {
  private func temporaryRoot() throws -> URL {
    let base = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    let url = URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @MainActor func testBothVoicesAppearWhileShortCaptionsRemainInHistoryAndMenu() async throws {
    _ = NSApplication.shared
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try VoiceLibrary(root: root)
    for (id, vector) in [("sample", [1, 0] as [Float]), ("live:owner", [1, 0]), ("live:guest", [0, 1])] {
      try db.record(id: id, source: "card", live: true, seconds: 3, voice: vector)
    }
    let model = AppModel(libraryURL: root)
    model.preferences.captions.showInFullScreen = true
    model.desktop.start(model: model)
    let first = Date().addingTimeInterval(-4)
    let guest = LiveLine(id: "guest", segment: 1, sentence: 0, text: "同事发言", isFinal: true,
                         voiceID: "live:guest", receivedAt: first,
                         bubblePhrase: .init(text: "同事发言", continuesPrevious: false))
    let mine = LiveLine(id: "owner", segment: 1, sentence: 1, text: "我的发言", isFinal: true,
                        voiceID: "live:owner", receivedAt: first.addingTimeInterval(1),
                        bubblePhrase: .init(text: "我的发言", continuesPrevious: true))
    let short = LiveLine(id: "short", segment: 1, sentence: 2, text: "嗯", isFinal: true,
                         receivedAt: first.addingTimeInterval(2))
    var draft = mine
    draft.isFinal = false
    let rows = [guest, mine, short]
    for line in rows { model.captionHistory.accept(line, evidenceID: line.voiceID) }
    model.desktop.refresh(transcript: rows)
    XCTAssertEqual(model.menuRecentSpeech?.line.id, "short")

    model.selectCaption(model.captionHistory.records[0])
    XCTAssertEqual(model.selectedCaption?.id, "guest")
    model.desktop.refresh()
    func bubbleTexts() -> [String]? {
      model.desktop.panel?.feedView.rootView.presentation.content.items.map(\.text)
    }
    XCTAssertEqual(bubbleTexts(), ["同事发言", "我的发言"])
    model.desktop.refresh(transcript: [draft, short])
    XCTAssertEqual(bubbleTexts(), [])
    model.voices.confirm("sample")
    model.desktop.refresh(transcript: rows)
    XCTAssertEqual(bubbleTexts(), ["同事发言", "我的发言"])
    XCTAssertEqual(model.captionHistory.records.map(\.id), ["guest", "owner", "short"])
    XCTAssertEqual(model.menuRecentSpeech?.line.id, "short")
    XCTAssertTrue(model.correctCaption("owner", expectedTurn: "live:owner"))
    model.desktop.refresh()
    XCTAssertEqual(model.voices.negativeSampleCount, 1)
    XCTAssertEqual(bubbleTexts(), ["同事发言", "我的发言"])
    await model.shutdown()
  }

  @MainActor func testRealVoiceSamplesFilterLocalTurnsWithCloudEnabledAndALateFinal() async throws {
    guard let path = ProcessInfo.processInfo.environment["WORKDAY_PUBLIC_SPEECH"] else {
      throw XCTSkip("Requires the public speaker fixtures")
    }
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    func audio(_ name: String) throws -> Data {
      try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent(name + ".opusraw"))
    }
    let db = try VoiceLibrary(root: root)
    let sample = try await SpeakerEncoder().live(packets: audio("fangjun-sr-2"))
    try db.record(id: "sample", source: "training", live: true, seconds: 3, voice: try XCTUnwrap(sample))
    try db.confirm("sample")
    let old = TestLiveStream(), next = TestLiveStream()
    var streams = [old, next]
    let local = LivePreview(makeLocalStream: { streams.removeFirst() })
    let cloud = LivePreview(makeStream: { _ in TestLiveStream() })
    let model = AppModel(libraryURL: root, live: cloud, localCaptions: local)
    model.preferences.captions.showInFullScreen = true
    model.desktop.start(model: model)
    model.preferences.cloudEnabled = true
    model.configureCaptions(service: AIService(key: "fixture"))
    // The router can wait for cloud text independently of the speaker encoder.
    func waitForCaption(_ text: String) async throws {
      for _ in 0..<200 {
        if model.captionHistory.records.contains(where: { $0.isFinal && $0.text == text }) { return }
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTFail("Missing final caption: " + text)
    }
    let guest = try audio("leijun-test-sr-2"), owner = try audio("fangjun-test-sr-1")
    model.card.onAudio?(guest)
    let split = Double(guest.count) / 2
    old.onEvent?(.sentence(id: 0, text: "同事说话", isFinal: true, startMs: 0, endMs: split))
    try await waitForCaption("同事说话")
    await model.voices.waitForStoppedTasks()
    model.desktop.refresh()
    XCTAssertEqual(model.menuRecentSpeech?.line.text, "同事说话")
    XCTAssertEqual(model.desktop.panel?.feedView.rootView.presentation.content.items.map(\.text), ["同事说话"])
    model.card.onAudio?(owner)
    let end = split + Double(owner.count) / 2
    old.onEvent?(.sentence(id: 1, text: "本人尾句", isFinal: false, startMs: split, endMs: end))
    model.card.onStreamReset?(.started)
    old.onEvent?(.sentence(id: 1, text: "本人尾句", isFinal: true, startMs: split, endMs: end))
    model.card.onAudio?(owner)
    next.onEvent?(.sentence(id: 0, text: "本人新句", isFinal: true, startMs: 0, endMs: Double(owner.count) / 2))
    try await waitForCaption("本人新句")
    await model.voices.waitForStoppedTasks()
    model.desktop.refresh()
    XCTAssertEqual(model.desktop.panel?.feedView.rootView.presentation.content.items.map(\.text), ["本人新句"])
    XCTAssertEqual(model.captionHistory.records.map(\.text), ["同事说话", "本人尾句", "本人新句"])
    await model.shutdown()
  }

  @MainActor func testBubblePreferenceKeepsAllSpeakersInSummaryAndOriginal() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appendingPathComponent("Library")
    let store = ArchiveStore(root: library)
    let file = root.appendingPathComponent("note20261110-090000.wav")
    try AudioFiles.wav(pcm: Data(repeating: 0, count: 320_000)).write(to: file)
    let recording = try await store.importAudio(file, sourceID: "card")
    let day = recording.day
    var doc = ProcessingDocument(recording: recording, model: "fixture")
    doc.phase = "complete"
    doc.editorialVersion = 2
    let mine = TranscriptLine(id: "owner", start: 0, end: 3, text: "我来核对合同")
    let guest = TranscriptLine(id: "guest", start: 3, end: 6, text: "同事提议周五发布")
    doc.transcript = [mine, guest]
    let discussion = mine.text + "。" + guest.text
    doc.conversations = [Conversation(id: "mixed", recordingID: recording.id, title: "合同与发布",
      summary: discussion, start: 0, end: 6, lineIDs: ["owner", "guest"], audioFile: recording.originalFile,
      sha256: recording.sha256, decisions: [], tasks: [guest.text])]
    try await store.save(doc, recording: recording)
    // An old owner-only summary must never be presented as the full day.
    let legacy = DaySummary(day: day, overview: mine.text, recordingIDs: [recording.id])
    try Files.writeJSON(legacy, to: library.appendingPathComponent("Days/\(day)/summary-owner.json"))

    let probe = PersonalSummaryProbe()
    let model = AppModel(libraryURL: library, inference: probe)
    model.preferences.cloudEnabled = true
    await model.reload()
    XCTAssertNil(model.summaries[day])
    model.scheduleProcessing()
    for _ in 0..<500 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    let calls = await probe.calls
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.flatMap { $0.excerpt ?? [] }, [mine, guest])
    XCTAssertEqual(model.summaries[day]?.overview, discussion)
    XCTAssertEqual(model.workspace(for: day).conversations.flatMap(\.lineIDs), ["owner", "guest"])
    XCTAssertTrue(model.summaryIsCurrent(day))
    let archive = try await store.document(for: recording)
    XCTAssertEqual(archive?.transcript, doc.transcript)
    XCTAssertEqual(try Files.hash(library.appendingPathComponent(recording.folder)
      .appendingPathComponent(recording.originalFile)), recording.sha256)
    await model.shutdown()

    let reopened = AppModel(libraryURL: library)
    await reopened.reload()
    XCTAssertEqual(reopened.summaries[day]?.overview, discussion)
    await reopened.shutdown()
  }
}

private actor PersonalSummaryProbe: InferenceServing {
  nonisolated let transcriptionModel = "fixture"
  private(set) var calls: [[Conversation]] = []
  func transcribe(audio: Data, format: String, chunk: Int, offset: Double, duration: Double) async throws -> [TranscriptLine] {
    XCTFail("The day summary should reuse the archived transcript")
    return []
  }
  func organize(lines: [TranscriptLine]) async throws -> [ConversationProposal] {
    XCTFail("The day summary should reuse the archived transcript")
    return []
  }
  func summarize(day: String, conversations: [Conversation], recordingIDs: [String]) async throws -> DaySummary {
    calls.append(conversations)
    let overview = conversations.map(\.summary).joined(separator: " ")
    var summary = DaySummary(day: day, overview: overview, recordingIDs: recordingIDs)
    summary.activities = [.init(kind: .event, title: overview, summary: overview, conversationIDs: conversations.map(\.id))]
    return summary
  }
}
