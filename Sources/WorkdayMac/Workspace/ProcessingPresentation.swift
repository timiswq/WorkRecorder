import Foundation
import WorkdayCore

extension AppModel {
  func recordingProcessingState(_ recording: Recording) -> RecordingProcessingState {
    let document = documents[recording.id]
    if document?.phase == "complete" { return .complete }
    if processingPaused && processingIsRunning { return .pausing }
    if processingID == recording.id && processingSummaryDay == nil {
      let stage: String
      switch document?.phase {
      case "transcribing": stage = "正在转写录音"
      case "organizing": stage = "正在提取事项"
      case "clipping": stage = "正在保存音频片段"
      default: stage = "正在准备转写录音"
      }
      return .working(stage)
    }
    if recordingIsScheduled(recording) { return .queued }
    if !processingIsAvailable { return .needsSetup }
    if processingPaused { return .paused }
    if document?.error != nil { return .failed }
    return processingIsRunning ? .blocked : .needsStart
  }

  func dayOverviewState(for day: String) -> DayOverviewState {
    let pending = (recordingsByDay[day] ?? []).filter { documents[$0.id]?.phase != "complete" }
    return dayProcessingState(for: day, pending: pending).withAvailability(processingIsAvailable)
  }

  func dayProcessingState(for day: String, pending: [Recording]) -> DayOverviewState {
    let active = pending.first { !processingPaused && processingID == $0.id && processingSummaryDay == nil }
    let stage: String? = active.flatMap {
      if case .working(let stage) = recordingProcessingState($0) { return stage }
      return nil
    }
    return DayOverviewState.resolve(
      hasOverview: !(summaries[day]?.overview.isEmpty ?? true), isCurrent: summaryIsCurrent(day),
      pending: pending.count, failedRecordings: pending.filter { documents[$0.id]?.error != nil }.count,
      generating: processingSummaryDay == day,
      queued: summaryIsScheduled(day), failed: summaryErrors[day] != nil,
      recordingStage: stage,
      queuedRecordings: pending.filter { recordingIsScheduled($0) }.count,
      paused: processingPaused, pausing: processingPaused && processingIsRunning,
      busy: processingIsRunning)
  }

  /// While another scope is active, use the existing per-record queue instead of dropping the command.
  func requestDayProcessing(_ day: String) {
    guard processingIsAvailable else { requestSettings(.recognition); return }
    guard !(processingPaused && processingIsRunning) else { return }
    let pending = workspace(for: day).recordings.filter { documents[$0.id]?.phase != "complete" }
    if pending.isEmpty { retryProcessing(scope: .summary(day)); return }
    if processingIsRunning {
      for recording in pending where processingID != recording.id && !recordingIsScheduled(recording) {
        retryProcessing(scope: .recording(recording.id))
      }
    } else { retryProcessing(scope: .day(day)) }
  }
}
