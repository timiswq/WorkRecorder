import Foundation
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class ArchiveSpeakerTests: XCTestCase {
  private func root() -> URL {
    let base = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    return URL(fileURLWithPath: base).appendingPathComponent("archive-voice-" + UUID().uuidString)
  }

  func testLongestNonoverlappingWindowsAndAgreement() throws {
    var evidence = ArchiveSpeaker()
    evidence.add(turn: "short", start: 0, end: 2.9, overlap: false)
    evidence.add(turn: "mixed", start: 4, end: 44, overlap: true)
    for (i, seconds) in [4, 12, 6, 28].enumerated() {
      let start = Double(i * 30 + 50)
      evidence.add(turn: String(i), start: start, end: start + Double(seconds), overlap: false)
    }
    XCTAssertEqual(evidence.windows, [140..<160, 80..<92, 110..<116])
    XCTAssertEqual(evidence.turns.count, 6)
    let v = try XCTUnwrap(ArchiveSpeaker.centroid([[1, 0], [0.8, 0.6], [0, -1]]))
    XCTAssertEqual(v[0], 0.94868, accuracy: 0.001)
    XCTAssertNil(ArchiveSpeaker.centroid([[1, 0], [0, 1]]))
    XCTAssertNil(ArchiveSpeaker.centroid([[1, 0], [0.707, 0.707], [0, 1]]))
  }

  @MainActor func testOnlyExplicitNamesTeachWithMarginAndOwnerPriority() throws {
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let db = try VoiceLibrary(root: directory)
    func index(_ recording: String, voice: [Float]?) throws -> String {
      let id = "file:" + recording
      try db.record(id: id, source: recording, live: false, seconds: 4, voice: voice)
      var speaker = ArchiveSpeaker()
      speaker.add(turn: id, start: 0, end: 4, overlap: false)
      speaker.voice = voice
      try db.replaceArchiveSpeakers(["asr:说话人 1": speaker], recording: recording)
      return id
    }
    let a = try index("a", voice: [1, 0])
    let b = try index("b", voice: [0, 1])
    let close = try index("close", voice: [0.72, 0.694])
    let match = try index("match", voice: [0.8, 0.6])
    let weak = try index("weak", voice: [0.55, -0.835])
    let silent = try index("silent", voice: nil)
    try db.nameArchiveSpeaker(turn: a, name: "林老师")
    try db.nameArchiveSpeaker(turn: b, name: "陈老师")
    XCTAssertFalse(try XCTUnwrap(db.label(close)).inferredName)
    XCTAssertFalse(try XCTUnwrap(db.label(weak)).inferredName)
    XCTAssertFalse(try XCTUnwrap(db.label(silent)).inferredName)
    XCTAssertEqual(try db.label(match)?.title, "林老师")
    XCTAssertTrue(try XCTUnwrap(db.label(match)).inferredName)
    try db.nameArchiveSpeaker(turn: a, name: "")
    XCTAssertFalse(try XCTUnwrap(db.label(match)).inferredName, "An inferred match cannot enroll itself")
    try db.nameArchiveSpeaker(turn: a, name: "林老师")
    try db.nameArchiveSpeaker(turn: match, name: "")
    XCTAssertNotEqual(try VoiceLibrary(root: directory).label(match)?.title, "林老师")
    try db.nameArchiveSpeaker(turn: a, name: "小林")
    XCTAssertEqual(try db.label(a)?.savedName, "小林")
    // Revised segmentation may recompute a centroid. It cannot replace a confirmed reference.
    var revised = ArchiveSpeaker()
    revised.add(turn: a, start: 1, end: 5, overlap: false)
    revised.voice = [0, -1]
    try db.replaceArchiveSpeakers(["asr:说话人 1": revised], recording: "a")
    let unchanged = try index("another", voice: [1, 0])
    XCTAssertEqual(try db.label(unchanged)?.title, "小林")
    let different = try index("different", voice: [0, -1])
    XCTAssertFalse(try XCTUnwrap(db.label(different)).inferredName)
    try db.nameArchiveSpeaker(turn: silent, name: "片中来宾")
    XCTAssertEqual(try db.label(silent)?.title, "片中来宾")
    XCTAssertThrowsError(try db.nameArchiveSpeaker(turn: silent, name: "我"))
    try db.record(id: "owner", source: "me", live: true, seconds: 4, voice: [1, 0])
    try db.confirm("owner")
    let ownTurn = try index("my-turn", voice: [1, 0])
    XCTAssertTrue(try XCTUnwrap(db.label(ownTurn)).isMine)
    XCTAssertNil(try db.label(ownTurn)?.savedName)
  }

  @MainActor func testNamedPublicVoiceThroughArchiveIndexAndRestart() async throws {
    guard let path = ProcessInfo.processInfo.environment["WORKDAY_PUBLIC_SPEECH"] else {
      throw XCTSkip("Requires the public speaker fixtures")
    }
    let directory = root()
    defer { try? FileManager.default.removeItem(at: directory) }
    let app = AppModel(libraryURL: directory)
    let voices = app.voices
    func index(_ filename: String) async throws -> (Recording, TranscriptLine, String) {
      let wav = URL(fileURLWithPath: path).appendingPathComponent(filename + ".wav")
      let recording = try await app.store.importAudio(wav, sourceID: "usb:fixture")
      let line = TranscriptLine(id: "0:0", start: 0, end: recording.duration, text: "发言", speaker: "发言人 1")
      var document = ProcessingDocument(recording: recording, model: "fixture")
      document.transcript = [line]
      document.phase = "complete"
      try await app.store.save(document, recording: recording)
      await app.reload()
      await voices.waitForStoppedTasks()
      XCTAssertNil(voices.error)
      return (recording, line, VoiceRecognition.key(recording, line))
    }
    let (_, _, training) = try await index("fangjun-sr-2")
    voices.nameArchiveSpeaker(training, "方老师")
    let (recording, line, matching) = try await index("fangjun-test-sr-1")
    let (_, _, other) = try await index("leijun-test-sr-2")
    XCTAssertNotEqual(voices.label(other)?.title, "方老师")
    XCTAssertEqual(voices.label(matching)?.title, "方老师")
    XCTAssertEqual(VoiceRecognition(root: directory).label(matching)?.inferredName, true)
    var shorter = line
    shorter.end = 1
    voices.observeArchive(recording, lines: [shorter])
    await voices.waitForStoppedTasks()
    XCTAssertFalse(try XCTUnwrap(voices.label(matching)).inferredName, "Same line count with revised times must reindex")
    await app.shutdown()
  }
}
