import Foundation
import XCTest
@testable import QS668Core

final class WebDemoTests: XCTestCase {
    func testWebKeyRepliesBeforeDeliveryOnBothProfiles() {
        let expected = ["5a00c1c10300030201", "5a01676b0300030401", "5a02050d0300030601", "5a030a2e0300030801"]
        for profile in RecorderProfile.supported {
            var input = RecorderNotifications()
            var writes: [String] = []
            var handled = 0
            func reply(_ bytes: [UInt8]) {
                writes.append(Wire.frame(bytes, seq: UInt8(writes.count)).map { String(format: "%02x", $0) }.joined())
            }
            for (index, key) in RecorderKey.allCases.enumerated() {
                let request = Wire.frame([3, key.rawValue], seq: UInt8(128 + index))
                let source = index.isMultiple(of: 2) ? profile.keys : profile.data
                input.receive(request.prefix(5), from: source, profile: profile, acknowledge: reply,
                              deliver: { _ in XCTFail() }, corrupted: { XCTFail() })
                let other = source == profile.data ? profile.keys : profile.data
                input.receive(Wire.frame([3, 20, 1], seq: 44), from: other, profile: profile,
                              acknowledge: { _ in XCTFail() }, deliver: { XCTAssertEqual($0.body, [1]) }, corrupted: { XCTFail() })
                input.receive(request.dropFirst(5), from: source, profile: profile, acknowledge: reply,
                              deliver: { _ in XCTAssertEqual(writes.count, index + 1); handled += 1 }, corrupted: { XCTFail() })
            }
            XCTAssertEqual(handled, 4)
            XCTAssertEqual(writes, expected)
            for payload: [UInt8] in [[3, 1, 99], [3, 2, 1], [3, 4, 1], [3], [1, 1, 1]] {
                input.receive(Wire.frame(payload, seq: 0), from: profile.keys, profile: profile,
                              acknowledge: { _ in XCTFail("Unexpected acknowledgment") }, deliver: { _ in }, corrupted: { XCTFail() })
            }
        }
    }

    func testWebInspectionFramingAndFileCommands() throws {
        XCTAssertEqual(RecorderProfile.select(services: ["AD40", "AE20"])?.service, "AE20")
        XCTAssertEqual(RecorderProfile.select(services: ["AD40"])?.write, "AD41")
        XCTAssertEqual(RecorderQuery.allCases.map(\.payload), [[0,3], [0,1], [0,10], [0,12], [3,19], [3,21], [3,23], [3,25], [2,0]])
        var parser = FrameParser()
        var zero = Array(Wire.frame([3,1], seq: 12))
        zero[2] = 0; zero[3] = 0
        var invalid = zero; invalid[2] = 1
        XCTAssertEqual(parser.push(Data(invalid + zero)).map(\.payload), [[3,1]])
        XCTAssertEqual(parser.corruptionCount, 1)
        let offset: UInt32 = 0x01020304
        let file = try RecorderCommand.download("a.opus", offset: offset).payload()
        XCTAssertEqual(Array(file.prefix(6)), [2,2,4,3,2,1])
        XCTAssertEqual(Wire.frame(file, seq: 3).count, 36)
        XCTAssertEqual(try RecorderCommand.segment("a", start: 1, end: offset).payload(), [2,12,1,0,0,0,4,3,2,1,97])
        let entry = Data(0..<28)
        XCTAssertEqual(try RecorderCommand.deleteEntry(entry).payload(), [2,8] + Array(entry))
        XCTAssertThrowsError(try RecorderCommand.deleteEntry(entry.dropLast()).payload())
    }

    func testBackpressureKeepsFramesWholeAndDisconnectDiscardsScheduledInspection() throws {
        var available = false
        var tx: [Data] = []
        var scheduled: [() -> Void] = []
        let writer = RecorderWriter(maximumLength: 36, needsResponse: false, canWrite: { available },
                                    submit: { tx.append($0) }, schedule: { delay, work in
            XCTAssertEqual(delay, 0.260); scheduled.append(work)
        })
        writer.inspect()
        try writer.send([3,2,1], acknowledgment: true)
        let file = try Wire.importPayload("note20260710-162938.wav")
        try writer.send(file)
        XCTAssertTrue(tx.isEmpty)
        XCTAssertTrue(scheduled.isEmpty)
        available = true
        writer.flush()
        XCTAssertEqual(tx.map { Array($0.dropFirst(6)) }, [[0,3],[3,2,1],file])
        XCTAssertEqual(tx.last?.count, 36)
        XCTAssertEqual(scheduled.count, 1)
        scheduled.removeFirst()()
        XCTAssertEqual(Array(tx.last!.dropFirst(6)), [0,1])
        writer.close()
        scheduled.removeFirst()()
        XCTAssertEqual(tx.count, 4)
        XCTAssertThrowsError(try writer.send([3,19]))
    }

    func testAcknowledgedGATTWritesWaitForCompletionAndCancelBeforeNextInspection() throws {
        var tx: [Data] = []
        var scheduled: [() -> Void] = []
        let writer = RecorderWriter(maximumLength: 20, needsResponse: true, canWrite: { true },
                                    submit: { tx.append($0) }, schedule: { _, work in scheduled.append(work) })
        writer.inspect()
        try writer.send([3,4,1], acknowledgment: true)
        XCTAssertEqual(tx.count, 1)
        XCTAssertTrue(scheduled.isEmpty)
        writer.wrote(error: nil)
        XCTAssertEqual(tx.count, 2)
        XCTAssertEqual(scheduled.count, 1)
        writer.cancelInspection()
        scheduled.removeFirst()()
        writer.wrote(error: nil)
        XCTAssertEqual(tx.count, 2)
        XCTAssertThrowsError(try writer.send(Wire.importPayload("a.wav")))
        XCTAssertEqual(tx.count, 2)
    }
}
