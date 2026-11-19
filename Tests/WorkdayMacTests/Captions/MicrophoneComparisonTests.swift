import AppKit
import AVFoundation
import XCTest
@testable import WorkdayCore
@testable import WorkdayMac

@MainActor final class MicrophoneComparisonTests: XCTestCase {
  private func library() throws -> URL {
    let root = try XCTUnwrap(ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"])
    return URL(fileURLWithPath: root).appendingPathComponent(UUID().uuidString)
  }

  func testSourcesPublishIndependentlyAndOnlyCardWritesHistory() async throws {
    _ = NSApplication.shared
    let cardStream = TestLiveStream()
    let micStream = TestLiveStream()
    let micPreview = LivePreview(input: .microphonePCM, makeLocalStream: { micStream })
    let pipe = MicrophoneCaptions.Samples.makeStream()
    let mic = MicrophoneCaptions(preview: micPreview, open: { pipe.stream })
    let model = AppModel(libraryURL: try library(), localCaptions: LivePreview(makeLocalStream: { cardStream }), microphone: mic)
    model.preferences.captions.showInFullScreen = true
    model.desktop.start(model: model)
    defer { model.desktop.stop(); pipe.continuation.finish() }
    func bubbles() -> [DesktopCaption] {
      model.desktop.refresh()
      return model.desktop.panel?.feedView.rootView.presentation.content.items ?? []
    }

    XCTAssertFalse(model.preferences.useMacMicrophone)
    model.preferences.useMacMicrophone = true
    XCTAssertTrue(bubbles().isEmpty)
    pipe.continuation.yield(Data(repeating: 0, count: 32_000))
    for _ in 0..<100 where micStream.audio.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(micStream.audio.count, 32_000)
    micStream.onEvent?(.sentence(id: 0, text: "只在气泡", isFinal: true, startMs: 0, endMs: 1000, words: nil))
    XCTAssertEqual(bubbles().map(\.inputLabel), [.microphone])
    XCTAssertNil(bubbles().first?.identityControls)
    XCTAssertEqual(micPreview.lines.first?.recordingRange, 0..<32_000)
    XCTAssertNil(micPreview.lines.first?.replay)
    XCTAssertTrue(model.captionSelection.lines.isEmpty)
    XCTAssertTrue(model.captionHistory.records.isEmpty)
    XCTAssertEqual(model.receivedLiveAudioBytes, 0)
    XCTAssertNil(model.audioMeter.sample)
    XCTAssertTrue(model.recordings.isEmpty)

    model.card.onAudio?(Data(repeating: 0, count: 2000))
    // The card's ordinary history can select the cloud while both bubbles stay on-device.
    model.captionSelection.configure(enabled: true)
    model.captionSelection.receiveCloud([LiveLine(id: "cloud", segment: 0, sentence: 0, text: "云端文字", isFinal: true,
      textSource: .cloud, recognitionRange: 0..<2000, stableCloudText: "云端文字")])
    cardStream.onEvent?(.sentence(id: 0, text: "录音卡本机文字", isFinal: true, startMs: 0, endMs: 1000, words: nil))
    let both = bubbles()
    XCTAssertEqual(both.map(\.inputLabel), [.microphone, .card])
    XCTAssertEqual(both.map(\.text), ["只在气泡", "录音卡本机文字"])
    XCTAssertEqual(model.captionHistory.records.map(\.text), ["云端文字"])
    XCTAssertNotNil(model.captionHistory.records.first?.replay)

    model.preferences.useMacMicrophone = false
    XCTAssertEqual(bubbles().count, 1)
    XCTAssertNil(bubbles().first?.inputLabel)
    XCTAssertTrue(micStream.cancelled)
    XCTAssertTrue(micPreview.lines.isEmpty)
    micStream.onEvent?(.sentence(id: 1, text: "已关闭", isFinal: true, startMs: nil, endMs: nil, words: nil))
    XCTAssertTrue(micPreview.lines.isEmpty)
    await model.shutdown()
    let saved = CaptionHistory(root: model.libraryURL)
    XCTAssertEqual(saved.records.map(\.text), ["云端文字"])
  }

  func testSilentOrUnavailableMicDoesNotBlockCardBubble() async throws {
    _ = NSApplication.shared
    let stream = TestLiveStream()
    let mic = MicrophoneCaptions(open: { throw WorkdayError.invalid("麦克风权限未开启") })
    let model = AppModel(libraryURL: try library(), localCaptions: LivePreview(makeLocalStream: { stream }), microphone: mic)
    model.preferences.captions.showInFullScreen = true
    model.desktop.start(model: model)
    model.preferences.useMacMicrophone = true
    for _ in 0..<50 where mic.failure == nil { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertNotNil(mic.failure)
    model.card.onAudio?(Data(repeating: 0, count: 40))
    stream.onEvent?(.sentence(id: 0, text: "只有卡", isFinal: true, startMs: 0, endMs: 20, words: nil))
    model.desktop.refresh()
    XCTAssertEqual(model.desktop.panel?.feedView.rootView.presentation.content.items.map(\.inputLabel), [.card])
    await model.shutdown()
  }

  func testConcurrentAppleRecognizersWithOpusAndPCMReplay() async throws {
    guard #available(macOS 26, *), let path = ProcessInfo.processInfo.environment["WORKDAY_APPLE_SPEECH"] else {
      throw XCTSkip("需要本地中文模型和完整验收语音样本")
    }
    _ = NSApplication.shared
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
    let decoded = try CardOpusDecoder(outputFormat: format).decode(data, endOfStream: true)
    let pcm = Data(bytes: try XCTUnwrap(decoded.int16ChannelData?[0]), count: Int(decoded.frameLength) * 2)
    let pipe = MicrophoneCaptions.Samples.makeStream()
    let mic = MicrophoneCaptions(open: { pipe.stream })
    let model = AppModel(libraryURL: try library(), microphone: mic)
    model.preferences.captions.showInFullScreen = true
    model.desktop.start(model: model)
    model.preferences.useMacMicrophone = true
    model.card.onStreamReset?(.started)
    defer { model.desktop.stop(); pipe.continuation.finish() }

    var concurrentBubbles = false
    for offset in stride(from: 0, to: data.count, by: 400) {
      let end = min(offset + 400, data.count)
      model.card.onAudio?(data.subdata(in: offset..<end))
      if offset * 16 < pcm.count {
        pipe.continuation.yield(pcm.subdata(in: offset * 16..<min(end * 16, pcm.count)))
      }
      try await Task.sleep(for: .milliseconds(120))
      let bubbles = model.desktop.panel?.feedView.rootView.presentation.content.items.filter { !$0.text.isEmpty } ?? []
      concurrentBubbles = concurrentBubbles || (bubbles.contains { $0.inputLabel == .microphone } && bubbles.contains { $0.inputLabel == .card })
    }
    model.card.onStreamReset?(.disconnected)
    mic.preview.boundary(.disconnected)
    for _ in 0..<300 where model.localCaptions.isWorking || mic.preview.isWorking {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(concurrentBubbles, "两路本机识别应同时在真实桌面气泡中出字")
    for preview in [model.localCaptions, mic.preview] {
      let words = preview.lines.map(\.text).joined()
      for keyword in ["首页", "日期", "本地"] { XCTAssertTrue(words.contains(keyword), preview.status + words) }
    }
    let ids = Set(mic.preview.lines.map(\.id))
    XCTAssertTrue(model.captionHistory.records.allSatisfy { !ids.contains($0.id) })
    XCTAssertTrue(mic.preview.lines.allSatisfy { $0.replay == nil && $0.voiceID == nil })
    await model.shutdown()
  }
}
