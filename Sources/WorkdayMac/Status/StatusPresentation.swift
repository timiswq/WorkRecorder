import AppKit
import Foundation
import WorkdayCore

/// Shared by the workspace, device page and menu bar. Hardware facts never depend on AI or copy errors.
enum StatusAction: Equatable {
  case sync(CardSyncPresentation.Action), bind, reconnect, refreshCard, bluetoothSettings
  case originals, live, processDay(String), retryRecordings(String), recognitionSettings, captionSettings, retryCaptions
  case retryImport, device, summary(String)

  var isSecondary: Bool {
    switch self {
    case .originals, .live, .device: return true
    default: return false
    }
  }

  var title: String {
    switch self {
    case .sync(let action): return action.rawValue
    case .bind: return "选择录音卡…"
    case .reconnect: return "重新连接"
    case .refreshCard: return "重新查询状态"
    case .bluetoothSettings: return "打开系统设置…"
    case .originals: return "查看原始录音"
    case .live: return "查看实时字幕"
    case .processDay: return "开始处理"
    case .retryRecordings: return "重试处理"
    case .recognitionSettings: return "设置语音识别"
    case .captionSettings: return "字幕设置"
    case .retryCaptions: return "重试本机识别"
    case .retryImport: return "重试导入"
    case .device: return "查看录音卡"
    case .summary: return "生成概述"
    }
  }
}

struct StatusActivity: Identifiable {
  enum State { case working, needsAction, manual, waiting, complete, information }
  let id: String
  let title: String
  let detail: String
  var state: State = .information
  var action: StatusAction?
  var error: String?
  var actionLabel: String? = nil
  var day: String?
  var requiresAction: Bool { state == .needsAction || state == .manual }
  var isWorking: Bool { state == .working }
}

struct StatusNotice: Identifiable {
  let source: String
  let message: String
  var id: String { source + "\n" + message }
}

/// Dismissal belongs to the surface, never to the underlying operation. A recovered issue may reappear.
struct StatusNoticeVisibility {
  private var dismissed = Set<String>()
  mutating func dismiss(_ notice: StatusNotice) { dismissed.insert(notice.id) }
  mutating func reconcile(_ notices: [StatusNotice]) { dismissed.formIntersection(notices.map(\.id)) }
  func firstVisible(in notices: [StatusNotice]) -> StatusNotice? {
    notices.first { !dismissed.contains($0.id) }
  }
}

struct StatusPresentation {
  let hardware: DesktopStatus
  let hardwareAction: StatusAction?
  let caption: StatusActivity
  let activities: [StatusActivity]
  let notices: [StatusNotice]
  var attention: [StatusActivity] { activities.filter(\.requiresAction) }
  var hasWarning: Bool { activities.contains { $0.state == .needsAction } }
  var summary: String {
    let required = attention
    if required.count == 1, let row = required.first { return row.title }
    if !required.isEmpty { return "需要处理 \(required.count) 项" }
    if let work = activities.first(where: \.isWorking) { return work.title }
    if let waiting = activities.first(where: { $0.state == .waiting && $0.id != "caption" }) {
      return waiting.title
    }
    if let waiting = activities.first(where: { $0.state == .waiting }) { return waiting.title }
    return "无进行中的任务"
  }
}

extension AppModel {
  func hardwareAction(for hardware: DesktopStatus) -> StatusAction? {
    if hardware.bluetoothBlock?.usesSettings == true { return .bluetoothSettings }
    if hardware.canConnect, preferences.selectedRecorderID != nil { return .reconnect }
    if hardware.canConnect, recorderName == nil { return .bind }
    if hardware.kind == .unknown { return .refreshCard }
    if hardware.kind == .recording { return .live }
    return nil
  }

