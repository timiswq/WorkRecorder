import Foundation

public enum WorkdayError: LocalizedError {
  case invalid(String)
  public var errorDescription: String? {
    if case .invalid(let text) = self { return text }
    return nil
  }
}

public struct Recording: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var startedAt: Date?
  public var importedAt: Date
  public var originalName: String
  public var folder: String
  public var originalFile: String
  public var companionFile: String?
  public var sha256: String
  public var bytes: Int64
  public var duration: Double
  public var pauses: [RecordingPause]?
  public var sourceAliases: [String]?
  public var companionBytes: Int64?
  public var sourceID: String
  public var wifiOriginal: WiFiOriginal?
  public var day: String { startedAt.map(WorkdayDate.day) ?? "日期未知" }
}

public enum WorkdayDate {
  public static func day(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "Asia/Shanghai")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
  }
  public static func clock(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.isFinite ? seconds : 0))
    return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
  }
}
