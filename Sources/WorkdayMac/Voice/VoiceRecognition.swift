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
  var canClearSamples: Bool { sampleCount > 0 || negativeSampleCount > 0 || !pendingCaptions.isEmpty }

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
  static func captionMark(_ lineID: String, evidence: String?) -> String {
    if let evidence, evidence.hasPrefix("draft:") { return "caption:" + evidence }
    return "caption:" + lineID
  }
  func captionSpeaker(lineID: String, evidenceID: String?) -> CaptionSpeaker {
    let utterance = Self.captionMark(lineID, evidence: evidenceID)
    let local = label(utterance) ?? .forUtterance()
    if let sample = local.sampleID { return CaptionSpeaker(id: sample, label: local, markedHere: true) }
    if !local.isMine, !local.excluded, let evidenceID, var matched = label(evidenceID) {
      // A sample confirmed on a covering cloud turn is an inference for this local bubble.
      if evidenceID.hasPrefix("live:"), evidenceID != "live:" + lineID { matched.sampleID = nil }
      return CaptionSpeaker(id: evidenceID, label: matched)
    }
    return CaptionSpeaker(id: utterance, label: local, markedHere: local.isMine || local.excluded)
  }
  func hasLiveVoice(_ id: String?) -> Bool {
    guard let id else { return false }
    if id.hasPrefix("realtime:") { return realtime.hasVoice(id) || (try? db().hasLiveVoice(id)) == true }
    if let known = usableLiveVoices.object(forKey: id as NSString) { return known.boolValue }
    let usable = (try? db().hasLiveVoice(id)) == true
    usableLiveVoices.setObject(NSNumber(value: usable), forKey: id as NSString)
    return usable
  }

  func markBubble(lineID: String, evidence: String, packets: Data, mine: Bool) {
    change { db in
      var canEnroll = true
      if evidence.hasPrefix("realtime:") {
        canEnroll = try realtime.persistFeedback(id: evidence, packets: packets, database: db)
      }
      try db.setCaptionMark(Self.captionMark(lineID, evidence: evidence), mine: mine,
                            evidence: canEnroll ? evidence : nil, packets: canEnroll ? packets : nil)
      pendingCaptions[lineID] = nil
    }
  }

  private func profileChanged() {
    realtime.profileChanged()
    captionIdentityRevision += 1
    objectWillChange.send()
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
      if let line = captionLineID, id == utterance, try db.label(id) == .forUtterance(mine: true) {
        pendingCaptions[line] = .mine
      }
    }
  }
  func setCaptionMark(lineID: String, mine: Bool, evidence: String?) {
    change { db in
      let packets = evidence.flatMap { $0.hasPrefix("realtime:") ? realtime.feedbackPackets($0) : nil }
      var canEnroll = true
      if let evidence, let packets {
        canEnroll = try realtime.persistFeedback(id: evidence, packets: packets, database: db)
      }
      let mark = Self.captionMark(lineID, evidence: evidence)
      try db.setCaptionMark(mark, mine: mine, evidence: canEnroll ? evidence : nil, packets: canEnroll ? packets : nil)
      let isPending = try db.label(mark) == .forUtterance(mine: mine)
      pendingCaptions[lineID] = evidence?.hasPrefix("realtime:") != true && isPending ? (mine ? .mine : .notMine) : nil
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
        profileChanged()
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
  func nameArchiveSpeaker(_ turn: String, _ name: String) {
    change { try $0.nameArchiveSpeaker(turn: turn, name: name) }
  }
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
  func clearSamples() {
    change {
      try $0.clearSamples()
      pendingCaptions.removeAll()
    }
  }
  private func change(_ perform: (VoiceLibrary) throws -> Void) {
    do {
      try perform(db())
      if error != nil { error = nil }
      profileChanged()
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