  func statusPresentation(at now: Date) -> StatusPresentation {
    let hardware = deviceStatus(at: now)
    let caption = captionStatus(at: now, hardware: hardware)
    let hardwareAction = hardwareAction(for: hardware)

    var activities: [StatusActivity] = []
    if usesWiFiCard, wifiSync.busy || !wifiSync.result.isEmpty {
      let state: StatusActivity.State = if wifiSync.busy {
        .working
      } else if wifiSync.pendingCleanup > 0 && preferences.cleanCardAfterSync {
        .needsAction
      } else {
        .information
      }
      activities.append(.init(id: "sync", title: wifiSync.busy ? wifiSync.message : "Wi-Fi 录音同步",
                              detail: wifiSync.result, state: state,
                              action: .device))
    } else if !usesWiFiCard && (!usb.volumes.isEmpty || pendingCount.total > 0) {
      let sync = cardSync
      let state: StatusActivity.State
      if sync.action != nil || sync.phase == .unsupported { state = .needsAction }
      else if sync.isWorking { state = .working }
      else if sync.phase == .saved { state = .complete }
      else { state = .waiting }
      activities.append(.init(id: "sync", title: sync.title, detail: sync.instruction, state: state,
                              action: sync.action.map { .sync($0) }
                                ?? (sync.hasSavedOriginals ? .originals : sync.phase == .unsupported ? .device : nil),
                              error: cardSyncFailure == nil ? nil : (self.sync.error ?? usb.issue)))
      if let failure = cardSyncFailure, sync.isWorking {
        activities.append(.init(id: "sync-failure", title: failure.title, detail: failure.instruction,
                                state: .needsAction, action: failure.action.map { .sync($0) },
                                error: self.sync.error ?? usb.issue))
      }
    }
    if let error = sync.error, sync.failedFile?.sourceID != "manual", cardSyncFailure == nil {
      activities.append(.init(id: "previous-sync", title: "上次录音卡同步未完成",
                              detail: "请重新连接对应的录音卡后重试。", state: .needsAction, action: .device, error: error))
    }
    if let file = sync.activeFile, file.sourceID == "manual" {
      activities.append(.init(id: "import", title: "正在导入音频到 Mac", detail: file.name, state: .working))
    } else if let error = sync.error, sync.failedFile?.sourceID == "manual" {
      activities.append(.init(id: "import", title: "音频尚未导入到 Mac", detail: "已完成的其他原件仍可查看。",
                              state: .needsAction, action: .retryImport, error: error))
    }

    activities += dayProcessingActivities(at: now)
    if let error, !recordings.contains(where: { recording in
      guard let cause = documents[recording.id]?.error else { return false }
      return error == cause || error == cause + "\n录音：" + recording.originalName
    }) {
      activities.append(.init(id: "app-error", title: "一项操作遇到问题", detail: "查看详情了解影响与原因。",
                              state: .needsAction, error: error))
    }
    if let error = player.error {
      activities.append(.init(id: "playback", title: "回听遇到问题", detail: "请检查对应原件后重新播放。",
                              state: .needsAction, action: .originals, error: error))
    }
    if caption.state == .needsAction { activities.append(caption) }
    var notices: [StatusNotice] = []
    if let error { notices.append(.init(source: "app", message: error)) }
    if let error = sync.error { notices.append(.init(source: "sync", message: error)) }
    if let error = usb.issue { notices.append(.init(source: "usb", message: error)) }
    if let error = player.error { notices.append(.init(source: "player", message: error)) }
    return .init(hardware: hardware, hardwareAction: hardwareAction, caption: caption,
                 activities: activities, notices: notices)
  }

  private func captionStatus(at now: Date, hardware: DesktopStatus) -> StatusActivity {
    func status(_ title: String, _ detail: String, _ state: StatusActivity.State = .waiting,
                _ action: StatusAction? = nil, error: String? = nil) -> StatusActivity {
      .init(id: "caption", title: title, detail: detail, state: state, action: action, error: error)
    }
    if usesWiFiCard && wifiSync.usingNetwork {
      return status("正在同步录音", "返回蓝牙连接后可继续接收实时字幕。", .waiting, .live)
    }
    if hardware.isUSB { return status("实时字幕暂停", "USB 连接期间暂停接收实时音频；已有字幕仍可查看。", .waiting, .live) }
    if !preferences.captions.enabled { return status("实时字幕已关闭", "录音卡的录音状态独立更新。", .waiting, .captionSettings) }
    if usesWiFiCard, let issue = card.wifiAudioIssue {
      return status("实时音频暂不可用", issue, .waiting, .live)
    }
    if localCaptions.canRetry {
      return status("实时字幕暂不可用", "本机识别遇到问题；这不代表录音卡已停止录音。", .needsAction, .retryCaptions,
                    error: localCaptions.status)
    }
    guard hardware.kind == .recording else {
      return status(hardware.kind == .paused ? "实时字幕随录音暂停" : "等待录音卡音频", hardware.instruction, .waiting, .live)
    }
    if let pending = localCaptions.pendingSpeech {
      return status(pending.text, "已检测到发言，正在生成字幕。", .working, .live)
    }
    if let last = captionSelection.lines.last, !last.isFinal, last.text.isEmpty, last.bubblePhrase != nil {
      return status("已收到声音", "已检测到发言，正在生成字幕。", .working, .live)
    }
    guard localCaptions.lastAudioAt.map({ now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) < 2 }) == true else {
      return status("暂未收到实时音频", "录音卡报告正在录音；请保持蓝牙连接并查看卡上指示。", .waiting, .live)
    }
    if preferences.cloudEnabled && preferences.realtime && live.canRetry {
      return status("正在使用本机字幕", "云端实时识别暂不可用，本机字幕继续显示。", .working, .live)
    }
    return status("正在接收实时音频", "有发言时会显示字幕。", .working, .live)
  }

  func performStatusAction(_ action: StatusAction) {
    switch action {
    case .sync(let action): performCardSync(action)
    case .bind: showRecorderPicker()
    case .reconnect: if !isolated { card.activate(.reconnectBound) }
    case .refreshCard: if !isolated { card.activate() }
    case .bluetoothSettings:
      if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") { NSWorkspace.shared.open(url) }
    case .originals: showOriginals()
    case .live: showLiveCaptions()
    case .processDay(let day): requestDayProcessing(day)
    case .retryRecordings(let day):
      for recording in recordingsByDay[day] ?? [] where documents[recording.id]?.error != nil {
        retryProcessing(scope: .recording(recording.id))
      }
    case .recognitionSettings: requestSettings(.recognition)
    case .captionSettings: requestSettings(.captions)
    case .retryCaptions: localCaptions.retry()
    case .retryImport: sync.retry()
    case .device: area = .device
    case .summary(let day): retryProcessing(scope: .summary(day))
    }
  }
}
