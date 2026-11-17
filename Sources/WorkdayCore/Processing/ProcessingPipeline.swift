import Foundation

extension ArchiveStore {
  public func document(for recording: Recording) throws -> ProcessingDocument? {
    let url = root.appendingPathComponent(recording.folder).appendingPathComponent(
      "processing.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let value = try JSONDecoder().decode(ProcessingDocument.self, from: Data(contentsOf: url))
    guard value.version == 1, value.recordingID == recording.id,
      value.sourceHash == recording.sha256
    else {
      throw WorkdayError.invalid("整理断点与原件不一致，原件已保留")
    }
    return value
  }
  public func save(_ document: ProcessingDocument, recording: Recording) throws {
    try Files.writeJSON(
      document,
      to: root.appendingPathComponent(recording.folder).appendingPathComponent("processing.json"))
  }
  public func summary(day: String) throws -> DaySummary? {
    let url = try dayDirectory(day).appendingPathComponent("summary.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(DaySummary.self, from: Data(contentsOf: url))
  }
  public func save(_ summary: DaySummary) throws {
    try Files.writeJSON(summary, to: dayDirectory(summary.day).appendingPathComponent("summary.json"))
  }
  func dayDirectory(_ day: String) throws -> URL {
    guard
      day == "日期未知" || day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    else { throw WorkdayError.invalid("日期无效") }
    return root.appendingPathComponent("Days/\(day)")
  }
}

public actor ProcessingPipeline {
  private let store: ArchiveStore
  private var active = false
  public init(store: ArchiveStore) { self.store = store }
  public func process(
    _ recording: Recording, service: any InferenceServing,
    progress: @Sendable (ProcessingDocument) async -> Void = { _ in }
  ) async throws -> ProcessingDocument {
    guard !active else { throw WorkdayError.invalid("已有录音正在整理") }
    active = true
    defer { active = false }
    let root = store.root
    let folder = root.appendingPathComponent(recording.folder)
    let original = folder.appendingPathComponent(recording.originalFile)
    var document =
      try await store.document(for: recording)
      ?? ProcessingDocument(recording: recording, model: service.transcriptionModel)
    if document.phase == "complete" { return document }
    // ESP can resume a legacy Flash 3.0 recording using its existing transcription checkpoint.
    if service is AIService, document.model == "qwen-audio-3.0-asr-flash" {
      document.legacyFlash30Chunks = document.completedChunks
      document.model = service.transcriptionModel
    }
    do {
      guard try Files.hash(original) == recording.sha256 else {
        throw WorkdayError.invalid("原件校验失败，请检查本地文件，整理已暂停")
      }
      let chunkDuration = ProcessingDocument.chunkDuration
      let count = Int(ceil(recording.duration / chunkDuration))
      guard document.completedChunks >= 0, document.completedChunks <= count,
        document.model == service.transcriptionModel
      else { throw WorkdayError.invalid("整理断点与当前识别模型不一致") }
      document.error = nil
      document.phase = "transcribing"
      try await checkpoint(&document, recording: recording, progress: progress)
      for index in document.completedChunks..<count {
        try Task.checkCancellation()
        let offset = Double(index) * chunkDuration
        let length = min(chunkDuration, recording.duration - offset)
        let audio = try AudioFiles.wavChunk(original, start: offset, duration: length)
        let lines = try await service.transcribe(
          audio: audio, format: "wav", chunk: index, offset: offset, duration: length)
        guard
          lines.allSatisfy({
            $0.start.isFinite && $0.end.isFinite && $0.start >= offset
              && $0.end <= offset + length + 0.001 && $0.end > $0.start
          }),
          Set((document.transcript + lines).map(\.id)).count == document.transcript.count
            + lines.count
        else {
          throw WorkdayError.invalid("转写时间轴或句子标识无效")
        }
        document.transcript += lines
        document.completedChunks = index + 1
        try await checkpoint(&document, recording: recording, progress: progress)
      }
      document.phase = "organizing"
      if document.analyzedBatches == 0 { document.editorialVersion = 2 }
      let batches = Self.batches(document.transcript)
      // Keep the saved batch numbers stable. Within each batch, organize each side of a
      // skipped chunk independently so a proposed clip can never span the missing words.
      let recognizedChunks = IndexSet(integersIn: 0..<count).subtracting(document.chunksWithoutWords)
      let contentRanges = recognizedChunks.rangeView.map { range in
        let end = min(Double(range.upperBound) * chunkDuration, recording.duration)
        return (Double(range.lowerBound) * chunkDuration)..<end
      }
      guard document.analyzedBatches <= batches.count else {
        throw WorkdayError.invalid("对话整理断点无效")
      }
      try await checkpoint(&document, recording: recording, progress: progress)
      for index in document.analyzedBatches..<batches.count {
        try Task.checkCancellation()
        let selection = try await Self.organize(
          batches[index][...], within: contentRanges, service: service)
        document.proposals += selection.proposals
        document.retainForDay(selection.deferredLineIDs)
        document.analyzedBatches = index + 1
        try await checkpoint(&document, recording: recording, progress: progress)
      }
      // Older interrupted clipping runs keep their existing clip/proposal correspondence.
      if document.conversations.isEmpty {
        let boundaryCount = max(0, batches.count - 1)
        for index in min(document.reviewedBoundaries ?? 0, boundaryCount)..<boundaryCount {
          try Task.checkCancellation()
          if let before = batches[index].last?.id, let after = batches[index + 1].first?.id {
            document.proposals = try await ConversationBoundary.reconcile(
              document.proposals,
              before: before, after: after, lines: document.transcript, service: service)
          }
          document.reviewedBoundaries = index + 1
          try await checkpoint(&document, recording: recording, progress: progress)
        }
      }
      try AIService.validate(document.proposals, lines: document.transcript)
      document.phase = "clipping"
      try await checkpoint(&document, recording: recording, progress: progress)
      while document.conversations.count < document.proposals.count {
        try Task.checkCancellation()
        let index = document.conversations.count
        let proposal = document.proposals[index]
        guard let first = document.transcript.firstIndex(where: { $0.id == proposal.firstID }),
          let last = document.transcript.firstIndex(where: { $0.id == proposal.lastID }),
          first <= last
        else { throw WorkdayError.invalid("剪辑依据不存在") }
        let firstLine = document.transcript[first]
        let lastLine = document.transcript[last]
        guard let range = contentRanges.first(where: { $0.contains(firstLine.start) })
        else { throw WorkdayError.invalid("剪辑时间超出了已转写范围") }
        // A proposal saved by an older version can span a skipped chunk.
        if !range.contains(lastLine.start) {
          let selected = try await Self.organize(
            document.transcript[first...last], within: contentRanges, service: service)
          document.proposals.replaceSubrange(index...index, with: selected.proposals)
          document.retainForDay(selected.deferredLineIDs)
          try await checkpoint(&document, recording: recording, progress: progress)
          continue
        }
        let previousEnd = first > 0 ? document.transcript[first - 1].end : 0
        let nextStart = last + 1 < document.transcript.count
          ? document.transcript[last + 1].start : recording.duration
        let start = max(range.lowerBound, firstLine.start - 0.35, min(previousEnd, firstLine.start))
        let end = min(range.upperBound, lastLine.end + 0.5, max(nextStart, lastLine.end))
        let id = UUID().uuidString.lowercased()
        let pending = root.appendingPathComponent(".incoming/clip-\(id).wav")
        defer { try? FileManager.default.removeItem(at: pending) }
        try AudioFiles.slice(original, start: start, end: end, destination: pending)
        let hash = try Files.hash(pending)
        let relative = "clips/\(id).wav"
        let destination = folder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        try FileManager.default.moveItem(at: pending, to: destination)
        let clip = Conversation(
          id: id, recordingID: recording.id, title: proposal.title, summary: proposal.summary,
          start: start, end: end, lineIDs: Array(document.transcript[first...last].map(\.id)),
          audioFile: relative,
          sha256: hash, decisions: proposal.decisions, tasks: proposal.tasks)
        document.conversations.append(clip)
        try await checkpoint(&document, recording: recording, progress: progress)
      }
      for clip in document.conversations {
        let url = folder.appendingPathComponent(clip.audioFile)
        guard
          clip.audioFile.range(of: #"^clips/[0-9a-f-]+\.wav$"#, options: .regularExpression) != nil,
          try Files.hash(url) == clip.sha256,
          abs(try AudioFiles.duration(url) - (clip.end - clip.start)) < 0.05
        else { throw WorkdayError.invalid("剪辑文件未通过归档核验") }
      }
      document.phase = "complete"
      try await checkpoint(&document, recording: recording, progress: progress)
      return document
    } catch {
      document.phase = "failed"
      document.error = error is CancellationError ? "整理已暂停，下次可从已保存位置继续" : error.localizedDescription
      // A failed checkpoint must remain an error; never report a completed archive.
      try await checkpoint(&document, recording: recording, progress: progress)
      throw error
    }
  }
  private func checkpoint(
    _ document: inout ProcessingDocument, recording: Recording,
    progress: @Sendable (ProcessingDocument) async -> Void
  ) async throws {
    document.updatedAt = Date()
    try await store.save(document, recording: recording)
    await progress(document)
  }
  private static func organize(
    _ batch: ArraySlice<TranscriptLine>, within ranges: [Range<Double>], service: any InferenceServing
  ) async throws -> ConversationBatch {
    var result = ConversationBatch()
    guard let first = batch.first, let last = batch.last else { return result }
    for range in ranges where range.upperBound > first.start && range.lowerBound <= last.start {
      let lines = batch.filter { range.contains($0.start) }
      guard !lines.isEmpty else { continue }
      let selected = try await service.organizeBatch(lines: lines)
      try AIService.validate(selected.proposals, lines: lines)
      result.proposals += selected.proposals
      result.deferredLineIDs += selected.deferredLineIDs
    }
    return result
  }
  private static func batches(_ lines: [TranscriptLine]) -> [[TranscriptLine]] {
    var result: [[TranscriptLine]] = []
    var current: [TranscriptLine] = []
    var bytes = 0
    for line in lines {
      if let first = current.first, let last = current.last,
        line.start - first.start > 900 || line.start - last.end > 120
          || bytes + line.text.utf8.count > 24000
      {
        result.append(current)
        current = []
        bytes = 0
      }
      current.append(line)
      bytes += line.text.utf8.count
    }
    if !current.isEmpty { result.append(current) }
    return result
  }
}
