import SwiftUI
import WorkdayCore

struct RootView: View {
  @ObservedObject var model: AppModel
  @Environment(\.openSettings) private var openSettings
  @State private var noticeVisibility = StatusNoticeVisibility()

  @State private var sidebarExpanded: Bool?

  var body: some View {
    GeometryReader { window in
      let expanded = sidebarExpanded ?? (window.size.width >= 820)
      HStack(spacing: 0) {
        sidebar(expanded: expanded)
        Divider()
        VStack(spacing: 0) {
          notice
          switch model.area {
          case .day: HistoryView(model: model)
          case .live:
            VStack(spacing: 0) {
              WorkspacePageHeader(title: "实时字幕", subtitle: "最近 24 小时 · 录音卡音频")
              Divider()
              CurrentView(model: model, history: model.captionHistory).id(model.libraryURL)
            }
          case .originals: RecordingLibraryView(model: model)
          case .device: RecordingCardView(model: model)
          }
          if model.player.selectionID != nil && model.player.route == nil {
            PlayerBar(model: model)
          } else if model.player.route != nil
            || (model.area == .day && !model.workspace.audio.spans.isEmpty)
          {
            DayPlaybackBar(model: model)
          }
        }
      }.toolbar { workspaceToolbar(expanded: expanded) }
        .toolbarBackground(Palette.surface, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
    }.background(Palette.background).foregroundStyle(Palette.text).tint(Palette.accent)
      .frame(minWidth: 690, minHeight: 510)
      .preferredColorScheme(
        model.preferences.theme == "system"
          ? nil : model.preferences.theme == "dark" ? .dark : .light
      )
      .onChange(of: model.settingsRequest) { _, _ in openSettings() }
  }

  @ToolbarContentBuilder private func workspaceToolbar(expanded: Bool) -> some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      Button {
        sidebarExpanded = !expanded
      } label: {
        Image(systemName: "sidebar.left")
      }
      .accessibilityLabel(expanded ? "收起导航" : "展开导航")
      .help(expanded ? "收起导航" : "展开导航")
    }.workspaceToolbarBackground()
    ToolbarItem(placement: .navigation) {
      DeviceStatusBar(model: model, desktop: model.desktop, component: .hardware)
    }.workspaceToolbarBackground()
    if #available(macOS 26, *) {
      ToolbarSpacer(.flexible)
    } else {
      ToolbarItem(placement: .automatic) { Spacer() }
    }
    ToolbarItem(placement: .primaryAction) {
      DeviceStatusBar(model: model, desktop: model.desktop, component: .activity)
    }.workspaceToolbarBackground()
    ToolbarItem(placement: .primaryAction) {
      Menu {
        Button("导入本地音频文件…") { model.chooseFiles() }.disabled(model.importLabel != nil)
        Button("继续整理待处理录音") { model.retryProcessing() }.disabled(model.processingID != nil)
        if model.processingID != nil { Button("暂停整理") { model.pauseProcessing() } }
        Divider()
        Button("打开资料库目录") { model.reveal() }
        Button("设置…") { openSettings() }
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.borderlessButton).help("资料库操作")
    }.workspaceToolbarBackground()
  }

  private func sidebar(expanded: Bool) -> some View {
    VStack(spacing: 4) {
      if expanded {
        Text("工作留声").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 7).padding(.top, 4).padding(.bottom, 6)
      }
      ForEach(WorkspaceArea.allCases, id: \.self) { area in
        if area == .device { Divider().padding(.vertical, 8) }
        Button {
          switch area {
          case .day: model.showDayUpdates()
          case .originals: model.showOriginals()
          case .live: model.showLiveCaptions()
          case .device: model.area = area
          }
        } label: {
          sidebarLabel(area, expanded: expanded)
            .foregroundStyle(model.area == area ? Palette.accent : Palette.text)
            .background(
              model.area == area ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.accessibilityLabel(area.rawValue).help(sidebarHelp(area))
          .accessibilityValue(sidebarHelp(area))
          .accessibilityAddTraits(model.area == area ? .isSelected : [])
      }
      Spacer()
      Divider()
      Button {
        openSettings()
      } label: {
        navigationLabel("设置", icon: "gearshape", expanded: expanded)
      }.accessibilityLabel("设置").help("设置")
    }.buttonStyle(.plain).padding(8).frame(width: expanded ? 154 : 54)
      .background(Palette.sidebar, ignoresSafeAreaEdges: [])
  }

  private func sidebarHelp(_ area: WorkspaceArea) -> String {
    switch area {
    case .day:
      switch model.daySidebarState {
      case .updated: return "全天事项有更新，点击查看"
      case .working: return "正在整理录音与全天事项"
      case .failed: return "部分整理需重试，右上角可查看任务"
      case .none: return area.rawValue
      }
    case .originals:
      return model.pendingSyncBadgeHint.map { $0 + "，点击查看原件与同步操作" }
        ?? "查看已保存原件与录音卡待同步录音"
    case .live: return model.deviceStatus(at: Date()).title
    case .device: return area.rawValue
    }
  }

  private func sidebarLabel(_ area: WorkspaceArea, expanded: Bool) -> some View {
    HStack(spacing: 8) {
      Group {
        if area == .live { SidebarLiveIndicator(model: model, meter: model.audioMeter) }
        else { Image(systemName: area.icon).frame(width: 22, height: 18) }
      }.font(.system(size: 15))
        .overlay(alignment: .topTrailing) {
          if !expanded {
            sidebarIndicator(area).scaleEffect(0.75).offset(x: 8, y: -6)
          }
        }
      if expanded {
        Text(area.rawValue).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        sidebarIndicator(area)
      }
    }.padding(.horizontal, 7).frame(maxWidth: .infinity, minHeight: 34)
      .contentShape(Rectangle())
  }

  @ViewBuilder private func sidebarIndicator(_ area: WorkspaceArea) -> some View {
    if area == .day { DaySidebarIndicator(state: model.daySidebarState) }
    else if area == .originals { PendingSyncBadge(model: model) }
  }

  private func navigationLabel(_ title: String, icon: String, expanded: Bool) -> some View {
    HStack(spacing: 9) {
      Image(systemName: icon).font(.system(size: 15)).frame(width: 22)
      if expanded {
        Text(title).lineLimit(1)
        Spacer(minLength: 0)
      }
    }.padding(.horizontal, 7).frame(maxWidth: .infinity, minHeight: 34)
      .contentShape(Rectangle())
  }

  @ViewBuilder private var notice: some View {
    let presentation = model.statusPresentation(at: Date())
    if let notice = noticeVisibility.firstVisible(in: presentation.notices) {
      HStack {
        ErrorDetailsButton(message: notice.message)
        if notice.source == "sync", model.sync.failedFile?.sourceID == "manual" {
          Button("重试导入") { model.sync.retry() }
        }
        Spacer()
        Button {
          noticeVisibility.dismiss(notice)
        } label: {
          Image(systemName: "xmark")
        }.accessibilityLabel("收起此提示，任务状态仍保留")
      }.buttonStyle(.plain).font(.callout).foregroundStyle(Palette.amber).padding(10)
    }
    Color.clear.frame(height: 0)
      .onChange(of: presentation.notices.map(\.id), initial: true) { _, _ in
        noticeVisibility.reconcile(presentation.notices)
      }
    if let label = model.importLabel, model.sync.usbLabel == nil {
      HStack {
        Text(label)
        FileTransferRow(transfer: model.sync.transfer)
      }.font(.caption).padding(8)
    }
  }
}

extension ToolbarContent {
  @ToolbarContentBuilder fileprivate func workspaceToolbarBackground() -> some ToolbarContent {
    if #available(macOS 26, *) {
      self.sharedBackgroundVisibility(.hidden)
    } else {
      self
    }
  }
}
