import QS668Core
import XCTest

@testable import WorkdayCore

final class CardStateTests: XCTestCase {
  func testWiFiStorageSurvivesRecordingEventsAndClearsOnDisconnect() {
    var card = CardState()
    card.connected = true
    card.updateWiFi(raw: 1, battery: 80, storage: .init(totalMegabytes: 2000, freeMegabytes: 1500))
    card.updateWiFi(event: .started, filename: "20261117103000")
    card.updateWiFi(event: .paused, filename: nil)
    XCTAssertEqual(card.filename, "20261117103000")
    XCTAssertEqual(card.freeStorageFraction, 0.75)
    XCTAssertEqual(card.totalBytes, 2_000_000_000)
    XCTAssertEqual(card.freeBytes, 1_500_000_000)
    card.updateWiFi(event: .started, filename: nil)
    XCTAssertNil(card.filename, "新录音尚未上报文件名时不能展示上一段录音")
    card.disconnect()
    XCTAssertNil(card.freeStorageFraction)
    XCTAssertNil(card.totalBytes)
    XCTAssertNil(card.freeBytes)
  }

  func frame(_ bytes: [UInt8]) -> Frame {
    var parser = FrameParser()
    return parser.push(Wire.frame(bytes, seq: 0))[0]
  }
  func testDisconnectFreezesConfirmedDurationAndInvalidatesPower() {
    var state = CardState()
    state.connected = true
    let now = Date()
    state.apply(frame([3, 20, 1]), at: now)
    state.apply(frame([3, 22, 0x98, 0x85, 0, 0, 0, 0]), at: now)
    state.apply(frame([0, 4, 80]), at: now)
    XCTAssertEqual(state.seconds, 34200)
    XCTAssertTrue(state.isFresh(at: now))
    state.disconnect()
    XCTAssertEqual(state.seconds, 34200)
    XCTAssertFalse(state.isFresh(at: now))
    XCTAssertNil(state.battery)
  }
  func testStaleStatusIsUnknownEvenWhenTransportConnected() {
    var state = CardState()
    state.connected = true
    let now = Date()
    state.apply(frame([3, 20, 1]), at: now)
    XCTAssertTrue(state.isFresh(at: now.addingTimeInterval(3)))
    XCTAssertFalse(state.isFresh(at: now.addingTimeInterval(11)))
  }
  func testBatteryExpiresIndependentlyOfRecordingAndRequiresANewReportAfterDisconnect() {
    var state = CardState()
    state.connected = true
    let now = Date()
    state.apply(frame([0, 4, 110]), at: now)
    XCTAssertEqual(state.currentBattery(at: now), 100)
    state.apply(frame([0, 4, 82]), at: now)
    XCTAssertEqual(state.currentBattery(at: now.addingTimeInterval(119)), 82)
    XCTAssertNil(state.currentBattery(at: now.addingTimeInterval(120)))
    state.apply(frame([0, 4, 255]), at: now)
    XCTAssertNil(state.currentBattery(at: now))
    state.apply(frame([0, 4, 0]), at: now)
    XCTAssertEqual(state.currentBattery(at: now), 0)
    state.disconnect()
    state.connected = true
    XCTAssertNil(state.currentBattery(at: now))
  }

