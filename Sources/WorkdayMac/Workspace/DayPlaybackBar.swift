import SwiftUI
import WorkdayCore

struct DayPlaybackBar: View {
  @ObservedObject var model: AppModel

  var body: some View {
    let player = model.player
    let route = player.route ?? model.workspace.audio
    HStack(spacing: 10) {
      HStack(spacing: 10) {
        Button {
          player.step(-1)
        } label: {
          Image(systemName: "backward.end.fill")
        }
        .disabled(player.route == nil || player.spanIndex == 0).accessibilityLabel("上一段录音")
        Button {
          if player.route == nil { model.playDay() } else { player.toggle() }
        } label: {
          Image(
            systemName: player.playing
              ? "pause.fill" : player.dayEnded ? "arrow.counterclockwise" : "play.fill"
          )
          .frame(width: 28, height: 28).foregroundStyle(Palette.surface)
          .background(Palette.accent, in: Circle())
        }.keyboardShortcut(.space, modifiers: [])
          .accessibilityLabel(player.playing ? "暂停全天回听" : "播放全天录音")
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
      }
      Button {
        if player.route != nil { model.showPlaybackDay() }
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text("全天回听 · " + route.day).font(.callout.weight(.medium)).lineLimit(1)
          Text(
            player.dayEnded
              ? "当天已播完"
              : "钟点 "
                + WorkdayDate.clock(
                  player.route == nil
                    ? route.spans.first?.clockStart ?? 0 : player.dayClock)
          )
          .font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
        }.frame(minWidth: 105, maxWidth: 220, alignment: .leading)
      }.help("全天回听 · " + route.day + "，返回正在回听的位置")
      Slider(
        value: Binding(
          get: { player.route == nil ? 0 : player.heardDuration },
          set: { model.seekDayProgress($0) }), in: 0...max(0.001, route.duration)
      )
      .accessibilityLabel("全天音频播放进度，自动跳过空档").frame(minWidth: 50, maxWidth: .infinity)
      Text(
        PlaybackTime.elapsed(player.route == nil ? 0 : player.heardDuration) + " / "
          + PlaybackTime.elapsed(route.duration)
      )
      .font(.caption.monospacedDigit()).foregroundStyle(Palette.muted).fixedSize()
      if player.route != nil {
        Button {
          player.stop()
        } label: {
          Image(systemName: "xmark")
        }
        .accessibilityLabel("结束全天回听")
      }
    }.buttonStyle(.plain).disabled(route.spans.isEmpty)
      .padding(.horizontal, 20).padding(.vertical, 10)
      .background(Palette.surface).overlay(alignment: .top) { Divider() }
      .accessibilityIdentifier("workspace-playback-bar")
  }
}

enum PlaybackTime {
  static func elapsed(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    return total >= 3600
      ? WorkdayDate.clock(seconds) : String(format: "%d:%02d", total / 60, total % 60)
  }
}
