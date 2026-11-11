import SwiftUI
import WorkdayCore

struct CardSyncPresentation {
  enum Action: String {
    case start = "立即同步"
    case retry = "重试同步"
    case retryCleanup = "重试清理"
    case confirm = "已在卡上保存，继续同步"
  }

  let title: String
  let instruction: String
  var action: Action?
}

extension AppModel {
  var cardSync: CardSyncPresentation {
    if !usb.volumes.isEmpty, usb.needsSaveConfirmation {
      return .init(title: "有一段录音待确认", instruction: "请先在录音卡上结束并保存接线前的那段录音。", action: .confirm)
    }
    if let file = sync.cleaningFile, usb.volumes.contains(where: { $0.id == file.sourceID }) {
      return .init(title: "正在核对并清理卡内副本", instruction: file.name)
    }
    if let file = sync.activeFile, usb.volumes.contains(where: { $0.id == file.sourceID }) {
      return .init(title: "正在同步到 Mac", instruction: file.name)
    }
    let cardError =
      sync.error != nil
      && (sync.failedFile.map { file in
        usb.volumes.contains { $0.id == file.sourceID }
      } ?? true)
    if cardError, sync.cleanupFailed {
      return .init(title: "卡内副本清理待重试", instruction: "请查看下方提示，核对后可重试清理。", action: .retryCleanup)
    }
    if !usb.volumes.isEmpty, usb.issue != nil || cardError {
      return .init(title: "同步遇到问题", instruction: "处理下方的错误提示后，可以重新同步。", action: .retry)
    }
    let automatic = preferences.autoSync
    let inventories = currentInventories
    let count = pendingCount
    let complete = !inventories.isEmpty && inventories.allSatisfy(\.complete)
    let prefix = (inventoryIsFresh ? "" : "上次发现") + (complete ? "" : "至少")
    let pending = "\(prefix)\(count.total) 段待同步"

    if usb.volumes.isEmpty {
      return .init(
        title: count.total > 0 ? pending + " · 等待 USB 连接" : "等待 USB 连接",
        instruction: automatic
          ? "在卡上结束并保存录音，用 USB 数据线连接 Mac 后会自动同步。"
          : "在卡上结束并保存录音，用 USB 数据线连接 Mac，再点「立即同步」。")
    }
    guard inventories.count == usb.volumes.count, inventoryIsFresh else {
      return .init(title: "正在读取录音卡", instruction: "正在核对卡内录音和 Mac 上的工作记录。")
    }
    if count.total == 0, complete {
      if inventories.allSatisfy({ $0.entries.isEmpty }) {
        let cleared = usb.volumes.reduce(Int64(0)) { $0 + (sync.clearedBytesByVolume[$1.id] ?? 0) }
        if cleared > 0 {
          let space = ByteCountFormatter.string(fromByteCount: cleared, countStyle: .file)
          return .init(title: "已同步并清理", instruction: "本次已清理 \(space) 卡内录音。可在左侧按日期查看 Mac 上的原件。")
        }
        return .init(title: "卡内暂无录音", instruction: "在录音卡上录音并保存后，可以在这里同步到 Mac。")
      }
      return .init(title: "录音已归档", instruction: "保持 USB 连接，卡内副本核对后会自动清理。")
    }
    if count.total > 0, count.total == count.unsupported {
      return .init(title: "发现 \(count.total) 段 OPUS 录音", instruction: "这些录音缺少配对的 WAV 文件，暂时无法同步。")
    }
    let title = count.total > 0 ? pending : "清单尚未读完"
    if automatic || !manualSyncVolumes.isEmpty {
      return .init(title: title, instruction: "正在准备同步，文件保存稳定后会逐段复制到 Mac。")
    }
    return .init(title: title, instruction: "自动同步已关闭。点「立即同步」，将录音保存到 Mac。", action: .start)
  }

  func performCardSync(_ action: CardSyncPresentation.Action) {
    guard cardSync.action == action else { return }
    switch action {
    case .start, .retry: retrySync()
    case .retryCleanup: sync.retry()
    case .confirm: confirmSavedOnCard()
    }
  }
}

struct SyncStatusView: View {
  @ObservedObject var model: AppModel
  @State private var showsDetails = false

  var body: some View {
    let state = model.cardSync
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "cable.connector")
        .font(.system(size: 17, weight: .medium)).foregroundStyle(Palette.accent)
        .frame(width: 32, height: 32)
        .background(Palette.selected, in: RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text("录音卡同步").font(.system(size: 15, weight: .semibold))
          Text(state.title).font(.system(size: 12, weight: .medium))
            .foregroundStyle(
              state.action != nil && state.action != .start ? Palette.amber : Palette.accent)
        }
        Text(state.instruction).font(.system(size: 12)).foregroundStyle(Palette.text)
          .fixedSize(horizontal: false, vertical: true)
        if model.sync.usbLabel != nil {
          FileTransferRow(transfer: model.sync.transfer)
        }
      }
      Spacer(minLength: 4)
      if let action = state.action {
        Button(action.rawValue) { model.performCardSync(action) }
          .buttonStyle(.borderedProminent).accessibilityIdentifier("card-sync-action")
      }
      Button("同步详情") { showsDetails.toggle() }
        .buttonStyle(.link)
        .popover(isPresented: $showsDetails) { details }
    }
    .controlSize(.small)
    .padding(.horizontal, 20).padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Palette.surface)
    .accessibilityElement(children: .contain).accessibilityIdentifier("card-sync")
  }

  private var details: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("录音卡同步").font(.headline)
      Text(model.preferences.autoSync ? "同步方式 · USB 接入后自动同步" : "同步方式 · 手动同步")
      if model.usb.volumes.isEmpty {
        Text("Mac 尚未识别到录音卡磁盘。如果已接线，请检查数据线，并确认能在访达中打开录音卡。")
          .foregroundStyle(.secondary)
      }
      Text("每段录音校验后自动清理卡内副本，转写和整理使用 Mac 上的原件。")
      Text(model.syncStatus)
      if !model.syncDetail.isEmpty { Text(model.syncDetail).foregroundStyle(.secondary) }
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
    }.font(.callout).padding(18).frame(width: 340, alignment: .leading)
  }
}

struct FileTransferRow: View {
  let transfer: TransferProgress?

  var body: some View {
    HStack(spacing: 10) {
      ProgressView(value: transfer?.fraction ?? 0).accessibilityLabel("录音传输进度")
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
