import XCTest
@testable import QS668Core

final class RealtimeTests: XCTestCase {
    func testStartRequiresAudioOrDeviceConfirmation() throws {
        var state = RealtimeSession()
        XCTAssertEqual(try state.start(), [1, 0])
        XCTAssertEqual(state.phase, .starting)
        state.filename("note20261025-140000.opus")
        XCTAssertEqual(state.phase, .starting)
        XCTAssertTrue(state.append(byteCount: 80))
        XCTAssertEqual(state.phase, .recording)
        XCTAssertEqual(state.audioSeconds, 0.04, accuracy: 0.0001)
        XCTAssertThrowsError(try state.start())
    }
    func testPauseAndResumeAreAcknowledged() throws {
        var state = RealtimeSession(); _ = try state.start(); _ = state.append(byteCount: 40)
        XCTAssertEqual(try state.pause(), [1, 3, 1])
        XCTAssertEqual(state.phase, .pausing)
        XCTAssertThrowsError(try state.resume())
        state.deviceStatus(1); XCTAssertEqual(state.phase, .paused)
        XCTAssertEqual(try state.resume(), [1, 3, 0])
        XCTAssertEqual(state.phase, .resuming)
        _ = state.append(byteCount: 40)
        XCTAssertEqual(state.phase, .recording)
    }
    func testStopDrainsLateAudioAndRejectsAfterFinalization() throws {
        var state = RealtimeSession(); _ = try state.start(); _ = state.append(byteCount: 40)
        XCTAssertEqual(try state.stop(), [1, 2])
        state.deviceStatus(0)
        XCTAssertEqual(state.phase, .stopping)
        XCTAssertFalse(state.stopConfirmed)
        state.deviceStatus(2)
        XCTAssertTrue(state.stopConfirmed)
        XCTAssertTrue(state.append(byteCount: 80))
        state.beginFinalizing()
        XCTAssertFalse(state.append(byteCount: 40))
        XCTAssertEqual(state.receivedBytes, 120)
        state.finish(success: true)
        XCTAssertFalse(state.phase.isActive)
    }
    func testConnectionLossIsNotMarkedAsCompleted() throws {
        var state = RealtimeSession(); _ = try state.start(); _ = state.append(byteCount: 40)
        state.markInterrupted("连接断开"); state.beginFinalizing(); state.finish(success: true)
        XCTAssertFalse(state.stopConfirmed)
        XCTAssertEqual(state.interruption, "连接断开")
        XCTAssertEqual(state.receivedBytes, 40)
        _ = try state.start()
        XCTAssertEqual(state.receivedBytes, 0)
        XCTAssertNil(state.interruption)
    }
    func testIndependentNotificationChannelsDoNotMixFragments() {
        let audio = Wire.frame([1, 1] + Array(repeating: 0x48, count: 40), seq: 10)
        let key = Wire.frame([3, 5], seq: 11)
        var ae22 = FrameParser(); var ae23 = FrameParser()
        XCTAssertTrue(ae22.push(audio.prefix(13)).isEmpty)
        XCTAssertEqual(ae23.push(key).first?.payload, [3, 5])
        XCTAssertEqual(ae22.push(audio.dropFirst(13)).first?.body.count, 40)
    }
}
