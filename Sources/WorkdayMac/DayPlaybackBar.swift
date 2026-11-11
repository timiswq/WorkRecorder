import SwiftUI
import WorkdayCore

struct DayPlaybackBar: View {
  @ObservedObject var model: AppModel
  @State private var scrub: Double?
  @State private var isScrubbing = false
  @FocusState private var rulerFocused: Bool
  @State private var seekNotice: String?
  var body: some View {
    let player = model.player
    let route = player.route ?? model.workspace.audio
    let clock =
      scrub ?? (player.route == nil ? route.spans.first?.clockStart ?? 0 : player.dayClock)
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 12) {
        Label("全天回听", systemImage: "speaker.wave.2").font(.headline)
        if model.area != .day { Text(WorkspaceDate.title(route.day)).font(.caption) }
        Button {
          player.step(-1)
        } label: {
          Image(systemName: "backward.end.fill")
        }
        .disabled(player.route == nil || player.spanIndex == 0).accessibilityLabel("上一段录音")
        Button {
          if player.route == nil { model.playDay() } else { player.toggle() }
        } label: {
          Image(systemName: player.playing ? "pause.fill" : (player.dayEnded ? "arrow.counterclockwise" : "play.fill")).frame(
            width: 28, height: 28
          )
          .foregroundStyle(Color.white).background(Color.blue, in: Circle())
        }.keyboardShortcut(.space, modifiers: []).accessibilityLabel(
          player.playing ? "暂停全天回听" : (player.dayEnded ? "从头播放全天录音" : "播放全天"))
        Button {
          if player.route == nil, route.spans.count > 1 {
            player.startDay(
              route, recordings: model.dayRecordings, root: model.libraryURL,
              clock: route.spans[1].clockStart)
          } else {
            player.step(1)
          }
        } label: {
          Image(systemName: "forward.end.fill")
        }
        .disabled(
          route.spans.count < 2
            || (player.route != nil && player.spanIndex + 1 >= route.spans.count)
        )
        .accessibilityLabel("下一段录音")
        Text(route.spans.isEmpty ? "—" : WorkdayDate.clock(clock)).font(.callout.monospacedDigit())
        if player.dayEnded {
          Text("当天已播完").font(.callout).foregroundStyle(Palette.muted)
        } else if let entry = model.workspace.activities.first(where: { $0.containsPlayback(player) }) {
          Button(entry.activity.title) {
            model.area = .day
            model.selectedDetail = .conversation(entry.id)
          }
          .foregroundStyle(Palette.accent).lineLimit(1)
        }
        Spacer()
        Text(route.spans.isEmpty ? "暂无可按钟点回听的录音" : (isScrubbing ? "松开定位" : seekNotice ?? "空档自动跳过"))
          .font(.caption).foregroundStyle(Palette.muted)
        if !route.spans.isEmpty {
          Text(shortClock(player.heardDuration) + " / " + shortClock(route.duration))
            .font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
        }
      }.buttonStyle(.plain)
      VStack(spacing: 0) {
        GeometryReader { geometry in
          let inset: CGFloat = 8
          let width = max(1, geometry.size.width - 2 * inset)
          ZStack(alignment: .leading) {
            Capsule().fill(Palette.line).frame(width: width, height: 4).offset(x: inset)
            ForEach(route.spans) { span in
              Capsule().fill(Palette.accent)
                .frame(width: min(max(2, width * span.duration / 86400), width * (1 - span.clockStart / 86400)), height: 4)
                .offset(x: inset + width * span.clockStart / 86400)
            }
            if !route.spans.isEmpty {
              Circle().fill(Palette.accent).frame(width: 12, height: 12)
                .overlay(Circle().stroke(Palette.surface, lineWidth: 2))
                .offset(x: inset - 6 + width * clock / 86400)
            }
          }.frame(maxHeight: .infinity).accessibilityHidden(true).allowsHitTesting(false)
          Slider(value: Binding(
            get: { clock }, set: { if isScrubbing { scrub = $0 } else { seek($0, route: route) } }),
            in: 0...86400
          ) { editing in
            isScrubbing = editing
            if !editing, let value = scrub {
              seek(value, route: route)
              scrub = nil
            }
          }
          .focused($rulerFocused).opacity(0.02).accessibilityLabel("按当天钟点定位")
          .accessibilityValue(WorkdayDate.clock(clock))
          .accessibilityAdjustableAction { direction in
            seek(max(0, min(86400, clock + (direction == .increment ? 60 : -60))), route: route)
          }
        }.frame(height: 20)
          .overlay { if rulerFocused { RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.accent).allowsHitTesting(false) } }
        HStack {
          ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
            if hour != 0 { Spacer() }
            Text(String(format: "%02d:00", hour))
          }
        }.font(.system(size: 10).monospacedDigit()).foregroundStyle(Palette.muted)
      }
    }.disabled(route.spans.isEmpty).padding(.horizontal, 22).padding(.vertical, 9)
      .background(Palette.surface).overlay(alignment: .top) { Divider() }
      .onChange(of: model.selectedDay) { _, _ in scrub = nil; seekNotice = nil }
      .onChange(of: player.spanIndex) { _, _ in if player.playing { seekNotice = nil } }
  }

  private func shortClock(_ seconds: Double) -> String {
    let total = Int(seconds)
    return total >= 3600
      ? WorkdayDate.clock(seconds) : String(format: "%d:%02d", total / 60, total % 60)
  }

  private func seek(_ value: Double, route: DayAudioTimeline) {
    if let location = route.locate(clock: value) {
      let span = route.spans[location.index]
      let resolved = span.clockStart + location.offset - span.sourceStart
      seekNotice = abs(value - resolved) >= 1 ? "空档已跳至 " + WorkdayDate.clock(resolved) : nil
    }
    if model.player.route == nil {
      model.player.startDay(
        route, recordings: model.dayRecordings, root: model.libraryURL, clock: value,
        autoplay: false)
    } else {
      model.player.seekDay(value)
    }
  }
}
