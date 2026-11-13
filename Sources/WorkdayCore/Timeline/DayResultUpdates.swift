import Foundation

/// Content receipts are library-local and versioned; reading one day never clears another.
public struct DayResultUpdates: Codable, Sendable {
  private struct Entry: Codable, Sendable {
    var signature: String
    var unseen: Bool
    var updatedAt: Date
  }
  private var entries: [String: Entry] = [:]
  public init() {}

  public var unseenDays: [String] {
    entries.filter { $0.value.unseen }.sorted {
      let left = $0.value.updatedAt
      let right = $1.value.updatedAt
      return left == right ? $0.key > $1.key : left > right
    }.map(\.key)
  }
  public func isUnseen(_ day: String) -> Bool { entries[day]?.unseen == true }
  public func signature(for day: String) -> String? { entries[day]?.signature }

  public mutating func seed(_ summaries: [DaySummary]) throws {
    for summary in summaries where entries[summary.day] == nil {
      entries[summary.day] = Entry(
        signature: try Self.signature(summary), unseen: false, updatedAt: summary.updatedAt)
    }
  }
  public mutating func record(_ summary: DaySummary) throws {
    let signature = try Self.signature(summary)
    guard entries[summary.day]?.signature != signature else { return }
    entries[summary.day] = Entry(signature: signature, unseen: true, updatedAt: summary.updatedAt)
  }
  public mutating func markViewed(day: String, signature: String) {
    guard entries[day]?.signature == signature else { return }
    entries[day]?.unseen = false
  }
  public mutating func retain(days: Set<String>) {
    entries = entries.filter { days.contains($0.key) }
  }

  public static func signature(_ summary: DaySummary) throws -> String {
    struct Content: Encodable {
      let overview: String
      let decisions: [SummaryNote]
      let tasks: [SummaryNote]
      let activities: [DayActivity]?
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return Files.digest(
      try encoder.encode(
        Content(
          overview: summary.overview,
          decisions: summary.decisions, tasks: summary.tasks, activities: summary.activities)))
  }
}

extension ArchiveStore {
  public func dayResultUpdates() throws -> DayResultUpdates {
    let url = root.appendingPathComponent("Sync/day-result-updates.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return DayResultUpdates() }
    return try JSONDecoder().decode(DayResultUpdates.self, from: Data(contentsOf: url))
  }
  public func saveDayResultUpdates(_ updates: DayResultUpdates) throws {
    try Files.writeJSON(updates, to: root.appendingPathComponent("Sync/day-result-updates.json"))
  }
}
