import AppKit
import CoreImage

struct DockIconAppearance: Hashable {
  let kind: DesktopStatus.Kind
  let reminder: Bool
}

/// Two approved, mouthless faces share the same native state marks. Counts belong to NSDockTile.
@MainActor enum DockIconArtwork {
  private static var images: [DockIconAppearance: NSImage] = [:]
  private static var mutedBases: [Bool: CGImage] = [:]
  private static let context = CIContext()
  private static let bases: [Bool: NSImage] = {
    var result: [Bool: NSImage] = [:]
    for (reminder, name) in [(false, "CompanionNormal"), (true, "CompanionReminder")] {
      if let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "DockArtwork"),
         let image = NSImage(contentsOf: url) { result[reminder] = image }
    }
    return result
  }()

  static func image(for appearance: DockIconAppearance) -> NSImage? {
    if let image = images[appearance] { return image }
    guard let base = baseImage(reminder: appearance.reminder, muted: appearance.kind == .disconnected),
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let graphics = NSGraphicsContext(bitmapImageRep: bitmap)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let cg = graphics.cgContext
    cg.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    cg.interpolationQuality = .high
    // Match the installed icon's standard macOS inset and rounded outer silhouette.
    cg.translateBy(x: 1024 * 0.08, y: 1024 * 0.08)
    cg.scaleBy(x: 0.84, y: 0.84)
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 1024, height: 1024),
                 xRadius: 1024 * 0.19 / 0.84, yRadius: 1024 * 0.19 / 0.84).addClip()
    cg.draw(base, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    if appearance.reminder {
      let tint = appearance.kind == .disconnected
        ? NSColor(srgbRed: 0.35, green: 0.37, blue: 0.45, alpha: 1)
        : NSColor(srgbRed: 34.0 / 255, green: 93.0 / 255, blue: 215.0 / 255, alpha: 1)
      DockReminderGaze.draw(color: tint)
    }
    DockStateMark.draw(appearance.kind)
    NSGraphicsContext.restoreGraphicsState()
    guard let rendered = bitmap.cgImage else { return nil }
    let image = NSImage(cgImage: rendered, size: NSSize(width: 1024, height: 1024))
    images[appearance] = image
    return image
  }

  private static func baseImage(reminder: Bool, muted: Bool) -> CGImage? {
    if muted, let cached = mutedBases[reminder] { return cached }
    guard let base = bases[reminder]?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return nil
    }
    guard muted else { return base }
    let filtered = CIImage(cgImage: base).applyingFilter(
      "CIColorControls", parameters: [kCIInputSaturationKey: 0.12])
    guard let result = context.createCGImage(filtered, from: filtered.extent) else { return base }
    mutedBases[reminder] = result
    return result
  }
}

/// Solid dots need a visible positional shift to read as a gaze. Changing their
/// aspect ratio alone disappeared at Dock size. No badge or extra face marks are drawn.
private enum DockReminderGaze {
  static func draw(color: NSColor) {
    NSColor.white.setFill()
    // The face is white here; clear just the raster pupils, well inside its edges.
    NSRect(x: 175, y: 520, width: 132, height: 155).fill()
    NSRect(x: 525, y: 520, width: 132, height: 155).fill()
    color.setFill()
    // Keep a clear white gap before the right face edge after 32px downsampling.
    for x in [330.0, 669.0] {
      NSBezierPath(ovalIn: NSRect(x: x - 52, y: 685 - 52, width: 104, height: 104)).fill()
    }
  }
}

/// Large rounded marks sit below the face, leaving the system's upper-right badge area clear.
private enum DockStateMark {
  static func draw(_ kind: DesktopStatus.Kind) {
    NSColor.white.set()
    switch kind {
    case .idle: break
    case .recording:
      for (x, height) in [(310.0, 105.0), (390.0, 180.0), (470.0, 135.0)] {
        pill(x, 85, 56, height).fill()
      }
    case .paused:
      pill(338, 90, 56, 165).fill()
      pill(434, 90, 56, 165).fill()
    case .saving:
      line([NSPoint(x: 414, y: 265), NSPoint(x: 414, y: 150)], width: 46)
      line([NSPoint(x: 350, y: 205), NSPoint(x: 414, y: 140), NSPoint(x: 478, y: 205)], width: 46)
      line([NSPoint(x: 306, y: 110), NSPoint(x: 306, y: 78),
            NSPoint(x: 522, y: 78), NSPoint(x: 522, y: 110)], width: 38)
    case .connecting:
      let ring = NSBezierPath()
      ring.appendArc(withCenter: NSPoint(x: 414, y: 170), radius: 90,
                     startAngle: 60, endAngle: 360)
      stroke(ring, width: 38)
    case .disconnected:
      pill(268, 150, 110, 40).fill()
      pill(340, 115, 57, 110).fill()
      pill(431, 115, 57, 110).fill()
      pill(460, 150, 102, 40).fill()
    case .unknown:
      let hook = NSBezierPath()
      hook.move(to: NSPoint(x: 355, y: 220))
      hook.curve(to: NSPoint(x: 469, y: 211),
                 controlPoint1: NSPoint(x: 355, y: 287), controlPoint2: NSPoint(x: 478, y: 287))
      hook.curve(to: NSPoint(x: 414, y: 133),
                 controlPoint1: NSPoint(x: 464, y: 173), controlPoint2: NSPoint(x: 414, y: 178))
      stroke(hook, width: 38)
      NSBezierPath(ovalIn: NSRect(x: 393, y: 65, width: 42, height: 42)).fill()
    case .usb:
      pill(377, 235, 74, 60, radius: 16).fill()
      pill(350, 130, 128, 110, radius: 34).fill()
      pill(397, 55, 34, 88).fill()
    }
  }

  private static func pill(_ x: Double, _ y: Double, _ width: Double, _ height: Double,
                           radius: Double? = nil) -> NSBezierPath {
    let corner = radius ?? min(width, height) / 2
    return NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height),
                        xRadius: corner, yRadius: corner)
  }

  private static func line(_ points: [NSPoint], width: Double) {
    let path = NSBezierPath()
    if let first = points.first { path.move(to: first) }
    for point in points.dropFirst() { path.line(to: point) }
    stroke(path, width: width)
  }

  private static func stroke(_ path: NSBezierPath, width: Double) {
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
  }
}
