import SwiftUI
import WorkdayCore

struct RecordingCardView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var desktop: DesktopCompanion
  @State private var showsTechnicalInfo = false
  private var capture: DevicePageCapture? { model.isolated ? SceneWindowCapture.devicePage : nil }

  var body: some View {
    let status = desktop.status
    let action = model.hardwareAction(for: status) ?? (status.canConnect ? .bind : nil)
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        header(status, showSwitch: action != .bind || model.recorderName != nil)
        if model.recorderName != nil && model.card.switchingTo == nil {
          metrics
        }
        syncContent(status, action: action)
        if model.recorderName != nil && model.card.switchingTo == nil {
          technicalInfo
        }
      }
      .font(.system(size: 13))
      .frame(maxWidth: capture?.width ?? .infinity, alignment: .leading)
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
        if capture != nil { SceneWindowCapture.deviceContentWidth = width }
      }
      .padding(.horizontal, 26).padding(.vertical, 24)
      .frame(maxWidth: 880, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Palette.surface)
    .task(id: usbBluetoothInventoryID) {
      if let id = usbBluetoothInventoryID { model.card.refreshUSBCardBluetoothInventory(for: id) }
    }
    .onChange(of: deviceIdentity) { _, _ in showsTechnicalInfo = false }
  }

  private var method: DeviceTransferMethod { model.usesWiFiCard ? .wifi : .usb }
  private var deviceIdentity: String? {
    model.preferences.selectedRecorderID ?? model.preferences.usbOnlyVolumeID
  }
  private var volume: USBVolume? { model.usesWiFiCard ? nil : model.usb.volumes.first }
  private var hasLiveBluetoothState: Bool {
    model.card.switchingTo == nil && model.card.state.connected
      && (capture?.bluetoothID ?? model.card.stateDeviceID)
        .map { $0 == model.preferences.selectedRecorderID } == true
  }
  private var activeTransfer: DeviceSyncTransfer? {
    model.usesWiFiCard ? model.wifiSync.currentTransfer : model.sync.deviceTransfer
  }

  private func liveUSBInventory(_ volume: USBVolume) -> DeviceInventory? {
    guard let inventory = model.usb.inventory, inventory.sourceID == volume.id,
          (0..<12).contains(Date().timeIntervalSince(inventory.observedAt)) else { return nil }
    return inventory
  }

  private func header(_ status: DesktopStatus, showSwitch: Bool) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 16) {
        Text(model.recorderName ?? "录音卡").font(.system(size: 26, weight: .semibold))
          .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
          .accessibilityAddTraits(.isHeader).accessibilityIdentifier("recorder-page-title")
        Spacer(minLength: 0)
        if showSwitch {
          Button(model.recorderName == nil ? "选择设备…" : "切换设备…") { model.showRecorderPicker() }
            .buttonStyle(.link).fixedSize().disabled(!model.canChangeCard || activeTransfer != nil)
            .help(model.canChangeCard ? "选择要连接的录音卡" : "当前操作完成后可切换设备")
        }
      }
      if let state = connectionLabel(status) {
        Text(state).monospacedDigit().foregroundStyle(Palette.muted)
      }
      if let error = model.card.selectionError {
        Text(error).foregroundStyle(Palette.amber)
      }
    }
  }

  private func connectionLabel(_ status: DesktopStatus) -> String? {
    if let target = model.card.switchingTo { return "正在验证 \(target.name) 的连接" }
    if model.recorderName == nil { return nil }
    let connection: String
    if volume != nil {
      connection = "USB 已连接"
    } else if model.usesWiFiCard, let id = model.wifiSync.connectedDeviceID,
              id == model.preferences.wifiBoundID {
      connection = "录音卡热点已连接"
    } else if hasLiveBluetoothState {
      connection = "蓝牙已连接"
    } else if let block = status.bluetoothBlock {
      connection = block.title
    } else if status.kind == .connecting && !model.wifiSync.usingNetwork {
      connection = status.title
    } else if model.usesWiFiCard && [.joining, .listing, .permission].contains(model.wifiSync.phase) {
      connection = "正在连接录音卡热点"
    } else {
      connection = model.preferences.usbOnlyVolumeID == nil ? "蓝牙未连接" : "USB 未连接"
    }
    if let battery = hasLiveBluetoothState ? model.card.state.currentBattery(at: Date()) : nil {
      return connection + " · " + (model.card.state.charging ? "充电中 " : "电量 ") + "\(battery)%"
    }
    return connection
  }

  private var metrics: some View {
    VStack(alignment: .leading, spacing: 5) {
      if activeTransfer == nil {
        DeviceDetailRow("传输方式") { Text(method.rawValue) }
      }
      DeviceDetailRow("卡内空间") { storage }
      DeviceDetailRow("卡内录音") {
        if let id = bluetoothInventoryID {
          BluetoothRecordingCountView(device: id, sync: model.wifiSync)
            .id(id).id(ObjectIdentifier(model.wifiSync))
        } else {
          Text(inventory?.label ?? inventoryHint).monospacedDigit()
        }
      }
    }
  }

  private var bluetoothInventoryID: String? {
    guard model.usesWiFiCard, !model.wifiSync.busy, hasLiveBluetoothState,
          model.card.state.phase == .idle, model.card.state.isFresh() else { return nil }
    return model.preferences.wifiBoundID
  }

  private var usbBluetoothInventoryID: String? {
    guard !model.usesWiFiCard, volume == nil, !model.sync.isBusy, hasLiveBluetoothState,
          model.card.state.phase == .idle, model.card.state.isFresh() else { return nil }
    return model.preferences.boundID
  }

  private var inventoryHint: String {
    if model.usesWiFiCard {
      if model.wifiSync.busy { return "等待读取" }
      if !hasLiveBluetoothState { return "蓝牙连接后读取" }
      if [.recording, .paused, .saving].contains(model.card.state.phase) { return "录音保存后读取" }
      return "等待设备状态"
    }
    if volume != nil { return "等待读取" }
    if !hasLiveBluetoothState { return "连接后读取" }
    return model.card.state.phase == .idle ? "等待读取" : "等待设备空闲"
  }

  private var inventory: CardRecordingCount? {
    if model.usesWiFiCard {
      guard model.wifiSync.deviceID == model.preferences.wifiBoundID, model.wifiSync.busy else { return nil }
      if hasLiveBluetoothState && [.recording, .paused, .saving].contains(model.card.state.phase) { return nil }
      return model.wifiSync.deviceInventory
    }
    let snapshot: DeviceInventory?
    if let volume {
      snapshot = liveUSBInventory(volume)
    } else if hasLiveBluetoothState, let source = model.boundSource, model.card.state.isFresh(),
              model.card.state.phase == .idle {
      snapshot = model.catalog.snapshots[source].flatMap {
        Date().timeIntervalSince($0.observedAt) < 65 ? $0 : nil
      }
    } else {
      snapshot = nil
    }
    guard let snapshot else { return nil }
    var pending: Int?
    if snapshot.complete && !model.usb.needsSaveConfirmation {
      let linked = model.catalog.bindings[snapshot.sourceID].map { Set([$0]) } ?? []
      pending = snapshot.pendingEntries(recordings: model.recordings, linkedSources: linked,
                                        activeName: nil).count
    }
    return .init(discovered: Set(snapshot.entries.map(\.stem)).count, complete: snapshot.complete,
                 pending: pending)
  }

  @ViewBuilder private var storage: some View {
    let space = volume == nil ? nil : (capture?.diskSpace ?? model.usb.diskSpace)
    let state = model.card.state
    if let space {
      storageReadout(free: space.free, total: space.total)
    } else if hasLiveBluetoothState {
      if let free = state.freeBytes, let total = state.totalBytes,
         total > 0, (0...total).contains(free) {
        storageReadout(free: free, total: total)
      } else if let fraction = state.freeStorageFraction, (0...1).contains(fraction) {
        Text(Self.availableSpace(fraction)).monospacedDigit()
      } else {
        Text("暂无读数").foregroundStyle(Palette.muted)
      }
    } else {
      Text("暂无读数").foregroundStyle(Palette.muted)
    }
  }

  private func storageReadout(free: Int64, total: Int64) -> some View {
    let usedBytes = total - free
    let used = Double(usedBytes) / Double(total)
    let percent = used.formatted(.percent.precision(.fractionLength(used < 0.01 || used > 0.99 ? 0...1 : 0...0)))
    let usage = if used > 0 && used < 0.001 { "已用不足 0.1%" }
      else if used > 0.999 && used < 1 { "已用超过 99.9%" }
      else { "已用 \(percent)" }
    let label = Text(usage).monospacedDigit().foregroundStyle(Palette.muted)
    let capacity = Text("总容量 \(storageSize(total))")
    let occupied = Text("已用 \(storageSize(usedBytes))")
    let remaining = Text("剩余 \(storageSize(free))")
    return VStack(alignment: .leading, spacing: 6) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 14) {
          capacity
          occupied
          remaining
        }.fixedSize()
        VStack(alignment: .leading, spacing: 4) {
          capacity
          occupied
          remaining
        }
      }.monospacedDigit()
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          DeviceMeterTrack(fraction: used, height: 4).frame(width: 200).accessibilityHidden(true)
          label.fixedSize()
        }
        VStack(alignment: .leading, spacing: 4) {
          DeviceMeterTrack(fraction: used, height: 4).frame(maxWidth: 200).accessibilityHidden(true)
          label
        }
      }
    }
  }

  private func storageSize(_ bytes: Int64) -> String {
    // Preserve the card's 1 MB resolution even when total and free both read in GB.
    if bytes >= 1_000_000_000 {
      let gb = Double(bytes) / 1_000_000_000
      return gb.formatted(.number.precision(.fractionLength(0...3))) + " GB"
    }
    if bytes >= 1_000_000 {
      let mb = Double(bytes) / 1_000_000
      return mb.formatted(.number.precision(.fractionLength(0...3))) + " MB"
    }
    return ByteCountFormatStyle(style: .file, allowedUnits: [.mb, .kb, .bytes],
                                spellsOutZero: false).format(bytes)
  }

  private var technicalInfo: some View {
    DisclosureGroup("技术信息", isExpanded: capture?.expandsTechnicalInfo == true
      ? .constant(true) : $showsTechnicalInfo) {
      VStack(alignment: .leading, spacing: 6) {
        if hasLiveBluetoothState, let firmware = model.card.state.firmware, !firmware.isEmpty {
          technicalRow("固件版本", firmware)
        }
        if hasLiveBluetoothState, let serial = model.card.serial, !serial.isEmpty {
          technicalRow("序列号", serial)
        }
        if let id = model.preferences.selectedRecorderID { technicalRow("蓝牙标识", id) }
        if let disk = capture?.diskIdentifier ?? volume?.uuid
          ?? model.selectedUSBSource.map({ String($0.dropFirst("usb:".count)) }) {
          technicalRow("磁盘标识", disk)
        }
        HStack(spacing: 12) {
          Button("设备设置…") { model.requestSettings(.device) }
          if let volume {
            Button("在访达中查看磁盘") {
              guard model.usb.volumes.first == volume, volume.isMounted else { return }
              NSWorkspace.shared.open(volume.url)
            }
          }
        }.padding(.top, 4)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
    }
  }

  private func technicalRow(_ label: String, _ value: String) -> some View {
    DeviceDetailRow(label) {
      Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
  }

  private static func availableSpace(_ fraction: Double) -> String {
    if fraction > 0 && fraction < 0.001 { return "可用不足 0.1%" }
    if fraction > 0.999 && fraction < 1 { return "可用超过 99.9%" }
    return "可用 " + fraction.formatted(.percent.precision(.fractionLength(0...1)))
  }

  @ViewBuilder private func syncContent(_ status: DesktopStatus, action: StatusAction?) -> some View {
    if model.usesWiFiCard && model.wifiSync.busy {
      wifiOperation
    } else if let volume {
      usbOperation(volume)
    } else {
      recordingStatus(status, action: action)
      if model.usesWiFiCard { wifiResult }
    }
  }

  private var wifiOperation: some View {
    let sync = model.wifiSync
    let transfer = activeTransfer
    let verifying = transfer?.stageIsVerifying == true
    let title = if verifying { "正在校验下载文件" }
      else if transfer != nil { "正在同步录音" }
      else if sync.phase == .archiving { "正在将录音归档到 Mac" }
      else { sync.message }
    return DeviceSyncSection(
      title: title,
      method: .wifi, transfer: transfer, showsSpinner: verifying || transfer == nil
    ) {
      if sync.phase == .cleaning, let saved = sync.outcome.saved {
        Text("已保存到 Mac \(saved) 段").foregroundStyle(Palette.muted).monospacedDigit()
      }
      if sync.phase != .archiving && sync.phase != .restoring {
        Button("取消") { sync.cancel() }.buttonStyle(.bordered)
      }
    }
  }

  private func usbOperation(_ source: USBVolume) -> some View {
    let current = model.cardSync
    let reading = liveUSBInventory(source) == nil && current.action != .confirm
      && [.waiting, .empty, .preparing, .saved, .unsupported].contains(current.phase)
    let state: CardSyncPresentation = reading
      ? .init(title: "正在读取录音卡", instruction: "正在核对卡内录音和 Mac 上的原件，无需重复操作。", phase: .reading)
      : current
    let transfer = activeTransfer
    let run = model.sync.deviceRun
    let verifying = transfer?.stageIsVerifying == true
    let settled = !state.isWorking
    let showSaved = settled && (run.saved > 0 || run.deleted > 0
      || (!run.positions.isEmpty && state.phase == .saved))
    let title = if verifying { "正在校验 Mac 原件" }
      else if transfer != nil { "正在同步录音" }
      else if showSaved { "已保存到 Mac \(run.saved) 段" }
      else { state.title }
    let hint = if transfer != nil { "请保持 USB 连接。" }
      else if showSaved && (state.phase == .saved || state.phase == .cleanupFailed) { nil as String? }
      else { state.instruction }
    return DeviceSyncSection(title: title, method: .usb, transfer: transfer, hint: hint,
                             showsSpinner: verifying || (state.isWorking && transfer == nil)) {
      if showSaved {
        DeviceSyncResultLines(result: usbOutcome(state, run: run))
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) { usbActions(state, source: source, showSaved: showSaved) }
        VStack(alignment: .leading, spacing: 8) { usbActions(state, source: source, showSaved: showSaved) }
      }
      Text("USB 连接期间实时字幕暂停，录音状态请查看卡上指示。")
        .foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func usbOutcome(_ state: CardSyncPresentation, run: USBRecordingRun) -> DeviceSyncOutcome {
    var result = DeviceSyncOutcome(saved: run.saved)
    if run.deleted > 0 { result.addCopies("已删除 \(run.deleted) 段卡内副本。") }
    if state.phase == .cleanupFailed { result.addCopies("卡内副本待清理。") }
    else if !model.preferences.cleanCardAfterSync && run.saved > 0 && run.deleted == 0 {
      result.addCopies("卡内副本已保留。")
    }
    return result
  }

  @ViewBuilder private func usbActions(_ state: CardSyncPresentation, source: USBVolume, showSaved: Bool) -> some View {
    if let action = state.action, action != .start || activeTransfer == nil {
      DevicePagePrimaryButton(action.rawValue) {
        guard model.usb.volumes.first == source else { return }
        model.performCardSync(action)
      }.accessibilityIdentifier("card-sync-action")
    }
    if state.hasSavedOriginals || showSaved {
      if state.action == nil {
        DevicePagePrimaryButton("查看原始录音") { model.showOriginals() }
      } else if showSaved {
        Button("查看原始录音") { model.showOriginals() }.buttonStyle(.bordered)
      }
    }
    CardSyncDetailsButton(model: model)
  }

  @ViewBuilder private var wifiResult: some View {
    let sync = model.wifiSync
    let sameCard = sync.deviceID != nil && sync.deviceID == model.preferences.wifiBoundID
    let result = sameCard ? sync.outcome : DeviceSyncOutcome()
    let retryCleanup = sameCard && sync.pendingCleanup > 0 && model.preferences.cleanCardAfterSync
    if result.saved != nil || result.copies != nil || result.notice != nil
      || sync.failedImports > 0 || retryCleanup {
      DeviceSyncSection(title: result.saved.map { "已保存到 Mac \($0) 段" } ?? "同步结果", method: .wifi) {
        DeviceSyncResultLines(result: result)
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) {
            wifiResultActions(result, retryCleanup: retryCleanup, sameCard: sameCard)
          }
          VStack(alignment: .leading, spacing: 8) {
            wifiResultActions(result, retryCleanup: retryCleanup, sameCard: sameCard)
          }
        }
      }
    }
  }

  @ViewBuilder private func wifiResultActions(_ result: DeviceSyncOutcome, retryCleanup: Bool,
                                              sameCard: Bool) -> some View {
    if model.wifiSync.failedImports > 0 {
      DevicePagePrimaryButton("重试本地归档") { model.wifiSync.retryLocal(for: model.preferences.wifiBoundID) }
    }
    if retryCleanup {
      let target = model.recorderSyncTarget
      Button("重试清理卡内副本") { model.syncRecorder(target) }.buttonStyle(.bordered)
        .disabled(target == nil || !model.canUseWiFiSync)
    }
    if (result.saved ?? 0) > 0 { Button("查看原始录音") { model.showOriginals() } }
    if sameCard {
      WiFiSettingsButton()
    }
  }

  private func recordingStatus(_ status: DesktopStatus, action: StatusAction?) -> some View {
    let title = status.canConnect ? "未连接" : status.kind == .idle ? "空闲" : status.displayTitle
    return VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: StatusStyle.symbol(status.kind)).font(.system(size: 15))
          .foregroundStyle(StatusStyle.color(status)).accessibilityHidden(true)
        Text(title).font(.system(size: 18, weight: .semibold)).accessibilityAddTraits(.isHeader)
        if let elapsed = status.elapsed {
          Text(WorkdayDate.clock(elapsed)).monospacedDigit().foregroundStyle(Palette.muted)
            .accessibilityLabel("已录 " + WorkdayDate.clock(elapsed))
        }
      }
      Text(instruction(status)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
      if hasLiveBluetoothState, [.recording, .paused, .saving].contains(status.kind),
         let name = model.card.state.filename, !name.isEmpty {
        DeviceDetailRow("当前文件") { Text(name).textSelection(.enabled) }
      }
      if status.kind == .idle && model.usesWiFiCard {
        let target = model.recorderSyncTarget
        DevicePagePrimaryButton("同步录音") { model.syncRecorder(target) }
          .disabled(!model.canUseWiFiSync || target == nil)
          .accessibilityIdentifier("wifi-sync-recordings")
      } else if let action {
        DevicePagePrimaryButton(action.title) { model.performStatusAction(action) }
          .disabled(action == .bind && !model.canChangeCard)
          .accessibilityIdentifier("recorder-page-action")
      }
    }
  }

  private func instruction(_ status: DesktopStatus) -> String {
    switch status.kind {
    case .recording: return "在卡上按键暂停或结束录音，保存后可同步。"
    case .idle where model.usesWiFiCard:
      return "同步时 Mac 会临时加入设备热点，当前 Wi-Fi 可能短暂中断。"
    case .idle:
      return "在卡上按键开始录音。用 USB 数据线连接 Mac，可同步已保存的录音。"
    case .disconnected where model.preferences.usbOnlyVolumeID != nil:
      return "用 USB 数据线将这张录音卡连接到 Mac。"
    case .disconnected where status.canConnect && model.recorderName == nil:
      return "选择附近的录音卡，或用 USB 数据线连接设备。"
    default: return status.instruction
    }
  }
}

