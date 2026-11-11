import Foundation
import WorkdayCore

struct ActivityEntry: Identifiable {
  let activity: DayActivity
  let clips: [Conversation]
  var id: String { activity.id }
  var start: Date? { clips.first?.wallStart }
  var end: Date? { clips.compactMap(\.wallEnd).max() }
  @MainActor func containsPlayback(_ player: Player) -> Bool {
    clips.contains { $0.recordingID == player.recordingID && $0.start <= player.sourcePosition && player.sourcePosition < $0.end }
  }
  var period: String {
    guard let start else { return "时间未知" }
    switch WorkdayTimeline.calendar.component(.hour, from: start) {
    case ..<12: return "上午"
    case 12..<18: return "下午"
    default: return "晚上"
    }
  }
  var timeLabel: String {
    guard let start else { return "时间未知" }
    let first = WorkdayTimeline.time(start)
    guard activity.kind != .moment, let end else { return first }
    let last =
      WorkdayTimeline.calendar.isDate(start, inSameDayAs: end) ? WorkdayTimeline.time(end) : "24:00"
    return first == last ? first : first + " – " + last
  }
}

struct DayWorkspace {
  let recordings: [Recording]
  let conversations: [Conversation]
  let activities: [ActivityEntry]
  let audio: DayAudioTimeline

  init(
    day: String, recordings: [Recording], documents: [String: ProcessingDocument],
    summary: DaySummary?
  ) {
    self.recordings = recordings.filter { WorkdayTimeline.days($0).contains(day) }
      .sorted { ($0.startedAt ?? $0.importedAt) < ($1.startedAt ?? $1.importedAt) }
    audio = DayAudioTimeline(day: day, recordings: self.recordings)
    let clips = WorkdayTimeline.evidence(
      day: day, recordings: self.recordings, documents: documents)
    let cited = Set(summary?.activities?.flatMap(\.conversationIDs) ?? [])
    conversations = clips.filter { $0.needsClassification != true || cited.contains($0.id) }
    let evidence = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
    activities = DayActivity.timeline(clips, saved: summary?.activities).map {
      ActivityEntry(activity: $0, clips: $0.conversationIDs.compactMap { evidence[$0] })
    }
  }
}

enum WorkspaceArea { case day, live, library, settings }
enum LibraryTab: String, CaseIterable {
  case originals = "原始录音"
  case device = "录音卡"
}
