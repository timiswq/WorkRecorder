import SwiftUI
import WorkdayCore

struct PlayerBar: View {
  @ObservedObject var model: AppModel
  var body: some View {
    let range = model.player.playbackRange ?? 0...model.player.duration
    VStack(spacing: 0) {
      Divider().overlay(Palette.line)
      HStack(spacing: 10) {
        Button {
          model.player.toggle()
        } label: {
          Image(systemName: model.player.playing ? "pause.fill" : "play.fill").font(
            .system(size: 13)
          ).frame(width: 28, height: 28).foregroundStyle(Palette.surface).background(
            Palette.accent, in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(model.player.playing ? "暂停播放" : "播放录音")
        .keyboardShortcut(.space, modifiers: [])

        VStack(alignment: .leading, spacing: 4) {
          Text(model.playbackHeading).font(.callout.weight(.medium)).lineLimit(1)
            .help(model.playbackHeading)
          Text(model.player.title).font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
        }.frame(minWidth: 110, maxWidth: 240, alignment: .leading)
        Slider(
          value: Binding(get: { model.player.position }, set: { model.player.seek($0) }),
          in: range.lowerBound...max(range.lowerBound + 0.001, range.upperBound)
        ).accessibilityLabel("播放位置")
        Text(
          PlaybackTime.elapsed(max(0, model.player.position - range.lowerBound)) + " / "
            + PlaybackTime.elapsed(range.upperBound - range.lowerBound)
        )
        .font(.caption.monospacedDigit()).foregroundStyle(Palette.muted).fixedSize()
        if let recording = model.recordings.first(where: { $0.id == model.player.recordingID }) {
          Menu {
            Button("查看对应原件") {
              model.showOriginals(for: recording.day)
              model.libraryRecordingID = recording.id
            }
            Button("播放对应原录音") { model.playOriginal(recording, at: model.player.sourcePosition) }
          } label: {
            Image(systemName: "ellipsis")
          }
          .fixedSize().menuStyle(.borderlessButton).accessibilityLabel("回听来源")
        } else if model.player.captionID != nil {
          Button {
            model.showLiveCaptions()
          } label: {
            Image(systemName: "text.bubble")
          }
          .buttonStyle(.plain).accessibilityLabel("返回实时字幕")
        }
        Button {
          model.player.stop()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain).accessibilityLabel("关闭单段播放")
      }.padding(.horizontal, 20).padding(.vertical, 10).background(Palette.surface)
    }
    .accessibilityIdentifier("workspace-playback-bar")
  }
}
