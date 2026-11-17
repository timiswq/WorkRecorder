import Foundation
import QS668Core
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class DesktopPresentationTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_000)

  func testDisconnectedRecordingIsHistoricalAndUSBIsNotDisconnection() throws {
    var card = try recording()
    card.disconnect()
    let offline = DesktopStatus.resolve(card: card, connection: .disconnected, now: now)
    XCTAssertEqual(offline.kind, .disconnected)
    XCTAssertTrue(offline.detail.contains("最后确认"))
    XCTAssertEqual(
      DesktopStatus.resolve(card: card, connection: .usb, usbConnected: true, now: now).kind,
      .usb)
  }

  func testStaleRecordingNeverLooksCurrentAndUnknownIsNotIdle() throws {
    let card = try recording()
    XCTAssertEqual(
      DesktopStatus.resolve(card: card, connection: .connected, now: now.addingTimeInterval(11))
        .kind,
      .unknown)
    var unknown = CardState()
    unknown.connected = true
    XCTAssertEqual(
      DesktopStatus.resolve(card: unknown, connection: .connected, now: now).kind, .unknown)
  }

  @MainActor func testTranscriptionFailureKeepsRecordingStatus() throws {
    let stream = TestLiveStream()
    let live = LivePreview(makeStream: { _ in stream })
    let base = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    let model = AppModel(libraryURL: URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString), live: live)
    defer { live.reset() }
    model.card.state = try recording()
    live.configure(enabled: true, service: AIService(key: "test-only"))
    live.append(Data(repeating: 0, count: 40))
    stream.onEvent?(.failed(code: "network", message: "测试云端连接失败"))
    XCTAssertTrue(live.canRetry)
    let status = model.deviceStatus(at: now)
    XCTAssertEqual(status.kind, .recording)
    XCTAssertFalse(status.warning, "云端异常不能给录音卡标记硬件故障")
    XCTAssertEqual(status.detail, "蓝牙已连接")
  }

  func testUSBExplainsCaptionInterruptionWithoutClaimingRecordingStopped() throws {
    let status = DesktopStatus.resolve(card: try recording(), connection: .usb, usbConnected: true, now: now)
    XCTAssertEqual(status.title, "USB 文件连接")
    XCTAssertTrue(status.detail.contains("实时字幕暂停"))
    XCTAssertTrue(status.detail.contains("无法确认"))
    XCTAssertNil(status.elapsed)
  }

  @MainActor func testSharedStatusExpiresAndRestoresTheTwoHardwareReadingsIndependently() throws {
    let model = AppModel(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    model.card.state = try recording()
    model.desktop.start(model: model)
    defer { model.desktop.stop() }
    var parser = FrameParser()
    func report(_ bytes: [UInt8], _ seconds: TimeInterval) throws {
      model.card.state.apply(try XCTUnwrap(parser.push(Wire.frame(bytes, seq: 0)).first),
                             at: now.addingTimeInterval(seconds))
    }
    func sample(_ seconds: TimeInterval) -> DesktopStatus {
      model.desktop.refresh(now: now.addingTimeInterval(seconds))
      return model.desktop.status
    }
    try report([3, 22, 30, 0, 0, 0, 0, 0], 0)
    try report([0, 4, 78], 0)
    XCTAssertEqual(sample(0).elapsed, 30)
    XCTAssertEqual([sample(0.5).elapsed, sample(1).elapsed, sample(2).elapsed, sample(3).elapsed],
                   [30, 31, 32, 33])
    try report([3, 22, 32, 0, 0, 0, 0, 0], 4)
    XCTAssertEqual(sample(4).elapsed, 32)
    XCTAssertEqual(sample(5).elapsed, 33)
    try report([3, 20, 1], 14)
    XCTAssertEqual(sample(14).kind, .recording)
    XCTAssertNil(sample(14).elapsed)
    XCTAssertEqual(sample(14).battery, 78)
    try report([3, 20, 1], 120)
    try report([3, 22, 150, 0, 0, 0, 0, 0], 120)
    XCTAssertEqual(sample(120).elapsed, 150)
    XCTAssertNil(sample(120).battery)
    try report([0, 4, 72], 121)
    XCTAssertEqual(sample(121).battery, 72)
    model.usb.volumes = [USBVolume(id: "usb:test", url: model.libraryURL, name: "fixture")]
    XCTAssertNil(sample(121).elapsed)
    XCTAssertNil(sample(121).battery)
  }

  @MainActor func testKnownBluetoothBlockSurvivesUSBAndClearsWhenBluetoothIsRestored() {
    let model = AppModel(libraryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    func status() -> DesktopStatus { model.deviceStatus(at: now) }
    XCTAssertTrue(status().canConnect)
    model.preferences.boundID = "fixture"
    model.card.updateBluetoothState(.poweredOff)
    XCTAssertEqual(status().title, "Mac 蓝牙已关闭")
    XCTAssertFalse(status().canConnect)
    model.usb.volumes = [USBVolume(id: "usb:test", url: model.libraryURL, name: "fixture")]
    XCTAssertEqual(status().kind, .usb)
    XCTAssertFalse(status().warning)
    XCTAssertNil(status().bluetoothBlock)
    model.card.updateBluetoothState(.unauthorized)
    model.usb.volumes = []
    XCTAssertEqual(status().title, "未获蓝牙权限")
    XCTAssertFalse(status().canConnect)
    XCTAssertTrue(status().detail.contains("隐私与安全性"))
    model.card.updateBluetoothState(.poweredOn)
    XCTAssertTrue(status().canConnect)
    XCTAssertNil(status().bluetoothBlock)
  }

  func testManualReconnectSelectsOnlyTheBoundCardWithAutomaticConnectionOff() {
    XCTAssertTrue(CardObserver.Search.reconnectBound.selects("card", boundID: "card", autoConnect: false))
    XCTAssertFalse(CardObserver.Search.reconnectBound.selects("other", boundID: "card", autoConnect: false))
    XCTAssertFalse(CardObserver.Search.preferred.selects("card", boundID: "card", autoConnect: false))
    XCTAssertFalse(CardObserver.Search.all.selects("card", boundID: "card", autoConnect: true))
  }

  func testManualDisconnectEndsLiveAudioAndWaitsForExplicitSelection() throws {
    let card = CardObserver()
    let id = UUID()
    card.boundID = id.uuidString
    card.state = try recording()
    card.choices = [CardChoice(id: id, name: "旧卡", rssi: -60)]
    var boundaries: [LiveAudioBoundary] = []
    card.onStreamReset = { boundaries.append($0) }

    card.disconnect()
    XCTAssertFalse(card.state.connected)
    XCTAssertEqual(card.connectionPhase, .disconnected)
    XCTAssertEqual(boundaries, [.disconnected])
    XCTAssertTrue(card.choices.isEmpty)
    XCTAssertEqual(card.boundID, id.uuidString)

    card.updateBluetoothState(.poweredOff)
    card.updateBluetoothState(.poweredOn)
    card.suspendForUSB(true)
    card.suspendForUSB(false)
    card.resumeAfterWake()
    card.activateAutomatically()
    XCTAssertFalse(card.scanning)
    XCTAssertEqual(card.connectionPhase, .disconnected)
    XCTAssertEqual(boundaries, [.disconnected])
  }

  func testSearchingAndConnectingHaveDistinctStatusText() {
    let card = CardState()
    let searching = DesktopStatus.resolve(card: card, connection: .searching)
    let connecting = DesktopStatus.resolve(card: card, connection: .connecting)
    XCTAssertEqual(searching.kind, .connecting)
    XCTAssertEqual(searching.title, "正在寻找录音卡")
    XCTAssertEqual(connecting.title, "正在连接录音卡")
  }

  func testUSBImportDoesNotExposeStaleRecordingAndLocalImportDoesNotHideRecording() throws {
    let card = try recording()
    XCTAssertEqual(
      DesktopStatus.resolve(
        card: card, connection: .usb, usbConnected: true, now: now
      ).kind, .usb)
    XCTAssertEqual(
      DesktopStatus.resolve(
        card: card, connection: .connected, now: now
      ).kind, .recording)
  }

  func testPartialRevisionsStayOneCaptionAndFinalExpiresAfterTwelveSeconds() {
    var state = DesktopCaptionState()
    state.update(lines: [line("正")], canPresent: true, now: now)
    state.update(lines: [line("正在讨论")], canPresent: true, now: now.addingTimeInterval(1))
    XCTAssertEqual(state.items.last?.text, "正在讨论")
    state.update(
      lines: [line("正在讨论。", final: true)], canPresent: true, now: now.addingTimeInterval(2))
    state.update(
      lines: [line("正在讨论。", final: true)], canPresent: true, now: now.addingTimeInterval(13))
    XCTAssertNotNil(state.items.last)
    state.update(
      lines: [line("正在讨论。", final: true)], canPresent: true, now: now.addingTimeInterval(14))
    XCTAssertNil(state.items.last)
  }

  func testSuppressionConsumesTextAndDoesNotReplayAfterResume() {
    var state = DesktopCaptionState()
    state.update(lines: [line("第一句")], canPresent: true, now: now)
    state.update(lines: [line("第二句", sentence: 1)], canPresent: false, now: now)
    state.update(
      lines: [line("第二句", sentence: 1)], canPresent: true, now: now.addingTimeInterval(1))
    XCTAssertNil(state.items.last)
    state.update(
      lines: [line("第三句", sentence: 2)], canPresent: true, now: now.addingTimeInterval(2))
    XCTAssertEqual(state.items.last?.text, "第三句")
  }

  func testDelayedOldSentenceDoesNotReplaceNewerCaption() {
    var state = DesktopCaptionState()
    let latest = line("最新一句", sentence: 3)
    state.update(lines: [latest], canPresent: true, now: now)
    state.update(
      lines: [line("迟到的旧句", sentence: 2, final: true), latest],
      canPresent: true, now: now.addingTimeInterval(1))
    XCTAssertEqual(state.items.last?.text, "最新一句")
  }

  func testLateFinalAfterDisconnectionCannotReappear() {
    var state = DesktopCaptionState()
    state.update(lines: [line("断线前")], canPresent: true, now: now)
    state.update(lines: [line("断线前")], canPresent: false, now: now)
    state.update(lines: [line("断线前的末句。", final: true)], canPresent: true, now: now)
    XCTAssertNil(state.items.last)
    state.update(lines: [line("新连接的文字", sentence: 1)], canPresent: true, now: now)
    XCTAssertEqual(state.items.last?.text, "新连接的文字")
  }

  func testPartialTimesOutAndResetClearsDisplay() {
    var state = DesktopCaptionState()
    state.update(lines: [line("正在识别")], canPresent: true, now: now)
    state.update(lines: [line("正在识别")], canPresent: true, now: now.addingTimeInterval(10))
    XCTAssertNil(state.items.last)
    state.update(
      lines: [line("新录音", sentence: 1)], canPresent: true, now: now.addingTimeInterval(11))
    state.update(lines: [], canPresent: true, now: now.addingTimeInterval(12))
    XCTAssertNil(state.items.last)
  }

  func testLongFinalCaptionKeepsFullTextForAccessibilityAndHasBoundedHold() {
    var state = DesktopCaptionState()
    let long = "先确认今天的工作目标，" + String(repeating: "中间内容", count: 50) + "最后一句。"
    state.update(lines: [line(long, final: true)], canPresent: true, now: now)
    XCTAssertEqual(state.items.last?.text, long)
    state.update(
      lines: [line(long, final: true)], canPresent: true, now: now.addingTimeInterval(15))
    XCTAssertNotNil(state.items.last)
    state.update(
      lines: [line(long, final: true)], canPresent: true, now: now.addingTimeInterval(16))
    XCTAssertNil(state.items.last)
  }

  func testLongPartialStillTracksRecentWordsUntilFinalized() {
    var state = DesktopCaptionState()
    let text = "开头" + String(repeating: "正在讨论", count: 40) + "最新的工作进度"
    state.update(lines: [line(text)], canPresent: true, now: now)
    XCTAssertTrue(state.items[0].text.hasSuffix("最新的工作进度"))
    state.update(lines: [line(text + "。", final: true)], canPresent: true, now: now)
    XCTAssertEqual(state.items.count, 1)
    XCTAssertTrue(state.items[0].text.hasPrefix("开头"))
  }

  func testOldPreferencesKeepAccountAndLibraryWhenCaptionFieldsAreMissing() throws {
    let json =
      #"{"boundID":"device-id","boundName":"我的卡","autoConnect":false,"autoSync":false,"autoOrganize":false,"cloudEnabled":true,"realtime":true,"theme":"dark","workspaceID":"workspace","libraryPath":"/custom/library"}"#
    let prefs = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
    XCTAssertEqual(prefs.boundID, "device-id")
    XCTAssertEqual(prefs.libraryPath, "/custom/library")
    XCTAssertTrue(prefs.cloudEnabled)
    XCTAssertTrue(prefs.realtime)
    XCTAssertFalse(prefs.autoSync)
    XCTAssertTrue(prefs.captions.enabled)
    XCTAssertFalse(prefs.captions.showInFullScreen)
    let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
    XCTAssertEqual(decoded.libraryPath, "/custom/library")
    XCTAssertEqual(decoded.captions, prefs.captions)
  }

  func testExistingCaptionSettingsKeepTheirValuesWhenUsernameIsMissing() throws {
    let json = #"{"enabled":false,"showInFullScreen":true,"displayID":"external"}"#
    let captions = try JSONDecoder().decode(CaptionPreferences.self, from: Data(json.utf8))
    XCTAssertFalse(captions.enabled)
    XCTAssertTrue(captions.showInFullScreen)
    XCTAssertEqual(captions.displayID, "external")
    XCTAssertNil(captions.username)
    XCTAssertEqual(captions.resolvedUsername(systemUsername: "系统用户"), "系统用户")
  }

  func testCustomCaptionUsernameSurvivesPreferencesRoundTrip() throws {
    var preferences = Preferences()
    preferences.boundID = "existing-card"
    preferences.captions.username = "  青木 👩🏽‍💻  "
    let restored = try JSONDecoder().decode(
      Preferences.self, from: JSONEncoder().encode(preferences))
    XCTAssertEqual(restored.boundID, "existing-card")
    XCTAssertEqual(restored.captions.username, preferences.captions.username)
    XCTAssertEqual(restored.captions.resolvedUsername(systemUsername: "系统用户"), "青木 👩🏽‍💻")
  }

  func testEmptyCaptionUsernameFallsBackAndWhitespaceDoesNotBreakTheBubble() {
    var captions = CaptionPreferences()
    for value in [nil, "", " \n\t "] as [String?] {
      captions.username = value
      XCTAssertEqual(captions.resolvedUsername(systemUsername: " 当前用户 "), "当前用户")
    }
    captions.username = "青木\n  同学"
    XCTAssertEqual(captions.resolvedUsername(systemUsername: "系统用户"), "青木 同学")
  }

  private func line(_ text: String, sentence: Int = 0, final: Bool = false) -> LiveLine {
    LiveLine(id: "session:\(sentence)", segment: 0, sentence: sentence, text: text, isFinal: final)
  }

  private func recording() throws -> CardState {
    var card = CardState()
    card.connected = true
    var parser = FrameParser()
    let frame = try XCTUnwrap(parser.push(Data(Wire.frame([3, 20, 1], seq: 0))).first)
    card.apply(frame, at: now)
    return card
  }
}
