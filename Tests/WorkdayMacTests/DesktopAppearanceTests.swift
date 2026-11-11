import AppKit
import SwiftUI
import XCTest

@testable import WorkdayMac

final class DesktopAppearanceTests: XCTestCase {
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

  func testNamesRespectRenderedWidthWithoutBreakingEmoji() {
    XCTAssertEqual(CaptionTypography.displayName("青木"), "青木")
    for name in ["这是非常长的用户名", "Qing Wang's Work", String(repeating: "👩🏽‍💻", count: 20)] {
      let compact = CaptionTypography.displayName(name)
      XCTAssertLessThanOrEqual(CaptionTypography.width(of: compact), CaptionTypography.nameWidth)
      XCTAssertTrue(compact.hasSuffix("…"))
      XCTAssertTrue(name.hasPrefix(String(compact.dropLast())))
    }
    XCTAssertEqual(
      CaptionTypography.displayName(String(repeating: "长名字", count: 10_000)),
      CaptionTypography.displayName(String(repeating: "长名字", count: 30)))
  }

  @MainActor func testNativeAppearanceFixtures() throws {
    guard ProcessInfo.processInfo.environment["WORKDAY_DESKTOP_SNAPSHOTS"] == "1" else { return }
    _ = NSApplication.shared
    let labels = ["断联", "连接中", "待确认", "待机", "录音", "暂停", "保存", "USB", "同步"]
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
            status: .init(kind: .recording, title: "", detail: "", warning: true), animated: false)
          Text("录音·转写异常").font(.system(size: 10))
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
