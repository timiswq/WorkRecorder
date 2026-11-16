import AppKit
import QS668Core
import SwiftUI
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class MenuBarPanelTests: XCTestCase {
  func testCurrentCaptionFailureComesBeforeHistoricalSummaryErrors() {
    let caption = StatusActivity(id: "caption", title: "实时字幕暂不可用", detail: "本机识别遇到问题",
      state: .needsAction, action: .retryCaptions)
    let presentation = StatusPresentation(
      hardware: .init(kind: .recording, title: "正在录音", detail: "蓝牙已连接"),
      hardwareAction: .live, caption: caption,
      activities: [.init(id: "summary:2026-11-14", title: "11月14日概述待重试", detail: "",
        state: .needsAction, action: .summary("2026-11-14")), caption], notices: [])
    let summary = MenuBarTaskSummary(presentation)
    XCTAssertEqual(summary.attentionCount, 2)
    XCTAssertEqual(summary.detail, "实时字幕暂不可用")
    XCTAssertEqual(summary.destination, .live)
  }

  @MainActor func testViewingAnOldFailureNavigatesWithoutRetryingIt() throws {
    let model = makeModel()
    model.summaryErrors["2026-11-14"] = "示例概述错误"
    let summary = MenuBarTaskSummary(model.statusPresentation(at: Date()))
    XCTAssertEqual(summary.destination, .day("2026-11-14"))
    model.selectMenuBarDestination(try XCTUnwrap(summary.destination))
    XCTAssertEqual(model.selectedDay, "2026-11-14")
    XCTAssertEqual(model.area, .day)
    XCTAssertEqual(model.summaryErrors["2026-11-14"], "示例概述错误")
    XCTAssertNil(model.processingID)
    XCTAssertFalse(model.processingIsRunning)
  }

  @MainActor func testOpeningMainPreservesTheExistingWorkspace() {
    let model = makeModel()
    model.selectDay("2026-11-14")
    model.area = .originals
    model.selectMenuBarDestination(.main)
    XCTAssertEqual(model.selectedDay, "2026-11-14")
    XCTAssertEqual(model.area, .originals)
    model.selectMenuBarDestination(.live)
    XCTAssertEqual(model.area, .live)
  }

  @MainActor func testHidingAndRestoringDesktopCaptionsDoesNotDisableRecognitionOrRecording() throws {
    let model = makeModel()
    model.preferences.captions.enabled = true
    model.card.state.connected = true
    var parser = FrameParser()
    model.card.state.apply(parser.push(Wire.frame([3, 20, 1], seq: 1))[0])
    let before = Date()
    XCTAssertTrue(model.toggleMenuBarCaptionVisibility())
    XCTAssertTrue(model.desktop.isSnoozed)
    XCTAssertEqual(try XCTUnwrap(model.desktop.snoozedUntil).timeIntervalSince(before), 900, accuracy: 2)
    XCTAssertTrue(model.preferences.captions.enabled)
    XCTAssertEqual(model.card.state.phase, .recording)
    XCTAssertTrue(model.toggleMenuBarCaptionVisibility())
    XCTAssertNil(model.desktop.snoozedUntil)
    XCTAssertTrue(model.preferences.captions.enabled)
    model.preferences.captions.enabled = false
    XCTAssertFalse(model.toggleMenuBarCaptionVisibility())
    XCTAssertFalse(model.preferences.captions.enabled, "查看显示入口不能偷偷启用识别")
  }

  @MainActor func testCommonStatesAndManyOldFailuresFitWithoutScrolling() throws {
    _ = NSApplication.shared
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]!)
      .appendingPathComponent("compact-menu-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root)
    model.loading = false
    for day in 1...20 { model.summaryErrors[String(format: "2026-11-%02d", day)] = "示例后台错误" }
    for phase in [0, 1, 2, 3, 4] {
      if phase > 0 {
        model.card.state.connected = true
        var parser = FrameParser()
        model.card.state.apply(parser.push(Wire.frame([3, 20, UInt8(phase)], seq: 1))[0])
      }
      let host = NSHostingController(rootView: MenuBarPanel(model: model, desktop: model.desktop))
      for proposedHeight in [0.0, 10.0, 650.0] {
        let size = host.sizeThatFits(in: NSSize(width: 340, height: proposedHeight))
        XCTAssertEqual(size.width, 340, accuracy: 1)
        XCTAssertGreaterThanOrEqual(size.height, 250)
        XCTAssertLessThanOrEqual(size.height, 320,
          "后台错误数量不能把常用操作挤到滚动区域，phase=\(phase)")
      }
    }
    model.usb.volumes = [.init(id: "usb:test", url: root,
      name: String(repeating: "会议室录音卡", count: 12))]
    let usb = NSHostingController(rootView: MenuBarPanel(model: model, desktop: model.desktop))
    XCTAssertLessThanOrEqual(usb.sizeThatFits(in: NSSize(width: 340, height: 650)).height, 320)
  }

  @MainActor private func makeModel() -> AppModel {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]!)
      .appendingPathComponent("menu-actions-" + UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root)
    model.loading = false
    return model
  }
}
