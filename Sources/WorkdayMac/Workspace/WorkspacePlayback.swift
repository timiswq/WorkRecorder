import Foundation
import WorkdayCore

extension DayAudioTimeline {
  func navigationIndex(clock: Double, recordingID: String?) -> Int {
    // A stopped excerpt at a source's endpoint still belongs to that recording.
    // locate(clock:) intentionally skips that endpoint for continuous day seeking.
    spans.firstIndex {
      $0.recordingID == recordingID && $0.clockStart <= clock + 0.000001
        && clock <= $0.clockEnd + 0.000001
    } ?? spans.firstIndex { $0.clockEnd > clock } ?? max(0, spans.count - 1)
  }

  var navigationRange: ClosedRange<Double> {
    guard let first = spans.first, let last = spans.last else { return 0...86400 }
    let start = floor(first.clockStart / 1800) * 1800
    let end = min(86400, max(start + 1800, ceil(last.clockEnd / 1800) * 1800))
    return start...end
  }
  /// The compact player uses audio elapsed time; the day ruler uses wall-clock time.
  func clock(atElapsed elapsed: Double) -> Double? {
    guard elapsed.isFinite, let last = spans.last else { return nil }
    var remaining = max(0, elapsed)
    for span in spans {
      if remaining < span.duration { return span.clockStart + remaining }
      remaining -= span.duration
    }
    return last.clockEnd
  }
}

extension AppModel {
  var reviewPlaybackDay: String? {
    if let day = player.route?.day { return day }
    guard let record = recordings.first(where: { $0.id == player.recordingID }),
      let start = record.startedAt else { return nil }
    // Keep a segment ending exactly at midnight attached to its actual source day.
    return WorkdayDate.day(start.addingTimeInterval(min(player.sourcePosition, max(0, record.duration - 0.000001))))
  }

  var reviewPlaybackClock: Double? {
    if player.route != nil { return player.dayClock }
    guard let record = recordings.first(where: { $0.id == player.recordingID }),
      let start = record.startedAt, let midnight = reviewPlaybackDay.flatMap(WorkspaceDate.date)
    else { return nil }
    return start.addingTimeInterval(player.sourcePosition).timeIntervalSince(midnight)
  }

  func seekReviewPlayback(_ clock: Double, on day: String) {
    guard clock.isFinite else { return }
    if player.route == nil, reviewPlaybackDay == day,
      let record = recordings.first(where: { $0.id == player.recordingID }),
      let start = record.startedAt, let midnight = WorkspaceDate.date(day)
    {
      let source = midnight.addingTimeInterval(clock).timeIntervalSince(start)
      let range = player.playbackRange ?? 0...record.duration
      if range.contains(source) { player.seek(source); return }
    }
    seekDayAudio(clock, on: day)
  }

  func showReviewPlaybackDay() {
    guard let day = reviewPlaybackDay else { return }
    if player.route != nil { showPlaybackDay(); return }
    selectDay(day)
    if let entry = workspace.activities.first(where: { $0.containsPlayback(player) }) {
      selectedDetail = .conversation(entry.id)
    } else { selectedDetail = player.recordingID.map(RecordDetailSelection.original) }
  }
  var playbackHeading: String {
    if let id = player.captionID {
      if let line = captionHistory.records.first(where: { $0.id == id }) {
        return "字幕回听 · " + CaptionTime.day(line.time, relativeTo: Date()) + " "
          + CaptionTime.seconds.string(from: line.time)
      }
      return player.title
    }
    if let day = player.route?.day { return "全天回听 · " + day }
    let kind: String
    if player.playbackRange != nil {
      kind =
        player.title == "逐句回听"
        ? "逐句回听"
        : player.title == "回听这段对话" ? "对话回听" : "片段回听"
    } else {
      kind = "原件回听"
    }
    let day = recordings.first { $0.id == player.recordingID }?.day
    return kind + " · " + (day ?? "日期未知")
  }

  func seekDayProgress(_ elapsed: Double) {
    let route = player.route ?? workspace.audio
    guard let clock = route.clock(atElapsed: elapsed) else { return }
    seekDayAudio(clock, on: route.day)
  }

  func seekDayAudio(_ clock: Double, on day: String) {
    guard clock.isFinite else { return }
    if player.route?.day == day {
      player.seekDay(clock)
    } else {
      let dayWorkspace = workspace(for: day)
      player.startDay(
        dayWorkspace.audio, recordings: dayWorkspace.recordings,
        root: libraryURL, clock: clock, autoplay: false)
    }
  }
}
