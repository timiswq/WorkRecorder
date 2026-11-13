import XCTest

@testable import WorkdayCore

final class DayResultUpdatesTests: XCTestCase {
  func testOnlyChangedContentCreatesAnUpdateAndOldReceiptCannotClearNewVersion() throws {
    var updates = DayResultUpdates()
    var summary = DaySummary(day: "2026-11-13", overview: "已确认交付时间", recordingIDs: ["r1"])
    try updates.seed([summary])
    XCTAssertTrue(updates.unseenDays.isEmpty, "旧资料首次载入不制造未读")
    summary.overview = "交付调整到周一"
    try updates.record(summary)
    let first = try DayResultUpdates.signature(summary)
    XCTAssertEqual(updates.unseenDays, ["2026-11-13"])
    summary.tasks = [SummaryNote(text: "通知客户", conversationIDs: ["c1"])]
    try updates.record(summary)
    updates.markViewed(day: summary.day, signature: first)
    XCTAssertEqual(updates.unseenDays, ["2026-11-13"])
    updates.markViewed(day: summary.day, signature: try DayResultUpdates.signature(summary))
    XCTAssertTrue(updates.unseenDays.isEmpty)
    summary.updatedAt = Date().addingTimeInterval(100)
    summary.inputFingerprint = "different-input-same-result"
    try updates.record(summary)
    XCTAssertTrue(updates.unseenDays.isEmpty, "时间与输入变化不等于可见内容变化")
  }

  func testReadReceiptIsPerDayAndSurvivesLibraryReload() async throws {
    let root = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
        ?? NSTemporaryDirectory()
    )
    .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ArchiveStore(root: root)
    var updates = DayResultUpdates()
    let old = DaySummary(day: "2026-11-12", overview: "昨日结果", recordingIDs: [])
    let new = DaySummary(day: "2026-11-13", overview: "今日结果", recordingIDs: [])
    try updates.record(old)
    try updates.record(new)
    updates.markViewed(day: new.day, signature: try DayResultUpdates.signature(new))
    try await store.saveDayResultUpdates(updates)
    let loaded = try await store.dayResultUpdates()
    XCTAssertEqual(loaded.unseenDays, ["2026-11-12"])
  }
}
