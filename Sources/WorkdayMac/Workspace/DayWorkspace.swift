import Foundation
import WorkdayCore

struct ActivityEntry: Identifiable {
  let activity: DayActivity
  var clips: [Conversation]
  var manualIDs: [String] = []
  var addedSentenceIDs: Set<String> = []
  var isManualItem = false
  var anchorSentences: [String] = []
  var timelineClips: [Conversation]? = nil
  var id: String { manualIDs.first ?? (isRaw ? "raw:" + activity.id : activity.id) }
  var isRaw: Bool { activity.kind == .aside }
  var start: Date? { (timelineClips ?? clips).first?.wallStart }
  var end: Date? { (timelineClips ?? clips).compactMap(\.wallEnd).max() }
  @MainActor func containsPlayback(_ player: Player) -> Bool {
    clips.contains { player.isAt($0.recordingID, from: $0.start, to: $0.end) }
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
    summary: DaySummary?, organization: DayOrganization = DayOrganization()
  ) {
    self.recordings = recordings.filter { WorkdayTimeline.days($0).contains(day) }
      .sorted { ($0.startedAt ?? $0.importedAt) < ($1.startedAt ?? $1.importedAt) }
    audio = DayAudioTimeline(day: day, recordings: self.recordings)
    let clips = WorkdayTimeline.evidence(
      day: day, recordings: self.recordings, documents: documents)
    let cited = Set(summary?.activities?.flatMap(\.conversationIDs) ?? [])
    conversations = clips.filter { $0.needsClassification != true || cited.contains($0.id) }
    let evidence = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
    let automatic = DayActivity.timeline(clips, saved: summary?.activities).map {
      ActivityEntry(activity: $0, clips: $0.conversationIDs.compactMap { evidence[$0] })
    }
    let spans = self.recordings.flatMap { recording -> [[Conversation]] in
      guard let document = documents[recording.id] else { return [] }
      return WorkdayTimeline.sentenceSlices(day: day, recording: recording, document: document)
    }
    activities = DayArrangement.entries(automatic: automatic, spans: spans, organization: organization)
  }
}

enum WorkspaceArea: String, CaseIterable {
  case day = "全天事项"
  case live = "实时字幕"
  case originals = "原始录音"
  case device = "录音卡"

  var icon: String {
    switch self {
    case .day: return "calendar"
    case .live: return "text.bubble"
    case .originals: return "waveform"
    case .device: return "externaldrive"
    }
  }
}
