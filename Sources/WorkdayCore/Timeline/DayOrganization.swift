import Darwin
import Foundation

/// A reference points to a sentence in an original recording, clipped at a pause or midnight.
extension WorkdayTimeline {
  public static func sentenceSlices(
    day: String, recording: Recording, document: ProcessingDocument
  ) -> [[Conversation]] {
    let spans = slices(recording, start: 0, end: recording.duration).filter { $0.day == day }
    return spans.map { span in
      document.transcript.compactMap { line -> Conversation? in
        let start = max(line.start, span.start)
        let end = min(line.end, span.end)
        guard line.start.isFinite, line.end.isFinite, start < end,
          !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let date = span.date?.addingTimeInterval(start - span.start)
        return Conversation(
          id: "\(recording.id)/\(line.id)/\(start)", recordingID: recording.id, title: "",
          summary: line.text, start: start, end: end, lineIDs: [line.id], excerpt: [line],
          wallStart: date, wallEnd: date?.addingTimeInterval(end - start), audioSourceStart: 0,
          audioFile: recording.originalFile, sha256: recording.sha256, decisions: [], tasks: [])
      }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
  }
}

public struct DayOrganization: Codable, Sendable {
  public struct Item: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    /// Original automatic activity evidence, used to reattach after the day is regenerated.
    public let anchors: [String]
    public let anchorSentences: [String]
    public let initialSentences: [String]
    public var sentences: [String]

    public init(
      title: String, summary: String, anchors: [String], anchorSentences: [String],
      sentences: [String]
    ) {
      self.id = "manual:" + UUID().uuidString
      self.title = title
      self.summary = summary
      self.anchors = anchors
      self.anchorSentences = anchorSentences
      self.initialSentences = sentences
      self.sentences = sentences
    }
  }
  public fileprivate(set) var revision = 0
  public var items: [Item] = []
  public init() {}
}

extension ArchiveStore {
  public func organization(day: String) throws -> DayOrganization {
    let url = try dayDirectory(day).appendingPathComponent("organization.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return DayOrganization() }
    return try JSONDecoder().decode(DayOrganization.self, from: Data(contentsOf: url))
  }

  public func saveOrganization(_ proposal: DayOrganization, day: String) throws -> DayOrganization {
    // Separate app instances can open the same local library. Lock the directory
    // because atomic JSON replacement changes the inode of the data file.
    let directory = try dayDirectory(day)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let fd = open(directory.path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    while flock(fd, LOCK_EX) != 0 {
      if errno != EINTR { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
    let current = try organization(day: day)
    guard proposal.revision == current.revision else {
      throw WorkdayError.invalid("当天事项已有更新，请重新选择原话后保存。")
    }
    var next = proposal
    next.revision += 1
    try Files.writeJSON(next, to: directory.appendingPathComponent("organization.json"))
    return next
  }
}
