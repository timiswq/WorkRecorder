import Foundation

public struct TranscriptLine: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var start: Double
  public var end: Double
  public var text: String
  public var speaker: String?
  public init(id: String, start: Double, end: Double, text: String, speaker: String? = nil) {
    self.id = id
    self.start = start
    self.end = end
    self.text = text
    self.speaker = speaker
  }
}

public struct ConversationProposal: Codable, Equatable, Sendable {
  public var title: String
  public var summary: String
  public var firstID: String
  public var lastID: String
  public var decisions: [String]
  public var tasks: [String]
  public init(
    title: String, summary: String, firstID: String, lastID: String, decisions: [String] = [],
    tasks: [String] = []
  ) {
    self.title = title
    self.summary = summary
    self.firstID = firstID
    self.lastID = lastID
    self.decisions = decisions
    self.tasks = tasks
  }
}

public struct ConversationBatch: Sendable {
  public var proposals: [ConversationProposal]
  public var deferredLineIDs: [String]

  public init(proposals: [ConversationProposal] = [], deferredLineIDs: [String] = []) {
    self.proposals = proposals
    self.deferredLineIDs = deferredLineIDs
  }
}

public struct Conversation: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var recordingID: String
  public var title: String
  public var summary: String
  public var start: Double
  public var end: Double
  public var lineIDs: [String]
  public var excerpt: [TranscriptLine]?
  public var needsClassification: Bool?
  public var wallStart: Date?
  public var wallEnd: Date?
  public var audioSourceStart: Double?
  public var audioFile: String
  public var sha256: String
  public var decisions: [String]
  public var tasks: [String]
}

public struct ProcessingDocument: Codable, Sendable {
  static let chunkDuration: Double = 120
  public var version = 1
  public var recordingID: String
  public var sourceHash: String
  public var phase = "pending"
  public var error: String?
  public var completedChunks = 0
  public var analyzedBatches = 0
  public var deferredLineIDs: [String]?
  public var reviewedBoundaries: Int?
  public var editorialVersion: Int?
  public var transcript: [TranscriptLine] = []
  public var proposals: [ConversationProposal] = []
  public var conversations: [Conversation] = []
  public var updatedAt = Date()
  public var model: String
  public var legacyFlash30Chunks: Int?
  public init(recording: Recording, model: String) {
    recordingID = recording.id
    sourceHash = recording.sha256
    self.model = model
  }

  mutating func retainForDay(_ lineIDs: [String]) {
    guard !lineIDs.isEmpty else { return }
    deferredLineIDs = (deferredLineIDs ?? []) + lineIDs
  }
  // A completed chunk with no transcript lines is a durable outcome, including in older archives.
  var chunksWithoutWords: IndexSet {
    var missing = IndexSet(integersIn: 0..<max(0, completedChunks))
    let processedDuration = Double(completedChunks) * Self.chunkDuration
    for line in transcript where line.start >= 0 && line.start < processedDuration {
      missing.remove(Int(line.start / Self.chunkDuration))
    }
    return missing
  }

  public var unrecognizedChunkDescription: String? {
    let ranges = chunksWithoutWords.rangeView.map { range in
      range.count == 1 ? "\(range.lowerBound + 1)" : "\(range.lowerBound + 1)–\(range.upperBound)"
    }
    return ranges.isEmpty ? nil : "第 \(ranges.joined(separator: "、")) 段未识别到文字"
  }

  public var label: String {
    switch phase {
    case "transcribing": return "正在转写"
    case "organizing": return "正在提取事项"
    case "clipping": return "正在保存剪辑"
    case "complete":
      if let count = deferredLineIDs?.count, count > 0 { return "已生成文字与事项 · \(count) 句保留为原话" }
      return "文字与事项已生成"
    case "failed": return "录音处理失败"
    default: return "录音尚未处理"
    }
  }
}

public struct SummaryNote: Codable, Identifiable, Equatable, Sendable {
  public var text: String
  public var conversationIDs: [String]
  public var id: String { text + conversationIDs.joined() }
  public init(text: String, conversationIDs: [String]) {
    self.text = text
    self.conversationIDs = conversationIDs
  }
}
public struct DaySummary: Codable, Sendable {
  public var day: String
  public var overview: String
  public var decisions: [SummaryNote]
  public var tasks: [SummaryNote]
  public var recordingIDs: [String]
  public var updatedAt: Date
  public var inputFingerprint: String?
  public var activities: [DayActivity]?
  public init(
    day: String, overview: String, decisions: [SummaryNote] = [], tasks: [SummaryNote] = [],
    recordingIDs: [String], updatedAt: Date = Date()
  ) {
    self.day = day
    self.overview = overview
    self.decisions = decisions
    self.tasks = tasks
    self.recordingIDs = recordingIDs
    self.updatedAt = updatedAt
  }
}

public protocol InferenceServing: Sendable {
  var transcriptionModel: String { get }
  func transcribe(audio: Data, format: String, chunk: Int, offset: Double, duration: Double)
    async throws -> [TranscriptLine]
  func organize(lines: [TranscriptLine]) async throws -> [ConversationProposal]
  func organizeBatch(lines: [TranscriptLine]) async throws -> ConversationBatch
  func summarize(day: String, conversations: [Conversation], recordingIDs: [String]) async throws
    -> DaySummary
}

extension InferenceServing {
  public func organizeBatch(lines: [TranscriptLine]) async throws -> ConversationBatch {
    ConversationBatch(proposals: try await organize(lines: lines))
  }
}
