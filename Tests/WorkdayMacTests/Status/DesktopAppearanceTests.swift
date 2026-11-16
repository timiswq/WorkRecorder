import AppKit
import SwiftUI
import XCTest

@testable import WorkdayMac

final class DesktopAppearanceTests: XCTestCase {
  @MainActor func testMenuBarLabelOnlyPublishesChangesToItsIconOrText() {
    _ = NSApplication.shared
    var recording = DesktopStatus(kind: .recording, title: "正在录音", detail: "蓝牙已连接")
    let label = MenuBarLabelState(recording)
    let image = label.content.image
    var changes = 0
    let observation = label.objectWillChange.sink { changes += 1 }
    defer { observation.cancel() }

    for seconds in 1...60 {
      recording.elapsed = Double(seconds)
      recording.battery = 100 - seconds
      label.update(recording)
    }
    XCTAssertEqual(changes, 0)
    XCTAssertTrue(image === WorkdayStatusArtwork.image(for: recording))
    let renamed = DesktopStatus(kind: .recording, title: "录音中", detail: "正在接收设备音频")
    label.update(renamed)
    XCTAssertEqual(changes, 1)
    XCTAssertEqual(label.content.detail, renamed.detail)
    XCTAssertTrue(image === label.content.image)
    recording.warning = true
    label.update(recording)
    XCTAssertEqual(changes, 2)
    XCTAssertFalse(image === label.content.image)
  }

  @MainActor func testMenuBarArtworkIncludesDistinctStatesInAFixedTemplateImage() throws {
    _ = NSApplication.shared
    var images = Set<Data>()
    for kind in DesktopStatus.Kind.allCases {
      let image = WorkdayStatusArtwork.image(for: .init(kind: kind, title: "", detail: ""))
      XCTAssertTrue(image.isTemplate)
      XCTAssertEqual(image.size, NSSize(width: 26, height: 18))
      images.insert(try XCTUnwrap(image.tiffRepresentation))
    }
    XCTAssertEqual(images.count, DesktopStatus.Kind.allCases.count)
    let recording = WorkdayStatusArtwork.image(for: .init(kind: .recording, title: "", detail: ""))
    let warning = WorkdayStatusArtwork.image(
      for: .init(kind: .recording, title: "", detail: "", warning: true))
    XCTAssertNotEqual(recording.tiffRepresentation, warning.tiffRepresentation)
  }

  func testFinalStillShowsLatestWordsWithAndWithoutSpeakerButtons() {
    let text = "今天先完成" + String(repeating: "一项很长的工作安排，", count: 6) + "然后准备发布。"
    let partial = DesktopCaption(id: "one", text: text, isFinal: false)
    let visible = CaptionTypography.visibleText(partial, username: "很长的中文用户名")
    XCTAssertTrue(visible.hasPrefix("…"))
    XCTAssertTrue(visible.hasSuffix("然后准备发布。"))
    XCTAssertLessThan(visible.count, text.count)
    XCTAssertEqual(
      CaptionTypography.visibleText(.init(id: "one", text: text, isFinal: true), username: "很长的中文用户名"),
      visible)
    var labeled = partial
    labeled.voiceID = "speaker"
    labeled.identityControls = .confirm
    let narrowed = CaptionTypography.visibleText(labeled, username: "很长的中文用户名")
    XCTAssertTrue(narrowed.hasSuffix("然后准备发布。"))
    XCTAssertEqual(narrowed, visible, "发言人按钮在独立一行，不占用字幕正文宽度")
  }

  func testLongCaptionStartsAtANearbyPhraseOrWordBoundary() {
    func visible(_ text: String) -> String {
      CaptionTypography.visibleText(.init(id: "line", text: text, isFinal: true), username: "青木")
    }
    let chinese = String(repeating: "先确认计划，", count: 9) + "最后检查这版的录音效果。"
    XCTAssertTrue(visible(chinese).hasPrefix("…先确认计划，"))
    XCTAssertTrue(visible(chinese).hasSuffix("最后检查这版的录音效果。"))
    let english = String(repeating: "prepare ", count: 17) + "final draft"
    XCTAssertTrue(visible(english).hasPrefix("…prepare "))
    XCTAssertTrue(visible(english).hasSuffix("final draft"))
    let uninterrupted = String(repeating: "甲", count: 90) + "乙"
    XCTAssertTrue(visible(uninterrupted).hasPrefix("…甲"))
    XCTAssertTrue(visible(uninterrupted).hasSuffix("乙"))
    XCTAssertEqual(visible("直接读这句。"), "直接读这句。")
  }

