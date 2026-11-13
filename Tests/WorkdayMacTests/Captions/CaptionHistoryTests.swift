import Foundation
import AVFoundation
import XCTest
import WorkdayCore

@testable import WorkdayMac

final class CaptionHistoryTests: XCTestCase {
  @MainActor func testReplayUsesFinalAudioOffsetsAndSurvivesRelaunchAndRecordingSwitch() async throws {
    let output = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    let root = URL(fileURLWithPath: output).appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = TestLiveStream(), second = TestLiveStream()
    var streams = [first, second]
    let feed = LivePreview(makeLocalStream: { streams.removeFirst() })
    let model = AppModel(libraryURL: root, localCaptions: feed)
    feed.configure(enabled: true, service: nil)
    let packets = (0..<30).reduce(into: Data()) { bytes, index in
      var packet = Data(repeating: UInt8(index), count: 40)
      packet[0] = 0x48
      bytes.append(packet)
    }
    model.card.onAudio?(packets.prefix(53))
    model.card.onAudio?(packets.dropFirst(53))
    first.onEvent?(.sentence(id: 0, text: "第一句", isFinal: false, startMs: 131, endMs: 276))
    XCTAssertNil(model.captionHistory.records.first?.replay)
    first.onEvent?(.sentence(id: 0, text: "第一句", isFinal: true, startMs: 131, endMs: 276))
    let original = try XCTUnwrap(model.captionHistory.records.first)
    let clip = try XCTUnwrap(feed.lines.first?.replay)
    XCTAssertEqual(clip.packets, packets.subdata(in: 80..<600))
    XCTAssertEqual(clip.frames.start, (131 - 40) * 16)
    XCTAssertEqual(clip.frames.end, (276 - 40) * 16)
    let before = try await model.captionHistory.replayAudio(for: original)
    XCTAssertEqual(before.count, 44 + 145 * 32)
    first.onEvent?(.sentence(id: 1, text: "下一句", isFinal: false))
    model.card.onStreamReset?(.started)
    model.card.onAudio?(packets.prefix(40))
    first.onEvent?(.sentence(id: 1, text: "下一句话", isFinal: true, startMs: 341, endMs: 490))
    second.onEvent?(.sentence(id: 0, text: "另一段录音", isFinal: true, startMs: 30, endMs: 60))
    XCTAssertEqual(feed.lines.map(\.text), ["另一段录音"])
    XCTAssertNil(model.captionHistory.records.last?.replay)
    // Same text/duration with shifted boundaries must replace the stored audio.
    first.onEvent?(.sentence(id: 0, text: "第一句", isFinal: true, startMs: 151, endMs: 296))
    await model.shutdown()
    let restored = AppModel(libraryURL: root)
    let record = try XCTUnwrap(restored.captionHistory.records.first)
    let revised = try await restored.captionHistory.replayAudio(for: record)
    XCTAssertEqual(revised.count, before.count)
    XCTAssertNotEqual(revised, before)
    do {
      _ = try await restored.captionHistory.replayAudio(for: original)
      XCTFail("Revised timestamps must invalidate the previous audio reference")
    } catch {}
    let next = try XCTUnwrap(restored.captionHistory.records.first { $0.text == "下一句话" })
    let audio = try await restored.captionHistory.replayAudio(for: next)
    XCTAssertEqual(try AVAudioPlayer(data: audio).duration, 0.149, accuracy: 0.0001)
    restored.selectCaption(next)
    XCTAssertEqual(restored.selectedCaption, CaptionSelection(id: next.id, time: next.time))
    XCTAssertEqual(restored.captionPosition, .latest)
    XCTAssertNil(restored.player.selectionID)
    restored.replayCaption(next)
    XCTAssertEqual(restored.player.captionID, next.id)
    restored.selectCaption(record)
    XCTAssertEqual(restored.captionPosition, .scrolling)
    XCTAssertEqual(restored.player.captionID, next.id, "浏览另一句应让原句继续播放")
    let minute = CaptionWindow.minute(record.time)
    restored.selectCaptionRange(minute...minute, in: CaptionWindow(now: Date()))
    XCTAssertEqual(restored.player.captionID, next.id)
    restored.replayCaption(record)
    XCTAssertEqual(restored.player.captionID, record.id)
    let expired = CaptionHistory(root: root, clock: { Date().addingTimeInterval(86401) })
    XCTAssertTrue(expired.records.isEmpty)
    do {
      _ = try await restored.captionHistory.replayAudio(for: record)
      XCTFail("Expired audio must also be removed from disk")
    } catch {}
    await restored.shutdown()
  }

