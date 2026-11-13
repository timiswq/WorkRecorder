import Foundation

public struct DayAudioSpan: Equatable, Identifiable, Sendable {
  public let recordingID: String
  public let sourceStart: Double
  public let sourceEnd: Double
  public let clockStart: Double
  public var duration: Double { sourceEnd - sourceStart }
  public var clockEnd: Double { clockStart + duration }
  public var id: String { "\(recordingID)#\(sourceStart)" }
}

/// Playback follows a single chronological route. Simultaneous originals remain independently accessible.
public struct DayAudioTimeline: Equatable, Sendable {
  public let day: String
  public let spans: [DayAudioSpan]
  public let duration: Double

  public init(day: String, recordings: [Recording], preferredRecordingID: String? = nil) {
    self.day = day
    var candidates: [DayAudioSpan] = []
    for record in recordings {
      for part in WorkdayTimeline.slices(record, start: 0, end: record.duration)
      where part.day == day {
        guard let date = part.date else { continue }
        let clock = date.timeIntervalSince(WorkdayTimeline.calendar.startOfDay(for: date))
        candidates.append(
          .init(
            recordingID: record.id, sourceStart: part.start,
            sourceEnd: part.end, clockStart: clock))
      }
    }
    if let preferredRecordingID {
      // When a quote belongs to the second microphone, keep its actual audio in the route.
      let priority = candidates.filter { $0.recordingID == preferredRecordingID }
      candidates = candidates.flatMap { span -> [DayAudioSpan] in
        if span.recordingID == preferredRecordingID { return [span] }
        var ranges = [span.clockStart..<span.clockEnd]
        for other in priority
        where span.clockStart < other.clockEnd && other.clockStart < span.clockEnd {
          ranges = ranges.flatMap { range in
            if range.upperBound <= other.clockStart || range.lowerBound >= other.clockEnd {
              return [range]
            }
            var rest: [Range<Double>] = []
            if range.lowerBound < other.clockStart {
              rest.append(range.lowerBound..<other.clockStart)
            }
            if other.clockEnd < range.upperBound { rest.append(other.clockEnd..<range.upperBound) }
            return rest
          }
        }
        return ranges.map {
          DayAudioSpan(
            recordingID: span.recordingID,
            sourceStart: span.sourceStart + ($0.lowerBound - span.clockStart),
            sourceEnd: span.sourceStart + ($0.upperBound - span.clockStart),
            clockStart: $0.lowerBound)
        }
      }
    }
    var route: [DayAudioSpan] = []
    var until: Double = 0
    for span in candidates.sorted(by: {
      $0.clockStart == $1.clockStart
        ? $0.recordingID < $1.recordingID : $0.clockStart < $1.clockStart
    }) where span.clockEnd > until {
      let skip = max(0, until - span.clockStart)
      route.append(
        .init(
          recordingID: span.recordingID, sourceStart: span.sourceStart + skip,
          sourceEnd: span.sourceEnd, clockStart: span.clockStart + skip))
      until = span.clockEnd
    }
    spans = route
    duration = route.reduce(0) { $0 + $1.duration }
  }

  public func locate(clock: Double) -> (index: Int, offset: Double)? {
    guard clock.isFinite, let last = spans.last else { return nil }
    guard let index = spans.firstIndex(where: { $0.clockEnd > clock }) else {
      return (spans.count - 1, last.sourceEnd)
    }
    let span = spans[index]
    return (index, span.sourceStart + max(0, clock - span.clockStart))
  }
}
