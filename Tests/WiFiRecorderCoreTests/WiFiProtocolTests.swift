import XCTest

@testable import WiFiRecorderCore

final class WiFiProtocolTests: XCTestCase {
  func testStorageFractionFromCapturedStatusKeepsCapacityUnitIndependent() throws {
    var parser = BLEParser()
    let status = try XCTUnwrap(captures().flatMap { parser.feed($0) }.first { $0.key == 5 })
    let report = try XCTUnwrap(WiFiCardStatus(status.payload))
    XCTAssertEqual(try XCTUnwrap(report.freeStorageFraction), 59_627.0 / 59_628, accuracy: 0.0000001)
    XCTAssertEqual(report.battery, 60)
    XCTAssertEqual(report.recordingCode, 1)
    XCTAssertNil(WiFiCardStatus(Array(status.payload.prefix(10))))
    for (total, free) in [(0, 0), (10, 11)] {
      let bytes = Wire.beBytes(UInt64(total)) + Wire.beBytes(UInt64(free)) + [0, 65, 1]
      let invalidSpace = try XCTUnwrap(WiFiCardStatus(bytes))
      XCTAssertNil(invalidSpace.freeStorageFraction)
      XCTAssertEqual(invalidSpace.battery, 65)
      XCTAssertEqual(invalidSpace.recordingCode, 1)
    }
  }

  func testFrozenCommandsAndCRC() {
    XCTAssertEqual(Wire.crc(Array("123456789".utf8)), 0xBB3D)
    let cases: [(UInt8, String)] = [
      (5, "A00A01050051D1"), (6, "A00A010600A1D1"), (7, "A00A01070031D0"), (8, "A00A010800C1D5"),
      (9, "A00A01090051D4"),
    ]
    for (key, expected) in cases { XCTAssertEqual(Wire.hex(Wire.ble(.b3085, key)), expected) }
  }
  func captures() throws -> [Data] {
    let url = wifiFixture("notifications.hex")
    return try String(contentsOf: url).split(separator: "\n").map { line in
      let bytes = line.split(separator: " ").compactMap { UInt8($0, radix: 16) }
      return Data(bytes)
    }
  }
  func testActual42NotificationsAndCRCRejection() throws {
    let input = try captures()
    var parser = BLEParser()
    let frames = input.flatMap { parser.feed($0) }
    XCTAssertEqual(frames.count, 42)
    XCTAssertEqual(parser.rejectedCRC, 0)
    var counts: [Int] = []
    var names = Set<String>()
    for f in frames where f.key == 10 {
      if f.payload.first == 0 {
        names.insert(try RecordingEntry(f.payload).id)
      } else {
        counts.append(names.count)
        names.removeAll()
      }
    }
    XCTAssertEqual(counts, [5, 5, 5, 6])
    for var a in input {
      a[a.count - 1] ^= 1
      var p = BLEParser()
      XCTAssertTrue(p.feed(a).isEmpty)
      XCTAssertEqual(p.rejectedCRC, 1)
    }
  }
  func testFragmentedHistoricalNotifications() throws {
    let all = try captures().reduce(Data(), +)
    for chunk in [1, 2, 7, 19, 20, 127, 256] {
      var p = BLEParser()
      var count = 0
      for offset in stride(from: 0, to: all.count, by: chunk) {
        count += p.feed(all.subdata(in: offset..<min(offset + chunk, all.count))).count
      }
      XCTAssertEqual(count, 42)
    }
  }
  func testTCPFragmentsCoalescingAndBadTail() throws {
    let list = [UInt8(0)] + Array("20261116123456".utf8) + Wire.beBytes(20000)
    let raw = Wire.wifi(10, list) + Wire.wifi(10, [2])
    var p = TCPParser()
    var frames: [Packet] = []
    for b in raw { frames += try p.feed(Data([b])) }
    XCTAssertEqual(frames.map(\.key), [10, 10])
    XCTAssertEqual(try RecordingEntry(frames[0].payload).size, 20000)
    var bad = Wire.wifi(10, [2])
    bad[bad.count - 1] = 0
    var q = TCPParser()
    XCTAssertThrowsError(try q.feed(bad))
  }
  func testExtendedCredentialsPreserveSpaces() throws {
    let raw = Array("Doway_0001".utf8) + Array(" a12345 ".utf8)
    XCTAssertEqual(
      try HotspotCredentials(raw + Array(repeating: 0, count: 10)).password, " a12345 ")
    XCTAssertThrowsError(try HotspotCredentials(Array(raw.prefix(17))))
  }
  func item(_ size: UInt64 = 12) throws -> RecordingEntry {
    try RecordingEntry([0] + Array("20261116123456".utf8) + Wire.beBytes(size))
  }
  func withStore(_ body: (DownloadStore, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "WifiLabTests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(DownloadStore(root: root), root)
  }
  func testEndRequiredAndExactBytesCommit() throws {
    try withStore { store, _ in
      let f = try item()
      let sink = try store.begin(device: "A", file: f, resume: true)
      XCTAssertFalse(try sink.accept([0] + Wire.beBytes(12)))
      XCTAssertFalse(try sink.accept(Array(repeating: 7, count: 12)))
      XCTAssertNil(store.completed(device: "A", file: f))
      XCTAssertTrue(try sink.accept([2]))
      XCTAssertEqual(
        try Data(contentsOf: store.completed(device: "A", file: f)!), Data(repeating: 7, count: 12))
      XCTAssertThrowsError(try store.begin(device: "A", file: f, resume: false))
    }
  }
  func testTruncatedEndAndOverflowRetainPart() throws {
    try withStore { store, _ in
      let f = try item()
      let sink = try store.begin(device: "A", file: f, resume: true)
      _ = try sink.accept([3, 4, 5])
      XCTAssertThrowsError(try sink.accept([2]))
      XCTAssertThrowsError(try sink.accept(Array(repeating: 3, count: 10)))
      sink.close()
      XCTAssertEqual(try Data(contentsOf: sink.partial).count, 3)
      XCTAssertNil(store.completed(device: "A", file: f))
    }
  }
  func testResumeAndDeviceIsolation() throws {
    try withStore { store, _ in
      let f = try item()
      let a = try store.begin(device: "A", file: f, resume: true)
      _ = try a.accept([3, 4, 5, 6, 7, 8])
      a.close()
      let b = try store.begin(device: "A", file: f, resume: true)
      XCTAssertEqual(b.offset, 6)
      _ = try b.accept([9, 10, 11, 12, 13, 14])
      _ = try b.accept([2])
      XCTAssertNotEqual(
        store.url(device: "A", file: f, partial: false),
        store.url(device: "B", file: f, partial: false))
      XCTAssertNil(store.completed(device: "B", file: f))
    }
  }
}
