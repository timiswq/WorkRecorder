import Foundation

public struct RecordingPause: Codable, Equatable, Sendable {
  public var offset: Double
  public var duration: Double
  public init(offset: Double, duration: Double) {
    self.offset = offset
    self.duration = duration
  }
}
public struct DayAudioSlice: Equatable, Sendable {
  public var day: String
  public var start: Double
  public var end: Double
  public var date: Date?
}

public enum WorkdayTimeline {
  public static var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return value
  }
  public static func date(_ recording: Recording, offset: Double) -> Date? {
    guard offset.isFinite, offset >= 0, let start = recording.startedAt else { return nil }
    let gaps = validPauses(recording).filter { $0.offset <= offset }.reduce(0) { $0 + $1.duration }
    return start.addingTimeInterval(offset + gaps)
  }
  private static func validPauses(_ recording: Recording) -> [RecordingPause] {
    (recording.pauses ?? []).filter {
      $0.offset.isFinite && $0.duration.isFinite && $0.offset >= 0 && $0.offset < recording.duration
        && $0.duration > 0 && $0.duration < 604800
    }.sorted { $0.offset < $1.offset }
  }
  public static func slices(_ recording: Recording, start: Double, end: Double) -> [DayAudioSlice] {
    guard start.isFinite, end.isFinite, recording.duration.isFinite, start >= 0,
      end > start, end <= recording.duration, end - start < 604800
    else { return [] }
    guard recording.startedAt != nil else {
      return [.init(day: "日期未知", start: start, end: end, date: nil)]
    }
    let boundaries = Array(
      Set(validPauses(recording).map(\.offset).filter { $0 > start && $0 < end } + [end])
    ).sorted()
    var cursor = start
    var result: [DayAudioSlice] = []
    for boundary in boundaries {
      while cursor < boundary - 0.000001 {
        guard let wall = date(recording, offset: cursor),
          let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: wall))
        else { break }
        let length = min(boundary - cursor, midnight.timeIntervalSince(wall))
        guard length > 0 else { break }
        result.append(
          .init(day: WorkdayDate.day(wall), start: cursor, end: cursor + length, date: wall))
        cursor += length
      }
    }
    return result
  }
  public static func days(_ recording: Recording) -> [String] {
    Array(Set(slices(recording, start: 0, end: recording.duration).map(\.day))).sorted()
  }
  public static func conversations(
    day: String, recordings: [Recording], documents: [String: ProcessingDocument]
  ) -> [Conversation] {
    var result: [(Conversation, Date?)] = []
    for record in recordings {
      guard let document = documents[record.id] else { continue }
      for original in document.conversations {
        let parts = slices(record, start: original.start, end: original.end)
        for (index, part) in parts.enumerated() where part.day == day {
          var clip = original
          if parts.count > 1 {
            clip.id = original.id + ":\(index):\(day)"
            clip.audioSourceStart = original.audioSourceStart ?? original.start
            clip.start = part.start
            clip.end = part.end
            let lines = document.transcript.filter {
              original.lineIDs.contains($0.id) && $0.end > part.start && $0.start < part.end
            }
            guard !lines.isEmpty else { continue }
            clip.lineIDs = lines.map(\.id)
            clip.summary = lines.map(\.text).joined(separator: " ")
            clip.decisions = []
            clip.tasks = []
          }
          clip.wallStart = part.date
          clip.wallEnd = part.date?.addingTimeInterval(part.end - part.start)
          result.append((clip, part.date))
        }
      }
    }
    return result.sorted {
      let a = $0.1 ?? .distantPast
      let b = $1.1 ?? .distantPast
      return a == b ? $0.0.id < $1.0.id : a < b
    }.map(\.0)
  }
  public static func fingerprint(
    day: String, recordings: [Recording], documents: [String: ProcessingDocument]
  ) -> String {
    struct DocumentStamp: Encodable {
      var id: String
      var hash: String
      var model: String
      var phase: String
      var updatedAt: Date
      var transcriptCount: Int
      var chunks: Int
      var batches: Int
      var clips: [Conversation]
    }
    struct Input: Encodable {
      let activitySchema = 2
      var day: String
      var recordings: [Recording]
      var documents: [DocumentStamp]
    }
    let items = recordings.filter { days($0).contains(day) }.sorted { $0.id < $1.id }
    let stamps = items.compactMap { item -> DocumentStamp? in
      guard let doc = documents[item.id] else { return nil }
      return DocumentStamp(
        id: item.id, hash: doc.sourceHash, model: doc.model, phase: doc.phase,
        updatedAt: doc.updatedAt, transcriptCount: doc.transcript.count,
        chunks: doc.completedChunks,
        batches: doc.analyzedBatches, clips: doc.conversations)
    }
    let input = Input(day: day, recordings: items, documents: stamps)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let encoded = try? encoder.encode(input) else { return "invalid" }
    return Files.digest(encoded)
  }
  public static func time(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
  }
}
