import Foundation

extension WorkdayTimeline {
  /// Deferred sentences and unselected lines from older archives remain available to the daily editor.
  public static func evidence(
    day: String, recordings: [Recording],
    documents: [String: ProcessingDocument]
  ) -> [Conversation] {
    var clips = conversations(day: day, recordings: recordings, documents: documents)
    let sourceMap = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0) })
    let transcripts = documents.filter { sourceMap[$0.key] != nil }.mapValues {
      Dictionary(
        $0.transcript.map { ($0.id, $0) },
        uniquingKeysWith: { first, _ in first })
    }
    for index in clips.indices {
      let clip = clips[index]
      let ids = clip.lineIDs
      let samples = ids.count <= 6 ? Array(ids.indices) : (0..<6).map { $0 * (ids.count - 1) / 5 }
      clips[index].excerpt = samples.compactMap { transcripts[clip.recordingID]?[ids[$0]] }
    }
    for record in recordings {
      guard let doc = documents[record.id], doc.phase == "complete" else { continue }
      let deferred = Set(doc.deferredLineIDs ?? [])
      guard doc.editorialVersion == nil || !deferred.isEmpty else { continue }
      let selected = Set(doc.conversations.flatMap(\.lineIDs))
      for line in doc.transcript where !selected.contains(line.id)
        && (doc.editorialVersion == nil || deferred.contains(line.id)) {
        for part in slices(record, start: line.start, end: min(line.end, record.duration))
        where part.day == day {
          let id = "\(record.id)/\(line.id)/\(part.start)"
          clips.append(
            Conversation(
              id: id, recordingID: record.id, title: "", summary: line.text,
              start: part.start, end: part.end, lineIDs: [line.id], excerpt: [line],
              needsClassification: true, wallStart: part.date,
              wallEnd: part.date?.addingTimeInterval(part.end - part.start),
              audioSourceStart: 0, audioFile: record.originalFile,
              sha256: record.sha256, decisions: [], tasks: []))
        }
      }
    }
    return clips.sorted {
      if $0.wallStart != $1.wallStart {
        return ($0.wallStart ?? .distantPast) < ($1.wallStart ?? .distantPast)
      }
      if $0.recordingID == $1.recordingID, $0.start != $1.start { return $0.start < $1.start }
      let lhs = sourceMap[$0.recordingID]?.importedAt ?? .distantPast
      let rhs = sourceMap[$1.recordingID]?.importedAt ?? .distantPast
      return lhs == rhs ? $0.id < $1.id : lhs < rhs
    }
  }
}
