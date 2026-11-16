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

/// Four stable sections: hardware facts, quick actions, one task summary, window/menu commands.
struct MenuBarPanel: View {
  @ObservedObject var model: AppModel
  @ObservedObject var desktop: DesktopCompanion
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    let presentation = model.statusPresentation(at: Date())
    VStack(alignment: .leading, spacing: 0) {
      hardware(presentation)
        .padding(.bottom, 8)
      Divider()
      quickActions(presentation)
        .padding(.vertical, 4)
      Divider()
      taskSummary(MenuBarTaskSummary(presentation))
        .padding(.vertical, 8)
      Spacer(minLength: 4)
      Divider()
      footer.padding(.top, 4)
    }
    .padding(12)
    .frame(width: 340)
    .frame(minHeight: 250, alignment: .top)
    .fixedSize(horizontal: false, vertical: true)
    .foregroundStyle(Palette.text)
    .background(Palette.surface)
    .tint(Palette.accent)
    .font(.system(size: 13))
    .controlSize(.small)
    .accessibilityIdentifier("workday-menu-panel")
    .onAppear { model.card.monitorsMenuBattery = true }
    .onDisappear { model.card.monitorsMenuBattery = false }
    .preferredColorScheme(model.preferences.theme == "system" ? nil
      : model.preferences.theme == "dark" ? .dark : .light)
  }

  private func hardware(_ presentation: StatusPresentation) -> some View {
    let status = presentation.hardware
    return VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        WorkdayStatusIcon(status: status).foregroundStyle(StatusStyle.color(status))
        Text(status.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
        Spacer(minLength: 4)
        if let seconds = status.elapsed {
          Text(WorkdayDate.clock(seconds)).monospacedDigit()
            .accessibilityLabel("已录 " + WorkdayDate.clock(seconds))
        } else if status.kind == .recording || status.kind == .paused {
          Text("时长待更新").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
      }
      HStack(spacing: 8) {
        Text(hardwareDetail(status)).lineLimit(1).truncationMode(.middle)
          .foregroundStyle(Palette.muted)
        Spacer(minLength: 0)
        if let action = presentation.hardwareAction, action != .live {
          Button(action.title) { perform(action) }
            .buttonStyle(.link).foregroundStyle(Palette.accent).fixedSize()
            .accessibilityIdentifier("menu-hardware-action")
        }
      }.font(.system(size: 11))
    }.help(status.detail + "\n" + status.instruction)
  }

  private func hardwareDetail(_ status: DesktopStatus) -> String {
    var parts: [String] = []
    if !status.isUSB, let battery = status.battery {
      parts.append(model.card.state.charging ? "充电中" : "电量 \(battery)%")
    }
    switch status.kind {
    case .recording: parts.append("暂停、结束请在卡上操作")
    case .paused: parts.append("在录音卡上继续或结束")
    case .saving: parts.append("正在保存到录音卡")
    case .idle: parts.append("按录音卡上的按键开始录音")
    case .connecting: parts.append("请保持录音卡开启并靠近 Mac")
    case .unknown: parts.append("等待设备回复，录音状态待确认")
    case .usb:
      parts.append(model.usb.volumes.map(\.name).joined(separator: "、"))
      parts.append("卡上录音待确认")
    case .disconnected:
      parts.append(status.bluetoothBlock == nil ? "连接后可查看录音状态" : "请检查系统蓝牙设置")
    }
    return parts.joined(separator: " · ")
  }

  private func quickActions(_ presentation: StatusPresentation) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Button { show(.live) } label: {
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Text("查看实时字幕").fontWeight(.medium)
            Spacer()
            if presentation.caption.state == .needsAction {
              Text("暂不可用").font(.system(size: 11)).foregroundStyle(Palette.amber)
            }
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium))
              .foregroundStyle(Palette.muted)
          }
          if let recent = model.menuRecentSpeech {
            Text(MenuBarTaskSummary.short(recent.line.transcript.text))
              .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
          }
        }.padding(.horizontal, 4).padding(.vertical, 6)
          .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(MenuBarCommandStyle()).accessibilityIdentifier("menu-open-live")
        .help("打开主窗口的实时字幕，查看完整原话与识别状态")

      HStack {
        Text("桌面字幕")
        Spacer()
        if !model.preferences.captions.enabled {
          Text("已关闭").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        Button(model.preferences.captions.enabled
          ? (desktop.isSnoozed ? "恢复显示" : "隐藏 15 分钟") : "设置…") {
          if !model.toggleMenuBarCaptionVisibility() { settings(.captions) }
        }.buttonStyle(.borderless).foregroundStyle(Palette.accent)
          .accessibilityIdentifier("menu-caption-visibility")
          .help(model.preferences.captions.enabled
            ? "仅隐藏或恢复桌面气泡，不关闭语音识别，也不改变录音状态"
            : "打开字幕设置；不会直接启用语音识别")
      }.padding(.horizontal, 4).frame(height: 28)
    }
  }

  private func taskSummary(_ summary: MenuBarTaskSummary) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(summary.headline).font(.system(size: 11))
        Spacer()
        if let target = summary.destination {
          Button("查看") { show(target) }.buttonStyle(.link)
            .font(.system(size: 11)).accessibilityIdentifier("menu-view-tasks")
            .accessibilityLabel("查看后台任务：" + summary.fullDetail)
        }
      }.foregroundStyle(Palette.muted)
      Text(summary.detail).font(.system(size: 12)).lineLimit(1)
        .foregroundStyle(summary.attentionCount > 0 ? Palette.amber : Palette.muted)
    }.help(summary.fullDetail)
  }

  private var footer: some View {
    HStack(spacing: 4) {
      Button { show(.main) } label: {
        Text("打开工作留声").frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
          .contentShape(Rectangle())
      }.buttonStyle(MenuBarCommandStyle()).accessibilityIdentifier("menu-open-main")
        .help("打开主窗口，保留上次查看的页面")
      Menu {
        Button("录音卡") { show(.device) }
        Button("原始录音") { show(.originals) }
        if model.player.route != nil, !model.player.dayEnded {
          Divider()
          Button(model.player.playing ? "暂停回听" : "继续回听") { model.player.toggle() }
          Button("查看回听原文") { model.showPlaybackDay(); openMainWindow() }
        }
        Divider()
        Button("设置…") { settings() }
        Button("退出工作留声") { NSApp.terminate(nil) }
      } label: {
        Text("更多")
      }.menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("更多操作").accessibilityIdentifier("menu-more")
    }.padding(.horizontal, 4)
  }

  private func settings(_ section: SettingsSection? = nil) {
    if let section { model.settingsSection = section }
    dismiss()
    openSettings()
  }

  private func perform(_ action: StatusAction) {
    switch action {
    case .bind: settings(.device)
    case .recognitionSettings: settings(.recognition)
    case .captionSettings: settings(.captions)
    default: model.performStatusAction(action)
    }
  }

  private func show(_ target: MenuBarDestination) {
    model.selectMenuBarDestination(target)
    openMainWindow()
  }

  private func openMainWindow() {
    dismiss()
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
  }
}

private struct MenuBarCommandStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    CommandSurface(configuration: configuration)
  }

  private struct CommandSurface: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
      configuration.label
        .background(hovering || configuration.isPressed ? Palette.selected : .clear,
          in: RoundedRectangle(cornerRadius: 4))
        .onHover { hovering = $0 }
    }
  }
}
