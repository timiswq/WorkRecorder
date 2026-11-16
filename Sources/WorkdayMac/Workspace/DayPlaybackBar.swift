import AppKit
import SwiftUI
import WorkdayCore

struct DayPlaybackBar: View {
  @ObservedObject var model: AppModel

  var body: some View {
    let player = model.player
    let day = model.reviewPlaybackDay ?? model.selectedDay ?? ""
    let workspace = model.workspace(for: day)
    let route = player.route ?? workspace.audio
    let clock = model.reviewPlaybackClock ?? route.spans.first?.clockStart ?? 0
    let index = route.navigationIndex(clock: clock, recordingID: player.recordingID)
    ViewThatFits(in: .horizontal) {
      controls(route: route, clock: clock, index: index, compact: false)
      controls(route: route, clock: clock, index: index, compact: true)
    }
    .buttonStyle(.plain).padding(.horizontal, 20).padding(.vertical, 10)
    .background(Palette.surface).overlay(alignment: .top) { Divider() }
    .accessibilityIdentifier("workspace-playback-bar")
  }

  private func controls(route: DayAudioTimeline, clock: Double, index: Int, compact: Bool) -> some View {
    let scope = model.player.route != nil || model.player.selectionID == nil ? "当天录音"
      : model.player.playbackRange == nil ? "原始录音"
      : model.player.title == "逐句回听" ? "这句原话" : "这段对话"
    return HStack(spacing: compact ? 8 : 14) {
      HStack(spacing: 10) {
        if !compact {
          Button { step(-1, route: route, index: index) } label: { Image(systemName: "backward.end.fill") }
            .disabled(index == 0).accessibilityLabel("上一段录音")
        }
        Button {
          if model.player.selectionID != nil { model.player.toggle() }
          else { model.playDay() }
        } label: {
          Image(systemName: model.player.playing ? "pause.fill" : model.player.dayEnded ? "arrow.counterclockwise" : "play.fill")
            .frame(width: 30, height: 30).foregroundStyle(Palette.surface)
            .background(Palette.accent, in: Circle())
        }.keyboardShortcut(.space, modifiers: [])
          .accessibilityLabel((model.player.playing ? "暂停" : "播放") + scope)
          .help((model.player.playing ? "暂停" : "播放") + scope)
          .disabled(route.spans.isEmpty && model.player.selectionID == nil)
        if !compact {
          Button { step(1, route: route, index: index) } label: { Image(systemName: "forward.end.fill") }
            .disabled(index + 1 >= route.spans.count).accessibilityLabel("下一段录音")
        }
      }
      VStack(alignment: .leading, spacing: 2) {
        if route.day != model.selectedDay {
          Button(WorkspaceDate.title(route.day)) { model.showReviewPlaybackDay() }
            .font(.caption).foregroundStyle(Palette.accent).help("返回正在播放的日期")
        } else if model.player.route == nil && model.player.playbackRange != nil {
          Text(model.player.title == "逐句回听" ? "这句原话" : "这段对话")
            .font(.caption2).foregroundStyle(Palette.muted)
        } else {
          Text(scope).font(.caption2).foregroundStyle(Palette.muted)
        }
        Text(route.spans.isEmpty ? "—" : WorkdayDate.clock(clock)).font(.callout.monospacedDigit()).fixedSize()
      }
      DayActivityOverview(route: route, clock: clock) { model.seekReviewPlayback($0, on: route.day) }
        .disabled(route.spans.isEmpty)
      Menu {
        ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
          Button { model.player.setExcerptRate(Float(speed)) } label: {
            if Float(speed) == model.player.excerptRate { Label(speed.formatted() + "×", systemImage: "checkmark") }
            else { Text(speed.formatted() + "×") }
          }
        }
      } label: { Text(model.player.excerptRate.formatted() + "×").monospacedDigit() }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("播放速度")
      recordingsMenu(route: route)
      if model.player.selectionID != nil {
        Button { model.player.stop() } label: { Image(systemName: "xmark") }
          .foregroundStyle(Palette.muted).accessibilityLabel("结束回听")
      }
    }
  }

  private func recordingsMenu(route: DayAudioTimeline) -> some View {
    let recordings = model.workspace(for: route.day).recordings
    return Menu {
      if route.day != model.selectedDay && !model.workspace.audio.spans.isEmpty {
        Button("播放正在浏览的这一天") { model.playDay() }
        Divider()
      }
      ForEach(recordings) { recording in
        Menu(recording.originalName) {
          Button("查看原文") {
            model.showOriginals(for: route.day)
            model.libraryRecordingID = recording.id
          }
          Button("播放原录音") { model.playOriginal(recording) }
          Button("在访达中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([
              model.libraryURL.appendingPathComponent(recording.folder).appendingPathComponent(recording.originalFile)])
          }
        }
      }
      Divider()
      Button("查看全部原始录音") { model.showOriginals(for: route.day) }
    } label: { Text("录音 \(recordings.count)") }
      .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("录音来源与原文")
  }

  private func step(_ delta: Int, route: DayAudioTimeline, index: Int) {
    guard route.spans.indices.contains(index + delta) else { return }
    model.player.startDay(route, recordings: model.workspace(for: route.day).recordings,
      root: model.libraryURL, clock: route.spans[index + delta].clockStart, autoplay: model.player.playing)
  }
}

enum PlaybackTime {
  static func elapsed(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    return total >= 3600 ? WorkdayDate.clock(seconds) : String(format: "%d:%02d", total / 60, total % 60)
  }
}
