import AppKit
import SwiftUI
import WorkdayCore

struct MenuBarStatusLabel: View {
  @ObservedObject var desktop: DesktopCompanion
  var body: some View {
    Image(nsImage: WorkdayStatusArtwork.image(for: desktop.status))
      .help("工作留声 · \(desktop.status.title)\n\(desktop.status.detail)")
      .accessibilityLabel("工作留声，\(desktop.status.title)，\(desktop.status.detail)")
  }
}

struct MenuBarPanel: View {
  @ObservedObject var model: AppModel
  @ObservedObject var desktop: DesktopCompanion
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("工作留声", systemImage: "waveform").font(.callout.weight(.semibold))
        Spacer()
        Menu {
          Button("设备与资料库") { show(.library) }
          Button("设置…") {
            dismiss()
            openSettings()
          }
          Divider()
          Button("退出工作留声") { NSApp.terminate(nil) }
        } label: {
          Image(systemName: "ellipsis")
        }.menuStyle(.borderlessButton).fixedSize()
          .accessibilityLabel("更多菜单栏操作")
      }
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Circle().fill(statusColor).frame(width: 8, height: 8)
        Text(desktop.status.title).font(.system(size: 21, weight: .semibold))
        Spacer(minLength: 0)
        if [.recording, .paused, .saving].contains(desktop.status.kind),
          let seconds = model.card.state.seconds
        {
          Text(WorkdayDate.clock(seconds)).font(.callout.monospacedDigit())
        }
      }
      HStack {
        Text(model.demo ? "合成示例" : model.preferences.boundName)
        if model.card.state.isFresh(), let battery = model.card.state.battery {
          Label("\(battery)%", systemImage: "battery.\(min(100, max(0, (Int(battery) + 12) / 25 * 25)))percent")
        }
      }.font(.caption).foregroundStyle(Palette.muted)
      if desktop.status.kind != .recording {
        Text(desktop.status.detail).font(.caption).foregroundStyle(Palette.muted)
        if desktop.status.kind == .disconnected || desktop.status.kind == .connecting {
          HStack {
            Text(model.card.status).font(.caption).foregroundStyle(Palette.muted)
            Spacer()
            Button(model.preferences.boundID == nil ? "连接设备" : "重新连接") {
              if model.preferences.boundID == nil {
                model.settingsSection = .device
                dismiss()
                openSettings()
              } else {
                model.card.activate()
              }
            }.disabled(model.isolated || desktop.status.kind == .connecting)
          }
        }
      }
      if let label = model.importLabel {
        if desktop.status.kind != .syncing { Text(label).font(.caption) }
        FileTransferRow(transfer: model.sync.transfer)
      }
      if desktop.status.kind == .recording || model.live.canRetry {
        Divider()
        let recent = model.menuRecentSpeech
        HStack {
          Text("最近一句")
          Spacer()
          if let date = recent?.line.receivedAt {
            Text(date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second()).monospacedDigit()
          }
        }.font(.caption).foregroundStyle(Palette.muted)
        Group {
          if model.live.canRetry {
            HStack {
              Text(model.live.status).font(.caption).foregroundStyle(Palette.amber).lineLimit(2)
              Spacer()
              Button("重试转写") { model.live.retry() }
            }
          } else if let recent {
            HStack(alignment: .top, spacing: 8) {
              RoundedRectangle(cornerRadius: 1).fill(Palette.accent).frame(width: 2)
              let name = recent.speaker?.captionTitle(using: model.preferences.captions)
              Text((name.map { $0 + "  " } ?? "") + recent.line.text).font(.callout).lineLimit(2)
            }
          } else {
            Text(model.live.status).font(.caption).foregroundStyle(Palette.muted)
          }
        }.frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .topLeading)
        Button("查看实时字幕 →") { show(.live) }.buttonStyle(.link)
      }
      if let route = model.player.route, !model.player.dayEnded {
        Divider()
        HStack {
          Label("全天回听 · " + WorkspaceDate.title(route.day), systemImage: "speaker.wave.2")
          Text(WorkdayDate.clock(model.player.dayClock)).monospacedDigit()
          Spacer()
          Button {
            model.player.toggle()
          } label: {
            Image(systemName: model.player.playing ? "pause.fill" : "play.fill")
          }
          .buttonStyle(.plain).accessibilityLabel(model.player.playing ? "暂停回听" : "继续回听")
        }.font(.caption)
      }
      Divider()
      HStack {
        Label("桌面语音气泡", systemImage: "captions.bubble")
        Spacer()
        Toggle("桌面语音气泡", isOn: $model.preferences.captions.enabled).labelsHidden()
          .toggleStyle(.switch).accessibilityIdentifier("desktop-captions-toggle")
      }
      if model.preferences.captions.enabled {
        HStack {
          Label(desktop.isSnoozed ? "已临时隐藏" : "临时隐藏", systemImage: "moon")
            .foregroundStyle(Palette.muted)
          Spacer()
          Button(desktop.isSnoozed ? "恢复显示" : "15 分钟") {
            if desktop.isSnoozed { desktop.resume() } else { desktop.snooze() }
          }.buttonStyle(.link)
        }.font(.caption)
      }
      Divider()
      HStack {
        Button {
          show(.day)
        } label: {
          Label("打开今天的时间线", systemImage: "calendar")
        }
        .buttonStyle(.plain).accessibilityIdentifier("menu-open-main")
        Spacer()
        Button {
          dismiss()
          openSettings()
        } label: {
          Image(systemName: "gearshape")
        }
        .buttonStyle(.plain).accessibilityLabel("打开设置")
      }
    }
    .controlSize(.small).font(.callout).padding(18).frame(width: 320)
    .foregroundStyle(Palette.text).background(Palette.surface).tint(Palette.accent)
    .accessibilityIdentifier("workday-menu-panel")
    .preferredColorScheme(
      model.preferences.theme == "system" ? nil : model.preferences.theme == "dark" ? .dark : .light
    )
  }

  private var statusColor: Color {
    switch desktop.status.kind {
    case .recording: return Palette.red
    case .paused, .unknown: return Palette.amber
    case .disconnected: return Palette.muted
    default: return Palette.accent
    }
  }

  private func show(_ area: WorkspaceArea) {
    dismiss()
    if area == .day { model.showToday() } else { model.area = area }
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
  }
}
