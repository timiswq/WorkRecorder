import SwiftUI

struct WiFiSyncControls: View {
  @ObservedObject var model: AppModel
  var compact = false

  var body: some View {
    let sync = model.wifiSync
    let target = model.recorderSyncTarget
    let start = Button("同步录音") { model.syncRecorder(target) }
      .disabled(!model.canUseWiFiSync || target == nil)
      .accessibilityIdentifier("wifi-sync-recordings")
    VStack(alignment: .leading, spacing: 6) {
      if sync.busy {
        HStack {
          ProgressView().controlSize(.small)
          Text(sync.message)
          if sync.phase != .archiving && sync.phase != .restoring {
            Button("取消") { sync.cancel() }
          }
        }
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
    if sync.pendingCleanup > 0 && !sync.busy && model.preferences.cleanCardAfterSync {
      let target = model.recorderSyncTarget
      Button("重试清理卡内副本") { model.syncRecorder(target) }
        .disabled(target == nil || !model.canUseWiFiSync)
    }
    if showSettings && !sync.busy && !sync.result.isEmpty {
      WiFiSettingsButton()
    }
  }
}

struct WiFiSettingsButton: View {
  var body: some View {
    Button("Wi-Fi 设置…") {
      if let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") {
        NSWorkspace.shared.open(url)
      }
    }.buttonStyle(.link)
  }
}
