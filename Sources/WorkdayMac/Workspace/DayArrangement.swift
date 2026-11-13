import Foundation
import WorkdayCore

enum DayArrangement {
  static func entries(
    automatic: [ActivityEntry], spans: [[Conversation]], organization: DayOrganization
  )
    -> [ActivityEntry]
  {
    let sources = spans.flatMap { $0 }
    let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let byRecording = Dictionary(grouping: sources, by: \.recordingID)
      .mapValues { Dictionary(grouping: $0, by: { $0.lineIDs[0] }) }
    func sentences(_ clip: Conversation) -> [Conversation] {
      let index = byRecording[clip.recordingID]
      return clip.lineIDs.flatMap { index?[$0] ?? [] }.filter {
        $0.end > clip.start && $0.start < clip.end
      }
    }

    let events = automatic.filter { !$0.isRaw }
    let eventSources = events.map { $0.clips.flatMap(sentences).map(\.id) }
    let clipOwners = Dictionary(
      events.enumerated().flatMap { i, event in
        event.activity.conversationIDs.map { ($0, i) }
      }, uniquingKeysWith: { first, _ in first })
    let sourceOwners = Dictionary(
      eventSources.enumerated().flatMap { i, ids in
        ids.map { ($0, i) }
      }, uniquingKeysWith: { first, _ in first })

    var supplements: [Int: [DayOrganization.Item]] = [:]
    var standalone: [DayOrganization.Item] = []
    var assigned = Set(organization.items.flatMap(\.sentences))
    for item in organization.items {
      if let owner = item.anchors.compactMap({ clipOwners[$0] }).first
        ?? item.anchorSentences.compactMap({ sourceOwners[$0] }).first
      {
        supplements[owner, default: []].append(item)
      } else {
        standalone.append(item)
        assigned.formUnion(item.anchorSentences)
      }
    }

    var result: [ActivityEntry] = []
    var used = assigned
    for (index, original) in events.enumerated() {
      let additions = supplements[index] ?? []
      var entry = original
      entry.clips = original.clips.compactMap { clip in
        let lines = sentences(clip)
        let kept = lines.filter { !assigned.contains($0.id) }
        used.formUnion(kept.map(\.id))
        guard kept.count != lines.count else { return clip }
        guard !kept.isEmpty else { return nil }
        var trimmed = clip
        trimmed.audioSourceStart = clip.audioSourceStart ?? clip.start
        trimmed.lineIDs = kept.flatMap(\.lineIDs)
        trimmed.excerpt = kept.compactMap { $0.excerpt?.first }
        trimmed.start = kept[0].start
        trimmed.wallStart = kept[0].wallStart
        trimmed.end = kept.map(\.end).max() ?? clip.end
        trimmed.wallEnd = kept.compactMap(\.wallEnd).max()
        return trimmed
      }
      entry.anchorSentences = eventSources[index].filter { !assigned.contains($0) }
      entry.manualIDs = additions.map(\.id)
      entry.addedSentenceIDs = Set(additions.flatMap(\.sentences))
      entry.timelineClips = entry.clips.isEmpty ? original.clips : entry.clips
      entry.clips += additions.flatMap(\.sentences).compactMap { byID[$0] }.sorted(by: earlier)
      if !entry.clips.isEmpty { result.append(entry) }
    }

    for item in standalone {
      let anchors = item.anchorSentences.compactMap { byID[$0] }.sorted(by: earlier)
      let added = item.sentences.compactMap { byID[$0] }.sorted(by: earlier)
      let primary =
        anchors.isEmpty
        ? item.initialSentences.compactMap { byID[$0] }.sorted(by: earlier) : anchors
      let primaryIDs = Set(primary.map(\.id))
      let clips = primary + added.filter { !primaryIDs.contains($0.id) }
      guard !clips.isEmpty else { continue }
      let event = DayActivity(
        kind: .event, title: item.title, summary: item.summary,
        conversationIDs: clips.map(\.id))
      result.append(
        ActivityEntry(
          activity: event, clips: clips, manualIDs: [item.id],
          addedSentenceIDs: Set(added.map(\.id)).subtracting(primaryIDs), isManualItem: true,
          timelineClips: primary.isEmpty ? added : primary))
    }

    // Flush at every claimed sentence, even across a silent gap of less than a second.
    for span in spans {
      var group: [Conversation] = []
      func flush() {
        guard let first = group.first else { return }
        let raw = DayActivity(
          kind: .aside, title: first.summary, summary: "", conversationIDs: group.map(\.id))
        result.append(ActivityEntry(activity: raw, clips: group))
        group.removeAll(keepingCapacity: true)
      }
      for clip in span {
        if used.contains(clip.id) {
          flush()
          continue
        }
        if let last = group.last, clip.start - last.end > 90 { flush() }
        group.append(clip)
      }
      flush()
    }
    let recordOrder = Dictionary(
      spans.enumerated().compactMap { index, span in
        span.first.map { ($0.recordingID, index) }
      }, uniquingKeysWith: min)
    return result.sorted { a, b in
      if a.start != b.start { return (a.start ?? .distantPast) < (b.start ?? .distantPast) }
      let x = (a.timelineClips ?? a.clips)[0]
      let y = (b.timelineClips ?? b.clips)[0]
      if x.recordingID != y.recordingID {
        return (recordOrder[x.recordingID] ?? 0, x.recordingID) < (
          recordOrder[y.recordingID] ?? 0, y.recordingID
        )
      }
      return (x.start, a.id) < (y.start, b.id)
    }
  }

  private static func earlier(_ a: Conversation, _ b: Conversation) -> Bool {
    (a.wallStart ?? .distantPast, a.recordingID, a.start, a.id)
      < (b.wallStart ?? .distantPast, b.recordingID, b.start, b.id)
  }
}
