import Foundation
import WiFiRecorderCore
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class WiFiLiveAudioTests: XCTestCase {
  private func fixture() throws -> Data { try Data(contentsOf: wifiFixture("silence.bin")) }

  func testPartialAndCombinedNotificationsYieldTheSameTimelineAsRawPackets() throws {
    let bytes = try fixture()
    let framed = WiFiLiveAudio()
    let raw = WiFiLiveAudio()
    var output = Data()
    for offset in stride(from: 0, to: bytes.count, by: 37) {
      output.append(try framed.append(bytes.subdata(in: offset..<min(offset + 37, bytes.count))))
    }
    var rawOutput = Data()
    for offset in stride(from: 0, to: bytes.count, by: 88) {
      rawOutput.append(try raw.append(bytes.subdata(in: offset + 8..<offset + 88)))
    }
    XCTAssertEqual(output.count, 16 * 40)
    XCTAssertEqual(output, rawOutput)
    let native = WiFiLiveAudio()
    XCTAssertEqual(try native.append(Data(output.prefix(40))), output.prefix(40))
  }

  func testDamagedFrameIsRejectedAndNextRecordingCanStartCleanly() throws {
    var frame = Data(try fixture().prefix(88))
    frame[4] ^= 1
    let audio = WiFiLiveAudio()
    XCTAssertThrowsError(try audio.append(frame))
    XCTAssertThrowsError(try audio.append(Data(repeating: 255, count: 80)))
    XCTAssertTrue(try audio.append(Data([0, 0, 0])).isEmpty)
    audio.reset()
    XCTAssertEqual(try audio.append(fixture()).count, 16 * 40)
  }

  @MainActor func testBoundariesRouteOnlyActiveAudioAndDoNotRefocusOnReconnectOrResume() throws {
    let card = CardObserver()
    card.state.connected = true
    var starts = 0
    var bytes = 0
    var boundaries: [LiveAudioBoundary] = []
    card.onRecordingStarted = { starts += 1 }
    card.onStreamReset = { boundaries.append($0) }
    card.onAudio = { bytes += $0.count }
    let audio = try fixture()
    card.receiveWiFiState(1, battery: 80)
    card.receiveWiFiAudio(audio)
    XCTAssertEqual(starts, 0)
    XCTAssertEqual(bytes, 640)
    card.receiveWiFiEvent(.paused, name: "sample")
    card.receiveWiFiState(1, battery: 80)
    card.receiveWiFiAudio(audio)
    XCTAssertEqual(card.state.phase, .paused)
    XCTAssertEqual(bytes, 640)
    card.receiveWiFiEvent(.resumed, name: "sample")
    card.receiveWiFiEvent(.ended, name: "sample")
    card.receiveWiFiAudio(audio)
    card.receiveWiFiState(0, battery: 80)
    card.receiveWiFiEvent(.started, name: "next")
    card.receiveWiFiState(1, battery: 80)
    XCTAssertEqual(starts, 1)
    XCTAssertEqual(boundaries, [.started, .paused, .resumed, .ended, .started])
    card.receiveWiFiAudio(Data(repeating: 255, count: 40))
    XCTAssertNotNil(card.wifiAudioIssue)
    XCTAssertEqual(bytes, 640)
    card.receiveWiFiAudio(audio)
    XCTAssertNil(card.wifiAudioIssue)
    XCTAssertEqual(bytes, 1280)
  }

  @MainActor func testLiveChineseRecognitionFromWiFiPackets() async throws {
    guard #available(macOS 26, *), let path = ProcessInfo.processInfo.environment["WORKDAY_APPLE_SPEECH"]
    else { throw XCTSkip("需要中文语音模型与验收语音样本") }
    let speech = try Data(contentsOf: URL(fileURLWithPath: path))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root)
    model.preferences.recorderKind = .wifi
    model.preferences.cloudEnabled = false
    model.preferences.captions.enabled = true
    model.card.state.connected = true
    model.card.receiveWiFiEvent(.started, name: "sample")
    var sawWordsDuringRecording = false
    for offset in stride(from: 0, to: speech.count, by: 40) {
      // RFC 6716 code 3, one frame. Increase padding without changing the test speech.
      let original = Array(speech[offset..<offset + 40])
      var packet: [UInt8]
      if original[0] == 0x48 {
        packet = [0x4B, 0x41, 38] + original.dropFirst() + Array(repeating: 0, count: 38)
      } else if original[0] == 0x4B && original[1] == 1 {
        packet = [0x4B, 0x41, 39] + original.dropFirst(2) + Array(repeating: 0, count: 39)
      } else {
        XCTAssertEqual(original[0], 0x4B)
        guard original[1] == 0x41 && original[2] < 215 else { return XCTFail("验收样本包格式改变") }
        packet = original + Array(repeating: 0, count: 40)
        packet[2] += 40
      }
      model.card.receiveWiFiAudio(Data(packet))
      if offset.isMultiple(of: 400) {
        try await Task.sleep(for: .milliseconds(100))
        if model.localCaptions.lines.contains(where: { !$0.text.isEmpty }) { sawWordsDuringRecording = true }
      }
    }
    model.card.receiveWiFiEvent(.ended, name: "sample")
    model.card.onStreamReset?(.disconnected)
    for _ in 0..<300 {
      if model.localCaptions.phase == .waiting || model.localCaptions.canRetry { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    let lines = model.localCaptions.lines
    let text = lines.map(\.text).joined()
    XCTAssertTrue(sawWordsDuringRecording)
    XCTAssertGreaterThan(model.voices.liveWindowsProcessed, 0, "蓝牙音频应进入实时声纹分析")
    for word in ["首页", "日期", "本地"] { XCTAssertTrue(text.contains(word), text) }
    XCTAssertTrue(model.captionHistory.records.contains { $0.replay != nil })
    XCTAssertEqual(model.receivedLiveAudioBytes, speech.count)
    await model.shutdown()
  }
}
