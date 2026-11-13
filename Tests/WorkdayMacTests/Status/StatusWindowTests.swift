import AppKit
import QS668Core
import SwiftUI
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class StatusWindowTests: XCTestCase {
  @MainActor func testNativeStatusSurfacesWithoutChangingFrontmostApplication() async throws {
    guard ProcessInfo.processInfo.environment["WORKDAY_STATUS_SNAPSHOTS"] == "1",
          let output = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
    else { throw XCTSkip("按需执行原生状态界面样张") }
    _ = NSApplication.shared
    let focus = BackgroundFocusProbe()
    defer { focus.stop() }
    let root = URL(fileURLWithPath: output).appendingPathComponent("status-fixture-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root.appendingPathComponent("Library"))
    model.loading = false
    model.area = .device
    model.preferences.autoOrganize = false
    model.desktop.start(model: model)
    defer { model.desktop.stop() }

    func capture<V: View>(_ view: V, name: String, size: NSSize, dark: Bool = false) async throws {
      let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.setFrameOrigin(NSPoint(x: -16000, y: -16000))
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      let host = NSHostingView(rootView: view)
      window.contentView = host
      defer { window.close() }
      host.setFrameSize(size)
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(150))
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        .write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
      XCTAssertFalse(focus.activatedTestApplication)
    }
    try await capture(RootView(model: model), name: "status-unbound", size: .init(width: 690, height: 650))
    model.card.state.connected = true
    model.card.name = String(repeating: "会议室录音卡", count: 12)
    var parser = FrameParser()
    model.card.state.apply(parser.push(Wire.frame([3, 20, 1], seq: 1))[0])
    model.card.state.apply(parser.push(Wire.frame([3, 22, 200, 0, 0, 0, 0, 0], seq: 2))[0])
    model.card.state.apply(parser.push(Wire.frame([0, 4, 62], seq: 3))[0])
    try await capture(RootView(model: model), name: "status-recording-battery-wide", size: .init(width: 1100, height: 650))
    model.error = "示例任务失败，已有原件仍可查看。"
    try await capture(RootView(model: model), name: "status-recording-narrow", size: .init(width: 690, height: 510))
    model.card.receive(parser.push(Wire.frame([3, 1], seq: 4))[0], channel: "AE22")
    XCTAssertEqual(model.area, .live)
    try await capture(RootView(model: model), name: "status-card-start-opens-captions", size: .init(width: 900, height: 640))
    model.area = .device
    try await capture(MenuBarPanel(model: model, desktop: model.desktop), name: "status-menu-recording", size: .init(width: 340, height: 650))
    model.error = nil
    model.card.state.apply(parser.push(Wire.frame([3, 20, 3], seq: 3))[0])
    model.preferences.theme = "dark"
    try await capture(RootView(model: model), name: "status-paused-dark", size: .init(width: 690, height: 650), dark: true)
    model.preferences.theme = "light"
    model.card.state.disconnect()
    let card = root.appendingPathComponent("Card")
    let directory = card.appendingPathComponent("record")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let uuid = try XCTUnwrap(card.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
    let volume = USBVolume(id: "usb:" + uuid, url: card, name: "NO NAME")
    model.usb.volumes = [volume]
    model.preferences.autoSync = false
    try await model.sync.load()
    let file = directory.appendingPathComponent("note20261113-090000.wav")
    try AudioFiles.wav(pcm: Data(repeating: 0, count: 32000)).write(to: file)
    func scan() {
      let files = USBMonitor.files(volume).files
      model.usb.onScan?(.init(files: files, ready: files, inventories: [
        .init(sourceID: volume.id, entries: files.map { .init(name: $0.name, duration: nil, bytes: $0.size) }, observedAt: Date(), complete: true)
      ]))
    }
    scan()
    try await capture(RootView(model: model), name: "status-usb-manual", size: .init(width: 900, height: 760))
    model.usb.activeFilenameUnknown = true
    try await capture(MenuBarPanel(model: model, desktop: model.desktop), name: "status-menu-save-confirmation", size: .init(width: 340, height: 650))
    model.usb.activeFilenameUnknown = false
    model.performCardSync(.start)
    scan()
    for _ in 0..<500 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(model.isBusy)
    scan()
    XCTAssertEqual(model.cardSync.phase, .saved)
    XCTAssertTrue(model.cardSync.hasSavedOriginals)
    XCTAssertEqual(model.recordings.count, 1)
    XCTAssertTrue(USBMonitor.files(volume).files.isEmpty)
    try await capture(RootView(model: model), name: "status-usb-saved", size: .init(width: 1100, height: 760))
    try await capture(MenuBarPanel(model: model, desktop: model.desktop), name: "status-menu-usb-saved", size: .init(width: 340, height: 650))
    await model.shutdown()
  }
}
