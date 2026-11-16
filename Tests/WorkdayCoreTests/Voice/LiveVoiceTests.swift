import Foundation
import XCTest
@testable import WorkdayCore

final class LiveVoiceTests: XCTestCase {
  func testRollingWindowsRefreshWithoutSentenceEventsAndBoundMemory() {
    var buffer = LiveVoiceBuffer()
    var windows: [LiveVoiceWindow] = []
    for second in 0..<20 {
      windows += buffer.append(Array(repeating: 0.05, count: 16_000), speech: true, startFrame: second * 16_000)
    }
    XCTAssertEqual(windows.first?.range, 0..<80_000)
    XCTAssertEqual(windows.last?.range, 240_000..<320_000)
    XCTAssertEqual(windows.count, 16)
    XCTAssertEqual(windows.last?.quality.voicedSeconds, 5)
    XCTAssertLessThanOrEqual(buffer.retainedFrames, 80_000)
  }

  func testGapCannotJoinUnrelatedAudioAndQuietCannotBecomeIdentity() {
    var buffer = LiveVoiceBuffer()
    _ = buffer.append(Array(repeating: 0.05, count: 48_000), speech: true, startFrame: 0)
    XCTAssertTrue(buffer.append(Array(repeating: 0.05, count: 16_000), speech: true, startFrame: 160_000).isEmpty)
    let windows = buffer.append(Array(repeating: 0, count: 64_000), speech: false, startFrame: 176_000)
    XCTAssertTrue(windows.allSatisfy { !$0.quality.usableForIdentity })
  }

  func testVoicedDurationClippingAndNonfiniteAudioAreChecked() {
    var buffer = LiveVoiceBuffer()
    _ = buffer.append(Array(repeating: 0.05, count: 32_000), speech: true, startFrame: 0)
    let weak = buffer.append(Array(repeating: 0, count: 48_000), speech: false, startFrame: 32_000)
    XCTAssertEqual(weak.first?.quality.voicedSeconds, 2)
    XCTAssertEqual(weak.first?.quality.reason, .insufficientSpeech)
    buffer.reset()
    let clipped = buffer.append(Array(repeating: 1, count: 80_000), speech: true, startFrame: 0)
    XCTAssertEqual(clipped.first?.quality.reason, .clipped)
    buffer.reset()
    let invalid = buffer.append(Array(repeating: Float.nan, count: 80_000), speech: true, startFrame: 0)
    XCTAssertEqual(invalid.first?.quality.reason, .invalidAudio)
  }

  func testProfileAuditDoesNotScoreSampleAgainstItself() {
    let values = SpeakerProfileAudit.consistency([[1, 0], [0, 1]])
    XCTAssertEqual(values, [0, 0])
    XCTAssertNil(SpeakerProfileAudit.consistency([[1, 0]]).first!)
  }

  func testTrackerNeedsNewEvidenceAndDropsOwnerOnSpeakerChange() {
    var tracker = LiveIdentityTracker()
    let mine = LiveOwnerAssessment(ownerScore: 0.8, negativeScore: -1)
    let guest = LiveOwnerAssessment(ownerScore: 0.2, negativeScore: -1)
    let first = tracker.observe(range: 0..<64_000, voice: [1, 0], changeVoice: [1, 0], assessment: mine, changeAssessment: mine)
    XCTAssertEqual(first.status, .pending)
    let duplicate = tracker.observe(range: 0..<64_000, voice: [1, 0], changeVoice: [1, 0], assessment: mine, changeAssessment: mine)
    XCTAssertEqual(duplicate.status, .pending)
    let second = tracker.observe(range: 16_000..<80_000, voice: [1, 0], changeVoice: [1, 0], assessment: mine, changeAssessment: mine)
    XCTAssertEqual(second.status, .owner)
    XCTAssertEqual(tracker.creditedFrames, 80_000)
    let changed = tracker.observe(range: 32_000..<96_000, voice: [0.8, 0.6], changeVoice: [0, 1], assessment: mine, changeAssessment: guest)
    XCTAssertEqual(changed.status, .unknown)
    XCTAssertEqual(changed.reason, .speakerChanged)
    XCTAssertNotEqual(changed.track, second.track)
    tracker.reset()
    XCTAssertEqual(tracker.creditedFrames, 0)
  }

  func testExplicitNegativeBlocksOwnerAndProfileRevisionCannotReuseConfirmation() {
    var tracker = LiveIdentityTracker()
    let blocked = LiveOwnerAssessment(ownerScore: 0.8, negativeScore: 0.82)
    XCTAssertEqual(blocked.reason, .negativeMatch)
    let first = tracker.observe(range: 0..<64_000, voice: [1, 0], changeVoice: [1, 0], assessment: blocked, changeAssessment: blocked)
    XCTAssertEqual(first.status, .notOwner)
    tracker.reset()
    let noProfile = LiveOwnerAssessment(ownerScore: -1, negativeScore: -1)
    XCTAssertEqual(noProfile.reason, .noOwnerProfile)
  }
}
