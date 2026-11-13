import Foundation
import WorkdayCore

extension DayAudioTimeline {
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
