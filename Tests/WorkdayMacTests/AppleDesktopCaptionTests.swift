import AppKit
import Speech
import SwiftUI
import XCTest

@testable import WorkdayMac

final class AppleDesktopCaptionTests: XCTestCase {
  @MainActor func testCardPacketsReachNativeBubblesUsingInstalledChineseModel() async throws {
    let captions = try await replay(fixtureKey: "WORKDAY_APPLE_SPEECH", name: "apple-fixture")
    let text = captions.joined()
    for keyword in ["首页", "日期", "本地"] { XCTAssertTrue(text.contains(keyword), text) }
  }

  @MainActor func testRepeatedShortPhraseKeepsFirstAndLastWordsInVisibleBubbles() async throws {
    let captions = try await replay(fixtureKey: "WORKDAY_APPLE_SPEECH_EDGES", name: "apple-edges")
    XCTAssertEqual(captions.map { $0.filter { !$0.isWhitespace && !$0.isPunctuation } },
                   ["开始继续继续下一个好了", "先把今天的日期记下来", "最后再确认一遍全部完成"])
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
    XCTAssertTrue(model.live.lines.isEmpty)
    let panel = try XCTUnwrap(model.desktop.panel)
    let host = try XCTUnwrap(panel.contentView as? NSHostingView<CaptionFeedView>)
    XCTAssertTrue(panel.isVisible)
    XCTAssertEqual(host.rootView.presentation.content.items.map(\.id), Array(lines.suffix(4)).map(\.id))
    XCTAssertEqual(host.rootView.presentation.content.items.map(\.text), Array(lines.suffix(4)).map(\.text))
    let content = host.rootView.presentation.content
    let visible = content.items.map {
      CaptionTypography.visibleText($0, username: $0.speakerLabel ?? content.username)
    }
    await model.shutdown()
    try lines.map(\.text).joined(separator: "\n").write(to: URL(fileURLWithPath: output)
      .appendingPathComponent(name + "-captions.txt"), atomically: true, encoding: .utf8)
    return visible
  }
}
