import Foundation

struct InvalidConversationSelection: LocalizedError {
  let detail: String
  init(_ detail: String) { self.detail = detail }
  var errorDescription: String? { detail }
}

enum ConversationSelection {
  struct Topic: Decodable {
    let title: String
    let summary: String
    let decisions: [String]
    let tasks: [String]

    func proposal(first: TranscriptLine, last: TranscriptLine) throws -> ConversationProposal {
      let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty, title.count <= 100,
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw InvalidConversationSelection("片段标题或摘要无效") }
      return ConversationProposal(title: title, summary: summary, firstID: first.id, lastID: last.id,
        decisions: decisions, tasks: tasks)
    }
  }

  static func input(_ lines: [TranscriptLine]) throws -> String {
    struct NumberedLine: Encodable {
      let number: Int
      let start: Double
      let speaker: String?
      let text: String
    }
    let numbered = lines.enumerated().map { index, line in
      NumberedLine(number: index + 1, start: line.start, speaker: line.speaker, text: line.text)
    }
    return String(decoding: try JSONEncoder().encode(numbered), as: UTF8.self)
  }

  static func fromSections(_ data: Data, lines: [TranscriptLine]) throws -> [ConversationProposal] {
    struct Section: Decodable { let start: Int; let keep: Bool; let topic: Topic? }
    struct Response: Decodable { let sections: [Section] }
    let sections = try JSONDecoder().decode(Response.self, from: data).sections.sorted { $0.start < $1.start }
    var result: [ConversationProposal] = []
    for (index, section) in sections.enumerated() {
      guard section.start > 0, section.start <= lines.count else {
        throw InvalidConversationSelection("片段起点超出了本批的 \(lines.count) 句原文")
      }
      let next = index + 1 < sections.count ? sections[index + 1].start : lines.count + 1
      guard next > section.start, next <= lines.count + 1, section.keep == (section.topic != nil) else {
        throw InvalidConversationSelection("同一句的片段边界或保留标记有冲突")
      }
      if let topic = section.topic {
        result.append(try topic.proposal(first: lines[section.start - 1], last: lines[next - 2]))
      }
    }
    return result
  }

  static func fromLabels(_ data: Data, lines: [TranscriptLine]) throws -> [ConversationProposal] {
    struct Response: Decodable { let labels: [Int]; let topics: [Topic] }
    let value = try JSONDecoder().decode(Response.self, from: data)
    guard value.labels.count == lines.count else {
      throw InvalidConversationSelection("逐句标注需要 \(lines.count) 项，实际返回 \(value.labels.count) 项")
    }
    var result: [ConversationProposal] = []
    var used = Set<Int>()
    var start = 0
    while start < lines.count {
      let label = value.labels[start]
      var end = start + 1
      while end < lines.count && value.labels[end] == label { end += 1 }
      if label != 0 {
        guard label > 0, label <= value.topics.count, used.insert(label).inserted else {
          throw InvalidConversationSelection("逐句标注的对话编号无效或不连续")
        }
        result.append(try value.topics[label - 1].proposal(first: lines[start], last: lines[end - 1]))
      }
      start = end
    }
    guard used.count == value.topics.count else { throw InvalidConversationSelection("对话缺少对应原句") }
    return result
  }
}
