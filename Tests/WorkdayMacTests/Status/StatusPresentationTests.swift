import Foundation
import QS668Core
@testable import WorkdayCore
import XCTest

@testable import WorkdayMac

final class StatusPresentationTests: XCTestCase {
  @MainActor func testCardStartOpensLiveCaptionsFromEveryOtherWorkspace() {
    let model = isolated()
    model.card.state.connected = true
    var parser = FrameParser()
    for area in WorkspaceArea.allCases where area != .live {
      model.area = area
      model.captionPosition = .scrolling
      let start = parser.push(Wire.frame([3, 1], seq: 1))[0]
      model.card.receive(start, channel: "AE22")
      XCTAssertEqual(model.area, .live, "\(area) 中的新录音应转到实时字幕")
      XCTAssertEqual(model.captionPosition, .latest, "跳转后应跟随这次录音的新字幕")
    }
  }

  @MainActor func testResumeStateRefreshAndAudioBoundariesDoNotStealTheWorkspace() {
    let model = isolated()
    model.card.state.connected = true
    var parser = FrameParser()
    model.area = .originals
    model.card.didWrite(CardQuery.state.payload)
    model.card.receive(parser.push(Wire.frame([3, 20, 1], seq: 0))[0], channel: "AE22")
    XCTAssertEqual(model.area, .originals, "首次连上已经在录音的设备不应抢走当前页面")
    for payload: [UInt8] in [[3, 5], [3, 7]] {
      model.card.receive(parser.push(Wire.frame(payload, seq: 1))[0], channel: "AE22")
      XCTAssertEqual(model.area, .originals)
    }
    model.card.state.apply(parser.push(Wire.frame([3, 20, 1], seq: 1))[0])
    model.card.onStreamReset?(.started)
    XCTAssertEqual(model.area, .originals, "重连状态或文件边界不能伪装成机身开始按键")
    model.area = .live
    model.captionPosition = .scrolling
    model.card.receive(parser.push(Wire.frame([3, 1], seq: 2))[0], channel: "AE22")
    XCTAssertEqual(model.captionPosition, .scrolling, "已经在字幕页回看时保留用户位置")
    model.card.state.disconnect()
    model.area = .device
    model.card.receive(parser.push(Wire.frame([3, 1], seq: 3))[0], channel: "AE22")
    XCTAssertEqual(model.area, .device, "断连后的旧通知不得切换页面")
  }

  @MainActor func testConfirmedIdleToRecordingOpensCaptionsWithoutKeyNotifications() {
    let model = isolated()
    model.card.state.connected = true
    var parser = FrameParser()
    model.card.state.apply(parser.push(Wire.frame([3, 20, 2], seq: 1))[0])
    model.area = .device
    model.card.didWrite(CardQuery.state.payload)
    model.card.receive(parser.push(Wire.frame([3, 20, 1], seq: 2))[0], channel: "AE22")
    XCTAssertEqual(model.area, .live)
    model.area = .originals
    model.card.didWrite(CardQuery.state.payload)
    model.card.receive(parser.push(Wire.frame([3, 20, 1], seq: 3))[0], channel: "AE22")
    XCTAssertEqual(model.area, .originals, "同一段录音的后续查询不能重复跳转")
  }

  @MainActor func testUSBSaveConfirmationIsAnActionWhileHardwareStaysUnknown() {
    let model = isolated()
    model.usb.volumes = [.init(id: "usb:test", url: model.libraryURL, name: "NO NAME")]
    model.usb.activeFilenameUnknown = true
    let status = model.statusPresentation(at: Date())
    XCTAssertTrue(status.hardware.isUSB)
    XCTAssertNil(status.hardware.elapsed)
    XCTAssertEqual(status.attention.first?.action, .sync(.confirm))
    XCTAssertEqual(status.caption.state, .waiting)
    XCTAssertTrue(status.caption.title.contains("暂停"))
  }

  @MainActor func testRecordingAndBackgroundFailureHaveIndependentRecovery() {
    let model = isolated()
    model.card.state.connected = true
    var parser = FrameParser()
    model.card.state.apply(parser.push(Wire.frame([3, 20, 1], seq: 1))[0])
    model.recordings = [recording()]
    var document = ProcessingDocument(recording: model.recordings[0], model: "test")
    document.phase = "failed"
    document.error = "云端整理失败"
    model.documents["record"] = document
    model.error = "云端整理失败"
    let status = model.statusPresentation(at: Date())
    XCTAssertFalse(status.activities.contains { $0.id == "caption" })
    XCTAssertEqual(status.hardware.kind, .recording)
    XCTAssertFalse(status.hardware.warning)
    XCTAssertEqual(status.attention.count, 1)
    XCTAssertEqual(status.attention.first?.action, .recognitionSettings, "未配置的失败任务应先引导设置")
    XCTAssertEqual(status.notices.first?.message, "云端整理失败")
  }

