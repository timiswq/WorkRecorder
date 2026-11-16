import Foundation
import XCTest
@testable import WorkdayCore

final class LiveSpeakerStreamTests: XCTestCase {
  @MainActor func testContinuousPublicAudioProducesEvidenceBeforeAnyASRResult() async throws {
    guard let path = ProcessInfo.processInfo.environment["WORKDAY_PUBLIC_SPEECH"] else {
      throw XCTSkip("Requires public voice fixtures")
    }
    let raw = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("fangjun-test-sr-1.opusraw"))
    var evidence: [LiveVoiceEvidence] = []
    let stream = LiveSpeakerStream { evidence.append($0) }
    for offset in stride(from: 0, to: raw.count, by: 2000) {
      stream.append(raw.subdata(in: offset..<min(offset + 2000, raw.count)), offset: offset)
      try await Task.sleep(for: .milliseconds(80))
    }
    await stream.finish()
    let last = try XCTUnwrap(evidence.last)
    XCTAssertNotNil(last.voice)
    XCTAssertEqual(last.voice?.count, 192)
    XCTAssertGreaterThanOrEqual(last.quality.voicedSeconds, 3)
    XCTAssertEqual(last.pcm.count, 80_000)
    XCTAssertTrue(last.range.lowerBound >= last.packetStartFrame)
    XCTAssertTrue(last.packets.count.isMultiple(of: 40))
    XCTAssertGreaterThanOrEqual(last.range.upperBound, 64_000)
  }
}
