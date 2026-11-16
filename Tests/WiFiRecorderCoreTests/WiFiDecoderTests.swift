import AVFoundation
import XCTest

@testable import WiFiRecorderCore

final class WiFiDecoderTests: XCTestCase {
  private func fixture() throws -> Data { try Data(contentsOf: wifiFixture("silence.bin")) }
  private func workspace(_ run: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "WifiAudioTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try run(root)
  }
  func testReferenceFixtureDecodesToCompletePlayableWav() throws {
    try workspace { root in
      let source = root.appendingPathComponent("source.bin")
      let output = root.appendingPathComponent("output.wav")
      let bytes = try fixture()
      try bytes.write(to: source)
      let result = try RecordingDecoder.decode(source: source, destination: output)
      XCTAssertEqual(result.packets, 16)
      XCTAssertEqual(result.samples, 5120)
      XCTAssertEqual(result.duration, 0.32, accuracy: 0.0001)
      let audio = try AVAudioFile(forReading: output)
      XCTAssertEqual(audio.length, 5120)
      XCTAssertEqual(audio.fileFormat.sampleRate, 16000)
      XCTAssertEqual(audio.fileFormat.channelCount, 1)
      XCTAssertEqual(try Data(contentsOf: source), bytes)
      XCTAssertEqual(try Data(contentsOf: output).count, 10284)
    }
  }
  func testInvalidRangeAndTruncationNeverCommitOutput() throws {
    var wrongRange = try fixture()
    wrongRange[7] ^= 1
    for data in [
      wrongRange, Data(try fixture().dropLast()), Data([0, 0, 0]), Data(),
      Data([255, 255, 255, 255, 0, 0, 0, 0]),
    ] {
      try workspace { root in
        let source = root.appendingPathComponent("source.bin")
        let output = root.appendingPathComponent("output.wav")
        try data.write(to: source)
        XCTAssertThrowsError(try RecordingDecoder.decode(source: source, destination: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: source), data)
        XCTAssertEqual(
          try FileManager.default.contentsOfDirectory(atPath: root.path), ["source.bin"])
      }
    }
  }
  func testExistingWavIsNeverOverwritten() throws {
    try workspace { root in
      let source = root.appendingPathComponent("source.bin")
      let output = root.appendingPathComponent("output.wav")
      try fixture().write(to: source)
      let marker = Data("existing audio".utf8)
      try marker.write(to: output)
      XCTAssertThrowsError(try RecordingDecoder.decode(source: source, destination: output))
      XCTAssertEqual(try Data(contentsOf: output), marker)
    }
  }
}
