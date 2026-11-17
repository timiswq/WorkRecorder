import Foundation
import QS668Core
import SQLite3
import WorkdayCore
import XCTest
@testable import WorkdayMac

final class VoiceSampleResetTests: XCTestCase {
  private func root() -> URL {
    URL(fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent("voice-reset-" + UUID().uuidString)
  }

  @MainActor func testClearSamplesPreservesHistoryNamesAndCanBeEnrolledAgain() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try VoiceLibrary(root: root)
    let packets = Data(repeating: 72, count: 6000)
    try db.record(id: "owner", source: "card", live: true, seconds: 3, voice: [1, 0, 0])
    try db.record(id: "guest", source: "card", live: true, seconds: 3, voice: [0, 1, 0])
    try db.record(id: "colleague", source: "file", live: false, seconds: 3, voice: [0, 0, 1])
    try db.name(try XCTUnwrap(db.localGroup(for: "colleague")), "同事")
    try db.setCaptionMark("caption:owner", mine: true, evidence: "owner", packets: packets)
    try db.setCaptionMark("caption:guest", mine: false, evidence: "guest", packets: packets)
    XCTAssertEqual(db.sampleCount, 1)
    XCTAssertEqual(db.negativeSampleCount, 1)

    try db.clearSamples()
    let reopened = try VoiceLibrary(root: root)
    XCTAssertEqual(reopened.sampleCount, 0)
    XCTAssertEqual(reopened.negativeSampleCount, 0)
    XCTAssertFalse(reopened.confirmed)
    XCTAssertEqual(try reopened.assessLive([1, 0, 0]).reason, .noOwnerProfile)
    XCTAssertNil(try reopened.sampleAudio("owner"))
    XCTAssertNil(try reopened.sampleAudio("guest"))
    XCTAssertTrue(try XCTUnwrap(reopened.label("caption:owner")).isMine)
    XCTAssertTrue(try XCTUnwrap(reopened.label("caption:guest")).excluded)
    XCTAssertEqual(try reopened.label("colleague")?.savedName, "同事")
    XCTAssertTrue(try reopened.contains("owner"))
    XCTAssertTrue(try reopened.contains("guest"))
    try reopened.clearSamples()
    XCTAssertTrue(try XCTUnwrap(reopened.label("caption:owner")).isMine)
    try reopened.record(id: "new-owner", source: "new", live: true, seconds: 3, voice: [1, 0, 0])
    try reopened.setCaptionMark("caption:new", mine: true, evidence: "new-owner", packets: packets)
    XCTAssertEqual(reopened.sampleCount, 1)
    XCTAssertEqual(reopened.negativeSampleCount, 0)
  }

  @MainActor func testClearSamplesRollsBackBothLibrariesWhenDeletionFails() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try VoiceLibrary(root: root)
    try db.record(id: "owner", source: "card", live: true, seconds: 3, voice: [1, 0])
    try db.confirm("owner")
    try db.record(id: "guest", source: "card", live: true, seconds: 3, voice: [0, 1])
    try db.markNotMine("caption:guest", evidence: "guest")
    var handle: OpaquePointer?
    XCTAssertEqual(sqlite3_open(root.appendingPathComponent("Sync/voice-campplus-v1.sqlite").path, &handle), SQLITE_OK)
    defer { sqlite3_close(handle) }
    XCTAssertEqual(sqlite3_exec(handle, """
      CREATE TRIGGER prevent_sample_deletion BEFORE DELETE ON non_owner_samples
      BEGIN SELECT RAISE(ABORT,'test deletion failure'); END;
      """, nil, nil, nil), SQLITE_OK)
    XCTAssertThrowsError(try db.clearSamples())
    let reopened = try VoiceLibrary(root: root)
    XCTAssertEqual(reopened.sampleCount, 1)
    XCTAssertEqual(reopened.negativeSampleCount, 1)
    XCTAssertEqual(try reopened.label("owner")?.sampleID, "owner")
  }

  @MainActor func testLabelWithoutVoiceNeedsNoSampleResetWhenFinalEvidenceArrives() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try VoiceLibrary(root: root)
    let voices = VoiceRecognition(root: root)
    let stream = ResetTestStream()
    let live = LivePreview(makeStream: { _ in stream })
    defer { voices.stop(); live.reset() }
    live.onVoice = { _, _, _, _ in }
    live.configure(enabled: true, service: AIService(key: "local-test"))
    live.append(Data(repeating: 72, count: 6000))
    stream.onEvent?(.sentence(id: 0, text: "尚未定稿", isFinal: false))
    let lineID = try XCTUnwrap(live.lines.last?.id)
    voices.confirm("caption:" + lineID, captionLineID: lineID)
    XCTAssertFalse(voices.canClearSamples)
    voices.clearSamples()
    XCTAssertFalse(voices.canClearSamples)
    try db.record(id: "live:" + lineID, source: "card", live: true, seconds: 3, voice: [1, 0])
    stream.onEvent?(.sentence(id: 0, text: "现在定稿", isFinal: true, startMs: 0, endMs: 3000))
    XCTAssertNotNil(live.lines.last?.voiceID)
    XCTAssertEqual(voices.sampleCount, 0)
    XCTAssertEqual(try VoiceLibrary(root: root).sampleCount, 0)
    XCTAssertTrue(try XCTUnwrap(voices.label("caption:" + lineID)).isMine)
    XCTAssertNil(voices.error)
  }

  @MainActor func testClearSamplesInvalidatesCurrentRollingOwner() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try VoiceLibrary(root: root)
    try db.record(id: "owner", source: "train", live: true, seconds: 5, voice: [1, 0])
    try db.confirm("owner")
    let voices = VoiceRecognition(root: root)
    defer { voices.stop() }
    let line = LiveLine(id: "current", segment: 0, sentence: 0, text: "当前发言", isFinal: true,
                        recognitionRange: 0..<12_000)
    voices.observeLiveLines([line])
    let generation = UUID()
    for start in [0, 16_000] {
      voices.receiveLiveEvidence(.init(generation: generation, range: start..<start + 80_000,
        quality: .init(voicedSeconds: 4, duration: 5, rmsDBFS: -20, clippedFraction: 0, finite: true),
        voice: [1, 0], changeVoice: [1, 0], pcm: Array(repeating: 0.05, count: 80_000),
        packets: Data(repeating: 72, count: 10_000), packetStartFrame: start, inferenceMilliseconds: 1))
    }
    let id = try XCTUnwrap(voices.presentationLine(line).bubbleVoiceID)
    XCTAssertTrue(voices.label(id)?.isMine == true)
    let revision = voices.captionIdentityRevision
    voices.clearSamples()
    XCTAssertEqual(voices.sampleCount, 0)
    XCTAssertFalse(voices.label(id)?.isMine == true)
    XCTAssertNil(voices.presentationLine(line).bubbleVoiceID)
    XCTAssertGreaterThan(voices.captionIdentityRevision, revision)
    XCTAssertNil(voices.error)
  }
}

@MainActor private final class ResetTestStream: LiveASRStreaming {
  var onEvent: ((ASREvent) -> Void)?
  func start() {}
  func append(_ data: Data) {}
  func finish() {}
  func cancel() {}
}
