import XCTest

@testable import WorkdayCore

final class AudioLevelTests: XCTestCase {
  func testRealAmplitudeControlsFourSegmentsAndSilenceReleasesToZero() {
    var level = AudioLevelEnvelope()
    func feed(_ amplitude: Float, frames: Int = 1600) -> [Int] {
      let samples = [Float](repeating: amplitude, count: frames)
      return samples.withUnsafeBufferPointer { level.append($0) }
    }
    XCTAssertEqual(feed(0), [0])
    XCTAssertEqual(feed(0.005), [1])
    XCTAssertEqual(feed(0.02), [2])
    XCTAssertEqual(feed(0.08), [3])
    XCTAssertEqual(feed(0.4), [4])
    XCTAssertEqual(feed(0), [3], "回落稍慢，不能瞬间抖回零")
    XCTAssertEqual(feed(0, frames: 4800), [2, 1, 0])
  }

  func testChunkBoundariesDoNotChangeMeasuredLevelAndPublishAtTenHertz() {
    var whole = AudioLevelEnvelope()
    var split = AudioLevelEnvelope()
    let samples = [Float](repeating: 0.08, count: 16_000)
    let expected = samples.withUnsafeBufferPointer { whole.append($0) }
    var actual: [Int] = []
    for start in stride(from: 0, to: samples.count, by: 333) {
      actual += Array(samples[start..<min(start + 333, samples.count)])
        .withUnsafeBufferPointer { split.append($0) }
    }
    XCTAssertEqual(expected, [Int](repeating: 3, count: 10))
    XCTAssertEqual(actual, expected)
  }
}
