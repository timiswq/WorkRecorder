import SwiftUI
import WorkdayCore

struct OriginalRecordingRow: View {
  @ObservedObject var model: AppModel
  let recording: Recording
  let open: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        Button(action: open) {
          VStack(alignment: .leading, spacing: 7) {
            Text(recording.originalName).font(.system(size: 13, weight: .medium)).lineLimit(1)
              .help(recording.originalName)
            Text(
              humanDuration(recording.duration)
            )
            .font(.system(size: 12)).foregroundStyle(Palette.muted)
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("查看原录音，" + recording.originalName)
        Button {
          model.playOriginal(recording)
        } label: {
          Image(systemName: "play.circle.fill").font(.system(size: 25))
        }
        .buttonStyle(.plain).foregroundStyle(Palette.accent).accessibilityLabel(
          "播放完整录音，" + recording.originalName)
      }
      RecordingRetryButton(model: model, recording: recording)
      let state = model.recordingProcessingState(recording)
      if let error = model.documents[recording.id]?.error, state == .failed || state == .needsSetup {
        ErrorDetailsButton(message: error, context: "录音：\(recording.originalName)")
      }
    }.padding(13).background(
      model.area == .originals && model.libraryRecordingID == recording.id
        ? Palette.selected : Palette.surface,
      in: RoundedRectangle(cornerRadius: 8)
    )
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
  }
}

struct RecordingRetryButton: View {
  @ObservedObject var model: AppModel
  let recording: Recording
  var inMenu = false

  var body: some View {
    let state = model.recordingProcessingState(recording)
    if state != .complete {
      if inMenu {
        if let title = state.actionTitle { Button(title) { perform(state) } }
        else { Text(state.message) }
      } else {
        ProcessingStatusView(message: state.message, kind: state.kind, actionTitle: state.actionTitle) {
          perform(state)
        }
      }
    }
  }

  private func perform(_ state: RecordingProcessingState) {
    if state == .needsSetup { model.requestSettings(.recognition) }
    else { model.retryProcessing(scope: .recording(recording.id)) }
  }
}

struct RecordingLibraryView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    let recordings = model.visibleOriginals
    VStack(spacing: 0) {
      WorkspacePageHeader(
        title: "原始录音",
        subtitle: model.originalsDay.map {
          WorkspaceDate.heading($0, full: true) + " · \(recordings.count) 份"
        } ?? "Mac 资料库 · \(recordings.count) 份"
      ) {
        HStack(spacing: 12) {
          if let day = model.originalsDay {
            Button("全天事项") { model.selectDay(day) }
            Button("显示全部") { model.showOriginals() }
          }
          Button("导入音频…") { model.chooseFiles() }.disabled(model.importLabel != nil)
        }.buttonStyle(.bordered).controlSize(.small).font(.callout)
      }
      Divider()
      GeometryReader { geometry in
        let selected = model.libraryRecordingID
        let wide = geometry.size.width >= 810
        if wide, let selected {
          WorkspaceSplitView(minimumLeading: 280) {
            recordingList(recordings).frame(minWidth: 280, idealWidth: 380, maxWidth: .infinity)
          } trailing: {
            recordingDetail(selected, compact: false).frame(
              minWidth: 320, idealWidth: 450, maxWidth: .infinity)
          }
        } else if let selected {
          recordingDetail(selected, compact: true)
        } else {
          recordingList(recordings)
        }
      }
    }
  }

  private func recordingList(_ recordings: [Recording]) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 10) {
        if model.originalsDay == nil { PendingOriginalsView(model: model) }
        Text("已保存到 Mac · \(recordings.count) 份").font(.headline).padding(.bottom, 4)
        if recordings.isEmpty {
          Text(model.originalsDay == nil ? "Mac 上还没有录音" : "这一天没有本地原件")
            .foregroundStyle(Palette.muted)
        }
        ForEach(recordings) { recording in
          if model.originalsDay == nil {
            Text(recording.day).font(.caption).foregroundStyle(Palette.muted)
          }
          OriginalRecordingRow(model: model, recording: recording) {
            model.libraryRecordingID = recording.id
          }
        }
      }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func recordingDetail(_ id: String, compact: Bool) -> some View {
    RecordDetailView(
      model: model, compact: compact, originalID: id,
      onClose: { model.libraryRecordingID = nil }
    ).id(id)
  }

}

