import XCTest

@testable import WiFiRecorderCore

final class SyncBatchTests: XCTestCase {
  private func file(_ name: String, _ size: UInt64) throws -> RecordingEntry {
    try RecordingEntry([0] + Array(name.utf8) + Wire.beBytes(size))
  }
  func testOnlyMissingRecordingsAreDownloadedOnce() throws {
    let a = try file("20000106234909", 24288)
    let b = try file("20000106234841", 64416)
    let c = try file("20000106234825", 21120)
    var batch = SyncBatch(files: [a, b, c, b], existing: [a])
    XCTAssertEqual(batch.total, 2)
    XCTAssertEqual(batch.skipped, 1)
    XCTAssertEqual(try batch.next()?.name, "20000106234841")
    XCTAssertThrowsError(try batch.next())
    XCTAssertThrowsError(try batch.finish(c))
    try batch.finish(b)
    XCTAssertEqual(batch.completed, 1)
    XCTAssertEqual(try batch.next()?.name, "20000106234825")
    try batch.finish(c)
    XCTAssertNil(try batch.next())
    XCTAssertEqual(batch.completed, 2)
  }
  func testSameNameChangedSizeIsNotSkipped() throws {
    let old = try file("20000106234909", 24000)
    let fresh = try file("20000106234909", 24288)
    var batch = SyncBatch(files: [fresh], existing: [old])
    XCTAssertEqual(batch.skipped, 0)
    XCTAssertEqual(try batch.next()?.size, 24288)
  }
  func testCancelPreventsQueuedDownloads() throws {
    let a = try file("20000106234909", 24288)
    let b = try file("20000106234841", 64416)
    var batch = SyncBatch(files: [a, b], existing: [])
    _ = try batch.next()
    batch.cancel()
    XCTAssertNil(try batch.next())
    XCTAssertThrowsError(try batch.finish(a))
  }
  func testAllCompletedNeedsNoNewDownload() throws {
    let a = try file("20000106234909", 24288)
    var batch = SyncBatch(files: [a], existing: [a])
    XCTAssertEqual(batch.skipped, 1)
    XCTAssertEqual(batch.total, 0)
    XCTAssertNil(try batch.next())
  }
}