  func testOnlyActiveRecordingOrPauseWithFreshDurationCanDisplayElapsedTime() {
    var state = CardState()
    state.connected = true
    let now = Date()
    state.apply(frame([3, 20, 1]), at: now)
    state.apply(frame([3, 22, 20, 0, 0, 0, 0, 0]), at: now)
    XCTAssertEqual(state.currentDuration(at: now), 20)
    state.apply(frame([3, 20, 3]), at: now.addingTimeInterval(8))
    XCTAssertEqual(state.currentDuration(at: now.addingTimeInterval(9)), 28)
    XCTAssertNil(state.currentDuration(at: now.addingTimeInterval(10)))
    state.apply(frame([3, 22, 25, 0, 0, 0, 0, 0]), at: now.addingTimeInterval(10))
    state.apply(frame([3, 3]), at: now.addingTimeInterval(11))
    XCTAssertNil(state.currentDuration(at: now.addingTimeInterval(11)))
    state.disconnect()
    XCTAssertNil(state.currentDuration(at: now.addingTimeInterval(11)))
  }
  func testRecordingClockFreezesOnPauseAndResumesWithTheRemainingFractionOfASecond() {
    var state = CardState()
    state.connected = true
    let now = Date()
    state.apply(frame([3, 1]), at: now)
    state.apply(frame([3, 22, 29, 0, 0, 0, 0, 0]), at: now)
    state.apply(frame([3, 5]), at: now.addingTimeInterval(2.75))
    state.apply(frame([3, 20, 3]), at: now.addingTimeInterval(4))
    XCTAssertEqual(state.currentDuration(at: now.addingTimeInterval(5)), 31)
    XCTAssertEqual(state.seconds, 29)
    state.apply(frame([3, 7]), at: now.addingTimeInterval(5))
    XCTAssertEqual(state.currentDuration(at: now.addingTimeInterval(5)), 31)
    XCTAssertEqual(state.currentDuration(at: now.addingTimeInterval(5.25)), 32)
    state.apply(frame([3, 5]), at: now.addingTimeInterval(6))
    state.apply(frame([3, 22, 33, 0, 0, 0, 0, 0]), at: now.addingTimeInterval(7))
    XCTAssertEqual(state.currentDuration(at: now.addingTimeInterval(12)), 33)
    state.apply(frame([3, 20, 1]), at: now.addingTimeInterval(12))
    XCTAssertEqual(state.currentDuration(at: now.addingTimeInterval(13)), 34)
  }

  func testSubscribedIdleStaysCurrentUntilAnEventOrDisconnect() {
    let now = Date()
    var state = CardState()
    state.connected = true
    state.receivesKeyEvents = true
    state.apply(frame([3, 20, 2]), channel: "AD42", at: now)
    XCTAssertTrue(state.isFresh(at: now.addingTimeInterval(60)))
    state.apply(frame([3, 1, 9]), channel: "AD43", at: now)
    XCTAssertEqual(state.phase, .idle)
    state.apply(frame([3, 1]), channel: "AD42", at: now)
    XCTAssertEqual(state.phase, .recording)
    state.apply(frame([3, 20, 2]), channel: "AD42", at: now.addingTimeInterval(1), querySentAt: now)
    XCTAssertEqual(state.phase, .recording)
    state.disconnect()
    XCTAssertFalse(state.isFresh(at: now))
  }
  func testHardwareStopWaitsForFreshIdlePoll() {
    var state = CardState()
    state.connected = true
    let now = Date()
    state.apply(frame([3, 1]), channel: "AE23", at: now)
    state.apply(frame([3, 3]), channel: "AE23", at: now.addingTimeInterval(1))
    XCTAssertEqual(state.phase, .saving)
    state.apply(frame([3, 20, 1]), at: now.addingTimeInterval(2), querySentAt: now)
    XCTAssertEqual(state.phase, .saving)
    state.apply(
      frame([3, 20, 2]), at: now.addingTimeInterval(3), querySentAt: now.addingTimeInterval(2))
    XCTAssertEqual(state.phase, .idle)
  }
  func testNewFilenameClearsOldDuration() {
    var state = CardState()
    state.connected = true
    state.apply(frame([3, 24] + Array("note20261109-083000.wav".utf8)))
    state.apply(frame([3, 22, 10, 0, 0, 0, 0, 0]))
    state.apply(frame([3, 24] + Array("note20261109-093000.wav".utf8)))
    XCTAssertNil(state.seconds)
  }
  func testOnlyReadQueriesCanBeConstructed() {
    XCTAssertEqual(
      Set(CardQuery.allCases.map { $0.payload.map(String.init).joined(separator: ":") }),
      Set(["0:3", "0:1", "0:10", "0:12", "3:25", "3:19", "3:21", "3:23", "2:0"]))
  }
  func testOldDurationReplyAfterNewStartIsIgnored() {
    var state = CardState()
    state.connected = true
    let now = Date()
    state.apply(frame([3, 1]), channel: "AE23", at: now)
    state.apply(
      frame([3, 22, 100, 0, 0, 0, 0, 0]), at: now.addingTimeInterval(1),
      querySentAt: now.addingTimeInterval(-1))
    XCTAssertNil(state.seconds)
    state.apply(
      frame([3, 22, 1, 0, 0, 0, 0, 0]), at: now.addingTimeInterval(2),
      querySentAt: now.addingTimeInterval(1))
    XCTAssertEqual(state.seconds, 1)
  }
}
