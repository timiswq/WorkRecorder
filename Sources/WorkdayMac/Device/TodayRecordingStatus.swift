import SwiftUI
import WorkdayCore

struct TodayRecordingStatus: View {
  @ObservedObject var model: AppModel

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let status = model.deviceStatus(at: context.date)
      VStack(alignment: .leading, spacing: 8) {
        if model.dayRecordings.isEmpty {
          Text("今天还没有录音保存到 Mac").font(.title2.weight(.semibold))
        }
        nextStep(status)
      }.frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today-recording-status")
    }
  }

  @ViewBuilder private func nextStep(_ status: DesktopStatus) -> some View {
    switch status.kind {
    case .usb:
      let sync = model.cardSync
      Text(sync.title).font(.callout).foregroundStyle(Palette.muted)
      if let action = sync.action {
        Button(action.rawValue) { model.performCardSync(action) }
      } else if sync.hasSavedOriginals {
        Button("查看原始录音") { model.showOriginals() }
      } else if sync.phase == .unsupported {
        Button("查看未保存录音") { model.area = .device }
      }
    case .idle where model.pendingCount.total > 0:
      Text(model.cardSync.title).font(.callout).foregroundStyle(Palette.muted)
    case .idle:
      Text("在录音卡上按键开始录音。").font(.callout).foregroundStyle(Palette.muted)
    case .disconnected:
      if model.dayRecordings.isEmpty {
        Text("在录音卡上按键录音，结束并保存后，用 USB 连接 Mac 同步。")
          .font(.callout).foregroundStyle(Palette.muted)
        HStack(spacing: 14) {
          if let block = status.bluetoothBlock {
            if block.usesSettings { BluetoothSettingsButton().help(block.instruction) }
          } else {
            Button(model.preferences.boundID == nil ? "绑定录音卡…" : "重新连接") {
              if model.preferences.boundID == nil {
                model.requestSettings(.device)
              } else {
                model.area = .device
                if !model.isolated { model.card.activate(.reconnectBound) }
              }
            }
          }
          if model.recordings.isEmpty {
            Button("导入已有音频…") { model.chooseFiles() }
              .buttonStyle(.link).disabled(model.importLabel != nil)
          }
        }
      }
    default:
      Text(status.instruction).font(.callout).foregroundStyle(Palette.muted)
    }
  }
}
