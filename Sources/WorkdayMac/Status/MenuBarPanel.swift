import AppKit
import SwiftUI
import WorkdayCore

@MainActor final class MenuBarLabelState: ObservableObject {
  struct Content: Equatable {
    let image: NSImage
    let title: String
    let detail: String

    @MainActor init(_ status: DesktopStatus) {
      image = WorkdayStatusArtwork.image(for: status)
      title = status.title
      detail = status.detail
    }
  }

  @Published private(set) var content: Content

  init(_ status: DesktopStatus) { content = Content(status) }

  func update(_ status: DesktopStatus) {
    let next = Content(status)
    if next != content { content = next }
  }
}

struct MenuBarStatusLabel: View {
  @ObservedObject var state: MenuBarLabelState

  init(desktop: DesktopCompanion) { state = desktop.menuBarLabel }

  var body: some View {
    let label = state.content
    Image(nsImage: label.image)
      .help("工作留声 · \(label.title)\n\(label.detail)")
      .accessibilityLabel("工作留声，\(label.title)，\(label.detail)")
  }
}

struct MenuBarPanel: View {
  @ObservedObject var model: AppModel
  @ObservedObject var desktop: DesktopCompanion
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    let presentation = model.statusPresentation(at: Date())
    let status = presentation.hardware
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label("工作留声", systemImage: "waveform").font(.callout.weight(.semibold))
          Spacer()
          Menu {
            Button("录音卡") { show(.device) }
            Button("原始录音") { show(.originals) }
            Button("设置…") { dismiss(); openSettings() }
            Divider()
            Button("退出工作留声") { NSApp.terminate(nil) }
          } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("更多菜单栏操作")
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("录音卡").font(.caption).foregroundStyle(Palette.muted)
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: StatusStyle.symbol(status.kind)).accessibilityHidden(true)
            Text(status.title).font(.system(size: 20, weight: .semibold))
            Spacer(minLength: 0)
          }.foregroundStyle(StatusStyle.color(status))
          if let seconds = status.elapsed {
            Text("已录 " + WorkdayDate.clock(seconds)).monospacedDigit()
          } else if status.kind == .recording || status.kind == .paused {
            Text("时长暂未更新").font(.caption).foregroundStyle(Palette.muted)
          }
          if !status.isUSB, let battery = status.battery {
            Text(model.card.state.charging ? "充电中" : "电量 \(battery)%")
              .font(.caption).foregroundStyle(battery <= 10 ? Palette.amber : Palette.muted)
          }
          Text(status.isUSB ? status.detail : status.instruction).font(.caption).foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
          if status.isUSB {
            Text("USB · " + model.usb.volumes.map(\.name).joined(separator: "、"))
              .font(.caption).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
          }
          if let action = presentation.hardwareAction {
            Button(action.title) { perform(action) }
          }
        }
        let activities = presentation.attention + presentation.activities.filter { $0.state != .needsAction && $0.id != "caption" }
        Divider()
        Text("Mac · " + presentation.summary).font(.caption.weight(.medium)).foregroundStyle(Palette.muted)
        ForEach(activities.filter { $0.id != "caption" }) { activity in
          StatusActivityRow(activity: activity, perform: perform)
        }
        if model.importLabel != nil { FileTransferRow(transfer: model.sync.transfer) }
        if status.kind == .recording || status.kind == .paused || presentation.caption.state == .needsAction {
          Divider()
          StatusActivityRow(activity: presentation.caption, perform: perform)
          if let recent = model.menuRecentSpeech {
            HStack(alignment: .top, spacing: 8) {
              RoundedRectangle(cornerRadius: 1).fill(Palette.accent).frame(width: 2)
              let name = recent.speaker?.captionTitle(using: model.preferences.captions)
              VStack(alignment: .leading, spacing: 4) {
                Text((name.map { $0 + "  " } ?? "") + recent.line.transcript.text).lineLimit(2)
                Text(CaptionTime.seconds.string(from: recent.line.time)).font(.caption).foregroundStyle(Palette.muted)
              }
            }.frame(maxWidth: .infinity, minHeight: 40, maxHeight: 60, alignment: .topLeading)
          }
        }
        if let route = model.player.route, !model.player.dayEnded {
          Divider()
          HStack {
            Text("回听 · " + WorkspaceDate.title(route.day))
            Text(WorkdayDate.clock(model.player.dayClock)).monospacedDigit()
            Spacer()
            Button { model.player.toggle() } label: {
              Image(systemName: model.player.playing ? "pause.fill" : "play.fill")
            }.buttonStyle(.plain).accessibilityLabel(model.player.playing ? "暂停回听" : "继续回听")
          }.font(.caption)
        }
        Divider()
        HStack {
          Label("实时字幕与气泡", systemImage: "captions.bubble")
          Spacer()
          Toggle("实时字幕与气泡", isOn: $model.preferences.captions.enabled).labelsHidden()
            .toggleStyle(.switch).accessibilityIdentifier("desktop-captions-toggle")
        }
        if model.preferences.captions.enabled {
          VStack(alignment: .leading, spacing: 5) {
            HStack {
              Text(desktop.isSnoozed ? "桌面气泡已隐藏" : "临时隐藏桌面气泡").foregroundStyle(Palette.muted)
              Spacer()
              Button(desktop.isSnoozed ? "恢复显示" : "15 分钟") {
                if desktop.isSnoozed { desktop.resume() } else { desktop.snooze() }
              }.buttonStyle(.link)
            }
            if let until = desktop.snoozedUntil, desktop.isSnoozed {
              Text("隐藏至 " + until.formatted(date: .omitted, time: .shortened) + "，仅影响桌面气泡显示。")
                .foregroundStyle(Palette.muted)
            }
          }.font(.caption)
        }
        Divider()
        HStack {
          Button { show(.day) } label: { Label("打开主窗口", systemImage: "macwindow") }
            .buttonStyle(.plain).accessibilityIdentifier("menu-open-main")
          Spacer()
          Button { dismiss(); openSettings() } label: { Image(systemName: "gearshape") }
            .buttonStyle(.plain).accessibilityLabel("打开设置")
        }
      }.controlSize(.small).font(.callout).padding(18)
    }.frame(width: 340).frame(maxHeight: 650)
      .foregroundStyle(Palette.text).background(Palette.surface).tint(Palette.accent)
      .accessibilityIdentifier("workday-menu-panel")
      .onAppear { model.card.monitorsMenuBattery = true }
      .onDisappear { model.card.monitorsMenuBattery = false }
      .preferredColorScheme(model.preferences.theme == "system" ? nil : model.preferences.theme == "dark" ? .dark : .light)
  }

  private func perform(_ action: StatusAction) {
    switch action {
    case .originals: show(.originals)
    case .live: show(.live)
    case .device: show(.device)
    case .bind, .recognitionSettings, .captionSettings:
      model.settingsSection = action == .bind ? .device : action == .recognitionSettings ? .recognition : .captions
      dismiss()
      openSettings()
    default: model.performStatusAction(action)
    }
  }

  private func show(_ area: WorkspaceArea) {
    dismiss()
    switch area {
    case .day: model.openDefaultWorkspace()
    case .originals: model.showOriginals()
    case .live: model.showLiveCaptions()
    default: model.area = area
    }
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
  }
}
