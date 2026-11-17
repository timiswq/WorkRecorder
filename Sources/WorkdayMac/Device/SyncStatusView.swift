import SwiftUI
import WorkdayCore

struct CardSyncPresentation {
  enum Action: String {
    case start = "立即同步"
    case retry = "重试同步"
    case retryCleanup = "重试删除卡内副本"
    case confirm = "已在卡上保存，重新检查"
  }

  enum Phase { case waiting, reading, preparing, copying, verifying, cleaning, saved, empty, unsupported, failed, cleanupFailed }

  let title: String
  let instruction: String
  var action: Action?
  var phase: Phase = .waiting
  var hasSavedOriginals: Bool { [.saved, .cleaning, .cleanupFailed].contains(phase) }
  var isWorking: Bool { [.reading, .preparing, .copying, .verifying, .cleaning].contains(phase) }
}

extension AppModel {
  var cardSyncFailure: CardSyncPresentation? {
    guard !usb.volumes.isEmpty else { return nil }
    if let error = sync.error {
      if let file = sync.failedFile {
        if usb.volumes.contains(where: { $0.id == file.sourceID }) {
          return .init(title: sync.cleanupFailed ? "原件已保存，卡内副本未删除" : "部分录音尚未保存到 Mac",
                       instruction: sync.cleanupFailed
                         ? "\(file.name) 的 Mac 原件可查看和回听；删除卡内副本时遇到问题。"
                         : "\(file.name) 保存失败；已成功保存的其他原件仍可查看。",
                       action: sync.cleanupFailed ? .retryCleanup : .retry,
                       phase: sync.cleanupFailed ? .cleanupFailed : .failed)
        }
      } else {
        return .init(title: "同步记录保存失败", instruction: error, action: .retry, phase: .failed)
      }
    }
    if usb.issue != nil {
      return .init(title: "无法读取卡内录音", instruction: "请检查 USB 连接后重试；已保存到 Mac 的原件仍可查看。", action: .retry, phase: .failed)
    }
    return nil
  }

  var cardSync: CardSyncPresentation {
    if !usb.volumes.isEmpty, usb.needsSaveConfirmation {
      return .init(title: "请先在卡上结束并保存录音", instruction: "接线前的那段录音尚未确认保存；确认后会重新检查文件。", action: .confirm)
    }
    if let file = sync.cleaningFile, usb.volumes.contains(where: { $0.id == file.sourceID }) {
      return .init(title: "原件已保存，正在核对卡内副本", instruction: "核对一致后删除 \(file.name) 的卡内副本。请保持 USB 连接。", phase: .cleaning)
    }
    if let file = sync.activeFile, usb.volumes.contains(where: { $0.id == file.sourceID }) {
      let verifying = sync.transfer?.phase == .verifying
      return .init(title: verifying ? "正在校验 Mac 原件" : "正在保存录音到 Mac",
                   instruction: "\(file.name) · 请保持 USB 连接。", phase: verifying ? .verifying : .copying)
    }
    if let failure = cardSyncFailure { return failure }
    let automatic = preferences.autoSync
    let inventories = currentInventories
    let count = pendingCount
    let complete = !inventories.isEmpty && inventories.allSatisfy(\.complete)
    let prefix = (inventoryIsFresh ? "" : "上次发现") + (complete ? "" : "至少")
    let pending = "\(prefix)\(count.total) 段待同步"

    if usb.volumes.isEmpty {
      if !usb.detectedVolumes.isEmpty, !card.state.connected {
        return .init(title: "请选择 USB 录音卡", instruction: "点「选择录音卡」或「切换录音卡」选择要同步的 USB 设备。")
      }
      return .init(
        title: count.total > 0 ? pending + " · 等待 USB 连接" : "等待 USB 连接",
        instruction: automatic
          ? "在卡上结束并保存录音，用 USB 数据线连接 Mac 后会自动同步。"
          : "在卡上结束并保存录音，用 USB 数据线连接 Mac，再点「立即同步」。")
    }
    guard inventories.count == usb.volumes.count, inventoryIsFresh else {
      return .init(title: "正在读取录音卡", instruction: "正在核对卡内录音和 Mac 上的原件，无需重复操作。", phase: .reading)
    }
    if count.total == 0, complete {
      if inventories.allSatisfy({ $0.entries.isEmpty }) {
        let cleared = usb.volumes.reduce(Int64(0)) { $0 + (sync.clearedBytesByVolume[$1.id] ?? 0) }
        if cleared > 0 {
          let space = ByteCountFormatter.string(fromByteCount: cleared, countStyle: .file)
          return .init(title: "原件已保存在 Mac", instruction: "本次已删除卡内副本，释放 \(space)。原始录音可查看和回听。", phase: .saved)
        }
        return .init(title: "卡内暂无已保存的录音", instruction: "这不代表录音已经停止。录音与保存请在卡上操作。", phase: .empty)
      }
      return .init(title: "原件已保存在 Mac", instruction: "原始录音可查看和回听。保持 USB 连接，卡内副本核对一致后会删除。", phase: .saved)
    }
    if count.total > 0, count.total == count.unsupported {
      return .init(title: "\(count.total) 段录音暂未保存到 Mac", instruction: "这些 OPUS 录音缺少配对的 WAV 文件。请保留卡内文件，可在同步详情查看原因。", phase: .unsupported)
    }
    let title = count.total > 0 ? pending : "清单尚未读完"
    if automatic || !manualSyncVolumes.isEmpty {
      return .init(title: title, instruction: "正在等待文件保存稳定，随后逐段复制到 Mac。请保持 USB 连接。", phase: .preparing)
    }
    return .init(title: title, instruction: "自动同步已关闭。点「立即同步」，将录音保存到 Mac。", action: .start)
  }

