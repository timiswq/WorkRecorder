import Foundation
import WorkdayCore

/// Session-only rolling voices. The database is written only for final captions
/// or explicit feedback; one-second inference windows never become enrollments.
@MainActor final class RealtimeVoiceRecognition {
  enum Mode: String { case active, shadow, legacy }
  struct Entry {
    let evidence: LiveVoiceEvidence
    var decision: LiveIdentityDecision
  }
  private struct Summary {
    let range: Range<Int>
    let track: Int
    let status: LiveIdentityStatus
  }
  private struct Presentation {
    var line: LiveLine
    let entry: Entry
    let canEnroll: Bool
  }
  private let database: () throws -> VoiceLibrary
  private let changed: ([LiveLine]) -> Void
  private let failure: (Error) -> Void
  private var stream: LiveSpeakerStream?
  private var streamToken: UUID?
  private var tracker = LiveIdentityTracker()
  private var generation: UUID?
  private var entries: [Entry] = []
  private var summaries: [Summary] = []
  private var lines: [LiveLine] = []
  private var presentations: [String: Presentation] = [:]
  private var source = "live"
  private var stopped = false
  private let diagnosticURL: URL?
  private let mode: Mode
  private var diagnosticBytes = 0
  private(set) var windowsProcessed = 0

  init(mode: Mode? = nil, database: @escaping () throws -> VoiceLibrary, changed: @escaping ([LiveLine]) -> Void,
       failure: @escaping (Error) -> Void) {
    self.mode = mode ?? ProcessInfo.processInfo.environment["WORKDAY_LIVE_IDENTITY_MODE"].flatMap(Mode.init(rawValue:)) ?? .active
    self.database = database
    self.changed = changed
    self.failure = failure
    diagnosticURL = ProcessInfo.processInfo.environment["WORKDAY_LIVE_VOICE_REPORT"].map { URL(fileURLWithPath: $0) }
  }

  func append(_ data: Data, offset: Int, source: String) {
    guard !stopped, mode != .legacy else { return }
    self.source = source
    if stream == nil {
      let token = UUID()
      streamToken = token
      stream = LiveSpeakerStream(onReset: { [weak self] generation in
        guard self?.streamToken == token else { return }
        self?.resetGeneration(generation)
      }, onFailure: { [weak self] message in
        guard self?.streamToken == token else { return }
        self?.failure(WorkdayError.invalid(message))
      }, onEvidence: { [weak self] evidence in
        guard self?.streamToken == token else { return }
        self?.receive(evidence)
      })
    }
    stream?.append(data, offset: offset)
  }

  func observe(_ lines: [LiveLine]) {
    self.lines = Array(lines.suffix(160))
    rebuild()
  }

  func reset() {
    streamToken = nil
    stream?.cancel()
    stream = nil
    resetGeneration(nil)
  }

  private func resetGeneration(_ next: UUID?) {
    generation = next
    tracker.reset()
    entries.removeAll(keepingCapacity: true)
    summaries.removeAll(keepingCapacity: true)
    presentations.removeAll(keepingCapacity: true)
  }

  func profileChanged() {
    tracker.reset()
    // A changed profile must earn continuity again. Explicit caption marks are
    // handled by VoiceLibrary before any inferred realtime label.
    entries.removeAll(keepingCapacity: true)
    summaries.removeAll(keepingCapacity: true)
    presentations.removeAll(keepingCapacity: true)
  }

  func receive(_ evidence: LiveVoiceEvidence) {
    guard !stopped else { return }
    if generation == nil { resetGeneration(evidence.generation) }
    guard generation == evidence.generation else { return }
    do {
      let db = try database()
      let assessment = try evidence.voice.map { try db.assessLive($0) }
      let short = try evidence.changeVoice.map { try db.assessLive($0) }
      let decision: LiveIdentityDecision
      if let voice = evidence.voice, let assessment, evidence.quality.usableForIdentity {
        decision = tracker.observe(range: evidence.range, voice: voice, changeVoice: evidence.changeVoice,
                                   assessment: assessment, changeAssessment: short)
      } else if evidence.quality.reason == .insufficientSpeech {
        decision = tracker.pause(range: evidence.range)
      } else {
        tracker.reset()
        decision = .init(range: evidence.range, status: .unknown,
                         reason: evidence.quality.reason ?? .invalidAudio, track: -windowsProcessed - 1,
                         ownerScore: -1, negativeScore: -1)
      }
      if decision.status == .owner {
        // Two consistent windows may confirm the initial pending window of this
        // same track. No rejected/changed/negative window is back-promoted.
        for i in entries.indices where entries[i].decision.track == decision.track
          && entries[i].decision.status == .pending {
          let old = entries[i].decision
          entries[i].decision = .init(range: old.range, status: .owner, reason: .matched, track: old.track,
                                      ownerScore: old.ownerScore, negativeScore: old.negativeScore)
        }
      }
      let supportStart = summaries.last?.range.upperBound ?? evidence.range.lowerBound
      summaries.append(.init(range: min(supportStart, evidence.range.upperBound)..<evidence.range.upperBound,
                              track: decision.track, status: decision.status))
      if summaries.count > 3600 { summaries.removeFirst(summaries.count - 3600) }
      entries.append(.init(evidence: evidence, decision: decision))
      if entries.count > 16 { entries.removeFirst(entries.count - 16) }
      windowsProcessed += 1
      writeDiagnostic(evidence, decision: decision, sampleCount: db.sampleCount)
      rebuild()
    } catch { failure(error) }
  }

