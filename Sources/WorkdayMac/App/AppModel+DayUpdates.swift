import Foundation
import WorkdayCore

extension AppModel {
  func dayResultContent(_ summary: DaySummary) -> DaySummary {
    var content = summary
    content.activities = DayActivity.timeline(
      WorkdayTimeline.evidence(
        day: summary.day,
        recordings: recordings, documents: documents), saved: summary.activities)
    return content
  }
  func showDayUpdates() {
    if let day = dayUpdates.unseenDays.first { selectDay(day) } else { area = .day }
  }

  func recordDayUpdate(_ summary: DaySummary) {
    do {
      try dayUpdates.record(dayResultContent(summary))
      persistDayUpdates()
    } catch { notice = "更新提示暂未保存：\(error.localizedDescription)" }
  }

  func markDayViewed(_ day: String, signature: String) {
    guard area == .day, selectedDay == day, dayUpdates.isUnseen(day),
      dayUpdates.signature(for: day) == signature
    else { return }
    dayUpdates.markViewed(day: day, signature: signature)
    persistDayUpdates()
  }

  func persistDayUpdates() {
    dayUpdatesRevision += 1
    guard dayUpdatesSaveTask == nil else { return }
    let target = store
    dayUpdatesSaveTask = Task {
      defer { dayUpdatesSaveTask = nil }
      var saved = -1
      do {
        while saved != dayUpdatesRevision, target === store {
          let revision = dayUpdatesRevision
          try await target.saveDayResultUpdates(dayUpdates)
          saved = revision
        }
      } catch { notice = "更新提示暂未保存：\(error.localizedDescription)" }
    }
  }
}
