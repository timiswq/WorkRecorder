import XCTest
@testable import WorkdayCore

final class CardSpeechActivityTests: XCTestCase {
  func testSilenceAndShortPercussiveSoundsDoNotStartSpeech() throws {
    let detector = try XCTUnwrap(CardSpeechActivity.Detector())
    var samples = [Float](repeating: 0, count: 48_000)
    // Quiet lead-in, a single thump, then a train of short synthetic key clicks.
    for i in 0..<600 {
      samples[8000 + i] = Float(sin(Double(i) * 0.06) * exp(-Double(i) / 100))
    }
    for offset in stride(from: 16_000, to: 36_000, by: 2200) {
      for i in 0..<64 {
        samples[offset + i] = Float(sin(Double(i) * 2.1) * exp(-Double(i) / 9))
      }
    }
    let events = samples.withUnsafeBufferPointer { detector.detect($0.baseAddress!, count: $0.count) }
    XCTAssertTrue(events.isEmpty)
  }
}
