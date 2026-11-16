import SwiftUI

struct WiFiSyncControls: View {
  @ObservedObject var model: AppModel
  var compact = false

  var body: some View {
    let sync = model.wifiSync
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        if sync.busy { ProgressView().controlSize(.small) }
        Button(sync.busy ? sync.message : "同步录音") { model.startWiFiSync() }
          .disabled(model.isolated || sync.busy)
          .accessibilityIdentifier("wifi-sync-recordings")
        if sync.busy && sync.phase != .archiving && sync.phase != .restoring {
          Button("取消") { sync.cancel() }
        }
      }
      if !sync.result.isEmpty { Text(sync.result).font(.callout).textSelection(.enabled) }
      if sync.failedImports > 0 { Button("重试本地归档") { sync.retryLocal() }.disabled(sync.busy) }
      if !sync.busy { Text("同步时 Mac 会临时连接录音卡热点。").font(.caption).foregroundStyle(.secondary) }
      if !compact && !sync.busy && !sync.result.isEmpty {
        Button("Wi-Fi 设置…") {
          if let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") {
            NSWorkspace.shared.open(url)
          }
        }.buttonStyle(.link)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