  @MainActor func testSelectingADraftKeepsTheFullListAndReceivesItsFinalInPlace() async throws {
    let output = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    let root = URL(fileURLWithPath: output).appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root)
    let now = Date()
    let window = CaptionWindow(now: now)
    func accept(_ id: String, _ secondsAgo: Double, _ text: String, final: Bool = true) {
      let line = LiveLine(id: id, segment: 0, sentence: 0, text: text, isFinal: final,
                          receivedAt: now.addingTimeInterval(-secondsAgo))
      model.captionHistory.accept(line, evidenceID: nil)
    }
    func displayed() -> [CaptionRecord] {
      Array(window.visible(in: model.captionHistory.readingRecords).reversed())
    }
    accept("old", 1250, "早先的发言")
    accept("prior", 90, "继续")
    accept("ok", 5, "OK", final: false)
    let original = displayed()
    model.selectCaption(try XCTUnwrap(original.first))
    XCTAssertNil(model.captionPosition.selectedRange)
    XCTAssertEqual(displayed(), original)
    XCTAssertEqual(model.captionPosition, .latest)
    accept("after-click", 5, "普通点击后仍显示新句")
    XCTAssertEqual(displayed().first?.id, "after-click")
    model.captionPosition = .scrolling
    accept("late-final", 80, "上一段录音迟到的定稿")
    accept("next", 5, "同一时刻稍后到达的字幕")
    accept("newest", 1, "新发言")
    accept("ok", 5, "OK。")
    XCTAssertEqual(displayed().map(\.id), ["after-click", "ok", "prior", "old"])
    XCTAssertEqual(model.captionHistory.unreadCount(in: window), 3)
    XCTAssertEqual(displayed().first(where: { $0.id == "ok" })?.text, "OK。")
    XCTAssertEqual(displayed().first(where: { $0.id == "ok" })?.isFinal, true)

