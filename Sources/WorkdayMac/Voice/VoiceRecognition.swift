import Combine
import Foundation
import WorkdayCore

struct CaptionSpeaker {
  let id: String
  let label: VoiceLabel
  /// Persisted feedback to edit or undo. An inferred speaker has no mark on this caption.
  let markID: String?
  var markedHere: Bool { markID != nil }

  var hasSavedSample: Bool { markedHere && (label.sampleID != nil || label.isNegativeSample) }
  func title(using preferences: CaptionPreferences) -> String {
    markedHere && label.excluded ? "非本人" : label.captionTitle(using: preferences)
  }
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
  private let usableLiveVoices = NSCache<NSString, NSNumber>()
  private(set) var captionIdentityRevision = 0
  private var stopped = false
  var onRealtimeIdentityChanged: (([LiveLine]) -> Void)?
  private lazy var realtime = RealtimeVoiceRecognition(database: { [unowned self] in try self.db() },
    changed: { [weak self] lines in
      guard let self else { return }
      self.captionIdentityRevision += 1
      self.objectWillChange.send()
      self.onRealtimeIdentityChanged?(lines)
    }, failure: { [weak self] in self?.report($0) })
  @Published private(set) var error: String?
  var confirmed: Bool { library?.confirmed == true }
  var sampleCount: Int { library?.sampleCount ?? 0 }
  var negativeSampleCount: Int { library?.negativeSampleCount ?? 0 }
  var canClearSamples: Bool { sampleCount > 0 || negativeSampleCount > 0 }

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
    if let library {
      let saved = try? library.label(id)
      if saved?.sampleID != nil || saved?.isNegativeSample == true { return saved }
      return realtime.label(id) ?? saved
    }
    return id.hasPrefix("caption:") ? .forUtterance() : nil
  }
  // A label without audio follows the transcript row. A confirmed draft sample follows its exact audio span.
  static func captionMark(_ lineID: String, evidence: String?) -> String {
    if let evidence, evidence.hasPrefix("draft:") { return "caption:" + evidence }
    return "caption:" + lineID
  }
  func captionSpeaker(lineID: String, evidenceID: String?) -> CaptionSpeaker {
    let row = Self.captionMark(lineID, evidence: nil)
    let utterance = Self.captionMark(lineID, evidence: evidenceID)
    if row != utterance, let mark = label(row), mark.isMine || mark.excluded {
      return CaptionSpeaker(id: mark.sampleID ?? row, label: mark, markID: row)
    }
    let local = label(utterance) ?? .forUtterance()
    if local.isMine || local.excluded {
      return CaptionSpeaker(id: local.sampleID ?? utterance, label: local, markID: utterance)
    }
    if let evidenceID, var matched = label(evidenceID) {
      // A sample confirmed on a covering cloud turn is an inference for this local bubble.
      if evidenceID.hasPrefix("live:"), evidenceID != "live:" + lineID { matched.sampleID = nil }
      return CaptionSpeaker(id: evidenceID, label: matched, markID: nil)
    }
    return CaptionSpeaker(id: utterance, label: local, markID: nil)
  }
  func usableVoiceID(for line: LiveLine) -> String? {
    guard let id = line.bubbleVoiceID, hasLiveVoice(id) else { return nil }
    return id
  }
  func hasLiveVoice(_ id: String?) -> Bool {
    guard let id else { return false }
    if id.hasPrefix("realtime:") { return realtime.hasVoice(id) || (try? db().hasLiveVoice(id)) == true }
    if let known = usableLiveVoices.object(forKey: id as NSString) { return known.boolValue }
    let usable = (try? db().hasLiveVoice(id)) == true
    usableLiveVoices.setObject(NSNumber(value: usable), forKey: id as NSString)
    return usable
  }

  func appendLiveAudio(_ data: Data, offset: Int, source: String) {
    realtime.append(data, offset: offset, source: source)
  }
  func resetLiveAudio() { realtime.reset() }
  func observeLiveLines(_ lines: [LiveLine]) { realtime.observe(lines) }
  func presentationLine(_ line: LiveLine) -> LiveLine { realtime.presentation(line) }
  func receiveLiveEvidence(_ evidence: LiveVoiceEvidence) { realtime.receive(evidence) }
  var liveWindowsProcessed: Int { realtime.windowsProcessed }
  var inconsistentSampleCount: Int { (try? db().sampleConsistency().compactMap { $0 }.filter { $0 < 0.50 }.count) ?? 0 }
  func confirm(_ id: String, captionLineID: String? = nil) {
    change { db in
      let utterance = captionLineID.map { "caption:" + $0 }
      try db.confirm(id, utterance: utterance)
    }
  }

  /// Decide sample eligibility at the instant of feedback. A later voice result cannot enroll a label.
  func setCaptionMark(lineID: String, mine: Bool, evidence: String?, packets: Data? = nil) {
    updateIdentity { db in
      var sample = evidence
      var audio = packets
      if let evidence, evidence.hasPrefix("realtime:"), let current = realtime.feedbackPackets(evidence) {
        let selected = packets ?? current
        audio = selected
        if try !realtime.persistFeedback(id: evidence, packets: selected, database: db) { sample = nil }
      }
      if let id = sample, try !db.canEnrollCaption(id) { sample = nil }
      if let audio, !SpeakerEncoder.acceptsLivePacketCount(audio.count) { sample = nil }
      let previous = captionSpeaker(lineID: lineID, evidenceID: evidence)
      let mark = previous.markID ?? Self.captionMark(lineID, evidence: sample)
      try db.setCaptionMark(mark, mine: mine, evidence: sample, packets: sample == nil ? nil : audio)
      return sample != nil || previous.hasSavedSample
    }
  }
  func setExcluded(_ excluded: Bool, for id: String) {
    updateIdentity { db in
      guard let label = try db.label(id), excluded ? (label.canConfirm || label.canAddSample) : label.excluded
      else { return false }
      if let group = label.group, !label.isMine {
        if excluded { try db.reject(group) } else { try db.restore(group) }
      } else if excluded {
        try db.markNotMine(id, evidence: id.hasPrefix("caption:") ? nil : id)
      } else {
        try db.undoNotMine(id)
      }
      return label.group != nil || label.isNegativeSample || !id.hasPrefix("caption:")
    }
  }
  func undoConfirmation(for id: String) {
    updateIdentity { db in
      guard let label = try db.label(id), label.isMine else { return false }
      if let sample = label.sampleID { try db.removeSample(sample) }
      else if label.group == nil {
        try db.markUtterance(id, mine: nil)
      }
      return label.sampleID != nil
    }
  }
  func name(_ group: Int64, _ name: String) { change { try $0.name(group, name) } }
  func nameArchiveSpeaker(_ turn: String, _ name: String) {
    change { try $0.nameArchiveSpeaker(turn: turn, name: name) }
  }
  func undo() { change { try $0.undoConfirmation() } }
  func clearNegativeSamples() { change { try $0.clearNegativeSamples() } }
  func clearSamples() { change { try $0.clearSamples() } }
  private func change(_ perform: (VoiceLibrary) throws -> Void) {
    updateIdentity { db in
      try perform(db)
      return true
    }
  }
  /// A label-only correction leaves continuous speaker tracking intact.
  private func updateIdentity(_ edit: (VoiceLibrary) throws -> Bool) {
    do {
      if try edit(db()) { realtime.profileChanged() }
      if error != nil { error = nil }
      captionIdentityRevision += 1
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
        if try database.contains(id) {
          if countDuration, id.hasPrefix("draft:") { try database.creditFinalDraft(id, seconds: seconds) }
          return
        }
        let vector = try await encoder.live(packets: packets)
        try Task.checkCancellation()
        if vector != nil || !id.hasPrefix("draft:") {
          try recordLive(id: id, source: source, seconds: seconds, vector: vector, countDuration: countDuration)
        }
      } catch { report(error) }
    }
  }
  func recordLive(id: String, source: String, seconds: Double, vector: [Float]?, countDuration: Bool) throws {
    try db().record(id: id, source: source, live: true, seconds: seconds, voice: vector, countDuration: countDuration)
    usableLiveVoices.removeObject(forKey: id as NSString)
    captionIdentityRevision += 1
    objectWillChange.send()
  }

  func observeArchive(_ recording: Recording, lines: [TranscriptLine]) {
    guard !stopped, !lines.isEmpty else { return }
    var timing = Hasher()
    timing.combine(recording.sha256)
    for line in lines {
      timing.combine(line.id)
      timing.combine(line.start)
      timing.combine(line.end)
      timing.combine(line.speaker)
    }
    let signature = timing.finalize()
    guard scheduled[recording.id] != signature else { return }
    scheduled[recording.id] = signature
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
    let sorted = lines.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
      .sorted { $0.start < $1.start }
    let archiveID = recording.id + ":" + recording.sha256
    var speakers: [String: ArchiveSpeaker] = [:]
    var lastEnd: Double = 0
    for (i, line) in sorted.enumerated() {
      try Task.checkCancellation()
      let id = Self.key(recording, line)
      let overlap = line.start < lastEnd || (i + 1 < sorted.count && sorted[i + 1].start < line.end)
      lastEnd = max(lastEnd, line.end)
      var indexedVoice: [Float]?
      if try database.contains(id) {
        if i.isMultiple(of: 32) { await Task.yield() }
      } else {
        let vector =
          overlap ? nil : try await encoder.archived(file: file, start: line.start, end: line.end)
        indexedVoice = vector ?? []
        try Task.checkCancellation()
        try database.record(
          id: id, source: source, live: false, seconds: line.end - line.start, voice: vector)
        if vector != nil { objectWillChange.send() }
      }
      let speaker: String
      if let tag = line.speaker, !tag.isEmpty { speaker = "asr:" + tag }
      else if let group = try database.localGroup(for: id) { speaker = "group:" + String(group) }
      else { speaker = "turn:" + line.id }
      speakers[speaker, default: ArchiveSpeaker()].add(
        turn: id, start: line.start, end: line.end, overlap: overlap, indexedVoice: indexedVoice)
    }
    let cached = try database.cachedArchiveVoices(archiveID)
    for (key, evidence) in speakers {
      try Task.checkCancellation()
      if let old = cached[key], old.signature == evidence.signature {
        speakers[key]?.voice = old.voice
        continue
      }
      var samples: [[Float]] = []
      for window in evidence.windows {
        try Task.checkCancellation()
        if let indexed = evidence.indexedVoices[window] {
          if !indexed.isEmpty { samples.append(indexed) }
        } else if let voice = try await encoder.archived(file: file, start: window.lowerBound, end: window.upperBound) {
          samples.append(voice)
        }
      }
      speakers[key]?.voice = ArchiveSpeaker.centroid(samples)
    }
    try Task.checkCancellation()
    try database.replaceArchiveSpeakers(speakers, recording: archiveID)
    objectWillChange.send()
  }
  func waitForStoppedTasks() async {
    let tasks = Array(liveTasks.values)
    await archiveTask?.value
    for task in tasks { await task.value }
    if stopped { await realtime.finish() }
  }
  func stop() {
    stopped = true
    realtime.stop()
    archiveTask?.cancel()
    archives = [:]
    for task in liveTasks.values { task.cancel() }
  }
}
