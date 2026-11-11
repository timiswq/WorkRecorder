import SwiftUI
import WorkdayCore

struct PlayerBar: View {
  @ObservedObject var model: AppModel
  var body: some View {
    VStack(spacing: 0) {
      Divider().overlay(Palette.line)
      HStack(spacing: 16) {
        Button {
          model.player.toggle()
        } label: {
          Image(systemName: model.player.playing ? "pause.fill" : "play.fill").font(
            .system(size: 13)
          ).frame(width: 34, height: 34).foregroundStyle(Palette.surface).background(
            Palette.accent, in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(model.player.playing ? "暂停播放" : "播放录音")
        .keyboardShortcut(.space, modifiers: [])

        VStack(alignment: .leading, spacing: 4) {
          Text(model.player.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
          Text("本地音频").font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.frame(width: 170, alignment: .leading)
        Text(WorkdayDate.clock(model.player.position)).font(.system(size: 10, design: .monospaced))
          .foregroundStyle(Palette.muted)
        Slider(
          value: Binding(get: { model.player.position }, set: { model.player.seek($0) }),
          in: 0...max(0.1, model.player.duration)
        ).accessibilityLabel("播放位置")
        Text(WorkdayDate.clock(model.player.duration)).font(.system(size: 10, design: .monospaced))
          .foregroundStyle(Palette.muted)
        Button("播放对应原录音") {
          if let recording = model.recordings.first(where: { $0.id == model.player.recordingID }) {
            model.playOriginal(recording, at: model.player.sourcePosition)
          }
        }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Palette.accent)
        Button { model.player.stop() } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain).accessibilityLabel("关闭单段播放")
      }.padding(.horizontal, 24).frame(height: 72).background(Palette.surface)
    }
  }
}
