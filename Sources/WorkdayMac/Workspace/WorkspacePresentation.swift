import Foundation
import WorkdayCore

enum SettingsSection: String, CaseIterable, Identifiable {
  case device = "录音卡"
  case recognition = "语音识别"
  case captions = "桌面语音气泡"
  case archive = "本地归档"
  case appearance = "外观"
  var id: Self { self }
  var icon: String {
    switch self {
    case .device: return "waveform"
    case .recognition: return "text.bubble"
    case .captions: return "captions.bubble"
    case .archive: return "internaldrive"
    case .appearance: return "circle.lefthalf.filled"
    }
  }
}

enum RecordDetailSelection: Hashable {
  case conversation(String)
  case original(String)
}

/// A local recovery command must not silently resume other dates or recordings.
enum ProcessingScope: Equatable {
  case all
  case day(String)
  case summary(String)
  case recording(String)

  func includes(_ recording: Recording) -> Bool {
    switch self {
    case .all: return true
    case .summary: return false
    case .day(let day): return WorkdayTimeline.days(recording).contains(day)
    case .recording(let id): return recording.id == id
    }
  }

  func summaryDays(in recordings: [Recording]) -> Set<String> {
    switch self {
    case .day(let day), .summary(let day): return [day]
    default: return Set(recordings.filter(includes).flatMap(WorkdayTimeline.days))
    }
  }
}

enum WorkspaceDate {
  static func date(_ day: String?) -> Date? {
    guard let day else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = WorkdayTimeline.calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: day)
  }

  static func heading(_ day: String?, full: Bool = false) -> String {
    guard let date = date(day) else { return "日期未知" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = WorkdayTimeline.calendar.timeZone
    formatter.dateFormat = full || day?.prefix(4) != WorkdayDate.day(Date()).prefix(4)
      ? "yyyy年M月d日 EEEE" : "M月d日 EEE"
    return formatter.string(from: date)
  }

  static func title(_ day: String, today: String = WorkdayDate.day(Date())) -> String {
    if day == today { return "今天" }
    guard day != "日期未知" else { return day }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "yyyy-MM-dd"
    guard let date = formatter.date(from: day), let current = formatter.date(from: today) else {
      return day
    }
    if current.timeIntervalSince(date) == 86400 { return "昨天" }
    formatter.dateFormat = day.prefix(4) == today.prefix(4) ? "M月d日" : "yyyy年M月d日"
    return formatter.string(from: date)
  }
}

enum LiveReadingPosition {
  static func isAtTop(of bounds: CGRect, visible: CGRect, flipped: Bool) -> Bool {
    let distance = flipped ? visible.minY - bounds.minY : bounds.maxY - visible.maxY
    return distance <= 1
  }
}
