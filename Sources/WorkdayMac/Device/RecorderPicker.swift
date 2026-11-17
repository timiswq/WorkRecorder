import SwiftUI

struct RecorderPicker: View {
  @ObservedObject var model: AppModel
  @StateObject private var discovery = RecorderDiscovery()
  @Environment(\.dismiss) private var dismiss
  @State private var showsOtherDevices = false
  @State private var selectionIssue: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("选择录音卡").font(.title2.weight(.semibold))
      if let name = model.recorderName {
        let status = model.deviceStatus(at: Date())
        let id = model.preferences.selectedRecorderID
        let duplicates = discovery.choices.contains { $0.name == name && $0.id.uuidString != id }
        HStack(spacing: 8) {
          Text("当前设备").foregroundStyle(.secondary)
          Text(name + (duplicates ? id.map { " · " + $0.suffix(6) } ?? "" : "")).fontWeight(.medium)
          Spacer(minLength: 8)
          Text(status.displayTitle).foregroundStyle(.secondary)
        }.lineLimit(2)
      }
      if model.card.state.connected && model.card.state.phase == .recording {
        Text("切换会中断当前卡在 Mac 上的实时字幕，机身将继续录音。")
          .font(.callout).foregroundStyle(.secondary)
      }
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(discovery.choices.filter { knownKind($0) != nil }) { choice in
            bluetoothRow(choice)
          }
          ForEach(model.usb.detectedVolumes, id: \.url) { volume in
            let duplicateIDs = model.usb.detectedVolumes.filter { $0.id == volume.id }.count > 1
            let duplicates = model.usb.detectedVolumes.filter { $0.name == volume.name }.count > 1
            let detail = duplicateIDs ? "磁盘标识重复，请只保留一个连接" :
              duplicates ? "USB · \(volume.url.path)" : "USB"
            choiceRow(name: volume.name, detail: detail, current: model.usb.volumes.contains(volume)) {
              if model.chooseRecorder(volume) { dismiss() }
              else { selectionIssue = "无法使用这个磁盘，请检查连接并重新选择。" }
            }.disabled(duplicateIDs)
          }
          let others = discovery.choices.filter { knownKind($0) == nil }
          if !others.isEmpty {
            DisclosureGroup("其他蓝牙设备", isExpanded: $showsOtherDevices) {
              ForEach(others) { choice in bluetoothRow(choice) }
            }
          }
          HStack {
            Text(discovery.message).font(.caption).foregroundStyle(.secondary)
            if discovery.canRescan { Button("重新寻找") { discovery.start() } }
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      if let selectionIssue { Text(selectionIssue).font(.callout).foregroundStyle(Palette.amber) }
      if !model.canChangeCard {
        Text(model.card.switchingTo == nil ? "同步完成后可以切换录音卡。" : "正在连接所选设备。")
          .font(.callout)
      }
      HStack {
        Spacer()
        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }.padding(20).frame(width: 420, height: 350)
      .background(Palette.surface)
      .onAppear { if !model.isolated { discovery.start() } }
      .onDisappear { discovery.stop() }
  }

  private func knownKind(_ choice: CardChoice) -> RecorderKind? {
    if choice.id.uuidString == model.preferences.wifiBoundID { return .wifi }
    if choice.id.uuidString == model.preferences.boundID { return .usb }
    return choice.kind
  }

  private func bluetoothRow(_ choice: CardChoice) -> some View {
    let repeated = discovery.choices.contains { $0.id != choice.id && $0.name == choice.name }
      || (model.preferences.selectedRecorderID != choice.id.uuidString && model.recorderName == choice.name)
    let detail = (knownKind(choice)?.label ?? "蓝牙 · 连接时验证") + (repeated ? " · \(choice.id.uuidString.suffix(6))" : "")
    let current = model.card.state.connected && model.preferences.selectedRecorderID == choice.id.uuidString
    return choiceRow(name: choice.name, detail: detail, current: current) {
      if model.chooseRecorder(choice) { dismiss() }
      else { selectionIssue = model.card.selectionError ?? "当前无法切换录音卡。" }
    }
  }

  private func choiceRow(name: String, detail: String, current: Bool, action: @escaping () -> Void) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(name).fontWeight(.medium)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if current { Label("使用中", systemImage: "checkmark") }
      else { Button("使用") { action() }.disabled(!model.canChangeCard).accessibilityLabel("使用 \(name)，\(detail)") }
    }
  }
}
