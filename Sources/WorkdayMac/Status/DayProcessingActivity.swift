import Foundation
import WorkdayCore

extension AppModel {
  func dayProcessingActivities(at now: Date) -> [StatusActivity] {
    let today = WorkdayDate.day(now)
    let dates = Set(recordingsByDay.keys).union(summaryErrors.keys)
    return dates.sorted(by: >).compactMap { day in
      let records = recordingsByDay[day] ?? []
      let pending = records.filter { documents[$0.id]?.phase != "complete" }
      guard !pending.isEmpty || !summaryIsCurrent(day) else { return nil }
      let state = dayProcessingState(for: day, pending: pending)
      return dayProcessingActivity(state, day: day, dateTitle: WorkspaceDate.title(day, today: today),
                                   pending: pending, total: records.count)
    }
  }

  private func dayProcessingActivity(_ state: DayOverviewState, day: String, dateTitle: String,
                                     pending: [Recording], total: Int) -> StatusActivity? {
    func row(_ title: String, _ status: StatusActivity.State, detail: String = "",
             action: StatusAction? = nil, label: String? = nil, error: String? = nil) -> StatusActivity {
      let needsSetup = action != nil && !processingIsAvailable
      var notes: [String] = []
      if let reason = error?.split(whereSeparator: \.isNewline).first { notes.append(String(reason)) }
      if !detail.isEmpty { notes.append(detail) }
      if needsSetup { notes.append("请先完成语音识别设置。") }
      return StatusActivity(id: "day:" + day, title: dateTitle + " · " + title,
                            detail: notes.joined(separator: " "), state: status,
                            action: needsSetup ? .recognitionSettings : action, error: error,
                            actionLabel: needsSetup ? nil : label, day: day)
    }

    let failed = pending.filter { documents[$0.id]?.error != nil && $0.id != processingID && !recordingIsScheduled($0) }
    let hasProgress = pending.contains { recording in
      guard let document = documents[recording.id] else { return false }
      return document.completedChunks > 0 || !document.transcript.isEmpty
        || document.phase == "organizing" || document.phase == "clipping"
    }
    let pendingTitle = "\(pending.count) 段录音" + (hasProgress ? "待继续处理" : "待转写")
    switch state {
    case .ready, .noContent, .unconfigured:
      return nil
    case .generating:
      return row("正在生成概述", .working)
    case .processingRecordings(let stage):
      let complete = total - pending.count
      let progress = "当天已完成 \(complete)/\(total) 段。"
      let failedDetail = failed.isEmpty ? "" : " 另有 \(failed.count) 段处理失败。"
      return row(stage, .working, detail: progress + failedDetail)
    case .queued:
      return row("概述已排队", .waiting, detail: "将自动生成。")
    case .queuedRecordings(let count):
      return row("\(count) 段录音已排队", .waiting, detail: "将自动处理。")
    case .pausing:
      return row("正在暂停处理", .working)
    case .paused:
      let isSummary = pending.isEmpty
      return row(isSummary ? "概述生成已暂停" : "\(pending.count) 段录音已暂停处理", .manual,
                 action: isSummary ? .summary(day) : .processDay(day), label: isSummary ? "继续生成概述" : "继续处理")
    case .recordingsFailed(let count):
      let remaining = pending.count - count
      let detail = remaining > 0 ? "另有 \(remaining) 段录音待处理。" : "原件和已完成的进度已保留。"
      return row("\(count) 段录音处理失败", .needsAction, detail: detail,
                 action: .retryRecordings(day), error: failed.first.flatMap { documents[$0.id]?.error })
    case .pending, .blocked:
      let label = processingIsRunning ? "加入处理队列" : (hasProgress ? "继续处理" : "开始转写")
      return row(pendingTitle, .manual, action: .processDay(day), label: label)
    case .summaryFailed:
      let allTranscribed = total > 0 && pending.isEmpty
      let title = allTranscribed ? "录音已转写，概述生成失败" : "概述生成失败"
      let detail = pending.isEmpty ? "已有文字已保留。" : "另有" + pendingTitle + "。"
      return row(title, .needsAction, detail: total > 0 ? detail : "",
                 action: .summary(day), label: "重试概述", error: summaryErrors[day])
    case .missing:
      return row("录音已转写，概述待生成", .manual, action: .summary(day))
    case .outdated:
      return row("概述待更新", .manual, detail: "已有概述尚未包含最新内容。", action: .summary(day), label: "更新概述")
    }
  }
}