  @MainActor func testUnknownInventoryAndAnEmptyCardDoNotClaimSavedRecordings() {
    let model = isolated()
    let volume = USBVolume(id: "usb:test", url: model.libraryURL, name: "Card")
    model.usb.volumes = [volume]
    XCTAssertEqual(model.cardSync.phase, .reading)
    XCTAssertFalse(model.cardSync.hasSavedOriginals)
    model.catalog.snapshots[volume.id] = .init(sourceID: volume.id, entries: [], observedAt: Date(), complete: true)
    XCTAssertEqual(model.cardSync.phase, .empty)
    XCTAssertFalse(model.cardSync.hasSavedOriginals)
    XCTAssertFalse(model.statusPresentation(at: Date()).activities.contains { $0.action == .originals })
    model.catalog.snapshots[volume.id] = .init(sourceID: volume.id, entries: [
      .init(name: "note20261113-090000.opus", duration: 10, bytes: 100, isOpusOnly: true)
    ], observedAt: Date(), complete: true)
    XCTAssertEqual(model.statusPresentation(at: Date()).attention.first?.action, .device,
                   "无法同步的文件应有查看原因的入口")
  }

  @MainActor func testSavedOriginalStillWaitsForTextConfiguration() {
    let model = isolated()
    model.recordings = [recording()]
    let status = model.statusPresentation(at: Date())
    let processing = status.activities.first { $0.day == "2026-11-13" }
    XCTAssertEqual(processing?.state, .manual, "尚需设置时不能显示成会自动开始的等待任务")
    XCTAssertEqual(processing?.action, .recognitionSettings)
    XCTAssertTrue(processing?.title.contains("1 段录音待转写") == true)
    XCTAssertFalse(status.hardware.warning)
    model.documents["record"] = ProcessingDocument(recording: model.recordings[0], model: "test")
    model.processingID = "record"
    model.processingLabel = "正在转写"
    XCTAssertEqual(model.statusPresentation(at: Date()).activities.first { $0.day == "2026-11-13" }?.state, .working)
    model.pauseProcessing()
    XCTAssertEqual(model.statusPresentation(at: Date()).activities.first { $0.day == "2026-11-13" }?.action, .recognitionSettings)
  }

  @MainActor func testDismissingOneNoticePreservesFailuresAndOtherNotices() {
    let model = isolated()
    model.error = "整理失败"
    model.player.error = "回听失败"
    var visibility = StatusNoticeVisibility()
    let original = model.statusPresentation(at: Date())
    visibility.dismiss(original.notices[0])
    XCTAssertEqual(visibility.firstVisible(in: original.notices)?.message, "回听失败")
    XCTAssertEqual(model.error, "整理失败")
    XCTAssertEqual(model.player.error, "回听失败")
    XCTAssertEqual(model.statusPresentation(at: Date()).attention.count, 2)
    visibility.reconcile([])
    XCTAssertEqual(visibility.firstVisible(in: original.notices)?.message, "整理失败")
  }

  @MainActor func testFailedRecordingIsReportedInTheActiveRowForTheSameDay() {
    let model = isolated()
    let failed = recording()
    var active = failed
    active.id = "active"
    model.recordings = [failed, active]
    var document = ProcessingDocument(recording: failed, model: "test")
    document.phase = "failed"
    document.error = "转写失败"
    model.documents[failed.id] = document
    model.processingID = active.id
    let status = model.statusPresentation(at: Date())
    XCTAssertTrue(status.activities.contains { $0.day == "2026-11-13" && $0.isWorking })
    XCTAssertEqual(status.activities.count, 1)
    XCTAssertNil(status.activities.first?.action)
    XCTAssertTrue(status.activities.first?.detail.contains("另有 1 段处理失败") == true)
  }

  @MainActor private func isolated() -> AppModel {
    let base = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    return AppModel(libraryURL: URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString))
  }

  private func recording() -> Recording {
    .init(id: "record", startedAt: WorkspaceDate.date("2026-11-13"), importedAt: Date(), originalName: "note20261113-090000.wav", folder: "record",
          originalFile: "original.wav", sha256: "test", bytes: 100, duration: 60, sourceID: "usb:test")
  }
}