    let range = CaptionWindow.minute(now.addingTimeInterval(-180))...CaptionWindow.minute(now)
    model.selectCaptionRange(range, in: window)
    XCTAssertEqual(window.visible(in: model.captionHistory.readingRecords, during: range).map(\.id),
                   ["prior", "ok", "after-click"])
    XCTAssertEqual(model.captionHistory.unreadCount(in: window), 3)
    model.selectCaption(original[1])
    XCTAssertEqual(model.captionPosition, .range(range))
    XCTAssertEqual(model.selectedCaption?.id, "prior")
    model.selectCaptionRange(window.minutes, in: window)
    XCTAssertEqual(model.captionPosition, .scrolling)
    XCTAssertEqual(model.selectedCaption?.id, "prior")
    model.captionPosition = .latest
    XCTAssertEqual(model.captionPosition, .latest)
    XCTAssertNil(model.selectedCaption)
    XCTAssertEqual(displayed().map(\.id), ["newest", "next", "after-click", "ok", "late-final", "prior", "old"])
    await model.shutdown()
  }

  @MainActor func testClipPlayerStopsAtSentenceEnd() async throws {
    let player = Player()
    defer { player.stop() }
    let wav = AudioFiles.wav(pcm: Data(repeating: 0, count: 3200))
    let record = CaptionRecord(id: "silent-test", time: Date(), text: "回听", isFinal: true)
    player.playCaption(record, title: "回听") { wav }
    for _ in 0..<200 where (player.position < 0.1 || player.playing) && player.error == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNil(player.error)
    XCTAssertEqual(player.position, 0.1, accuracy: 0.0001)
    XCTAssertEqual(player.duration, 0.1, accuracy: 0.0001)
    XCTAssertFalse(player.playing)
  }

  @MainActor func testRollingWindowPersistsFullUtterancesAcrossRecordingsAndRelaunch() async throws {
    let output = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    let root = URL(fileURLWithPath: output).appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stream = TestLiveStream()
    var time = Date().addingTimeInterval(-900)
    let feed = LivePreview(clock: { time }, makeLocalStream: { stream })
    let model = AppModel(libraryURL: root, localCaptions: feed)
    feed.configure(enabled: true, service: nil)
    feed.append(Data(repeating: 0, count: 40))
    stream.onEvent?(.sentence(id: 0, text: "周四", isFinal: false))
    let first = try XCTUnwrap(model.menuRecentSpeech?.line)
    time.addTimeInterval(3)
    stream.onEvent?(.sentence(id: 0, text: "周五下午见。", isFinal: true))
    for n in 1...103 {
      time.addTimeInterval(1)
      stream.onEvent?(.sentence(id: n, text: "第\(n)句", isFinal: true))
    }
    XCTAssertEqual(feed.lines.count, LiveLine.maximumRetained)
    XCTAssertEqual(model.captionHistory.records.count, 104)
    XCTAssertEqual(model.captionHistory.records.first?.time, first.time)
    XCTAssertEqual(model.captionHistory.records.first?.text, "周五下午见。")
    XCTAssertTrue(model.confirmCaption(first.id))
    feed.boundary(.started)
    feed.append(Data(repeating: 0, count: 40))
    stream.onEvent?(.sentence(id: 0, text: "新的录音", isFinal: true))
    stream.onEvent?(.sentence(id: 1, text: "待撤回", isFinal: false))
    stream.onEvent?(.sentence(id: 1, text: "。", isFinal: true))
    await model.shutdown()
    let restored = AppModel(libraryURL: root)
    XCTAssertNil(restored.captionHistory.issue)
    XCTAssertEqual(restored.captionHistory.records, model.captionHistory.records)
    XCTAssertEqual(restored.captionHistory.records.count, 105)
    XCTAssertTrue(restored.captionSpeaker(for: try XCTUnwrap(restored.captionHistory.records.first)).label.isMine)
    XCTAssertEqual(restored.menuRecentSpeech?.line.text, "新的录音")
  }

  func testRulerRunsFromYesterdayToNowAndMapsMarksBackToTime() {
    let window = CaptionWindow(now: Date(timeIntervalSince1970: 1_800_000_025))
    XCTAssertEqual(window.time(atRulerFraction: 0), window.start)
    XCTAssertEqual(window.time(atRulerFraction: 1), window.now)
    XCTAssertEqual(window.time(atRulerFraction: 0.25), window.start.addingTimeInterval(6 * 3600))
    for hoursAgo in [0, 1, 6, 12, 23, 24] {
      let time = window.now.addingTimeInterval(-Double(hoursAgo) * 3600)
      XCTAssertEqual(window.time(atRulerFraction: window.rulerFraction(for: time)), time)
    }
  }

  func testRangeSpansMidnightIncludesBothMinutesAndClipsToLiveWindow() throws {
    let parse = ISO8601DateFormatter()
    let window = CaptionWindow(now: try XCTUnwrap(parse.date(from: "2026-11-13T09:00:10+08:00")))
    let midnight = WorkdayTimeline.calendar.startOfDay(for: window.now)
    let before = midnight.addingTimeInterval(-60)
    let times = [window.start.addingTimeInterval(-1), window.start, before.addingTimeInterval(-1),
                 before, midnight, midnight.addingTimeInterval(59.9), midnight.addingTimeInterval(60),
                 window.now, window.now.addingTimeInterval(1)]
    let records = times.enumerated().map { i, date in
      CaptionRecord(id: String(i), time: date, text: "字幕", isFinal: true)
    }
    let range = before...midnight
    XCTAssertEqual(window.visible(in: records, during: range).map(\.id), ["3","4","5"])
    XCTAssertEqual(window.visible(in: records, during: before...before).map(\.id), ["3"])
    XCTAssertEqual(window.visible(in: records, during: window.minutes).map(\.id), ["1","2","3","4","5","6","7"])
    let all = window.visible(in: records)
    XCTAssertEqual(all.neighbors(of: range).previous?.id, "2")
    XCTAssertEqual(all.neighbors(of: range).next?.id, "6")
    XCTAssertNil(all.neighbors(of: window.minutes).previous)
    XCTAssertNil(all.neighbors(of: window.minutes).next)
    XCTAssertNil(all.prefix(0).neighbors(of: range).next)
    XCTAssertNil(all.prefix(0).neighbors(of: range).previous)
    let gap = midnight.addingTimeInterval(600)
    XCTAssertTrue(window.visible(in: records, during: gap...gap).isEmpty)
    XCTAssertTrue(CaptionWindow(now: window.now.addingTimeInterval(86400)).visible(in: records, during: range).isEmpty)
    XCTAssertEqual(window.moving(.start, to: window.now, in: range), midnight...midnight)
    XCTAssertEqual(window.moving(.end, to: window.start, in: range), before...before)
    XCTAssertEqual(window.moving(.end, to: midnight, in: before...before), range)
    XCTAssertEqual(window.moving(.start, to: before, in: midnight...midnight), range)
    XCTAssertEqual(window.resolve(clock: before, near: window.now), before)
    XCTAssertEqual(window.resolve(clock: midnight, near: window.start), midnight)
    XCTAssertEqual(window.resolve(clock: window.now, near: window.start), window.minutes.lowerBound)
    XCTAssertEqual(window.resolve(clock: window.start, near: window.now), window.minutes.upperBound)
  }
}
