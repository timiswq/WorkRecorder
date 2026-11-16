import AppKit
import Darwin
import QS668Core
import SwiftUI

/// Opt-in development capture of the real Window scene. It is inert for a normal library.
@MainActor enum SceneWindowCapture {
  private static var started = false
  private static var activated = false

  static func start(window: NSWindow, model: AppModel) {
    guard model.isolated, let path = ProcessInfo.processInfo.environment["WORKDAY_SCENE_CAPTURE"],
      !started
    else { return }
    started = true
    // A hidden Window scene can attach before applicationDidFinishLaunching; start() is idempotent.
    model.start()
    let output = URL(fileURLWithPath: path, isDirectory: true)
    let pid = ProcessInfo.processInfo.processIdentifier
    activated = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    let token = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { notification in
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
        app.processIdentifier == pid
      else { return }
      MainActor.assumeIsolated { activated = true }
    }
    window.setFrameOrigin(NSPoint(x: -16000, y: -16000))
    Task {
      defer {
        NSWorkspace.shared.notificationCenter.removeObserver(token)
        // The opt-in process owns only a disposable library; never wait on normal app shutdown.
        Darwin.exit(0)
      }
      do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for _ in 0..<3000 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        try require(!model.loading, "The isolated library did not finish loading.")
        let day = ProcessInfo.processInfo.environment["WORKDAY_SCENE_DAY"] ?? "2026-11-10"
        model.selectDay(day)
        model.selectedDetail = model.workspace.activities.first(where: \.isRaw).map {
          .conversation($0.id)
        }
        model.card.state.connected = true
        var parser = FrameParser()
        for (sequence, payload) in [[3, 20, 1], [3, 22, 72, 10, 0, 0, 0, 0], [0, 4, 58]]
          .enumerated()
        {
          if let frame = parser.push(Wire.frame(payload.map(UInt8.init), seq: UInt8(sequence)))
            .first
          {
            model.card.state.apply(frame)
          }
        }
        var results: [[String: Any]] = []
        for (name, width, height, dark) in [
          ("scene-prototype", 1536.0, 980.0, false),
          ("scene-wide", 1140.0, 760.0, false),
          ("scene-minimum", 690.0, 510.0, false),
          ("scene-dark", 1140.0, 760.0, true),
        ] {
          if name == "scene-prototype" {
            model.selectedDetail = model.workspace.activities.first(where: { !$0.isRaw }).map {
              .conversation($0.id)
            }
          } else {
            model.selectedDetail = model.workspace.activities.first(where: \.isRaw).map {
              .conversation($0.id)
            }
          }
          model.preferences.theme = dark ? "dark" : "light"
          window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
          window.setContentSize(NSSize(width: width, height: height))
          window.setFrameOrigin(NSPoint(x: -16000, y: -16000))
          window.orderBack(nil)
          try await Task.sleep(for: .milliseconds(400))
          window.contentView?.layoutSubtreeIfNeeded()
          window.displayIfNeeded()
          let frameView = try unwrap(window.contentView?.superview, "Missing native window frame.")
          let toolbar = try unwrap(window.toolbar, "The Window scene has no native toolbar.")
          let close = try unwrap(
            window.standardWindowButton(.closeButton), "Missing native close button.")
          let closeFrame = close.convert(close.bounds, to: frameView)
          let itemViews = toolbar.items.flatMap { ($0 as? NSToolbarItemGroup)?.subitems ?? [$0] }
            .compactMap(\.view).filter { $0.bounds.width > 0 && $0.bounds.height > 0 }
          let itemFrames = itemViews.map { $0.convert($0.bounds, to: frameView) }
          let rowDelta = itemFrames.map { abs($0.midY - closeFrame.midY) }.max() ?? .infinity
          let chromeHeight = window.frame.height - window.contentLayoutRect.maxY
          let trailingGap = window.frame.width - (itemFrames.map(\.maxX).max() ?? 0)
          let bitmap = try unwrap(
            frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds),
            "Cannot capture the complete native window.")
          frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
          let png = try unwrap(
            bitmap.representation(using: .png, properties: [:]), "Cannot encode the capture.")
          try png.write(to: output.appendingPathComponent(name + ".png"))
          let boundaryDelta = try toolbarBoundaryDelta(png: png, size: frameView.bounds.size,
            chromeHeight: chromeHeight)
          try require(
            !activated && !NSApp.isActive, "The capture application took foreground focus.")
          try require(!itemFrames.isEmpty, "The native toolbar has no rendered controls.")
          try require(
            rowDelta <= 8, "Window buttons and toolbar controls are on separate rows: \(rowDelta).")
          try require(
            chromeHeight <= 60, "The native title/toolbar area is too tall: \(chromeHeight).")
          try require(
            trailingGap <= 30,
            "Mac tasks and the More menu are not trailing aligned: \(trailingGap).")
          try require(boundaryDelta <= 0.01,
            "The sidebar background extends through the toolbar: color delta \(boundaryDelta).")
          results.append([
            "name": name, "windowWidth": window.frame.width, "windowHeight": window.frame.height,
            "nativeChromeHeight": chromeHeight, "toolbarControlCenterDelta": rowDelta,
            "nativeToolbarStyle": window.toolbarStyle.rawValue,
            "trailingControlGap": trailingGap,
            "toolbarSidebarBoundaryColorDelta": boundaryDelta,
            "tookForegroundFocus": activated, "toolbarItemCount": toolbar.items.count,
          ])
        }
        let result: [String: Any] = ["passed": true, "processID": pid, "captures": results]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
          .write(to: output.appendingPathComponent("scene-validation.json"))
      } catch {
        let result: [String: Any] = [
          "passed": false, "error": error.localizedDescription,
          "tookForegroundFocus": activated,
        ]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
          .write(to: output.appendingPathComponent("scene-validation.json"))
      }
    }
  }

  /// Sample the actual sidebar edge below the toolbar, then check that it stops at the toolbar.
  private static func toolbarBoundaryDelta(png: Data, size: NSSize, chromeHeight: CGFloat) throws -> Double {
    let image = try unwrap(NSBitmapImageRep(data: png), "Cannot inspect the native capture.")
    let scaleX = CGFloat(image.pixelsWide) / size.width
    let scaleY = CGFloat(image.pixelsHigh) / size.height
    func rgb(_ x: CGFloat, _ y: CGFloat) throws -> [CGFloat] {
      let color = try unwrap(image.colorAt(x: Int(x * scaleX), y: Int(y * scaleY))?
        .usingColorSpace(.deviceRGB), "Cannot inspect a toolbar pixel.")
      return [color.redComponent, color.greenComponent, color.blueComponent]
    }
    func difference(_ first: [CGFloat], _ second: [CGFloat]) -> CGFloat {
      zip(first, second).map { abs($0 - $1) }.max() ?? 0
    }
    let bodyY = chromeHeight + 3
    let sidebar = try rgb(20, bodyY)
    var edge: CGFloat?
    for x in 30...min(300, Int(size.width) - 20) {
      if try difference(sidebar, rgb(CGFloat(x), bodyY)) > 0.02 {
        edge = CGFloat(x)
        break
      }
    }
    let boundary = try unwrap(edge, "Cannot locate the sidebar background boundary.")
    return Double(try difference(rgb(boundary - 6, 5), rgb(boundary + 6, 5)))
  }

  private static func require(_ condition: Bool, _ message: String) throws {
    if !condition {
      throw NSError(
        domain: "WorkdaySceneCapture", code: 1,
        userInfo: [NSLocalizedDescriptionKey: message])
    }
  }

  private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
      throw NSError(
        domain: "WorkdaySceneCapture", code: 2,
        userInfo: [NSLocalizedDescriptionKey: message])
    }
    return value
  }
}
