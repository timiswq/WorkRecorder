import Combine
import Foundation
import WorkdayCore

struct CaptionSpeaker {
  let id: String
  let label: VoiceLabel
  var markedHere = false

  var controls: CaptionIdentityControls { label.isMine ? .reject : .confirm }
}

@MainActor final class VoiceRecognition: ObservableObject {
  private let root: URL
  private let encoder = SpeakerEncoder()
  private var library: VoiceLibrary?
  private var archives: [String: (Recording, [TranscriptLine])] = [:]
  private var scheduled: [String: Int] = [:]
  private var archiveTask: Task<Void, Never>?
  private var liveTasks: [String: Task<Void, Never>] = [:]
  private enum CaptionMark { case mine, notMine }
  private var pendingCaptions: [String: CaptionMark] = [:]
  private var stopped = false
  @Published private(set) var error: String?
  var confirmed: Bool { library?.confirmed == true }
  var sampleCount: Int { library?.sampleCount ?? 0 }
  var negativeSampleCount: Int { library?.negativeSampleCount ?? 0 }

  init(root: URL) {
    self.root = root
    if FileManager.default.fileExists(
      atPath: root.appendingPathComponent("Sync/voice-campplus-v1.sqlite").path)
    {
      do { library = try VoiceLibrary(root: root) } catch {
        self.error = error.localizedDescription
      }
    }
  }
  private func db() throws -> VoiceLibrary {
    if let library { return library }
    let new = try VoiceLibrary(root: root)
    library = new
    return new
  }
  static func key(_ recording: Recording, _ line: TranscriptLine) -> String {
    "file:" + recording.id + ":" + recording.sha256 + ":" + line.id
  }
  static func source(_ filename: String?, fallback: String) -> String {
    guard let filename, !filename.isEmpty else { return fallback }
    return InventoryEntry.stem(filename).lowercased()
  }
  func label(_ id: String?) -> VoiceLabel? {
    guard let id else { return nil }
    if let library { return try? library.label(id) }
    return id.hasPrefix("caption:") ? .forUtterance() : nil
  }
  func captionSpeaker(lineID: String, evidenceID: String?) -> CaptionSpeaker {
    let utterance = "caption:" + lineID
    let local = label(utterance) ?? .forUtterance()
    if let sample = local.sampleID { return CaptionSpeaker(id: sample, label: local, markedHere: true) }
    if !local.isMine, !local.excluded, let evidenceID, var matched = label(evidenceID) {
      // A sample confirmed on a covering cloud turn is an inference for this local bubble.
      if evidenceID.hasPrefix("live:"), evidenceID != "live:" + lineID { matched.sampleID = nil }
      return CaptionSpeaker(id: evidenceID, label: matched)
    }
    return CaptionSpeaker(id: utterance, label: local, markedHere: local.isMine || local.excluded)
  }
  func confirm(_ id: String, captionLineID: String? = nil) {
    change { db in
      let utterance = captionLineID.map { "caption:" + $0 }
      try db.confirm(id, utterance: utterance)
      if let line = captionLineID, id == utterance, try db.label(id) == .forUtterance(mine: true) {
        pendingCaptions[line] = .mine
      }
    }
  }
  func setCaptionMark(lineID: String, mine: Bool, evidence: String?) {
    change { db in
      let mark = "caption:" + lineID
      try db.setCaptionMark(mark, mine: mine, evidence: evidence)
      pendingCaptions[lineID] = try db.label(mark) == .forUtterance(mine: mine)
        ? (mine ? .mine : .notMine) : nil
    }
  }
  /// A tap on a draft can precede both the final timestamps and local inference.
  func resolvePendingCaptions(in live: LivePreview) {
    guard !pendingCaptions.isEmpty, let library else { return }
    do {
      let retained = Set(live.lines.map(\.id))
      pendingCaptions = pendingCaptions.filter { retained.contains($0.key) }
      for line in live.lines {
        guard let mark = pendingCaptions[line.id], let id = line.voiceID else { continue }
        guard try library.contains(id) else {
          if let audio = live.confirmationAudio[line.id] {
            observeLive(id: id, source: audio.source, packets: audio.packets, seconds: audio.seconds,
                        countDuration: false)
          }
          continue
        }
        let utterance = "caption:" + line.id
        switch mark {
        case .mine: try library.confirm(id, utterance: utterance, pendingOnly: true)
        case .notMine: try library.markNotMine(utterance, evidence: id, pendingOnly: true)
        }
        pendingCaptions[line.id] = nil
        objectWillChange.send()
      }
    } catch { report(error) }
  }
  func setExcluded(_ excluded: Bool, for id: String) {
    change { db in
      guard let label = try db.label(id), excluded ? (label.canConfirm || label.canAddSample) : label.excluded
      else { return }
      if let group = label.group, !label.isMine {
        if excluded { try db.reject(group) } else { try db.restore(group) }
      } else if excluded {
        try db.markNotMine(id, evidence: id.hasPrefix("caption:") ? nil : id)
      } else {
        try db.undoNotMine(id)
        if id.hasPrefix("caption:") { pendingCaptions[String(id.dropFirst("caption:".count))] = nil }
      }
    }
  }
  func undoConfirmation(for id: String) {
    change { db in
      guard let label = try db.label(id), label.isMine else { return }
      if let sample = label.sampleID { try db.removeSample(sample) }
      else if label.group == nil {
        try db.markUtterance(id, mine: nil)
        if id.hasPrefix("caption:") { pendingCaptions[String(id.dropFirst("caption:".count))] = nil }
      }
    }
  }
  func name(_ group: Int64, _ name: String) { change { try $0.name(group, name) } }
  func undo() {
    change {
      try $0.undoConfirmation()
      pendingCaptions = pendingCaptions.filter { $0.value != .mine }
    }
  }
  func clearNegativeSamples() {
    change {
      try $0.clearNegativeSamples()
      pendingCaptions = pendingCaptions.filter { $0.value != .notMine }
    }
  }
  private func change(_ perform: (VoiceLibrary) throws -> Void) {
    do {
      try perform(db())
      if error != nil { error = nil }
      objectWillChange.send()
    } catch { report(error) }
  }
  private func report(_ failure: Error) {
    if !(failure is CancellationError), !stopped, error != failure.localizedDescription {
      error = failure.localizedDescription
    }
  }
  func observeLive(id: String, source: String, packets: Data, seconds: Double, countDuration: Bool = true) {
    guard !stopped, liveTasks[id] == nil else { return }
    liveTasks[id] = Task {
      defer { liveTasks[id] = nil }
      do {
        let database = try db()
        guard try !database.contains(id) else { return }
        let vector = try await encoder.live(packets: packets)
        try Task.checkCancellation()
        try database.record(id: id, source: source, live: true, seconds: seconds, voice: vector,
                            countDuration: countDuration)
        objectWillChange.send()
      } catch { report(error) }
    }
  }
  func observeArchive(_ recording: Recording, lines: [TranscriptLine]) {
    guard !stopped, !lines.isEmpty, scheduled[recording.id] != lines.count else { return }
    scheduled[recording.id] = lines.count
    archives[recording.id] = (recording, lines)
    guard archiveTask == nil else { return }
    archiveTask = Task(priority: .utility) {
      defer { archiveTask = nil }
      while !Task.isCancelled, let entry = archives.first {
        archives[entry.key] = nil
        do { try await index(entry.value.0, lines: entry.value.1) } catch {
          scheduled[entry.key] = nil
          report(error)
        }
      }
    }
  }
  private func index(_ recording: Recording, lines: [TranscriptLine]) async throws {
    let file = root.appendingPathComponent(recording.folder).appendingPathComponent(
      recording.originalFile)
    let source = Self.source(recording.originalName, fallback: recording.id)
    let database = try db()
    let sorted = lines.sorted { $0.start < $1.start }
    var lastEnd: Double = 0
    for (i, line) in sorted.enumerated() {
      try Task.checkCancellation()
      let id = Self.key(recording, line)
      let overlap = line.start < lastEnd || (i + 1 < sorted.count && sorted[i + 1].start < line.end)
      lastEnd = max(lastEnd, line.end)
      guard try !database.contains(id) else {
        if i.isMultiple(of: 32) { await Task.yield() }
        continue
      }
      let vector =
        overlap ? nil : try await encoder.archived(file: file, start: line.start, end: line.end)
      try Task.checkCancellation()
      try database.record(
        id: id, source: source, live: false, seconds: line.end - line.start, voice: vector)
      if vector != nil { objectWillChange.send() }
    }
  }
  func waitForStoppedTasks() async {
    let tasks = Array(liveTasks.values)
    await archiveTask?.value
    for task in tasks { await task.value }
  }
  func stop() {
    stopped = true
    archiveTask?.cancel()
    archives = [:]
    for task in liveTasks.values { task.cancel() }
  }
}
