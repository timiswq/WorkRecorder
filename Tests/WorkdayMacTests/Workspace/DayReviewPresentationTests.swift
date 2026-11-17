import WorkdayCore
import XCTest

@testable import WorkdayMac

final class DayReviewPresentationTests: XCTestCase {
  func testCompletedSilentRecordingsDoNotOfferAnIneffectiveGenerateAction() {
    let state = DayOverviewState.resolve(hasOverview: false, isCurrent: true)
    XCTAssertNil(state.actionTitle)
    XCTAssertEqual(state.message, "当天没有足够内容生成概述")
  }

  func testStaleOverviewDoesNotClaimToBeQueued() {
    let state = DayOverviewState.resolve(hasOverview: true, isCurrent: false)
    XCTAssertEqual(state, .outdated)
    XCTAssertEqual(state.message, "概述尚未包含最新内容")
    XCTAssertEqual(state.actionTitle, "更新概述")
  }

  func testPendingRecordingsAndActualQueueHaveDifferentRecoveryActions() {
    let pending = DayOverviewState.resolve(hasOverview: true, isCurrent: true, pending: 3)
    XCTAssertEqual(pending, .pending(3))
    XCTAssertEqual(pending.actionTitle, "开始处理")
    let queued = DayOverviewState.resolve(hasOverview: true, isCurrent: false, queued: true)
    XCTAssertEqual(queued, .queued)
    XCTAssertNil(queued.actionTitle)
    XCTAssertEqual(DayOverviewState.resolve(hasOverview: true, isCurrent: true), .ready)
    XCTAssertNil(DayOverviewState.ready.message)
  }

  func testMissingConfigurationDoesNotOfferAProcessingAction() {
    let state = DayOverviewState.resolve(hasOverview: false, isCurrent: false, pending: 1).withAvailability(false)
    XCTAssertEqual(state, .unconfigured)
    XCTAssertEqual(state.actionTitle, "设置语音识别")
  }

  func testActiveGenerationTakesPrecedenceOverPreviousFailure() {
    XCTAssertEqual(DayOverviewState.resolve(hasOverview: true, isCurrent: false,
      generating: true, failed: true), .generating)
    XCTAssertEqual(DayOverviewState.resolve(hasOverview: true, isCurrent: false,
      failedRecordings: 2), .recordingsFailed(2))
  }

  func testOverviewRemovesOnlyMatchingLeadingDate() {
    XCTAssertEqual(DayReviewText.overview("2026-11-13 全天讨论审批规则。", day: "2026-11-13"),
      "讨论审批规则。")
    XCTAssertEqual(DayReviewText.overview("讨论了 2026-11-13 的上线安排。", day: "2026-11-13"),
      "讨论了 2026-11-13 的上线安排。")
  }
}
