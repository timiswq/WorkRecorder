import SwiftUI
import WorkdayCore

/// One wall-clock ruler for finding audio and controlling playback, including gaps.
struct DayActivityOverview: View {
  let route: DayAudioTimeline
  let clock: Double
  let seek: (Double) -> Void
  @State private var scrub: Double?
  @State private var dragging = false
  @FocusState private var focused: Bool

  var body: some View {
    let bounds = route.navigationRange
    let value = min(bounds.upperBound, max(bounds.lowerBound, scrub ?? clock))
    VStack(spacing: 2) {
      GeometryReader { geometry in
        let inset: CGFloat = 6
        let width = max(1, geometry.size.width - inset * 2)
        let length = bounds.upperBound - bounds.lowerBound
        Canvas { context, size in
          let y = size.height / 2
          context.fill(Path(roundedRect: CGRect(x: inset, y: y - 3, width: width, height: 6),
            cornerRadius: 3), with: .color(Palette.line))
          for span in route.spans {
            let x = inset + (span.clockStart - bounds.lowerBound) / length * width
            let mark = CGRect(x: x, y: y - 3, width: max(2, span.duration / length * width), height: 6)
            context.fill(Path(roundedRect: mark, cornerRadius: 2), with: .color(Palette.accent.opacity(0.55)))
          }
          let x = inset + (value - bounds.lowerBound) / length * width
          context.fill(Path(CGRect(x: x - 0.75, y: y - 9, width: 1.5, height: 18)), with: .color(Palette.accent))
          context.fill(Path(ellipseIn: CGRect(x: x - 3, y: y - 11, width: 6, height: 6)), with: .color(Palette.accent))
        }.accessibilityHidden(true).allowsHitTesting(false)
        Slider(value: Binding(get: { value }, set: { target in
          if dragging { scrub = target } else { seek(target) }
        }), in: bounds) { editing in
          dragging = editing
          if !editing, let scrub { seek(scrub); self.scrub = nil }
        }.opacity(0.03).focused($focused)
          .accessibilityLabel("按钟点定位录音，空档自动跳过")
          .accessibilityValue(WorkdayDate.clock(value))
          .accessibilityAdjustableAction { direction in
            seek(min(bounds.upperBound, max(bounds.lowerBound, value + (direction == .increment ? 60 : -60))))
          }
      }.frame(height: 25)
        .overlay {
          if focused { RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.accent) }
        }
      HStack {
        Text(label(bounds.lowerBound))
        Spacer(minLength: 0)
        Text(label(bounds.lowerBound + (bounds.upperBound - bounds.lowerBound) / 3))
        Spacer(minLength: 0)
        Text(label(bounds.lowerBound + (bounds.upperBound - bounds.lowerBound) * 2 / 3))
        Spacer(minLength: 0)
        Text(label(bounds.upperBound))
      }.font(.system(size: 9).monospacedDigit()).foregroundStyle(Palette.muted)
    }.frame(minWidth: 110).help("拖动按时间查找录音，播放自动跳过空档")
      .accessibilityIdentifier("day-audio-ruler")
      .onChange(of: route.day) { _, _ in scrub = nil; dragging = false }
  }

  private func label(_ value: Double) -> String {
    let minutes = Int(value / 60)
    return String(format: "%02d:%02d", minutes / 60, minutes % 60)
  }
}
