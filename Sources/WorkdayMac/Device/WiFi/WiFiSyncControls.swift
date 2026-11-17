import SwiftUI

struct WiFiSyncControls: View {
  @ObservedObject var model: AppModel
  var compact = false
  var onDevicePage = false

  var body: some View {
    let sync = model.wifiSync
    let target = model.recorderSyncTarget
    let start = Button("同步录音") { model.syncRecorder(target) }
      .disabled(!model.canUseWiFiSync || target == nil)
      .accessibilityIdentifier("wifi-sync-recordings")
    VStack(alignment: .leading, spacing: onDevicePage ? 10 : 6) {
      if sync.busy {
        HStack {
          ProgressView().controlSize(.small)
          Text(sync.message)
          if sync.phase != .archiving && sync.phase != .restoring {
            Button("取消") { sync.cancel() }
          }
        }
      } else if onDevicePage {
        Text("同步时 Mac 会临时加入设备热点，当前 Wi-Fi 可能短暂中断。")
          .font(.callout).foregroundStyle(Palette.muted)
        start.buttonStyle(.borderedProminent).controlSize(.large)
      } else {
        start
        Text("同步时 Mac 会临时加入\(model.recorderName.map { "「\($0)」" } ?? "录音卡")的热点，无线网络可能短暂中断。")
          .font(.caption).foregroundStyle(.secondary)
      }
      WiFiSyncResult(model: model, showSettings: !compact)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct WiFiSyncResult: View {
  @ObservedObject var model: AppModel
  var showSettings = true

  var body: some View {
    let sync = model.wifiSync
    if !sync.result.isEmpty { Text(sync.result).font(.callout).textSelection(.enabled) }
    if sync.failedImports > 0 { Button("重试本地归档") { sync.retryLocal() }.disabled(sync.busy) }
    if showSettings && !sync.busy && !sync.result.isEmpty {
      Button("Wi-Fi 设置…") {
        if let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") {
          NSWorkspace.shared.open(url)
        }
      }.buttonStyle(.link)
    }
  }
}