  func performCardSync(_ action: CardSyncPresentation.Action) {
    guard !usesWiFiCard, card.switchingTo == nil, cardSync.action == action || cardSyncFailure?.action == action else { return }
    switch action {
    case .start, .retry: syncRecorder(recorderSyncTarget)
    case .retryCleanup: sync.retry()
    case .confirm: confirmSavedOnCard()
    }
  }
}

struct SyncStatusView: View {
  @ObservedObject var model: AppModel
  var showsOriginalsAction = true
  var onDevicePage = false
  @State private var showsDetails = false

  @ViewBuilder var body: some View {
    if onDevicePage {
      content
    } else {
      content.padding(18)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.line))
    }
  }

  private var content: some View {
    let state = model.cardSync
    let sourceID = model.usb.volumes.first?.id
    return HStack(alignment: .top, spacing: 12) {
      Group {
        if state.isWorking { ProgressView().controlSize(.small).accessibilityLabel(state.title) }
        else {
          Image(systemName: state.hasSavedOriginals ? "checkmark.circle" : state.action != nil ? "hand.tap" : "cable.connector")
            .font(.system(size: 17, weight: .medium)).foregroundStyle(Palette.muted).accessibilityHidden(true)
        }
      }.frame(width: 32, height: 32)

      VStack(alignment: .leading, spacing: 6) {
        Text("录音保存到 Mac").font(.caption).foregroundStyle(Palette.muted)
        Text(state.title).font(.title3.weight(.semibold))
            .foregroundStyle(
              state.action != nil && state.action != .start ? Palette.amber : Palette.accent)
        Text(state.instruction).font(.callout).foregroundStyle(Palette.text)
          .fixedSize(horizontal: false, vertical: true)
        if model.sync.usbLabel != nil {
          FileTransferRow(transfer: model.sync.transfer)
        }
        HStack(spacing: 14) {
          if let action = state.action {
            Button(action.rawValue) {
              guard let sourceID, model.usb.volumes.first?.id == sourceID else { return }
              model.performCardSync(action)
            }
              .buttonStyle(.borderedProminent).accessibilityIdentifier("card-sync-action")
          } else if state.hasSavedOriginals && showsOriginalsAction {
            Button("查看原始录音") { model.showOriginals() }.buttonStyle(.borderedProminent)
          }
          Button("同步详情") { showsDetails.toggle() }.buttonStyle(.bordered)
            .popover(isPresented: $showsDetails) { details }
        }.padding(.top, 5)
      }
      Spacer(minLength: 0)
    }
    .controlSize(.small)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain).accessibilityIdentifier("card-sync")
  }

  private var details: some View {
    ScrollView { VStack(alignment: .leading, spacing: 10) {
      Text("录音卡同步").font(.headline)
      Text(model.preferences.autoSync ? "同步方式 · USB 接入后自动同步" : "同步方式 · 手动同步")
      if model.usb.volumes.isEmpty {
        Text("Mac 尚未识别到录音卡磁盘。如果已接线，请检查数据线，并确认能在访达中打开录音卡。")
          .foregroundStyle(.secondary)
      }
      Text("每段录音校验一致后自动删除卡内副本，转写和整理使用 Mac 上的原件。文件保存完成与文字整理完成分别显示。")
      Text(model.syncStatus)
      if !model.syncDetail.isEmpty { Text(model.syncDetail).foregroundStyle(.secondary) }
      ForEach(model.currentInventories, id: \.sourceID) { inventory in
        ForEach(inventory.entries.filter(\.isOpusOnly), id: \.name) { entry in
          Text(entry.name + " · 缺少配对 WAV，尚未保存到 Mac").font(.caption).textSelection(.enabled)
        }
      }
      if let error = model.sync.error ?? model.usb.issue { ErrorDetailsButton(message: error) }
      if let free = model.card.state.freeBytes, let total = model.card.state.totalBytes {
        Text(
          "设备可用空间  \(ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))"
        )
      }
      let today = WorkdayDate.day(Date())
      let records = model.recordings.filter { WorkdayTimeline.days($0).contains(today) }
      let clips = WorkdayTimeline.conversations(
        day: today, recordings: records, documents: model.documents)
      Text("今天已保存 \(records.count) 段录音 · \(clips.count) 条工作细节")
      if let label = model.processingLabel { Text(label) }
      if let id = model.processingID, let recording = model.recordings.first(where: { $0.id == id })
      {
        Button("查看正在整理的录音") {
          model.selectDay(recording.day)
          model.selectedDetail = .original(recording.id)
          showsDetails = false
        }
      }
      Button("同步设置…") {
        showsDetails = false
        model.requestSettings(.archive)
      }
    }.font(.callout).padding(18) }.frame(width: 360).frame(maxHeight: 480)
  }
}

struct FileTransferRow: View {
  let transfer: TransferProgress?

  var body: some View {
    HStack(spacing: 10) {
      if let transfer {
        ProgressView(value: transfer.fraction).accessibilityLabel("录音传输进度")
      } else {
        ProgressView().controlSize(.small).accessibilityLabel("正在准备传输")
      }
      TimelineView(.periodic(from: .now, by: 1)) { _ in
        let label = Self.label(for: transfer, at: ProcessInfo.processInfo.systemUptime)
        Text(label).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          .fixedSize().accessibilityLabel("传输状态").accessibilityValue(label)
      }
    }
  }

  static func label(for transfer: TransferProgress?, at uptime: TimeInterval) -> String {
    guard let transfer else { return "测速中…" }
    if transfer.phase == .verifying { return "正在校验" }
    let rate = uptime - transfer.uptime >= 2 ? 0 : transfer.bytesPerSecond
    guard let rate else { return "测速中…" }
    let units: [(Double, String)] = [(1e9, "GB/s"), (1e6, "MB/s"), (1e3, "KB/s")]
    let unit = units.first { rate >= $0.0 } ?? (1, "B/s")
    return (rate / unit.0).formatted(.number.precision(.fractionLength(0...1))) + " " + unit.1
  }
}
