import SwiftUI
import WorkdayCore

/// A single expandable day map combines organization status and wall-clock seeking.
struct DayActivityOverview: View {
  @ObservedObject var model: AppModel
  let entries: [ActivityEntry]
  let selected: String?
  @State private var expanded = false
  @State private var scrub: Double?
  @State private var dragging = false
  @State private var seekNotice: String?
  @FocusState private var focused: Bool

  var body: some View {
    let route = model.workspace.audio
    let clock =
      scrub
      ?? (model.player.route?.day == route.day
        ? model.player.dayClock : route.spans.first?.clockStart ?? 0)
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          Label("已整理", systemImage: "circle.fill").foregroundStyle(Palette.accent)
          Label("未整理", systemImage: "circle").foregroundStyle(Palette.amber)
          Spacer(minLength: 0)
        }.font(.caption)
        GeometryReader { geometry in
          let inset: CGFloat = 7
          let width = max(1, geometry.size.width - inset * 2)
          Canvas { context, size in
            let y = size.height / 2
            context.fill(
              Path(CGRect(x: inset, y: y - 1, width: width, height: 2)), with: .color(Palette.line))
            for span in route.spans {
              let mark = CGRect(
                x: inset + span.clockStart / 86400 * width, y: y - 3,
                width: max(2, span.duration / 86400 * width), height: 6)
              context.fill(
                Path(roundedRect: mark, cornerRadius: 2), with: .color(Palette.muted.opacity(0.4)))
            }
            if let midnight = WorkspaceDate.date(route.day) {
              for entry in entries {
                guard let start = entry.start else { continue }
                let seconds = max(0, start.timeIntervalSince(midnight))
                let duration = max(0, entry.end?.timeIntervalSince(start) ?? 0)
                let x = min(width, seconds / 86400 * width)
                let w = min(max(4, duration / 86400 * width), max(1, width - x))
                let mark = CGRect(
                  x: inset + min(x, width - w), y: entry.id == selected ? y - 9 : y - 6,
                  width: w, height: entry.id == selected ? 18 : 12)
                let path = Path(roundedRect: mark, cornerRadius: 2)
                context.fill(path, with: .color(entry.isRaw ? Palette.surface : Palette.accent))
                if entry.isRaw { context.stroke(path, with: .color(Palette.amber), lineWidth: 1.5) }
              }
            }
            let x = inset + min(86400, max(0, clock)) / 86400 * width
            context.fill(
              Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10)),
              with: .color(Palette.accent))
          }.accessibilityHidden(true).allowsHitTesting(false)
          Slider(
            value: Binding(
              get: { clock },
              set: { value in
                if dragging { scrub = value } else { seek(value, route: route) }
              }), in: 0...86400
          ) { editing in
            dragging = editing
            if !editing, let scrub {
              seek(scrub, route: route)
              self.scrub = nil
            }
          }.focused($focused).opacity(0.03)
            .accessibilityLabel("按当天钟点定位回听")
            .accessibilityValue(WorkdayDate.clock(clock))
            .accessibilityAdjustableAction { direction in
              seek(max(0, min(86400, clock + (direction == .increment ? 60 : -60))), route: route)
            }
        }.frame(height: 28)
          .overlay {
            if focused {
              RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.accent).allowsHitTesting(false)
            }
          }
        HStack {
          Text("00:00")
          Spacer()
          Text("12:00")
          Spacer()
          Text("24:00")
        }.font(.caption2.monospacedDigit()).foregroundStyle(Palette.muted)
        Text(seekNotice ?? "回听钟点 " + WorkdayDate.clock(clock) + " · 空档自动跳过")
          .font(.caption).foregroundStyle(Palette.muted)
      }.padding(.top, 10)
    } label: {
      Text("全天分布与时间定位").font(.callout).foregroundStyle(Palette.muted)
    }.accessibilityIdentifier("day-activity-overview")
      .onChange(of: model.selectedDay) { _, _ in
        scrub = nil
        dragging = false
        seekNotice = nil
      }
  }

  private func seek(_ value: Double, route: DayAudioTimeline) {
    if let location = route.locate(clock: value) {
      let span = route.spans[location.index]
      let resolved = span.clockStart + location.offset - span.sourceStart
      seekNotice = abs(value - resolved) >= 1 ? "空档已跳至 " + WorkdayDate.clock(resolved) : nil
    }
    model.seekDayAudio(value, on: route.day)
  }
}
