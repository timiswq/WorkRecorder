import AppKit
import SwiftUI

@MainActor enum WorkdayStatusArtwork {
  private struct Key: Hashable {
    let kind: DesktopStatus.Kind
    let warning: Bool
  }
  private static var images: [Key: NSImage] = [:]

  static func image(for status: DesktopStatus) -> NSImage {
    let key = Key(kind: status.kind, warning: status.warning)
    if let cached = images[key] { return cached }
    // Flatten the complete mark into one template image for the native status item.
    // A menu-bar label must not depend on a custom SwiftUI stack preserving its badges.
    let renderer = ImageRenderer(
      content: WorkdayStatusIcon(status: status, animated: false).foregroundStyle(.black))
    renderer.scale = 2
    let image =
      renderer.nsImage ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!
    image.isTemplate = true
    images[key] = image
    return image
  }
}

/// A stable app mark with a separate, fixed-width state slot.
struct WorkdayStatusIcon: View {
  let status: DesktopStatus
  var animated = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 2) {
      Image(systemName: "waveform")
        .font(.system(size: 16, weight: .medium))
        .frame(width: 18, height: 18)
        .overlay {
          if status.kind == .disconnected {
            Path { path in
              path.move(to: CGPoint(x: 2, y: 2))
              path.addLine(to: CGPoint(x: 16, y: 16))
            }.stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
          }
        }
      VStack(spacing: 2) {
        marker.frame(width: 6, height: 8)
        if status.warning {
          Image(systemName: "exclamationmark")
            .font(.system(size: 6, weight: .bold)).frame(width: 6, height: 6)
        }
      }.frame(width: 6, height: 18)
    }
    .frame(width: 26, height: 18)
    .symbolRenderingMode(.monochrome)
    .accessibilityHidden(true)
  }

  @ViewBuilder private var marker: some View {
    switch status.kind {
    case .idle, .disconnected:
      Color.clear
    case .recording:
      Circle().frame(width: 5, height: 5)
    case .connecting:
      ConnectionArc(animated: animated && !reduceMotion)
    case .unknown:
      badge("minus")
    case .paused:
      badge("pause.fill")
    case .saving:
      badge("arrow.down.to.line")
    case .usb:
      badge("link")
    }
  }

  private func badge(_ symbol: String) -> some View {
    Image(systemName: symbol).font(.system(size: 7, weight: .semibold))
  }
}

private struct ConnectionArc: View {
  let animated: Bool
  @State private var spinning = false
  var body: some View {
    Circle().trim(from: 0.10, to: 0.80)
      .stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
      .frame(width: 5, height: 5)
      .rotationEffect(.degrees(spinning && animated ? 360 : 0))
      .animation(
        animated ? .linear(duration: 1.6).repeatForever(autoreverses: false) : nil,
        value: spinning && animated
      )
      .onAppear { spinning = true }
  }
}