struct RecordingCardView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var desktop: DesktopCompanion
  @State private var showsDeviceDetails = false

  init(model: AppModel) {
    self.model = model
    desktop = model.desktop
  }

  var body: some View {
    let presentation = model.statusPresentation(at: Date())
    let status = presentation.hardware
    VStack(spacing: 0) {
      WorkspacePageHeader(title: "录音卡", subtitle: "连接与原件归档")
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          if status.isUSB { SyncStatusView(model: model) }
          VStack(alignment: .leading, spacing: 10) {
            Label(
              status.isUSB ? "USB 连接与实时字幕" : status.title,
              systemImage: StatusStyle.symbol(status.kind)
            )
            .font(.title3.weight(.semibold)).foregroundStyle(StatusStyle.color(status))
            if status.isUSB {
              Text(status.detail).font(.callout)
            } else if let elapsed = status.elapsed {
              Text("已录 " + WorkdayDate.clock(elapsed)).font(.title2.monospacedDigit())
            } else if status.kind == .recording || status.kind == .paused {
              Text("时长暂未更新").font(.callout).foregroundStyle(Palette.muted)
            }
            Text(status.instruction).font(.callout).foregroundStyle(Palette.muted)
              .fixedSize(horizontal: false, vertical: true)
            if let action = presentation.hardwareAction {
              Button(action.title) { model.performStatusAction(action) }.buttonStyle(
                .borderedProminent)
            }
          }
          if !status.isUSB { SyncStatusView(model: model) }
          Divider()
          AppActivityList(model: model, desktop: desktop, includesSync: false)
          Divider()
          DisclosureGroup("设备与连接详情", isExpanded: $showsDeviceDetails) {
            VStack(alignment: .leading, spacing: 14) {
              Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                detail(
                  "蓝牙绑定", model.preferences.boundID == nil ? "尚未绑定" : model.preferences.boundName)
                if !model.usb.volumes.isEmpty {
                  detail("USB 磁盘", model.usb.volumes.map(\.name).joined(separator: "、"))
                } else if model.card.state.connected {
                  if let battery = status.battery {
                    detail("电量", model.card.state.charging ? "充电中" : "\(battery)%")
                  }
                  if let firmware = model.card.state.firmware, !firmware.isEmpty {
                    detail("固件版本", firmware)
                  }
                  if let free = model.card.state.freeBytes, let total = model.card.state.totalBytes
                  {
                    detail("卡内空间", "可用 " + bytes(free) + " / 共 " + bytes(total))
                  }
                }
                if status.kind == .disconnected || status.kind == .unknown {
                  detail("状态确认", status.detail)
                }
              }
              HStack(spacing: 14) {
                Button("设备设置…") { model.requestSettings(.device) }
                if let volume = model.usb.volumes.first {
                  Button("在访达中查看磁盘") { NSWorkspace.shared.open(volume.url) }
                }
              }
            }.font(.callout).padding(.top, 10)
          }.font(.callout)
        }.padding(24).frame(maxWidth: 880, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func detail(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(Palette.muted)
      Text(value).textSelection(.enabled)
    }
  }

  private func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
  }
}

struct BluetoothSettingsButton: View {
  var beforeOpening: () -> Void = {}

  var body: some View {
    Button("打开系统设置…") {
      if let url = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.apple.systempreferences")
      {
        beforeOpening()
        NSWorkspace.shared.open(url)
      }
    }
  }
}
