import QS668Core
import XCTest

@testable import WorkdayCore

final class CardStateTests: XCTestCase {
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
      Set(["0:3", "0:1", "0:10", "3:19", "3:21", "3:23", "2:0"]))
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
