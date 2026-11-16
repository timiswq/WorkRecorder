import AppKit
import QS668Core
import XCTest

@testable import WorkdayCore
@testable import WorkdayMac

final class DockIconTests: XCTestCase {
  @MainActor func testReminderEyesMoveClearlyTowardTheUpperRightAtDockSizes() throws {
    for size in [32, 56, 64] {
      let normal = try eyeCenters(reminder: false, size: size)
      let reminder = try eyeCenters(reminder: true, size: size)
      XCTAssertEqual(normal.count, 2, "\(size)px normal")
      XCTAssertEqual(reminder.count, 2, "\(size)px reminder")
      guard normal.count == 2, reminder.count == 2 else { continue }
      for (before, after) in zip(normal, reminder) {
        XCTAssertGreaterThan(after.x - before.x, Double(size) * 0.06,
                             "提醒眼睛应明显向系统右上角角标靠近，而不只是变椭圆")
        XCTAssertGreaterThan(before.y - after.y, Double(size) * 0.05,
                             "真实 Dock 小尺寸也必须能看出上看的方向")
      }
    }
  }

  @MainActor func testSystemBadgeChangesExpressionAndClearingItRestoresTheSameDeviceIcon() async throws {
    let app = NSApplication.shared
    defer { app.applicationIconImage = nil }
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root)
    let tile = NSDockTile()
    let controller = DockBadgeController(model: model, tile: tile)
    defer { controller.stop() }
    let normal = try iconData(app)
    model.catalog.snapshots["usb:fixture"] = .init(
      sourceID: "usb:fixture",
      entries: [.init(name: "note20261116-090000.wav", duration: 60, bytes: 200)],
      observedAt: Date(), complete: true)
    try await expectBadge(tile, "1")
    XCTAssertNotEqual(try iconData(app), normal, "系统角标出现时必须切换无嘴提醒表情")
    model.catalog.snapshots.removeAll()
    try await expectBadge(tile, nil)
    XCTAssertEqual(try iconData(app), normal, "角标消失后应恢复同一设备状态的原表情")
    await model.shutdown()
  }

  @MainActor func testDeviceTransitionsChangeTheIconWithoutAnyBadgeOrMainWindow() async throws {
    let app = NSApplication.shared
    defer { app.applicationIconImage = nil }
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root)
    let tile = NSDockTile()
    let controller = DockBadgeController(model: model, tile: tile)
    defer { controller.stop() }
    let offline = try iconData(app)
    model.card.state.connected = true
    var parser = FrameParser()
    model.card.state.apply(try XCTUnwrap(parser.push(Wire.frame([3, 20, 1], seq: 0)).first))
    try await Task.sleep(for: .milliseconds(200))
    let recording = try iconData(app)
    XCTAssertNotEqual(recording, offline, "无窗口、无数量角标时也应随设备状态换图")
    model.card.state.apply(try XCTUnwrap(parser.push(Wire.frame([3, 20, 3], seq: 1)).first))
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertNotEqual(try iconData(app), recording, "暂停必须有独立状态图")
    XCTAssertNil(tile.badgeLabel, "录音状态不能伪造待同步数量")
    await model.shutdown()
  }

  @MainActor func testCountsUpdateOnlyTheNativeBadgeAndSaveConfirmationRestoresTheNormalFace() async throws {
    let app = NSApplication.shared
    defer { app.applicationIconImage = nil }
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root)
    model.usb.volumes = [.init(id: "usb:fixture", url: root, name: "Fixture")]
    let tile = NSDockTile()
    let controller = DockBadgeController(model: model, tile: tile)
    defer { controller.stop() }
    let normal = try iconData(app)
    model.catalog.snapshots["usb:fixture"] = .init(
      sourceID: "usb:fixture",
      entries: [.init(name: "note20261116-090000.wav", duration: 1, bytes: 100)],
      observedAt: Date(), complete: false)
    try await expectBadge(tile, "≥1")
    let reminder = try iconData(app)
    XCTAssertNotEqual(reminder, normal)
    var iconWrites = 0
    let observation = app.observe(\.applicationIconImage) { _, _ in iconWrites += 1 }
    defer { observation.invalidate() }
    model.catalog.snapshots["usb:fixture"]?.complete = true
    try await expectBadge(tile, "1")
    model.catalog.snapshots["usb:fixture"]?.entries = (0..<100).map {
      .init(name: "note20261116-\(String(format: "%06d", $0)).wav", duration: 1, bytes: 100)
    }
    try await expectBadge(tile, "99+")
    XCTAssertEqual(try iconData(app), reminder, "数字不能画进图片，也不能改变提醒表情")
    XCTAssertEqual(iconWrites, 0, "数量改变只更新系统角标")
    model.usb.activeFilenameUnknown = true
    try await expectBadge(tile, nil)
    XCTAssertEqual(try iconData(app), normal, "保存待确认隐藏角标时，表情必须同步恢复")
    await model.shutdown()
  }

  @MainActor func testStaleDeviceStatusBecomesUnknownAndRecoversWithoutChangingTheCount() async throws {
    let app = NSApplication.shared
    defer { app.applicationIconImage = nil }
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root)
    model.desktop.start(model: model)
    defer { model.desktop.stop() }
    model.card.state.connected = true
    var parser = FrameParser()
    let frame = try XCTUnwrap(parser.push(Wire.frame([3, 20, 1], seq: 0)).first)
    model.card.state.apply(frame)
    model.desktop.refresh()
    let controller = DockBadgeController(model: model, tile: NSDockTile())
    defer { controller.stop() }
    let recording = try iconData(app)
    model.card.state.apply(frame, at: Date().addingTimeInterval(-11))
    model.desktop.refresh()
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(controller.appearance?.kind, .unknown)
    XCTAssertNotEqual(try iconData(app), recording, "过期状态不能继续显示正在录音")
    model.card.state.apply(frame)
    model.desktop.refresh()
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(controller.appearance?.kind, .recording)
    XCTAssertEqual(try iconData(app), recording)
    await model.shutdown()
  }

  @MainActor func testStopRestoresTheOriginalIconAndPreventsLaterUpdates() async throws {
    let app = NSApplication.shared
    app.applicationIconImage = nil
    let original = try iconData(app)
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(libraryURL: root)
    let tile = NSDockTile()
    let controller = DockBadgeController(model: model, tile: tile)
    XCTAssertNotEqual(try iconData(app), original)
    controller.stop()
    XCTAssertEqual(try iconData(app), original)
    model.catalog.snapshots["usb:fixture"] = .init(
      sourceID: "usb:fixture",
      entries: [.init(name: "note20261116-090000.wav", duration: 1, bytes: 100)],
      observedAt: Date(), complete: true)
    model.card.state.connected = true
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertNil(tile.badgeLabel)
    XCTAssertEqual(try iconData(app), original)
    controller.stop()
    await model.shutdown()
  }

  @MainActor func testAllSixteenAppearancesHaveDistinctCachedArtworkAndClearOuterCorners() throws {
    var variants = Set<Data>()
    for kind in DesktopStatus.Kind.allCases {
      for reminder in [false, true] {
        let key = DockIconAppearance(kind: kind, reminder: reminder)
        let image = try XCTUnwrap(DockIconArtwork.image(for: key), "正式资源必须随 SwiftPM 打包")
        XCTAssertTrue(image === DockIconArtwork.image(for: key), "重复更新应复用已有图像")
        XCTAssertFalse(image.isTemplate)
        let data = try XCTUnwrap(image.tiffRepresentation)
        variants.insert(data)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent, 0)
        if ProcessInfo.processInfo.environment["WORKDAY_DOCK_SNAPSHOTS"] == "1" {
          let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]!)
            .appendingPathComponent("dock-icons")
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          let filename = "\(kind)-\(reminder ? "reminder" : "normal").png"
          try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: folder.appendingPathComponent(filename))
        }
      }
    }
    XCTAssertEqual(variants.count, 16, "每种设备状态与表情组合必须可区分")
  }

  private func makeRoot() -> URL {
    URL(fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent("dock-icons-" + UUID().uuidString)
  }

  @MainActor private func eyeCenters(reminder: Bool, size: Int) throws -> [NSPoint] {
    let image = try XCTUnwrap(DockIconArtwork.image(for: .init(kind: .idle, reminder: reminder)))
    let bitmap = try XCTUnwrap(NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current!.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    if ProcessInfo.processInfo.environment["WORKDAY_DOCK_SNAPSHOTS"] == "1",
       let path = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] {
      let folder = URL(fileURLWithPath: path).appendingPathComponent("dock-gaze")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        .write(to: folder.appendingPathComponent("\(size)-\(reminder ? "reminder" : "normal").png"))
    }
    // Connected components isolate the two pupils from the blue shell, even when
    // the reminder eyes approach its right edge. Pixel coordinates start at top left.
    var blue = Set<Int>()
    for y in 0..<size {
      for x in 0..<size {
        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
           color.blueComponent - color.redComponent > 0.35, color.redComponent < 0.35 {
          blue.insert(y * size + x)
        }
      }
    }
    var centers: [NSPoint] = []
    while let seed = blue.popFirst() {
      var queue = [seed]
      var index = 0
      while index < queue.count {
        let pixel = queue[index]
        index += 1
        let x = pixel % size, y = pixel / size
        let adjacent = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
        for (nx, ny) in adjacent where nx >= 0 && nx < size && ny >= 0 && ny < size {
          let neighbor = ny * size + nx
          if blue.remove(neighbor) != nil { queue.append(neighbor) }
        }
      }
      guard queue.count >= 2, Double(queue.count) < Double(size * size) * 0.03 else { continue }
      let x = Double(queue.map { $0 % size }.reduce(0, +)) / Double(queue.count)
      let y = Double(queue.map { $0 / size }.reduce(0, +)) / Double(queue.count)
      if y > Double(size) * 0.2 && y < Double(size) * 0.5 {
        centers.append(NSPoint(x: x, y: y))
      }
    }
    return centers.sorted { $0.x < $1.x }
  }

  @MainActor private func iconData(_ app: NSApplication) throws -> Data {
    // The system's named NSImage lazily adds representations; compare visible pixels
    // at one fixed size rather than its mutable TIFF container.
    let image = try XCTUnwrap(app.applicationIconImage)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current!.cgContext.clear(CGRect(x: 0, y: 0, width: 256, height: 256))
    image.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256))
    NSGraphicsContext.restoreGraphicsState()
    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
  }

  @MainActor private func expectBadge(_ tile: NSDockTile, _ text: String?) async throws {
    for _ in 0..<100 {
      if tile.badgeLabel == text { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(tile.badgeLabel, text)
  }
}
