import XCTest
@testable import QS668Core

final class ProtocolTests: XCTestCase {
    func testClockPayloadUsesLittleEndianYearAndBeijingLeapDay() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2028-02-28T16:05:06Z"))
        let payload = try Wire.timeSyncPayload(date)
        XCTAssertEqual(payload, [0, 0, 0xec, 0x07, 2, 29, 0, 5, 6])
        let frame = Wire.frame(payload, seq: 19)
        XCTAssertEqual(frame.count, 15)
        var parser = FrameParser()
        XCTAssertEqual(parser.push(frame).first?.payload, payload)
        XCTAssertEqual(parser.corruptionCount, 0)
    }
    func testClockPayloadUsesBeijingYearBoundary() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-31T16:00:01Z"))
        XCTAssertEqual(try Wire.timeSyncPayload(date), [0, 0, 0xeb, 0x07, 1, 1, 0, 0, 1])
    }
    func testDocumentedCRCAndImportFrame() throws {
        XCTAssertEqual(Wire.crc(Array("123456789".utf8)), 0x31c3)
        let frame = Wire.frame(try Wire.importPayload("note20260710-162938.wav"), seq: 3)
        XCTAssertEqual(frame.count, 36)
        XCTAssertEqual(frame.map { String(format: "%02x", $0) }.joined(), "5a039e201e000202000000006e6f746532303236303731302d3136323933382e77617600")
    }
    func testFragmentationCoalescingAndCorruption() {
        let a = Wire.frame([0, 4, 85], seq: 2)
        let b = Wire.frame([2, 18, 0], seq: 3)
        var parser = FrameParser()
        XCTAssertTrue(parser.push(a.prefix(4)).isEmpty)
        let parsed = parser.push(a.dropFirst(4) + b)
        XCTAssertEqual(parsed.map(\.payload), [[0, 4, 85], [2, 18, 0]])
        var damaged = Array(a); damaged[2] ^= 1
        let next = parser.push(Data(damaged) + b)
        XCTAssertEqual(next.map(\.payload), [[2, 18, 0]])
        XCTAssertGreaterThan(parser.corruptionCount, 0)
    }
    func testStrictListParsingAndDate() throws {
        let name = Array("note20261025-123456.".utf8)
        let body: [UInt8] = [0, 0, 0, 1, 0, 0, 0, 3, 0, 0, 23, 112] + name + Array(repeating: 0, count: 20 - name.count)
        let entries = try DeviceRecording.parse(body)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].size, 6000)
        XCTAssertEqual(entries[0].duration, 3)
        XCTAssertEqual(entries[0].candidates, ["note20261025-123456.wav", "note20261025-123456.opus", "note20261025-123456."])
        XCTAssertEqual(ISO8601DateFormatter().string(from: try XCTUnwrap(entries[0].recordingDate)), "2026-10-25T04:34:56Z")
        XCTAssertThrowsError(try DeviceRecording.parse(Array(body.dropLast())))
        XCTAssertNil(DeviceRecording(duration: 9, size: 100, name: "unknown.opus").recordingDate)
        XCTAssertNil(DeviceRecording(duration: 9, size: 100, name: "note20261345-123456.").recordingDate)
    }
    func testUnsafeAndOverlongNamesRejected() {
        XCTAssertThrowsError(try Wire.importPayload("../unsafe.wav"))
        XCTAssertThrowsError(try Wire.importPayload(String(repeating: "x", count: 25)))
    }
    func testTruncatedAudioRejected() {
        XCTAssertThrowsError(try AudioEnvelope.validateWAV(Data("RIFF".utf8)))
        XCTAssertThrowsError(try AudioEnvelope.wrapOpus(Data(repeating: 0x48, count: 41)))
        XCTAssertThrowsError(try AudioEnvelope.wrapOpus(Data(repeating: 0, count: 40)))
    }
    func testOggAgainstProvidedPythonOracle() throws {
        let packet: [UInt8] = [0x48] + Array(1...39)
        let raw = Data(Array(repeating: packet, count: 75).flatMap { $0 })
        let ogg = try AudioEnvelope.wrapOpus(raw)
        let output = ProcessInfo.processInfo.environment["QS668_ORACLE"]
        if let output { XCTAssertEqual(ogg, try Data(contentsOf: URL(fileURLWithPath: output))) }
        XCTAssertTrue(ogg.starts(with: Data("OggS".utf8)))
        XCTAssertEqual(ogg[5], 2)
    }
}
