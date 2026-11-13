import AVFoundation
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class DayReplayTests: XCTestCase {
  @MainActor func testContinuousOriginalsSkipGapsFinishAndReplay() async throws {
    let root = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
        ?? NSTemporaryDirectory()
    )
    .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root.appendingPathComponent("Library"))
    for (time, samples) in [("090000", 12_800), ("140000", 8_000)] {
      let source = root.appendingPathComponent("note20261110-" + time + ".wav")
      try AudioFiles.wav(pcm: Data(repeating: 0, count: samples * 2)).write(to: source)
      _ = try await model.store.importAudio(source, sourceID: "fixture")
    }
    await model.reload()
    model.selectDay("2026-11-10")
    let player = model.player
    defer { player.stop() }
    let route = model.workspace.audio
    XCTAssertEqual(route.spans.count, 2)
    model.playDay()
    XCTAssertTrue(player.playing)
    player.toggle()
    XCTAssertFalse(player.playing)
    player.seekDay(12 * 3600)
    XCTAssertEqual(player.recordingID, route.spans[1].recordingID)
    XCTAssertEqual(player.dayClock, 14 * 3600, accuracy: 0.01)
    XCTAssertFalse(player.playing)
    player.step(-1)
    player.toggle()
    for _ in 0..<120 where player.playing { try await Task.sleep(for: .milliseconds(40)) }
    XCTAssertFalse(player.playing)
    XCTAssertNil(player.error)
    XCTAssertTrue(player.dayEnded)
    XCTAssertEqual(player.spanIndex, 1)
    XCTAssertEqual(player.dayClock, route.spans[1].clockEnd, accuracy: 0.02)
    player.toggle()
    XCTAssertTrue(player.playing)
    XCTAssertFalse(player.dayEnded)
    XCTAssertEqual(player.spanIndex, 0)
    model.selectDay("2026-11-09")
    XCTAssertEqual(player.route?.day, route.day)
    XCTAssertTrue(player.playing)
    player.toggle()
    let held = player.sourcePosition
    model.showPlaybackDay()
    XCTAssertEqual(model.selectedDay, route.day)
    XCTAssertEqual(model.selectedDetail, .original(try XCTUnwrap(player.recordingID)))
    XCTAssertEqual(player.sourcePosition, held)
    XCTAssertFalse(player.playing)
  }
}
