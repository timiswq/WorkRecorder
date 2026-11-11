import SwiftUI
import WorkdayCore

struct RootView: View {
  @ObservedObject var model: AppModel
  @Environment(\.openSettings) private var openSettings
  @State private var showsDates = false

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      HStack(spacing: 0) {
        VStack(spacing: 10) {
          railButton("全天事项", "calendar", .day)
          railButton("实时字幕", "waveform", .live)
          railButton("设备与资料库", "square.3.layers.3d", .library)
          Divider().padding(.horizontal, 13)
          railButton("设置", "gearshape", .settings)
          Spacer()
        }.buttonStyle(.plain).font(.system(size: 20)).foregroundStyle(Palette.muted)
          .padding(.top, 17).frame(width: 62).background(Palette.sidebar)
        Divider()
        VStack(spacing: 0) {
          notice
          switch model.area {
          case .day: HistoryView(model: model)
          case .live:
            GeometryReader { geometry in
              ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                  Text("实时字幕").font(.title.bold())
                  CurrentView(model: model, transcriptHeight: max(180, geometry.size.height - 238))
                  Button("桌面语音气泡设置") { model.requestSettings(.captions) }.buttonStyle(.link)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          case .library: RecordingLibraryView(model: model)
          case .settings: SettingsView(model: model, embedded: true)
          }
          if model.player.selectionID != nil && model.player.route == nil {
            PlayerBar(model: model)
          } else if model.area == .day || model.player.route != nil {
            DayPlaybackBar(model: model)
          }
        }
      }
    }.background(Palette.background).foregroundStyle(Palette.text).tint(Palette.accent)
      .frame(minWidth: 690, minHeight: 510)
      .preferredColorScheme(
        model.preferences.theme == "system"
          ? nil : model.preferences.theme == "dark" ? .dark : .light
      )
      .onChange(of: model.settingsRequest) { _, _ in openSettings() }
  }

  private var header: some View {
    ZStack {
      HStack {
        Text("工作留声").font(.system(size: 14, weight: .semibold)).padding(.leading, 78)
        Spacer()
        Menu {
          Button("导入本地音频文件…") { model.chooseFiles() }.disabled(model.importLabel != nil)
          Button("继续整理待处理录音") { model.retryProcessing() }.disabled(model.processingID != nil)
          if model.processingID != nil { Button("暂停整理") { model.pauseProcessing() } }
          Divider()
          Button("打开资料库目录") { model.reveal() }
          Button("设置…") { openSettings() }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).fixedSize().help("资料库操作")
      }
      if model.area == .day {
        HStack(spacing: 12) {
          Button {
            step(-1)
          } label: {
            Image(systemName: "chevron.left")
          }.accessibilityLabel("前一天")
          Button {
            showsDates.toggle()
          } label: {
            Text(WorkspaceDate.heading(model.selectedDay, full: true)).fontWeight(.medium)
          }
          Button {
            step(1)
          } label: {
            Image(systemName: "chevron.right")
          }.accessibilityLabel("后一天")
          Button {
            showsDates.toggle()
          } label: {
            Image(systemName: "calendar")
          }.accessibilityLabel("选择日期")
        }.buttonStyle(.plain)
          .popover(isPresented: $showsDates) {
            VStack(alignment: .leading) {
              ArchiveMonthCalendar(selectedDay: model.selectedDay, recordedDays: Set(model.days)) { day in
                model.selectDay(day)
                showsDates = false
              }
              Divider()
              Text("有录音的日期").font(.caption).foregroundStyle(.secondary)
              ArchiveDates(model: model).frame(height: 135)
            }.padding(14).frame(width: 280)
              .onChange(of: model.selectedDay) { _, _ in showsDates = false }
          }
      } else {
        Text(model.area == .live ? "实时字幕" : model.area == .library ? "设备与资料库" : "设置").fontWeight(
          .medium)
      }
    }.padding(.horizontal, 12).frame(height: 50).background(Palette.surface)
  }

  private func step(_ delta: Int) {
    let date = WorkspaceDate.date(model.selectedDay) ?? Date()
    if let next = WorkdayTimeline.calendar.date(byAdding: .day, value: delta, to: date) {
      model.selectDay(WorkdayDate.day(next))
    }
  }

  private func railButton(_ label: String, _ icon: String, _ area: WorkspaceArea) -> some View {
    Button {
      model.area = area
    } label: {
      Image(systemName: icon).frame(width: 42, height: 40)
        .foregroundStyle(model.area == area ? Palette.accent : Palette.muted)
        .background(
          model.area == area ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: 8))
    }.accessibilityLabel(label).help(label)
      .accessibilityAddTraits(model.area == area ? .isSelected : [])
  }

  @ViewBuilder private var notice: some View {
    if let error = model.error ?? model.sync.error ?? model.usb.issue ?? model.player.error {
      HStack {
        ErrorDetailsButton(message: error)
        if model.sync.error == error, model.sync.failedFile?.sourceID == "manual" {
          Button("重试导入") { model.sync.retry() }
        }
        Spacer()
        Button {
          model.error = nil
          model.sync.clearError()
          model.usb.issue = nil
          model.player.error = nil
        } label: {
          Image(systemName: "xmark")
        }.accessibilityLabel("关闭提示")
      }.buttonStyle(.plain).font(.callout).foregroundStyle(Palette.amber).padding(10)
    }
    if let label = model.importLabel, model.sync.usbLabel == nil {
      HStack {
        Text(label)
        FileTransferRow(transfer: model.sync.transfer)
      }.font(.caption).padding(8)
    }
  }
}