private struct DeviceDetailRow<Value: View>: View {
  let label: String
  let value: Value

  init(_ label: String, @ViewBuilder value: () -> Value) {
    self.label = label
    self.value = value()
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      Text(label).foregroundStyle(Palette.muted).frame(width: 84, alignment: .leading)
      value.frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minHeight: 24, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

private struct BluetoothRecordingCountView: View {
  let device: String
  let sync: WiFiRecordingSync
  @State private var result: Result<CardRecordingCount, Error>?
  @State private var total: Int?
  @State private var attempt = 0

  var body: some View {
    Group {
      switch result {
      case .none:
        Text(total.map { "共 \($0) 段 · 正在核对待同步数量…" } ?? "正在读取…").monospacedDigit()
      case .success(let count):
        Text(count.label).monospacedDigit()
      case .failure(let error):
        HStack(spacing: 8) {
          Text(total.map { "共 \($0) 段 · 待同步数未知" } ?? "暂未读到").help(error.localizedDescription)
          Button("重试") { attempt += 1 }.buttonStyle(.link)
        }
      }
    }
    .task(id: attempt) {
      result = nil
      total = nil
      do {
        let count = try await sync.bluetoothRecordingCount(for: device) { total = $0 }
        try Task.checkCancellation()
        result = .success(count)
      } catch {
        if !Task.isCancelled { result = .failure(error) }
      }
    }
  }
}
