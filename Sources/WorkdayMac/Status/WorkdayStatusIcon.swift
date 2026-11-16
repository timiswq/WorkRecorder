import AppKit
import SwiftUI

/// Original listening-companion artwork, including its state, in one native template image.
@MainActor enum WorkdayStatusArtwork {
  private struct Key: Hashable {
    let kind: DesktopStatus.Kind
    let warning: Bool
  }
  private static var images: [Key: NSImage] = [:]

  static func image(for status: DesktopStatus) -> NSImage {
    let key = Key(kind: status.kind, warning: status.warning)
    if let cached = images[key] { return cached }
    let image = NSImage(size: NSSize(width: 26, height: 18), flipped: true) { _ in
      ListeningCompanionDrawing.draw(kind: key.kind, warning: key.warning)
      return true
    }
    image.isTemplate = true
    images[key] = image
    return image
  }
}

struct WorkdayStatusIcon: View {
  let status: DesktopStatus

  var body: some View {
    Image(nsImage: WorkdayStatusArtwork.image(for: status))
      .renderingMode(.template)
      .frame(width: 26, height: 18)
      .accessibilityHidden(true)
  }
}

/// Draw at the final 26 × 18 point size. All openings are transparent; no background,
/// system symbols or raster assets are needed for light, dark or highlighted menu bars.
private enum ListeningCompanionDrawing {
  static func draw(kind: DesktopStatus.Kind, warning: Bool) {
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSColor.black.set()
    let right = kind == .usb ? 18.5 : 20.0

    if kind == .disconnected {
      // A large opening and a detached, raised ear distinguish lost contact from ready.
      let shell = NSBezierPath()
      shell.move(to: NSPoint(x: 5.0, y: 5.0))
      shell.curve(to: NSPoint(x: 10.0, y: 2.0),
                  controlPoint1: NSPoint(x: 5.8, y: 3.0), controlPoint2: NSPoint(x: 7.3, y: 2.0))
      shell.line(to: NSPoint(x: 13.5, y: 2.0))
      shell.curve(to: NSPoint(x: 19.3, y: 7.5),
                  controlPoint1: NSPoint(x: 17.4, y: 2.0), controlPoint2: NSPoint(x: 19.3, y: 3.9))
      shell.line(to: NSPoint(x: 19.3, y: 10.5))
      shell.curve(to: NSPoint(x: 13.5, y: 16.0),
                  controlPoint1: NSPoint(x: 19.3, y: 14.1), controlPoint2: NSPoint(x: 17.4, y: 16.0))
      shell.line(to: NSPoint(x: 10.0, y: 16.0))
      shell.curve(to: NSPoint(x: 5.0, y: 13.0),
                  controlPoint1: NSPoint(x: 7.3, y: 16.0), controlPoint2: NSPoint(x: 5.8, y: 15.0))
      stroke(shell, width: 1.5)
      rounded(0.3, 1.8, 2.4, 5.6, radius: 1.2).fill()
    } else {
      let shell = rounded(4.0, 1.5, right - 4.0, 15.0, radius: 6.8)
      shell.append(rounded(5.5, 3.0, right - 7.0, 12.0, radius: 5.4))
      shell.windingRule = .evenOdd
      shell.fill()
      rounded(0.6, 5.3, 2.2, 7.4, radius: 1.1).fill()
    }

    switch kind {
    case .connecting:
      let reach = NSBezierPath()
      reach.move(to: NSPoint(x: 22.0, y: 5.5))
      reach.curve(to: NSPoint(x: 22.0, y: 12.5),
                  controlPoint1: NSPoint(x: 24.3, y: 7.1), controlPoint2: NSPoint(x: 24.3, y: 10.9))
      stroke(reach, width: 1.6)
      let echo = NSBezierPath()
      echo.move(to: NSPoint(x: 24.0, y: 3.5))
      echo.curve(to: NSPoint(x: 24.0, y: warning ? 10.5 : 14.5),
                 controlPoint1: NSPoint(x: 25.2, y: 6.1),
                 controlPoint2: NSPoint(x: 25.2, y: warning ? 8.9 : 11.9))
      stroke(echo, width: 1.1)
    case .unknown:
      stroke(rounded(21.5, 4.8, 3.4, warning ? 5.7 : 8.4, radius: 1.7), width: 1.2)
    case .usb:
      rounded(20.0, 5.3, 2.0, 5.5, radius: 1.0).fill()
      let cable = NSBezierPath()
      cable.move(to: NSPoint(x: 21.0, y: warning ? 5.3 : 10.5))
      cable.curve(to: NSPoint(x: 24.0, y: warning ? 2.0 : 15.8),
                  controlPoint1: NSPoint(x: 21.0, y: warning ? 2.0 : 15.8),
                  controlPoint2: NSPoint(x: 22.2, y: warning ? 2.0 : 15.8))
      cable.line(to: NSPoint(x: 24.0, y: warning ? 3.2 : 12.0))
      stroke(cable, width: 1.3)
      rounded(22.6, warning ? 3.0 : 9.3, 2.8, 3.5, radius: 0.6).fill()
    default:
      rounded(21.7, 5.3, 2.2, warning ? 5.2 : 7.4, radius: 1.1).fill()
    }

    let faceRight = right - 2.8
    let face = rounded(6.8, 4.4, faceRight - 6.8, 9.2, radius: 4.2)
    let center = (6.8 + faceRight) / 2
    switch kind {
    case .recording:
      for (offset, height) in [(-2.8, 3.4), (0.0, 6.4), (2.8, 4.6)] {
        face.append(rounded(center + offset - 0.75, 9.0 - height / 2, 1.5, height, radius: 0.75))
      }
    case .paused:
      for offset in [-1.9, 1.9] {
        face.append(rounded(center + offset - 0.85, 6.3, 1.7, 5.4, radius: 0.85))
      }
    case .saving:
      // A falling fold over a receiving shelf means saving, never already completed.
      let fold = NSBezierPath()
      fold.move(to: NSPoint(x: center - 0.65, y: 5.6))
      fold.line(to: NSPoint(x: center + 0.65, y: 5.6))
      fold.line(to: NSPoint(x: center + 0.65, y: 8.2))
      fold.line(to: NSPoint(x: center + 1.7, y: 7.3))
      fold.line(to: NSPoint(x: center + 2.5, y: 8.2))
      fold.line(to: NSPoint(x: center, y: 10.5))
      fold.line(to: NSPoint(x: center - 2.5, y: 8.2))
      fold.line(to: NSPoint(x: center - 1.7, y: 7.3))
      fold.line(to: NSPoint(x: center - 0.65, y: 8.2))
      fold.close()
      face.append(fold)
      face.append(rounded(center - 3.1, 11.0, 6.2, 1.1, radius: 0.55))
    case .unknown:
      face.append(oval(center - 3.1, 8.3, 2.1, 2.1))
      face.append(oval(center + 1.0, 6.7, 2.1, 2.1))
    default:
      face.append(oval(center - 3.1, 7.9, 2.1, 2.1))
      face.append(oval(center + 1.0, 7.9, 2.1, 2.1))
    }
    face.windingRule = .evenOdd
    face.fill()

    if warning {
      // Reserve clear space below the right ear without obscuring the recording face.
      rounded(22.3, 12.0, 1.7, 3.1, radius: 0.85).fill()
      oval(22.3, 16.0, 1.7, 1.7).fill()
    }
  }

  private static func rounded(_ x: Double, _ y: Double, _ width: Double, _ height: Double,
                              radius: Double) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height),
                 xRadius: radius, yRadius: radius)
  }

  private static func oval(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: width, height: height))
  }

  private static func stroke(_ path: NSBezierPath, width: Double) {
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.stroke()
  }
}
