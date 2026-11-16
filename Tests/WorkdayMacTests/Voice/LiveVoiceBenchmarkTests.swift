import Foundation
import QS668Core
import WorkdayCore
import XCTest
@testable import WorkdayMac

/// Optional, reproducible labelled control. Encoded clips are repeated to probe
/// long drafts; these are not natural meetings or the user's wearing accuracy.
final class LiveVoiceBenchmarkTests: XCTestCase {
  private struct Row: Codable {
    let speaker: String
    let seconds: Double
    let legacyOwner: Bool
    let updatedOwner: Bool
    let usesRollingEvidence: Bool
  }
  @MainActor func testLabelledPublicLongDraftAndNoPauseSwitchBenchmark() async throws {
    guard let fixtures = ProcessInfo.processInfo.environment["WORKDAY_PUBLIC_SPEECH"],
          let output = ProcessInfo.processInfo.environment["WORKDAY_VOICE_BENCHMARK_OUTPUT"] else {
      throw XCTSkip("Set public fixtures and external benchmark output to run this evaluation")
    }
    let base = URL(fileURLWithPath: fixtures)
    func audio(_ name: String) throws -> Data { try Data(contentsOf: base.appendingPathComponent(name + ".opusraw")) }
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent("live-benchmark-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try VoiceLibrary(root: root)
    let training = try await SpeakerEncoder().live(packets: audio("fangjun-sr-2"))
    try db.record(id: "explicit-training", source: "independent-enrollment", live: true, seconds: 5,
                  voice: try XCTUnwrap(training))
    try db.confirm("explicit-training")
    let asr = BenchmarkASR()
    let local = LivePreview(makeLocalStream: { asr })
    let app = AppModel(libraryURL: root, localCaptions: local)
    app.configureCaptions(service: nil)
    var rows: [Row] = []
    var offset = 0
    for (number, name) in ["fangjun-test-sr-1", "leijun-test-sr-2"].enumerated() {
      let original = try audio(name)
      let long = original + original + original
      let begin = offset
      for cursor in stride(from: 0, to: long.count, by: 1000) {
        let part = long.subdata(in: cursor..<min(cursor + 1000, long.count))
        app.card.onAudio?(part)
        offset += part.count
        let final = cursor + part.count == long.count
        let sessionOrigin = offset - asr.receivedBytes
        asr.onEvent?(.sentence(id: number, text: number == 0 ? "本人持续发言" : "另一人持续发言", isFinal: final,
                               startMs: Double(max(0, begin - sessionOrigin)) / 2, endMs: Double(asr.receivedBytes) / 2))
        try await Task.sleep(for: .milliseconds(100))
        await app.voices.waitForStoppedTasks()
        guard let line = local.lines.last else { continue }
        let shown = app.voices.presentationLine(line)
        rows.append(.init(speaker: number == 0 ? "enrolled_control" : "different_control",
                          seconds: Double(offset - begin) / 2000,
                          legacyOwner: app.voices.label(line.bubbleVoiceID)?.isMine == true,
                          updatedOwner: app.voices.captionSpeaker(lineID: line.id, evidenceID: shown.bubbleVoiceID).label.isMine,
                          usesRollingEvidence: shown.bubbleVoiceID?.hasPrefix("realtime:") == true))
      }
    }
    await app.shutdown()
    let url = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(rows).write(to: url, options: .atomic)
    XCTAssertTrue(rows.contains { $0.speaker == "enrolled_control" && $0.updatedOwner && $0.usesRollingEvidence })
    XCTAssertFalse(rows.contains { $0.speaker == "different_control" && $0.updatedOwner })
    XCTAssertEqual(db.sampleCount, 1, "Inference must not automatically enroll any rolling window")
  }
}

@MainActor private final class BenchmarkASR: LiveASRStreaming {
  var onEvent: ((ASREvent) -> Void)?
  var receivedBytes = 0
  func start() { receivedBytes = 0 }
  func append(_ data: Data) { receivedBytes += data.count }
  func finish() {}
  func cancel() {}
}
