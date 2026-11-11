import Foundation

/// Evidence belongs to a dated slice, so one activity can cite several originals.
public struct DayActivity: Codable, Identifiable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case event, moment, aside }
  public var kind: Kind
  public var title: String
  public var summary: String
  public var conversationIDs: [String]
  public var topics: [String]?
  public var appointment: String?
  public var relatedIDs: [String]?
  public var quotes: [String: [String]]?
  public var id: String { conversationIDs.first ?? "" }

  public init(kind: Kind, title: String, summary: String, conversationIDs: [String]) {
    self.kind = kind
    self.title = title
    self.summary = summary
    self.conversationIDs = conversationIDs
  }

  /// Keep older archives and newly imported evidence readable before a day is reorganized.
  public static func timeline(_ clips: [Conversation], saved: [DayActivity]?) -> [DayActivity] {
    let order = Dictionary(uniqueKeysWithValues: clips.enumerated().map { ($1.id, $0) })
    var used = Set<String>()
    var items: [DayActivity] = []
    for var item in saved ?? [] {
      guard item.conversationIDs.allSatisfy({ order[$0] != nil && !used.contains($0) }) else {
        continue
      }
      item.conversationIDs = item.conversationIDs.filter { used.insert($0).inserted }
        .sorted { order[$0]! < order[$1]! }
      if !item.conversationIDs.isEmpty { items.append(item) }
    }
    var provisional: [DayActivity] = []
    var previous: Conversation?
    for clip in clips {
      guard clip.needsClassification != true, !used.contains(clip.id) else {
        previous = nil
        continue
      }
      if let last = previous, let end = last.wallEnd, let start = clip.wallStart,
        clip.title == last.title, (0...180).contains(start.timeIntervalSince(end)),
        !provisional.isEmpty
      {
        let i = provisional.count - 1
        provisional[i].conversationIDs.append(clip.id)
        if clip.summary != last.summary { provisional[i].summary += "\n" + clip.summary }
      } else {
        provisional.append(
          DayActivity(
            kind: .event, title: clip.title, summary: clip.summary,
            conversationIDs: [clip.id]))
      }
      previous = clip
    }
    return (items + provisional).sorted { order[$0.id]! < order[$1.id]! }
  }
}

/// Short ordinal references reduce model output and are resolved before persistence.
struct DayActivityProposal: Decodable {
  let kind: DayActivity.Kind
  let title: String
  let summary: String
  let parts: [Int]

  var topics: [String]?
  var appointment: String?
  var related: [Int]?
  struct Quote: Decodable {
    let part: Int
    let line: String
  }
  var quotes: [Quote]?

  static func resolve(_ proposals: [Self], against clips: [Conversation]) throws -> [DayActivity] {
    var used = Set<Int>()
    let items = try proposals.map { item -> DayActivity in
      guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !item.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !item.parts.isEmpty,
        item.parts.allSatisfy({
          $0 > 0 && $0 <= clips.count && used.insert($0).inserted
        })
      else { throw WorkdayError.invalid("事项引用无效或重复，请重试当天整理") }
      var activity = DayActivity(
        kind: item.kind, title: item.title, summary: item.summary,
        conversationIDs: item.parts.sorted().map { clips[$0 - 1].id })
      activity.topics = item.topics
      activity.appointment = item.appointment
      if let related = item.related {
        guard related.allSatisfy({ $0 > 0 && $0 <= clips.count && !item.parts.contains($0) })
        else { throw WorkdayError.invalid("关联事项无法定位，请重试当天整理") }
        activity.relatedIDs = related.map { clips[$0 - 1].id }
      }
      for quote in item.quotes ?? [] {
        guard item.parts.contains(quote.part), clips[quote.part - 1].lineIDs.contains(quote.line)
        else { throw WorkdayError.invalid("引述原话无法定位，请重试当天整理") }
        if activity.quotes == nil { activity.quotes = [:] }
        activity.quotes?[clips[quote.part - 1].id, default: []].append(quote.line)
      }
      return activity
    }
    guard
      clips.indices.allSatisfy({ used.contains($0 + 1) || clips[$0].needsClassification == true })
    else { throw WorkdayError.invalid("当天事项遗漏了工作对话，请重试整理") }
    return items
  }
}
