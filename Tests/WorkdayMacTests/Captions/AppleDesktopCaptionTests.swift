import AppKit
import QS668Core
import Speech
import SwiftUI
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class AppleDesktopCaptionTests: XCTestCase {
  @MainActor func testTwoUnpublishedSentencesCanShareSoundFeedbackOnlyOnce() async throws {
    guard let fixture = ProcessInfo.processInfo.environment["WORKDAY_APPLE_SPEECH_EDGES"],
          let output = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
    else { throw XCTSkip("Requires synthetic card audio") }
    let packets = try Data(contentsOf: URL(fileURLWithPath: fixture))
    let stream = TestLiveStream()
    let live = LivePreview(makeLocalStream: { stream })
    let root = URL(fileURLWithPath: output).appendingPathComponent(UUID().uuidString)
    let model = AppModel(libraryURL: root, localCaptions: live)
    live.configure(enabled: true, service: nil)
    model.card.onAudio?(packets.prefix(1200))
    for _ in 0..<100 where live.pendingSpeech == nil { try await Task.sleep(for: .milliseconds(20)) }
    let pending = try XCTUnwrap(live.pendingSpeech)
    model.card.onAudio?(packets.subdata(in: 1200..<3600))
    let words = [ASRWord(text: "号", startMs: 0, endMs: 600),
                 ASRWord(text: "队", startMs: 1500, endMs: 1800)]
    stream.sendApple(words, final: false, range: 0..<1800)
    let ids = live.lines.map(\.id)
    XCTAssertEqual(live.lines.map { $0.bubblePhrase?.text }, ["", ""])
    XCTAssertEqual(ids.first, pending.id)
    XCTAssertEqual(live.pendingSpeech?.id, pending.id)
    XCTAssertEqual(Set(ids).count, 2)

    let corrected = [ASRWord(text: "好", startMs: 0, endMs: 600),
                     ASRWord(text: "对", startMs: 1500, endMs: 1800)]
    stream.sendApple(corrected, final: true, range: 0..<1800)
    XCTAssertNil(live.pendingSpeech)
    XCTAssertEqual(model.captionSelection.lines.map(\.id), ids)
    XCTAssertEqual(model.captionSelection.lines.map(\.text), ["好", "对"])
    XCTAssertEqual(model.captionHistory.records.map(\.id), ids)
    XCTAssertEqual(model.captionHistory.records.map(\.text), ["好", "对"])
    await model.shutdown()
  }

  @MainActor func testSpeechFeedbackAndShortCaptionStayInTranscriptWithoutOpeningBubble() async throws {
    guard let fixture = ProcessInfo.processInfo.environment["WORKDAY_APPLE_SPEECH_EDGES"],
          let output = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
    else { throw XCTSkip("Requires synthetic card audio") }
    _ = NSApplication.shared
    let packets = try Data(contentsOf: URL(fileURLWithPath: fixture))
    let stream = TestLiveStream()
    var now = Date()
    let live = LivePreview(clock: { now }, makeLocalStream: { stream })
    let model = AppModel(libraryURL: URL(fileURLWithPath: output).appendingPathComponent(UUID().uuidString),
                         localCaptions: live)
    model.preferences.captions.showInFullScreen = true
    model.desktop.start(model: model)
    defer { model.desktop.stop(); live.reset() }
    live.configure(enabled: true, service: nil)
    var sent = 0
    let start = Date()
    // Pace the real detector with 20 ms packets while transcription is held back.
    while sent < packets.count && live.pendingSpeech == nil {
      model.card.onAudio?(packets.subdata(in: sent..<sent + 40))
      sent += 40
      try await Task.sleep(for: .milliseconds(20))
    }
    let pending = try XCTUnwrap(live.pendingSpeech)
    XCTAssertLessThanOrEqual(sent / 2, 500, "首句样本已送入半秒音频，字幕页应有收音反馈")
    XCTAssertNil(model.desktop.panel)
    XCTAssertTrue(model.captionHistory.records.isEmpty)
    XCTAssertTrue(live.lines.isEmpty)
    // Log the input clock separately from replay wall time (includes window setup and scheduling).
    print("First speech feedback from fixture start: input \(sent / 2) ms, wall \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    now.addTimeInterval(2.1)
    live.tick()
    XCTAssertEqual(live.pendingSpeech?.text, "已收到声音，字幕稍后显示")
    XCTAssertTrue(model.captionHistory.records.isEmpty)
    let end = Double(sent) / 2
    stream.sendApple([ASRWord(text: "号", startMs: 0, endMs: end)], final: false, range: 0..<end)
    XCTAssertNil(model.desktop.panel)
    stream.sendApple([ASRWord(text: "好", startMs: 0, endMs: end)], final: true, range: 0..<end)
    XCTAssertNil(live.pendingSpeech)
    XCTAssertNil(model.desktop.panel)
    XCTAssertEqual(live.lines.last?.id, pending.id)
    XCTAssertEqual(model.captionHistory.records.map(\.text), ["好"])
    await model.shutdown()
  }
  @MainActor func testCardPacketsReachNativeBubblesUsingInstalledChineseModel() async throws {
    let captions = try await replay(fixtureKey: "WORKDAY_APPLE_SPEECH", name: "apple-fixture")
    let text = captions.joined()
    for keyword in ["首页", "日期", "本地"] { XCTAssertTrue(text.contains(keyword), text) }
  }

  @MainActor func testRepeatedShortPhraseKeepsFirstAndLastWordsInTranscriptAndEligibleBubbles() async throws {
    let captions = try await replay(fixtureKey: "WORKDAY_APPLE_SPEECH_EDGES", name: "apple-edges")
    XCTAssertEqual(captions.map { $0.filter { !$0.isWhitespace && !$0.isPunctuation } },
                   ["开始继续继续下一个好了", "先把今天的日期记下来", "最后再确认一遍全部完成"])
  }

  @MainActor func testLastSentenceBecomesReplayableWhileCardKeepsSendingSilence() async throws {
    guard #available(macOS 26, *),
          let fixture = ProcessInfo.processInfo.environment["WORKDAY_APPLE_SPEECH"],
          let output = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
    else { throw XCTSkip("Requires the installed Chinese model and the card audio fixture") }
    let packets = try Data(contentsOf: URL(fileURLWithPath: fixture))
    // The last packet is digital silence. Keep the first utterance, ending at
    // the first sustained run of identical silent packets after its spoken text.
    let silence = Data(packets.suffix(40))
    let quietBlock = (0..<5).reduce(into: Data()) { data, _ in data.append(silence) }
    let gap = try XCTUnwrap(packets.range(of: quietBlock, in: 2000..<packets.count))
    let audio = packets.prefix(gap.lowerBound)
    let root = URL(fileURLWithPath: output).appendingPathComponent(UUID().uuidString)
    let model = AppModel(libraryURL: root)
    model.localCaptions.configure(enabled: true, service: nil)
    model.card.onStreamReset?(.started)
    for offset in stride(from: 0, to: audio.count, by: 200) {
      let chunk = Data(audio[offset..<min(offset + 200, audio.count)])
      model.card.onAudio?(chunk)
      try await Task.sleep(for: .milliseconds(chunk.count / 2))
    }
    let start = ContinuousClock.now
    var sent = audio.count
    // No disconnect, pause command, second utterance, or gap in packet delivery.
    for _ in 0..<80 {
      model.card.onAudio?(quietBlock)
      sent += quietBlock.count
      try await Task.sleep(for: .milliseconds(100))
      if model.captionHistory.records.last?.replay != nil { break }
    }
    let elapsed = start.duration(to: .now)
    let line = try XCTUnwrap(model.captionHistory.records.last)
    XCTAssertTrue(line.isFinal)
    XCTAssertNotNil(line.replay)
    XCTAssertTrue(line.text.contains("首页"), line.text)
    let wav = try await model.captionHistory.replayAudio(for: line)
    XCTAssertGreaterThan(wav.count, 44)
    XCTAssertEqual(model.localCaptions.receivedBytes, sent)
    print("Card fixture, continuous silence to playable local final: \(elapsed)")
    await model.shutdown()
  }

  @MainActor private func replay(fixtureKey: String, name: String) async throws -> [String] {
    guard #available(macOS 26, *),
      let fixture = ProcessInfo.processInfo.environment[fixtureKey],
      let output = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
    else { throw XCTSkip("Requires an installed Apple Chinese model and the synthetic card fixture") }
    let data = try Data(contentsOf: URL(fileURLWithPath: fixture))
    _ = NSApplication.shared
    let model = AppModel(libraryURL: URL(fileURLWithPath: output).appendingPathComponent(name))
    model.preferences.cloudEnabled = false
    model.preferences.realtime = false
    model.preferences.captions.enabled = true
    model.preferences.captions.showInFullScreen = true
    model.desktop.start(model: model)
    defer { model.desktop.stop(); model.localCaptions.reset() }
    var showedBeforeEnd = false
    model.card.onStreamReset?(.started)
    for offset in stride(from: 0, to: data.count, by: 800) {
      model.card.onAudio?(data.subdata(in: offset..<min(offset + 800, data.count)))
      try await Task.sleep(for: .milliseconds(150))
      if model.desktop.panel?.isVisible == true && !model.localCaptions.lines.isEmpty {
        showedBeforeEnd = true
      }
    }
    model.card.onStreamReset?(.disconnected)
    for _ in 0..<600 {
      if model.localCaptions.phase == .waiting || model.localCaptions.canRetry { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(model.localCaptions.phase, .waiting, model.localCaptions.status)
    let lines = model.localCaptions.lines
    XCTAssertGreaterThanOrEqual(lines.count, 3, "The fixture contains three phrases with two-second pauses")
    XCTAssertTrue(showedBeforeEnd, "The first live bubble must appear while more audio is still arriving")
    XCTAssertTrue(lines.allSatisfy(\.isFinal))
    for line in lines {
      let record = try XCTUnwrap(model.captionHistory.records.first { $0.id == line.id })
      let clip = try XCTUnwrap(line.replay, line.text)
      let start = try XCTUnwrap(line.recordingRange).lowerBound
      // The replay's preroll starts on a packet in the entire recording, even
      // when silence has closed an earlier recognizer session.
      let firstByte = (start - clip.frames.start / 8 + 20) / 40 * 40
      XCTAssertEqual(clip.packets, data.subdata(in: firstByte..<firstByte + clip.packets.count))
      do {
        let wav = try await model.captionHistory.replayAudio(for: record)
        XCTAssertEqual(wav.count, 44 + (clip.frames.end - clip.frames.start) * 2)
      } catch {
        XCTFail("本机字幕的缓存音频解码失败：\(error)")
      }
    }
    XCTAssertTrue(model.live.lines.isEmpty)
    await model.voices.waitForStoppedTasks()
    model.desktop.refresh()
    let panel = try XCTUnwrap(model.desktop.panel)
    let host = panel.feedView
    XCTAssertTrue(panel.isVisible)
    let visibleLines = lines.filter { model.voices.hasLiveVoice($0.voiceID) }.suffix(4)
    XCTAssertFalse(visibleLines.isEmpty)
    XCTAssertEqual(host.rootView.presentation.content.items.map(\.id), visibleLines.map(\.id))
    let bubbleText = host.rootView.presentation.content.items.map(\.text)
    XCTAssertEqual(bubbleText, try visibleLines.map { line in
      try XCTUnwrap(model.captionHistory.records.first { $0.id == line.id }).text
    })
    let transcript = lines.map(\.text)
    await model.shutdown()
    try lines.map(\.text).joined(separator: "\n").write(to: URL(fileURLWithPath: output)
      .appendingPathComponent(name + "-captions.txt"), atomically: true, encoding: .utf8)
    return transcript
  }
}
