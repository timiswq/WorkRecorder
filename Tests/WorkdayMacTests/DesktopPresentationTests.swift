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

  func testTranscriptionFailureKeepsRecordingStatus() throws {
    let status = DesktopStatus.resolve(
      card: try recording(), connection: .connected, transcriptionFailed: true, now: now)
    XCTAssertEqual(status.kind, .recording)
    XCTAssertTrue(status.warning)
    XCTAssertTrue(status.detail.contains("转写"))
  }

  func testUSBImportDoesNotExposeStaleRecordingAndLocalImportDoesNotHideRecording() throws {
    let card = try recording()
    XCTAssertEqual(
      DesktopStatus.resolve(
        card: card, connection: .usb, usbConnected: true, importLabel: "正在同步 2 / 5", now: now
      ).kind, .syncing)
    XCTAssertEqual(
      DesktopStatus.resolve(
        card: card, connection: .connected, importLabel: "导入文件", now: now
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
    XCTAssertEqual(decoded.workspaceID, "workspace")
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