  private func rebuild() {
    var next: [String: Presentation] = [:]
    for line in lines {
      guard let bytes = line.recognitionRange ?? line.recordingRange else { continue }
      let range = (bytes.lowerBound * 8)..<(bytes.upperBound * 8)
      // Identity may continue across ASR sentences once the latest short window
      // lies inside the new sentence. Enrollment has the stricter full-window
      // containment requirement below.
      guard var entry = entries.last(where: {
        $0.evidence.voice != nil && $0.evidence.quality.usableForIdentity
          && $0.evidence.range.overlaps(range)
          && ($0.evidence.range.lowerBound >= range.lowerBound
              || ($0.evidence.changeVoice != nil && $0.evidence.range.upperBound - 32_000 >= range.lowerBound))
          && $0.evidence.range.upperBound <= range.upperBound + 320
      }) else { continue }
      let tracks = Set(summaries.filter { $0.range.overlaps(range) && $0.range.upperBound <= range.upperBound + 320 }.map(\.track))
      let late = range.upperBound - entry.evidence.range.upperBound > 24_000
      if tracks.count > 1 || late {
        let old = entry.decision
        entry.decision = .init(range: old.range, status: .unknown,
                              reason: tracks.count > 1 ? .mixedSpeakers : .staleEvidence,
                              track: old.track, ownerScore: old.ownerScore, negativeScore: old.negativeScore)
      }
      // Keep the legacy exact-utterance result while a new track is still
      // pending; a pending rolling estimate must not erase an existing match.
      if entry.decision.status == .pending { continue }
      let evidence = entry.evidence
      let canEnroll = tracks.count <= 1 && !late && evidence.range.lowerBound >= range.lowerBound
        && evidence.range.upperBound <= range.upperBound + 320
      let id = "realtime:\(evidence.generation.uuidString):\(line.id):\(evidence.range.lowerBound)-\(evidence.range.upperBound)"
      var shown = line
      if line.isFinal {
        shown.voiceID = id
        shown.voicePackets = evidence.packets
        shown.voiceRange = evidence.range.lowerBound / 8..<evidence.range.upperBound / 8
      } else {
        shown.draftVoice = .init(id: id, range: evidence.range.lowerBound / 8..<evidence.range.upperBound / 8,
                                 packets: evidence.packets)
      }
      next[line.id] = .init(line: shown, entry: entry, canEnroll: canEnroll)
      if line.isFinal, mode == .active {
        do { try database().persistRealtimeEvidence(id: id, source: source, evidence: evidence, decision: entry.decision, canEnroll: canEnroll) }
        catch { failure(error) }
      }
    }
    let old = presentations
    presentations = next
    let updates = next.values.filter { value in
      let previous = old[value.line.id]
      return previous?.line != value.line || previous?.entry.decision != value.entry.decision
    }.map(\.line)
    if !updates.isEmpty, mode == .active { changed(updates) }
  }

  func presentation(_ line: LiveLine) -> LiveLine { mode == .active ? presentations[line.id]?.line ?? line : line }

  private func entry(for id: String) -> Entry? {
    presentations.values.first { $0.line.bubbleVoiceID == id }?.entry
  }

  func hasVoice(_ id: String) -> Bool { mode == .active && entry(for: id)?.evidence.voice != nil }
  func feedbackPackets(_ id: String) -> Data? { entry(for: id)?.evidence.packets }

  func label(_ id: String) -> VoiceLabel? {
    guard mode == .active, let entry = entry(for: id) else { return nil }
    // Current explicit profiles still have final say after undo/correction.
    let matches = entry.evidence.voice.flatMap { try? database().assessLive($0).reason } == .matched
    return entry.decision.status == .owner && matches ? .forUtterance(mine: true) : .forUtterance()
  }

  @discardableResult func persistFeedback(id: String, packets: Data, database: VoiceLibrary) throws -> Bool {
    guard let presentation = presentations.values.first(where: { $0.line.bubbleVoiceID == id }),
          packets == presentation.entry.evidence.packets else {
      throw WorkdayError.invalid("这段实时声纹已更新，请重新选择当前语句")
    }
    guard presentation.canEnroll else { return false }
    let entry = presentation.entry
    try database.persistRealtimeEvidence(id: id, source: source, evidence: entry.evidence,
                                         decision: entry.decision, canEnroll: true, savePCM: true)
    return true
  }

  func finish() async { await stream?.finish() }
  func stop() { stopped = true; streamToken = nil; stream?.cancel() }

  private struct Diagnostic: Encodable {
    let time: Date
    let generation: UUID
    let startFrame: Int
    let endFrame: Int
    let quality: LiveVoiceQuality
    let decision: LiveIdentityDecision
    let sampleCount: Int
    let inferenceMilliseconds: Double
  }
  private func writeDiagnostic(_ evidence: LiveVoiceEvidence, decision: LiveIdentityDecision, sampleCount: Int) {
    guard let diagnosticURL, diagnosticBytes < 8_000_000 else { return }
    do {
      try FileManager.default.createDirectory(at: diagnosticURL.deletingLastPathComponent(),
                                               withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let row = Diagnostic(time: Date(), generation: evidence.generation, startFrame: evidence.range.lowerBound,
                           endFrame: evidence.range.upperBound, quality: evidence.quality,
                           decision: decision, sampleCount: sampleCount, inferenceMilliseconds: evidence.inferenceMilliseconds)
      var data = try JSONEncoder().encode(row)
      data.append(10)
      if !FileManager.default.fileExists(atPath: diagnosticURL.path) {
        FileManager.default.createFile(atPath: diagnosticURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
      }
      let handle = try FileHandle(forWritingTo: diagnosticURL)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
      diagnosticBytes += data.count
    } catch { failure(error) }
  }
}
