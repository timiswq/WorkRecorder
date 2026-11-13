import Foundation
import QS668Core
import XCTest

@testable import WorkdayCore

final class SyncTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_794_297_600)
  func file(_ name: String, size: Int64 = 100) -> SyncFile {
    SyncFile(
      sourceID: "usb:card", path: "/record/\(name)", size: size,
      modified: now.addingTimeInterval(-20))
  }
  func testFailedCopyRemainsQueuedAcrossRestartAndTodayHasPriority() throws {
    var ledger = SyncLedger()
    let old = file("note20261109-090000.wav")
    let today = file("note20261110-090000.wav")
    ledger.discover([old, today])
    XCTAssertEqual(ledger.next(available: [old.id, today.id], at: now)?.file.id, today.id)
    ledger.fail(today.id, message: "拔线", at: now)
    let restored = try JSONDecoder().decode(SyncLedger.self, from: JSONEncoder().encode(ledger))
    XCTAssertEqual(restored.next(available: [old.id, today.id], at: now)?.file.id, old.id)
    XCTAssertEqual(
      restored.next(available: [today.id], at: now.addingTimeInterval(31))?.file.id, today.id)
  }
  func testSuccessDeduplicatesAndChangedSourceIsANewRevision() {
    var ledger = SyncLedger()
    let a = file("note20261110-090000.wav")
    ledger.discover([a])
    ledger.complete(a.id, recordingID: "archive")
    ledger.discover([a])
    XCTAssertNil(ledger.next(available: [a.id], at: now))
    let changed = file(a.name, size: 200)
    ledger.discover([changed])
    XCTAssertEqual(ledger.next(available: [changed.id], at: now)?.file.id, changed.id)
    XCTAssertEqual(ledger.entries.filter { $0.recordingID != nil }.count, 1)
  }
  func testOnlyAvailableAndSupportedFilesAreCopied() {
    var ledger = SyncLedger()
    let wav = file("note20261110-090000.wav")
    let opus = file("note20261110-100000.opus")
    ledger.discover([wav, opus])
    XCTAssertNil(ledger.next(available: [], at: now))
    XCTAssertNil(ledger.next(available: [opus.id], at: now))
    XCTAssertEqual(ledger.next(available: [wav.id], at: now)?.file.id, wav.id)
  }
  func frame(_ p: [UInt8]) -> Frame {
    var parser = FrameParser()
    return parser.push(Wire.frame(p, seq: 0))[0]
  }
  func testEmptyCompletedInventoryIsKnownButTimeoutIsNotZero() throws {
    var listing = InventoryCollector()
    listing.begin(sourceID: "ble:card", at: now)
    let complete = try listing.receive(frame([2, 18, 0]), at: now)
    XCTAssertEqual(complete?.entries.count, 0)
    XCTAssertEqual(complete?.complete, true)
    listing.begin(sourceID: "ble:card", at: now)
    let timeout = listing.expire(at: now.addingTimeInterval(13))
    XCTAssertEqual(timeout?.complete, false)
  }
  func testPartialListPairsFormatsAndDoesNotCountActiveRecording() throws {
    let entries = [
      InventoryEntry(name: "note20261110-090000.wav", duration: 60, bytes: 1_920_044),
      InventoryEntry(name: "note20261110-090000.opus", duration: 60, bytes: 120000),
      InventoryEntry(name: "note20261110-100000.", duration: 30, bytes: 60000),
    ]
    let snapshot = DeviceInventory(
      sourceID: "ble:card", entries: entries, observedAt: now, complete: false)
    let count = snapshot.count(
      recordings: [], linkedSources: [], activeName: "note20261110-100000.wav", today: "2026-11-10")
    XCTAssertEqual(count.today, 1)
    XCTAssertEqual(count.total, 1)
    XCTAssertFalse(snapshot.complete)
  }
  func testSameFilenameOnOtherCardCannotBeCountedAsSynced() {
    let entry = InventoryEntry(name: "note20261110-090000.", duration: 60, bytes: 120000)
    let snapshot = DeviceInventory(
      sourceID: "ble:card", entries: [entry], observedAt: now, complete: true)
    let recording = Recording(
      id: "a", startedAt: now, importedAt: now, originalName: "note20261110-090000.wav", folder: "",
      originalFile: "original.wav", sha256: "hash", bytes: 1_920_044, duration: 60,
      sourceID: "usb:other")
    let count = snapshot.count(
      recordings: [recording], linkedSources: [], activeName: nil, today: "2026-11-10")
    XCTAssertEqual(count.total, 1)
    XCTAssertEqual(count.unverified, 1)
  }
}
