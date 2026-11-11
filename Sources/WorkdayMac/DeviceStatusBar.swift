import SwiftUI
import WorkdayCore

/// Device and sync status stay visible while reviewing any date.
struct DeviceStatusBar: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let status = DesktopStatus.resolve(
          card: model.card.state, connection: model.card.connectionPhase,
          usbConnected: !model.usb.volumes.isEmpty, importLabel: model.sync.usbLabel,
          transcriptionFailed: model.live.phase == .failed, now: context.date)
        HStack(spacing: 10) {
          Image(systemName: "waveform").foregroundStyle(
            status.kind == .recording ? Palette.red : Palette.accent)
          if model.usb.volumes.isEmpty, model.card.state.connected {
            Text("蓝牙已连接").foregroundStyle(.secondary)
          }
          Text(status.kind == .disconnected ? "蓝牙未连接" : status.title).fontWeight(.medium)
          if model.usb.volumes.isEmpty, model.card.state.phase != .idle,
            let seconds = model.card.state.seconds
          {
            Text(
              (model.card.state.isFresh(at: context.date) ? "" : "上次时长 ")
                + WorkdayDate.clock(seconds)
            ).monospacedDigit()
              .help(model.card.state.isFresh(at: context.date) ? "设备已录时长" : "最后确认的设备时长")
          }
          if model.card.state.isFresh(at: context.date), let battery = model.card.state.battery {
            Label("\(battery)%", systemImage: "battery.75percent").foregroundStyle(Palette.muted)
          }
          Spacer(minLength: 8)
          if [.disconnected, .connecting, .unknown].contains(status.kind) {
            Button(model.card.scanning ? "蓝牙连接中…" : "连接蓝牙") {
              if model.preferences.boundID == nil {
                model.requestSettings(.device)
              } else if !model.isolated {
                model.card.activate()
              }
            }.disabled(model.card.scanning || model.demo)
          }
        }
        .font(.system(size: 12)).controlSize(.small).padding(.horizontal, 20).padding(.vertical, 8)
        .help(status.detail)
      }
      SyncStatusView(model: model)
      Divider().overlay(Palette.line)
    }
  }
}