  func testDisplayNamesKeepDistinctSuffixesAndBoundPastedGraphemes() {
    for name in ["上海研发陈晨", "上海研发林悦", "未知发言人 123"] {
      XCTAssertEqual(CaptionTypography.displayName(name), name)
    }
    let emoji = String(repeating: "👩🏽‍💻", count: 64)
    XCTAssertEqual(CaptionTypography.displayName(emoji + emoji), emoji + "…")
  }

  @MainActor func testNativeAppearanceFixtures() throws {
    guard ProcessInfo.processInfo.environment["WORKDAY_DESKTOP_SNAPSHOTS"] == "1" else { return }
    _ = NSApplication.shared
    let labels = ["断联", "连接中", "待确认", "待机", "录音", "暂停", "保存", "USB"]
    for dark in [false, true] {
      let scheme: ColorScheme = dark ? .dark : .light
      let iconStrip = HStack(spacing: 0) {
        ForEach(Array(DesktopStatus.Kind.allCases.enumerated()), id: \.offset) { i, kind in
          VStack(spacing: 12) {
            Image(
              nsImage: WorkdayStatusArtwork.image(for: .init(kind: kind, title: "", detail: "")))
            Text(labels[i]).font(.system(size: 11))
          }.frame(width: 70, height: 70)
        }
        VStack(spacing: 12) {
          WorkdayStatusIcon(
            status: .init(kind: .recording, title: "", detail: "", warning: true))
          Text("录音·需注意").font(.system(size: 10))
        }.frame(width: 90, height: 70)
      }
      .foregroundStyle(dark ? Color.white : .black)
      .background(dark ? Color(white: 0.12) : Color(white: 0.97))
      .environment(\.colorScheme, scheme)
      try save(
        iconStrip, size: NSSize(width: 720, height: 70),
        name: "status-icons-\(dark ? "dark" : "light")")

      for mode in ["standard", "opaque", "contrast"] {
        let feed = CaptionFeedPresentation()
        feed.update(CaptionPreview.items(at: 7), username: "青木", preview: false, animated: false)
        let view = VStack(alignment: .trailing, spacing: 6) {
          ForEach(feed.content.items.reversed()) { caption in
            CaptionBubbleContent(
              caption: caption, username: "青木", opaque: mode == "opaque",
              increasedContrast: mode == "contrast")
          }
        }
        .padding(6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .background(dark ? Color(white: 0.08) : .white)
        .environment(\.colorScheme, scheme)
        try save(
          view, size: NSSize(width: 360, height: 248),
          name: "feed-\(mode)-\(dark ? "dark" : "light")")
      }
    }
    let longText = "先确认今天的工作目标，" + String(repeating: "然后讨论具体安排，", count: 8) + "最后准备发布。"
    let edgeCases = VStack(alignment: .trailing, spacing: 6) {
      CaptionBubble(
        caption: .init(id: "final", text: longText, isFinal: true),
        username: "这是一个非常长的中文用户名")
      CaptionBubble(
        caption: .init(id: "partial", text: longText, isFinal: false),
        username: "这是一个非常长的中文用户名")
      CaptionBubble(
        caption: .init(id: "english", text: "这句继续确认最终的阅读效果。", isFinal: true),
        username: "Alex Chen")
      CaptionBubble(
        caption: .init(id: "emoji", text: "名字中的 emoji 也应保持完整。", isFinal: true),
        username: String(repeating: "👩🏽‍💻", count: 12))
    }.padding(6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      .background(.white)
    try save(edgeCases, size: NSSize(width: 360, height: 248), name: "caption-edge-cases")
  }

  @MainActor private func save<V: View>(_ content: V, size: NSSize, name: String) throws {
    let root = try XCTUnwrap(ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"])
    let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
    renderer.scale = 2
    let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      .write(to: URL(fileURLWithPath: root).appendingPathComponent("\(name).png"))
  }
}
