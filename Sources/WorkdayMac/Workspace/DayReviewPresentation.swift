import Foundation

/// Summary coverage and background job lifecycle are different facts.
enum ProcessingStatusKind: Equatable { case working, queued, actionRequired, failure, information }

enum DayOverviewState: Equatable {
  case ready, outdated, missing, noContent, generating, queued, summaryFailed, unconfigured
  case paused, pausing
  case pending(Int), recordingsFailed(Int), processingRecordings(String), queuedRecordings(Int), blocked(Int)

  static func resolve(
    hasOverview: Bool, isCurrent: Bool, pending: Int = 0, failedRecordings: Int = 0,
    generating: Bool = false, queued: Bool = false, failed: Bool = false,
    recordingStage: String? = nil, queuedRecordings: Int = 0, paused: Bool = false,
    pausing: Bool = false, busy: Bool = false
  ) -> Self {
    if pausing { return .pausing }
    if generating { return .generating }
    if let recordingStage { return .processingRecordings(recordingStage) }
    if pending == 0 && isCurrent { return hasOverview ? .ready : .noContent }
    if paused { return .paused }
    if queuedRecordings > 0 { return .queuedRecordings(queuedRecordings) }
    if queued { return .queued }
    if failedRecordings > 0 { return .recordingsFailed(failedRecordings) }
    if failed { return .summaryFailed }
    if pending > 0 { return busy ? .blocked(pending) : .pending(pending) }
    if hasOverview { return .outdated }
    return .missing
  }

  func withAvailability(_ available: Bool) -> Self {
    !available && actionTitle != nil ? .unconfigured : self
  }

  var message: String? {
    switch self {
    case .ready: return nil
    case .outdated: return "概述尚未包含最新内容"
    case .missing: return "概述尚未生成，需要手动启动"
    case .noContent: return "当天没有足够内容生成概述"
    case .generating: return "正在生成概述，无需重复启动"
    case .queued: return "概述已排队，将自动生成"
    case .summaryFailed: return "概述生成失败，需要重试"
    case .unconfigured: return "语音识别尚未就绪，请先完成设置"
    case .pending(let count): return "\(count) 段录音需要手动处理"
    case .blocked(let count): return "\(count) 段录音尚未启动，其他任务正在处理"
    case .recordingsFailed(let count): return "\(count) 段录音处理失败，需要重试"
    case .processingRecordings(let stage): return stage + "，无需重复启动"
    case .queuedRecordings(let count): return "\(count) 段录音已排队，将自动处理"
    case .paused: return "录音处理已暂停，需要手动继续"
    case .pausing: return "正在暂停后台处理…"
    }
  }

  var actionTitle: String? {
    switch self {
    case .ready, .noContent, .generating, .queued, .processingRecordings, .queuedRecordings, .pausing: return nil
    case .outdated: return "更新概述"
    case .missing: return "生成概述"
    case .summaryFailed: return "重试概述"
    case .pending: return "开始处理"
    case .blocked: return "加入处理队列"
    case .paused: return "继续处理"
    case .recordingsFailed: return "重试处理"
    case .unconfigured: return "设置语音识别"
    }
  }

  var kind: ProcessingStatusKind {
    switch self {
    case .generating, .processingRecordings, .pausing: return .working
    case .queued, .queuedRecordings: return .queued
    case .summaryFailed, .recordingsFailed: return .failure
    case .ready, .noContent: return .information
    default: return .actionRequired
    }
  }
}

/// Recording rows, full text and day overview all consult the same actual execution state.
enum RecordingProcessingState: Equatable {
  case complete, queued, paused, pausing, needsStart, needsSetup, failed, blocked
  case working(String)

  var message: String {
    switch self {
    case .complete: return "录音处理完成"
    case .queued: return "录音已排队，将自动处理"
    case .paused: return "录音处理已暂停，需要手动继续"
    case .pausing: return "正在暂停处理…"
    case .needsStart: return "录音需要手动处理"
    case .needsSetup: return "语音识别尚未就绪，请先完成设置"
    case .failed: return "录音处理失败，需要重试"
    case .blocked: return "这段录音尚未启动，其他任务正在处理"
    case .working(let stage): return stage
    }
  }

  var actionTitle: String? {
    switch self {
    case .complete, .queued, .working, .pausing: return nil
    case .paused: return "继续处理"
    case .needsStart: return "开始处理"
    case .needsSetup: return "设置语音识别"
    case .failed: return "重试处理"
    case .blocked: return "加入处理队列"
    }
  }

  var kind: ProcessingStatusKind {
    switch self {
    case .working, .pausing: return .working
    case .queued: return .queued
    case .failed: return .failure
    case .complete: return .information
    default: return .actionRequired
    }
  }
}

enum DayReviewText {
  static func overview(_ text: String, day: String) -> String {
    var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.hasPrefix(day) {
      result.removeFirst(day.count)
      result = result.trimmingCharacters(in: CharacterSet(charactersIn: " ：:·，,\n"))
      if result.hasPrefix("全天") { result.removeFirst(2) }
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
