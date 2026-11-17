import AppKit
import QS668Core
import SwiftUI
import XCTest

@testable import WorkdayCore
@testable import WorkdayMac

final class SidebarStatusTests: XCTestCase {
  @MainActor func testDeviceTitleFollowsConnectedCardAndFallsBackAfterDisconnect() {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root)
    XCTAssertEqual(model.recorderSidebarTitle, "录音卡")

    model.card.onWiFiBound?("fixture-fw925", "FW925")
    XCTAssertEqual(model.recorderName, "FW925")
    XCTAssertEqual(model.recorderSidebarTitle, "录音卡")
    model.card.name = "FW925"
    model.card.state.connected = true
    XCTAssertEqual(model.recorderSidebarTitle, "FW925")
    model.card.state.disconnect()
    XCTAssertEqual(model.recorderSidebarTitle, "录音卡")

    model.preferences.recorderKind = .usb
    model.preferences.usbOnlyVolumeID = "usb:fixture"
    model.preferences.usbOnlyVolumeName = "CB08"
    XCTAssertEqual(model.recorderSidebarTitle, "录音卡")
    model.usb.volumes = [.init(id: "usb:fixture", url: root, name: "CB08")]
    XCTAssertEqual(model.recorderSidebarTitle, "CB08")
    model.usb.volumes = []
    XCTAssertEqual(model.recorderSidebarTitle, "录音卡")
  }

  @MainActor func testKnownPendingOriginalKeepsBadgeWhileRecordingAndAfterDisconnect() {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root)
    model.preferences.boundID = "fixture"
    let active = "note20261113-160000.wav"
    let pending = "note20261113-155022.wav"
    model.catalog.snapshots["ble:fixture"] = .init(
      sourceID: "ble:fixture",
      entries: [
        .init(name: active, duration: 54, bytes: 100),
        .init(name: pending, duration: 60, bytes: 200),
      ], observedAt: Date().addingTimeInterval(-3600), complete: true)
    model.card.state.connected = true
    var parser = FrameParser()
    model.card.state.apply(parser.push(Wire.frame([3, 20, 1], seq: 0))[0])
    model.card.state.apply(parser.push(Wire.frame([3, 24] + Array(active.utf8), seq: 1))[0])
    XCTAssertEqual(model.pendingOriginals.map(\.entry.name), [pending])
    XCTAssertTrue(model.cardSync.title.contains("上次发现1 段待同步"))
    XCTAssertEqual(model.pendingSyncBadge, 1, "页面已有待同步录音时，旧清单与正在录音都不能隐藏提醒")
    XCTAssertEqual(model.pendingSyncBadgeText, "1")
    XCTAssertTrue(model.pendingSyncBadgeHint?.contains("上次发现") == true)
    model.card.state.disconnect()
    XCTAssertEqual(model.pendingSyncBadge, 1, "等待 USB 连接时仍应保留已知待同步提示")
  }

  @MainActor func testRealCardPacketsDriveMeterWithCaptionsDisabledWithoutPublishingWholeWorkspace()
    async throws
  {
    guard let path = ProcessInfo.processInfo.environment["WORKDAY_APPLE_SPEECH"] else {
      throw XCTSkip("按需使用录音卡 Opus 回放验证输入电平")
    }
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root)
    model.preferences.captions.enabled = false
    model.preferences.realtime = false
    let packets = Data(try Data(contentsOf: URL(fileURLWithPath: path)).prefix(12_000))
    var maximum = 0
    var workspacePublishes = 0
    let meterSubscription = model.audioMeter.$sample.compactMap { $0 }.sink {
      maximum = max(maximum, $0.segments)
    }
    let workspaceSubscription = model.objectWillChange.sink { workspacePublishes += 1 }
    for start in stride(from: 0, to: packets.count, by: 200) {
      model.card.onAudio?(Data(packets[start..<min(start + 200, packets.count)]))
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertGreaterThan(maximum, 0)
    XCTAssertNotNil(model.audioMeter.sample)
    XCTAssertEqual(workspacePublishes, 0, "高频电平不能驱动整个工作区重绘")
    meterSubscription.cancel()
    workspaceSubscription.cancel()
    model.audioMeter.reset()
    XCTAssertNil(model.audioMeter.sample)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertNil(model.audioMeter.sample, "重置后丢弃旧解码回调")
    await model.shutdown()
  }

  @MainActor func testHiddenSummaryDoesNotClearAnUnseenUpdate() async throws {
    _ = NSApplication.shared
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root)
    let summary = DaySummary(day: "2026-11-13", overview: "有新的工作事项", recordingIDs: [])
    model.summaries[summary.day] = summary
    model.recordDayUpdate(summary)
    model.selectDay(summary.day)
    let window = NSWindow(
      contentRect: .init(x: -16000, y: -16000, width: 500, height: 300),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = NSHostingView(rootView: DaySummaryView(model: model))
    window.contentView?.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(1100))
    XCTAssertTrue(model.dayUpdates.isUnseen(summary.day))
    XCTAssertEqual(model.daySidebarState, .updated)
    model.processingID = "another-recording"
    XCTAssertEqual(model.daySidebarState, .updated, "新内容提示优先于新一轮整理转圈")
    await model.shutdown()
  }

  @MainActor func testPendingBadgeQualifiesIncompleteAndCachedCountsAndFallsAfterSave() async {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root)
    let source = "usb:fixture"
    model.usb.volumes = [.init(id: source, url: model.libraryURL, name: "Fixture")]
    let wav = InventoryEntry(name: "note20261113-090000.wav", duration: 1, bytes: 100)
    let opus = InventoryEntry(name: "note20261113-090000.opus", duration: 1, bytes: 20)
    model.catalog.snapshots[source] = .init(
      sourceID: source, entries: [wav, opus], observedAt: Date(), complete: false)
    XCTAssertEqual(model.pendingSyncBadge, 1)
    XCTAssertEqual(model.pendingSyncBadgeText, "≥1")
    XCTAssertTrue(model.pendingSyncBadgeHint?.contains("至少") == true)
    model.catalog.snapshots[source]?.complete = true
    XCTAssertEqual(model.pendingSyncBadge, 1)
    XCTAssertEqual(model.pendingSyncBadgeText, "1")
    XCTAssertEqual(model.pendingOriginals.count, 1)
    model.usb.excludedStems = [InventoryEntry.stem(wav.name)]
    XCTAssertNil(model.pendingSyncBadge)
    model.usb.excludedStems = []
    model.catalog.snapshots[source]?.observedAt = Date().addingTimeInterval(-30)
    XCTAssertEqual(model.pendingSyncBadge, 1)
    XCTAssertTrue(model.pendingSyncBadgeHint?.contains("上次发现") == true)
    model.usb.issue = "读取失败，待重试"
    XCTAssertEqual(model.pendingSyncBadge, 1, "读取失败也不能清掉已知未保存的录音")
    model.usb.issue = nil
    model.catalog.snapshots[source]?.observedAt = Date()
    model.recordings = [
      Recording(
        id: "r", startedAt: nil, importedAt: Date(), originalName: wav.name,
        folder: "Records/r", originalFile: "original.wav", sha256: "hash", bytes: 100,
        duration: 1, sourceID: source)
    ]
    XCTAssertNil(model.pendingSyncBadge)
    XCTAssertTrue(model.pendingOriginals.isEmpty)
    await model.shutdown()
  }

  func testSilenceStreamLossAndStoppedHardwareRemainDistinct() {
    let now = Date()
    let recording = DesktopStatus(kind: .recording, title: "正在录音", detail: "")
    XCTAssertEqual(
      LiveSidebarState.resolve(status: recording, sample: .init(segments: 0, at: now), now: now),
      .level(0))
    XCTAssertEqual(
      LiveSidebarState.resolve(
        status: recording, sample: .init(segments: 4, at: now.addingTimeInterval(-3)), now: now),
      .noAudio)
    XCTAssertEqual(
      LiveSidebarState.resolve(
        status: .init(kind: .idle, title: "未录音", detail: ""), sample: .init(segments: 4, at: now),
        now: now), .idle)
    XCTAssertEqual(
      LiveSidebarState.resolve(
        status: .init(kind: .usb, title: "USB", detail: ""), sample: .init(segments: 4, at: now),
        now: now), .unknown)
  }

  private func makeRoot() -> URL {
    URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
        ?? NSTemporaryDirectory()
    )
    .appendingPathComponent("sidebar-" + UUID().uuidString)
  }
}
