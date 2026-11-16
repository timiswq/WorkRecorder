import Foundation
import XCTest
import WorkdayCore
@testable import WorkdayMac

final class LiveIdentityIntegrationTests: XCTestCase {
  private func root() -> URL {
    URL(fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent("live-identity-" + UUID().uuidString)
  }

  @MainActor func testUnknownAutoGroupCannotVetoExplicitOwnerButConfirmedNegativeCan() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try VoiceLibrary(root: root)
    try db.record(id: "owner", source: "train", live: true, seconds: 4, voice: [1, 0])
    try db.confirm("owner")
    try db.record(id: "unknown", source: "train", live: true, seconds: 4, voice: [0.49, 0.871722])
    let query: [Float] = [0.7, 0.7141428]
    try db.record(id: "live:query", source: "test", live: true, seconds: 4, voice: query)
    XCTAssertFalse(try db.label("live:query")?.isMine == true)
    XCTAssertEqual(try db.assessLive(query).reason, .matched)
    try db.markNotMine("not-owner", evidence: "unknown")
    XCTAssertEqual(try db.assessLive(query).reason, .negativeMatch)
  }

  @MainActor func testRollingDraftRefreshDoesNotTeachAndFeedbackRetainsExactWindow() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try VoiceLibrary(root: root)
    try db.record(id: "owner", source: "training", live: true, seconds: 4, voice: [1, 0])
    try db.confirm("owner")
    let voices = VoiceRecognition(root: root)
    let generation = UUID()
    var line = LiveLine(id: "sentence", segment: 0, sentence: 0, text: "持续讲话", isFinal: false,
                        recognitionRange: 0..<10_000)
    voices.observeLiveLines([line])
    func evidence(_ start: Int, marker: UInt8) -> LiveVoiceEvidence {
      LiveVoiceEvidence(generation: generation, range: start..<start + 64_000,
        quality: .init(voicedSeconds: 4, duration: 4, rmsDBFS: -20, clippedFraction: 0, finite: true),
        voice: [1, 0], changeVoice: [1, 0], pcm: Array(repeating: 0.05, count: 64_000),
        packets: Data(repeating: marker, count: 8000), packetStartFrame: start,
        inferenceMilliseconds: 1)
    }
    voices.receiveLiveEvidence(evidence(0, marker: 72))
    voices.receiveLiveEvidence(evidence(16_000, marker: 73))
    let shown = voices.presentationLine(line)
    let id = try XCTUnwrap(shown.bubbleVoiceID)
    XCTAssertTrue(voices.label(id)?.isMine == true)
    XCTAssertEqual(voices.sampleCount, 1)
    XCTAssertEqual(try db.liveEvidenceCount(), 0, "Draft windows must stay in bounded memory")
    let packets = try XCTUnwrap(shown.bubblePackets)
    voices.setCaptionMark(lineID: line.id, mine: true, evidence: id)
    XCTAssertEqual(voices.sampleCount, 2)
    line.recognitionRange = 0..<12_000
    voices.observeLiveLines([line])
    voices.receiveLiveEvidence(evidence(32_000, marker: 74))
    XCTAssertNotEqual(voices.presentationLine(line).bubbleVoiceID, id)
    XCTAssertEqual(try db.sampleAudio(id), packets)
    XCTAssertEqual(try db.liveSamplePCM(id)?.count, 64_000)
    XCTAssertEqual(voices.sampleCount, 2)
    voices.stop()
  }

  @MainActor func testMixedLongCaptionCannotBorrowOwnerAndResetRejectsOldGeneration() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try VoiceLibrary(root: root)
    try db.record(id: "owner", source: "train", live: true, seconds: 4, voice: [1, 0])
    try db.confirm("owner")
    let voices = VoiceRecognition(root: root)
    let generation = UUID()
    let line = LiveLine(id: "mixed", segment: 0, sentence: 0, text: "先本人后同事", isFinal: false,
                        recognitionRange: 0..<14_000)
    voices.observeLiveLines([line])
    func evidence(_ start: Int, voice: [Float], change: [Float], generation: UUID) -> LiveVoiceEvidence {
      .init(generation: generation, range: start..<start + 64_000,
            quality: .init(voicedSeconds: 4, duration: 4, rmsDBFS: -20, clippedFraction: 0, finite: true),
            voice: voice, changeVoice: change, pcm: Array(repeating: 0.1, count: 64_000),
            packets: Data(repeating: 72, count: 8000), packetStartFrame: start, inferenceMilliseconds: 1)
    }
    voices.receiveLiveEvidence(evidence(0, voice: [1, 0], change: [1, 0], generation: generation))
    voices.receiveLiveEvidence(evidence(16_000, voice: [1, 0], change: [1, 0], generation: generation))
    voices.receiveLiveEvidence(evidence(32_000, voice: [0.8, 0.6], change: [0, 1], generation: generation))
    voices.receiveLiveEvidence(evidence(48_000, voice: [0, 1], change: [0, 1], generation: generation))
    XCTAssertFalse(voices.label(voices.presentationLine(line).bubbleVoiceID)?.isMine == true)
    voices.resetLiveAudio()
    let next = UUID()
    voices.receiveLiveEvidence(evidence(0, voice: [1, 0], change: [1, 0], generation: next))
    voices.receiveLiveEvidence(evidence(16_000, voice: [1, 0], change: [1, 0], generation: next))
    let current = voices.presentationLine(line).bubbleVoiceID
    voices.receiveLiveEvidence(evidence(64_000, voice: [0, 1], change: [0, 1], generation: generation))
    XCTAssertEqual(voices.presentationLine(line).bubbleVoiceID, current)
    voices.stop()
  }

  @MainActor func testShadowModeDoesNotChangePresentationOrWriteWindowRows() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try VoiceLibrary(root: root)
    var updates = 0
    let live = RealtimeVoiceRecognition(mode: .shadow, database: { db }, changed: { _ in updates += 1 }, failure: { XCTFail($0.localizedDescription) })
    let line = LiveLine(id: "shadow", segment: 0, sentence: 0, text: "只记录", isFinal: true,
                        recognitionRange: 0..<12_000)
    live.observe([line])
    let evidence = LiveVoiceEvidence(generation: UUID(), range: 0..<80_000,
      quality: .init(voicedSeconds: 4, duration: 5, rmsDBFS: -20, clippedFraction: 0, finite: true),
      voice: [1, 0], changeVoice: [1, 0], pcm: Array(repeating: 0.1, count: 80_000),
      packets: Data(repeating: 72, count: 10_000), packetStartFrame: 0, inferenceMilliseconds: 1)
    live.receive(evidence)
    XCTAssertEqual(live.presentation(line), line)
    XCTAssertEqual(updates, 0)
    XCTAssertEqual(try db.liveEvidenceCount(), 0)
    live.stop()
  }

  @MainActor func testInsufficientSpeechDoesNotInventSpeakerChangeWithinOwnerCaption() throws {
    try checkSpeakerAfterPause(remainsOwner: true)
  }

  @MainActor func testDifferentSpeakerAfterPauseCannotInheritOwnerCaption() throws {
    try checkSpeakerAfterPause(remainsOwner: false)
  }

  @MainActor private func checkSpeakerAfterPause(remainsOwner: Bool) throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try VoiceLibrary(root: root)
    try db.record(id: "owner", source: "train", live: true, seconds: 5, voice: [1, 0])
    try db.confirm("owner")
    let voices = VoiceRecognition(root: root)
    defer { voices.stop() }
    let line = LiveLine(id: "pause", segment: 0, sentence: 0, text: "中间短暂停顿", isFinal: false,
                        recognitionRange: 0..<18_000)
    voices.observeLiveLines([line])
    let generation = UUID()
    func receive(_ start: Int, voice: [Float]?) {
      voices.receiveLiveEvidence(.init(generation: generation, range: start..<start + 80_000,
        quality: .init(voicedSeconds: voice == nil ? 2.7 : 4, duration: 5,
                       rmsDBFS: -25, clippedFraction: 0, finite: true),
        voice: voice, changeVoice: voice, pcm: Array(repeating: 0.05, count: 80_000),
        packets: Data(repeating: 72, count: 10_000), packetStartFrame: start, inferenceMilliseconds: 1))
    }
    receive(0, voice: [1, 0])
    receive(16_000, voice: [1, 0])
    receive(32_000, voice: nil)
    let next: [Float] = remainsOwner ? [1, 0] : [0, 1]
    receive(48_000, voice: next)
    receive(64_000, voice: next)
    XCTAssertEqual(voices.label(voices.presentationLine(line).bubbleVoiceID)?.isMine == true, remainsOwner)
    XCTAssertEqual(voices.sampleCount, 1, "Neither pauses nor a speaker change may teach a new owner sample")
  }

  @MainActor func testContinuousTrackIdentifiesANewShortSentenceWithoutBorrowingEnrollmentAudio() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try VoiceLibrary(root: root)
    try db.record(id: "owner", source: "train", live: true, seconds: 4, voice: [1, 0])
    try db.confirm("owner")
    let voices = VoiceRecognition(root: root)
    let line = LiveLine(id: "continuation", segment: 0, sentence: 1, text: "后面一句", isFinal: false,
                        recognitionRange: 6000..<10_000)
    voices.observeLiveLines([line])
    let generation = UUID()
    for start in [0, 16_000] {
      voices.receiveLiveEvidence(.init(generation: generation, range: start..<start + 64_000,
        quality: .init(voicedSeconds: 4, duration: 4, rmsDBFS: -20, clippedFraction: 0, finite: true),
        voice: [1, 0], changeVoice: [1, 0], pcm: Array(repeating: 0.05, count: 64_000),
        packets: Data(repeating: 72, count: 8000), packetStartFrame: start, inferenceMilliseconds: 1))
    }
    let shown = voices.presentationLine(line)
    let id = try XCTUnwrap(shown.bubbleVoiceID)
    XCTAssertTrue(voices.label(id)?.isMine == true)
    voices.markBubble(lineID: line.id, evidence: id, packets: try XCTUnwrap(shown.bubblePackets), mine: true)
    XCTAssertEqual(voices.sampleCount, 1, "A neighbouring window may identify continuity but must not enroll on this short sentence's feedback")
    XCTAssertTrue(voices.captionSpeaker(lineID: line.id, evidenceID: id).markedHere)
    voices.stop()
  }

  @MainActor func testFinalCaptionFeedbackKeepsPacketEvidenceAfterMemoryEviction() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try VoiceLibrary(root: root)
    let voices = VoiceRecognition(root: root)
    let line = LiveLine(id: "history", segment: 0, sentence: 0, text: "历史发言", isFinal: true,
                        recognitionRange: 0..<12_000)
    voices.observeLiveLines([line])
    let packets = Data(repeating: 72, count: 10_000)
    voices.receiveLiveEvidence(.init(generation: UUID(), range: 0..<80_000,
      quality: .init(voicedSeconds: 4, duration: 5, rmsDBFS: -20, clippedFraction: 0, finite: true),
      voice: [1, 0], changeVoice: [1, 0], pcm: Array(repeating: 0.1, count: 80_000),
      packets: packets, packetStartFrame: 0, inferenceMilliseconds: 1))
    let id = try XCTUnwrap(voices.presentationLine(line).bubbleVoiceID)
    voices.observeLiveLines([])
    voices.setCaptionMark(lineID: line.id, mine: true, evidence: id)
    XCTAssertEqual(try db.sampleAudio(id), packets)
    XCTAssertEqual(voices.sampleCount, 1)
    voices.stop()
  }
}
