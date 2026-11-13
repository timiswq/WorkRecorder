import Foundation
import SQLite3
import WorkdayCore

struct VoiceLabel: Equatable {
  static let unknown = "未知发言人"
  static func forUtterance(mine: Bool? = nil) -> Self {
    .init(title: mine.map { $0 ? "我" : "不是我" } ?? unknown,
          canConfirm: mine == nil, isMine: mine == true, excluded: mine == false, group: nil)
  }
  static func acceptsName(_ name: String) -> Bool {
    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return !value.isEmpty && !["我", "可能是我"].contains(value)
  }
  var title: String
  var canConfirm: Bool
  var isSuggestion: Bool = false
  var isMine: Bool = false
  var excluded = false
  var savedName: String? = nil
  var group: Int64?
  var sampleID: String? = nil
  var isNegativeSample = false
  var archiveSpeaker = false
  var hasArchiveVoice = false
  var inferredName = false
  var canAddSample: Bool { isMine && group != nil && sampleID == nil }

  func captionTitle(using preferences: CaptionPreferences) -> String {
    if isMine { return preferences.resolvedUsername() }
    if isNegativeSample { return "非本人" }
    if excluded, title == "不是我" { return Self.unknown }
    if isSuggestion, let group { return "\(Self.unknown) \(group)" }
    return title
  }
}

/// Each sample points to one utterance explicitly confirmed in this recording library.
@MainActor final class VoiceLibrary {
  private static let identityThreshold: Float = 0.62
  private static let matchMargin: Float = 0.06
  private let db: OpaquePointer
  private var references: [Int64: [Float]] = [:]
  private var sampleGroups: [String: Int64] = [:]
  private var captionSamples: [String: String] = [:]
  private var ownerProfiles: [Int64: [Float]] = [:]
  private var individualOwnerVoices: [[Float]] = []
  private var namedProfiles: [String: [[Float]]] = [:]
  private var negativeVoices: [[Float]] = []
  private var negativeOrigins: [String: String] = [:]
  private var dataVersion = -1
  private var candidate: Int64?
  var sampleCount: Int { sampleGroups.count }
  var negativeSampleCount: Int { negativeVoices.count }
  var confirmed: Bool { sampleCount > 0 }

  init(root: URL) throws {
    let dir = root.appendingPathComponent("Sync", isDirectory: true)
    try FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = dir.appendingPathComponent("voice-campplus-v1.sqlite")
    var handle: OpaquePointer?
    let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    guard result == SQLITE_OK, let handle else {
      sqlite3_close(handle)
      throw WorkdayError.invalid("无法打开本地声纹资料")
    }
    db = handle
    sqlite3_busy_timeout(db, 2500)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    try exec(
      """
      PRAGMA foreign_keys=ON;
      CREATE TABLE IF NOT EXISTS speakers(id INTEGER PRIMARY KEY, reference BLOB NOT NULL, name TEXT, rejected INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS turns(id TEXT PRIMARY KEY, source TEXT NOT NULL, live INTEGER NOT NULL, speaker INTEGER REFERENCES speakers(id), voice BLOB);
      CREATE INDEX IF NOT EXISTS turns_by_source ON turns(source, live);
      CREATE TABLE IF NOT EXISTS durations(source TEXT NOT NULL, live INTEGER NOT NULL, speaker INTEGER NOT NULL, seconds REAL NOT NULL, PRIMARY KEY(source,live,speaker));
      CREATE INDEX IF NOT EXISTS durations_by_source ON durations(source,live);
      CREATE TABLE IF NOT EXISTS archive_speakers(
        recording TEXT NOT NULL, speaker TEXT NOT NULL, signature TEXT NOT NULL, voice BLOB,
        name TEXT, enrolled BLOB,
        PRIMARY KEY(recording,speaker));
      CREATE TABLE IF NOT EXISTS archive_speaker_turns(
        turn TEXT PRIMARY KEY REFERENCES turns(id), recording TEXT NOT NULL, speaker TEXT NOT NULL,
        FOREIGN KEY(recording,speaker) REFERENCES archive_speakers(recording,speaker) ON DELETE CASCADE);
      CREATE INDEX IF NOT EXISTS archive_turns_by_speaker ON archive_speaker_turns(recording,speaker);
      CREATE TABLE IF NOT EXISTS utterance_marks(turn TEXT PRIMARY KEY, mine INTEGER NOT NULL CHECK(mine IN (0,1)));
      CREATE TABLE IF NOT EXISTS non_owner_samples(
        mark TEXT PRIMARY KEY REFERENCES utterance_marks(turn) ON DELETE CASCADE,
        evidence TEXT NOT NULL UNIQUE REFERENCES turns(id));
      """)
    try migrateOwnerSamples()
    try exec("""
      CREATE TABLE IF NOT EXISTS owner_sample_audio(
        evidence TEXT PRIMARY KEY REFERENCES owner_samples(turn) ON DELETE CASCADE, packets BLOB NOT NULL);
      CREATE TABLE IF NOT EXISTS non_owner_sample_audio(
        evidence TEXT PRIMARY KEY REFERENCES non_owner_samples(evidence) ON DELETE CASCADE, packets BLOB NOT NULL);
      CREATE TABLE IF NOT EXISTS credited_live_drafts(turn TEXT PRIMARY KEY REFERENCES turns(id) ON DELETE CASCADE);
      """)
    try refresh()
  }
  deinit { sqlite3_close(db) }

  private func exec(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
  }
  private func failure() -> Error {
    WorkdayError.invalid("本地声纹资料读写失败：" + String(cString: sqlite3_errmsg(db)))
  }
  private func transaction(_ body: () throws -> Void) throws {
    try exec("BEGIN IMMEDIATE")
    do {
      try body()
      try exec("COMMIT")
    } catch {
      try? exec("ROLLBACK")
      throw error
    }
  }
  private func migrateOwnerSamples() throws {
    try transaction {
      var tables = Set<String>()
      try query("SELECT name FROM sqlite_master WHERE type='table'") {
        tables.insert(String(cString: sqlite3_column_text($0, 0)))
      }
      guard !tables.contains("owner_samples") else { return }
      try exec("CREATE TABLE owner_samples(turn TEXT PRIMARY KEY REFERENCES turns(id), caption TEXT UNIQUE)")
      if tables.contains("identity") {
        try exec("INSERT INTO owner_samples(turn) SELECT turn FROM identity; DROP TABLE identity;")
      }
      // Old per-turn confirmations can be learned when the key identifies the exact audio.
      // Old caption-only marks have no persisted alignment to a final audio span.
      try exec("""
        INSERT OR IGNORE INTO owner_samples(turn)
          SELECT t.id FROM utterance_marks m JOIN turns t ON t.id=m.turn JOIN speakers s ON s.id=t.speaker
          WHERE m.mine=1 AND length(t.voice)>0 AND s.name IS NULL AND s.rejected=0;
        DELETE FROM utterance_marks WHERE mine=1 AND turn IN (SELECT turn FROM owner_samples);
        """)
    }
  }
  private enum Value {
    case text(String)
    case int(Int64)
    case seconds(Double)
    case vector([Float])
    case packets(Data)
    case null
  }
  private func query(_ sql: String, _ values: [Value] = [], row: (OpaquePointer) -> Void = { _ in })
    throws
  {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
      throw failure()
    }
    defer { sqlite3_finalize(stmt) }
    let copy = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (i, value) in values.enumerated() {
      let n = Int32(i + 1)
      let code: Int32
      switch value {
      case .text(let s): code = sqlite3_bind_text(stmt, n, s, -1, copy)
      case .int(let i): code = sqlite3_bind_int64(stmt, n, i)
      case .seconds(let d): code = sqlite3_bind_double(stmt, n, d)
      case .null: code = sqlite3_bind_null(stmt, n)
      case .packets(let packets):
        code = packets.withUnsafeBytes { sqlite3_bind_blob(stmt, n, $0.baseAddress, Int32($0.count), copy) }
      case .vector(let v):
        code = v.withUnsafeBytes {
          sqlite3_bind_blob(stmt, n, $0.baseAddress, Int32($0.count), copy)
        }
      }
      guard code == SQLITE_OK else { throw failure() }
    }
    while true {
      switch sqlite3_step(stmt) {
      case SQLITE_ROW: row(stmt)
      case SQLITE_DONE: return
      default: throw failure()
      }
    }
  }
  private func vector(_ stmt: OpaquePointer, _ i: Int32) -> [Float]? {
    let bytes = Int(sqlite3_column_bytes(stmt, i))
    guard bytes > 0, bytes.isMultiple(of: 4), let ptr = sqlite3_column_blob(stmt, i) else {
      return nil
    }
    return Array(
      UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: Float.self), count: bytes / 4))
  }
  private func refresh() throws {
    try query("PRAGMA data_version") { dataVersion = Int(sqlite3_column_int($0, 0)) }
    references.removeAll()
    try query("SELECT id,reference FROM speakers") {
      references[sqlite3_column_int64($0, 0)] = vector($0, 1)
    }
    sampleGroups.removeAll()
    captionSamples.removeAll()
    individualOwnerVoices.removeAll()
    var sums: [Int64: [Float]] = [:]
    try query("""
      SELECT o.turn,o.caption,t.speaker,t.voice,s.name,s.rejected FROM owner_samples o
      JOIN turns t ON t.id=o.turn LEFT JOIN speakers s ON s.id=t.speaker
      ORDER BY o.turn
      """) { stmt in
      guard let voice = vector(stmt, 3) else { return }
      let id = String(cString: sqlite3_column_text(stmt, 0))
      let group = sqlite3_column_int64(stmt, 2)
      if let caption = sqlite3_column_text(stmt, 1) { captionSamples[String(cString: caption)] = id }
      sampleGroups[id] = group
      // A correction to an ambiguous or named group teaches only this exact voice.
      if group == 0 || sqlite3_column_type(stmt, 4) != SQLITE_NULL || sqlite3_column_int(stmt, 5) != 0 {
        individualOwnerVoices.append(voice)
        return
      }
      if sums[group] == nil { sums[group] = voice }
      else if sums[group]?.count == voice.count {
        for i in voice.indices { sums[group]![i] += voice[i] }
      }
    }
    // Separate profiles preserve distinct recording conditions. Within each group,
    // a normalized mean gives every confirmed utterance equal weight.
    ownerProfiles = sums.compactMapValues { sum in
      let length = sqrt(sum.reduce(Float(0)) { $0 + $1 * $1 })
      return length.isFinite && length > 0 ? sum.map { $0 / length } : nil
    }
    try loadNegativeSamples()
    try loadNamedProfiles()
    try rank()
  }
  private func loadNegativeSamples() throws {
    negativeVoices.removeAll()
    negativeOrigins.removeAll()
    try query("""
      SELECT n.mark,n.evidence,t.voice FROM non_owner_samples n
      JOIN utterance_marks m ON m.turn=n.mark AND m.mine=0 JOIN turns t ON t.id=n.evidence
      """) { stmt in
      guard let voice = vector(stmt, 2) else { return }
      let mark = String(cString: sqlite3_column_text(stmt, 0))
      let evidence = String(cString: sqlite3_column_text(stmt, 1))
      negativeOrigins[mark] = mark
      negativeOrigins[evidence] = mark
      negativeVoices.append(voice)
    }
  }
  private func refreshExternalChanges() throws {
    var current = dataVersion
    try query("PRAGMA data_version") { current = Int(sqlite3_column_int($0, 0)) }
    if current != dataVersion { try refresh() }
  }
  private func rank() throws {
    candidate = nil
    guard !confirmed else { return }
    // USB supersedes the observed BLE portion when both describe the same card file.
    try query(
      """
      SELECT d.speaker FROM durations d JOIN speakers s ON s.id=d.speaker
      WHERE s.rejected=0 AND s.name IS NULL AND (d.live=0 OR NOT EXISTS
        (SELECT 1 FROM durations a WHERE a.source=d.source AND a.live=0))
      GROUP BY d.speaker ORDER BY SUM(d.seconds) DESC, d.speaker LIMIT 1
      """
    ) { candidate = sqlite3_column_int64($0, 0) }
  }
  func hasLiveVoice(_ id: String) throws -> Bool {
    var found = false
    try query("SELECT 1 FROM turns WHERE id=? AND live=1 AND length(voice)>0", [.text(id)]) { _ in found = true }
    return found
  }

  /// A final can reuse its already indexed draft. Count that interval exactly once.
  func creditFinalDraft(_ id: String, seconds: Double) throws {
    try transaction {
      try query("INSERT OR IGNORE INTO credited_live_drafts SELECT id FROM turns WHERE id=? AND live=1 AND speaker IS NOT NULL",
                [.text(id)])
      guard sqlite3_changes(db) == 1 else { return }
      try query("""
        INSERT INTO durations(source,live,speaker,seconds)
          SELECT source, live, speaker, ? FROM turns WHERE id=?
          ON CONFLICT(source,live,speaker) DO UPDATE SET seconds=seconds+excluded.seconds
        """, [.seconds(seconds), .text(id)])
    }
    try rank()
  }

  private func ownerScore(_ voice: [Float], individualOnly: Bool = false) -> Float {
    let individual = individualOwnerVoices.map { SpeakerEncoder.similarity($0, voice) }.max() ?? -1
    if individualOnly { return individual }
    return max(ownerProfiles.values.map { SpeakerEncoder.similarity($0, voice) }.max() ?? -1, individual)
  }

  func contains(_ id: String) throws -> Bool {
    var exists = false
    try query("SELECT 1 FROM turns WHERE id=?", [.text(id)]) { _ in exists = true }
    return exists
  }

  func record(id: String, source: String, live: Bool, seconds: Double, voice: [Float]?,
              countDuration: Bool = true) throws {
    guard seconds.isFinite, seconds > 0 else { return }
    try exec("BEGIN IMMEDIATE")
    do {
      try refreshExternalChanges()
      if try contains(id) {
        try exec("COMMIT")
        return
      }
      var group: Int64?
      var newReference: [Float]?
      let voice = voice.flatMap { $0.allSatisfy(\.isFinite) && $0.contains(where: { $0 != 0 }) ? $0 : nil }
      if let voice {
        let scores = references.map { ($0.key, SpeakerEncoder.similarity($0.value, voice)) }.sorted
        { $0.1 > $1.1 }
        if let best = scores.first, best.1 >= 0.50,
          best.1 - (scores.dropFirst().first?.1 ?? -1) >= Self.matchMargin
        {
          group = best.0
        } else if scores.first?.1 ?? -1 < 0.50 {
          try query("INSERT INTO speakers(reference) VALUES(?)", [.vector(voice)])
          group = sqlite3_last_insert_rowid(db)
          newReference = voice
        }
      }
      try query(
        "INSERT INTO turns(id,source,live,speaker,voice) VALUES(?,?,?,?,?)",
        [
          .text(id), .text(source), .int(live ? 1 : 0), group.map(Value.int) ?? .null,
          voice.map(Value.vector) ?? .null,
        ])
      if let group, countDuration {
        try query(
          """
          INSERT INTO durations(source,live,speaker,seconds) VALUES(?,?,?,?)
          ON CONFLICT(source,live,speaker) DO UPDATE SET seconds=seconds+excluded.seconds
          """, [.text(source), .int(live ? 1 : 0), .int(group), .seconds(seconds)])
      }
      try exec("COMMIT")
      if let group, let newReference { references[group] = newReference }
      try rank()
    } catch {
      try? exec("ROLLBACK")
      throw error
    }
  }

  func label(_ id: String) throws -> VoiceLabel? {
    try refreshExternalChanges()
    if negativeOrigins[id] != nil {
      var label = VoiceLabel.forUtterance(mine: false)
      label.isNegativeSample = true
      return label
    }
    var result: VoiceLabel?
    try query("SELECT mine FROM utterance_marks WHERE turn=?", [.text(id)]) {
      result = .forUtterance(mine: sqlite3_column_int($0, 0) != 0)
    }
    if let result { return result }
    let sample = captionSamples[id] ?? id
    if let group = sampleGroups[sample] {
      return VoiceLabel(title: "我", canConfirm: false, isMine: true, group: group == 0 ? nil : group, sampleID: sample)
    }
    if id.hasPrefix("caption:") { return .forUtterance() }
    try query(
      """
      SELECT t.voice,s.id,s.name,s.rejected FROM turns t LEFT JOIN speakers s ON t.speaker=s.id WHERE t.id=?
      """, [.text(id)]
    ) { stmt in
      guard let voice = vector(stmt, 0) else { return }
      let group = sqlite3_column_int64(stmt, 1)
      let name = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
      let rejected = sqlite3_column_int(stmt, 3) != 0
      let score = ownerScore(voice, individualOnly: rejected || name != nil)
      let competingScore: Float
      if group == 0 {
        competingScore = references.filter { ownerProfiles[$0.key] == nil }
          .map { SpeakerEncoder.similarity($0.value, voice) }.max() ?? -1
      } else {
        competingScore = ownerProfiles[group] != nil ? -1 : references[group].map { SpeakerEncoder.similarity($0, voice) } ?? 1
      }
      if score >= Self.identityThreshold, score >= competingScore + Self.matchMargin,
         negativeVoices.allSatisfy({ sample in
           let other = SpeakerEncoder.similarity(sample, voice)
           return other < Self.identityThreshold || score >= other + Self.matchMargin
         }) {
        result = VoiceLabel(title: "我", canConfirm: false, isMine: true, group: group == 0 ? nil : group)
      } else if group == 0 || ownerProfiles[group] != nil {
        // A weak match in a trained group can be corrected for this utterance.
        result = .forUtterance()
      } else {
        let suggested = !confirmed && group == candidate && !rejected && name == nil
        result = VoiceLabel(
          title: name ?? (suggested ? "可能是我" : "\(VoiceLabel.unknown) \(group)"),
          canConfirm: !rejected && name == nil, isSuggestion: suggested,
          excluded: rejected, savedName: name, group: group)
      }
    }
    if id.hasPrefix("file:"), result?.isMine != true {
      result = try archiveLabel(id, base: result)
    }
    return result
  }
  func confirm(_ id: String, utterance: String? = nil, pendingOnly: Bool = false) throws {
    try transaction {
      if let utterance, try label(utterance)?.excluded == true { return }
      if pendingOnly {
        guard let utterance, try label(utterance) == .forUtterance(mine: true) else { return }
      }
      guard let label = try label(id), label.canConfirm || label.canAddSample || label.sampleID != nil
      else { return }
      if id.hasPrefix("caption:") {
        if label.canConfirm { try markUtterance(id, mine: true) }
        return
      }
      try attachOwnerSample(id, utterance: utterance)
    }
    try refresh()
  }
  private func attachOwnerSample(_ id: String, utterance: String?) throws {
    try query("""
      INSERT OR IGNORE INTO owner_samples(turn,caption)
      SELECT t.id,? FROM turns t WHERE t.id=? AND length(t.voice)>0
      """, [utterance.map(Value.text) ?? .null, .text(id)])
    if let utterance {
      try query("UPDATE OR IGNORE owner_samples SET caption=? WHERE turn=? AND caption IS NULL",
                [.text(utterance), .text(id)])
      // Only clear a pending mark if this exact caption is now bound to the sample.
      try query("DELETE FROM utterance_marks WHERE turn=? AND mine=1 AND EXISTS (SELECT 1 FROM owner_samples WHERE turn=? AND caption=?)",
                [.text(utterance), .text(id), .text(utterance)])
    }
  }

  func removeSample(_ id: String) throws {
    try query("DELETE FROM owner_samples WHERE turn=?", [.text(id)])
    try refresh()
  }
  func markUtterance(_ id: String, mine: Bool?) throws {
    if let mine {
      try query("""
        INSERT INTO utterance_marks(turn,mine)
        SELECT ?,? WHERE NOT EXISTS (SELECT 1 FROM owner_samples WHERE turn=? OR caption=?)
        ON CONFLICT(turn) DO UPDATE SET mine=excluded.mine
        """, [.text(id), .int(mine ? 1 : 0), .text(id), .text(id)])
    } else {
      try query("DELETE FROM utterance_marks WHERE turn=?", [.text(id)])
    }
  }
  /// The mark is immediate. Only its own indexed, single-speaker audio can become a counterexample.
  func markNotMine(_ mark: String, evidence: String?, pendingOnly: Bool = false) throws {
    try transaction {
      if pendingOnly {
        guard try label(mark) == .forUtterance(mine: false) else { return }
      } else {
        if let current = try label(mark), current.isMine && !current.canAddSample { return }
        try markUtterance(mark, mine: false)
      }
      guard let evidence else { return }
      try attachNegativeSample(mark, evidence: evidence)
    }
    try loadNegativeSamples()
  }
  private func attachNegativeSample(_ mark: String, evidence: String) throws {
    try query("""
      INSERT OR IGNORE INTO non_owner_samples(mark,evidence)
      SELECT m.turn,t.id FROM utterance_marks m JOIN turns t ON t.id=?
      WHERE m.turn=? AND m.mine=0 AND length(t.voice)>0
        AND NOT EXISTS (SELECT 1 FROM owner_samples o WHERE o.turn=t.id OR o.caption=m.turn)
      """, [.text(evidence), .text(mark)])
  }

  func sampleAudio(_ evidence: String) throws -> Data? {
    var packets: Data?
    try query("""
      SELECT packets FROM owner_sample_audio WHERE evidence=?
      UNION ALL SELECT packets FROM non_owner_sample_audio WHERE evidence=?
      """, [.text(evidence), .text(evidence)]) { stmt in
      if let blob = sqlite3_column_blob(stmt, 0) {
        packets = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
      }
    }
    return packets
  }

  /// A correction replaces only this bubble's feedback and its exact local audio sample.
  func setCaptionMark(_ mark: String, mine: Bool, evidence: String?, packets: Data? = nil) throws {
    try transaction {
      if let packets {
        guard let evidence, try hasLiveVoice(evidence),
              (4000...240000).contains(packets.count), packets.count.isMultiple(of: 40) else {
          throw WorkdayError.invalid("未找到这段语音的可用声纹")
        }
      }
      let audio = try packets ?? evidence.flatMap { try sampleAudio($0) }
      try query("DELETE FROM utterance_marks WHERE turn=?", [.text(mark)])
      if !mine {
        try query("DELETE FROM owner_samples WHERE caption=? OR (turn=? AND caption IS NULL)",
                  [.text(mark), evidence.map(Value.text) ?? .null])
      }
      try markUtterance(mark, mine: mine)
      if let evidence {
        if mine { try attachOwnerSample(evidence, utterance: mark) }
        else { try attachNegativeSample(mark, evidence: evidence) }
      }
      if let audio, let evidence {
        var bound = false
        let sql = mine ? "SELECT 1 FROM owner_samples WHERE caption=? AND turn=?"
                       : "SELECT 1 FROM non_owner_samples WHERE mark=? AND evidence=?"
        try query(sql, [.text(mark), .text(evidence)]) { _ in bound = true }
        if !bound { throw WorkdayError.invalid("这段语音的声纹样本未能保存") }
        let table = mine ? "owner_sample_audio" : "non_owner_sample_audio"
        try query("INSERT OR IGNORE INTO \(table)(evidence,packets) VALUES(?,?)", [.text(evidence), .packets(audio)])
      }
    }
    try refresh()
  }

  func undoNotMine(_ id: String) throws {
    try transaction {
      try refreshExternalChanges()
      try query("DELETE FROM utterance_marks WHERE turn=? AND mine=0", [.text(negativeOrigins[id] ?? id)])
    }
    try loadNegativeSamples()
  }
  func clearNegativeSamples() throws {
    try exec("DELETE FROM non_owner_samples")
    try loadNegativeSamples()
  }
  func reject(_ group: Int64) throws {
    try transaction {
      try refreshExternalChanges()
      guard ownerProfiles[group] == nil else { return }
      try query("UPDATE speakers SET rejected=1 WHERE id=?", [.int(group)])
    }
    try rank()
  }
  func restore(_ group: Int64) throws {
    try query("UPDATE speakers SET rejected=0 WHERE id=?", [.int(group)])
    try rank()
  }
  func name(_ group: Int64, _ name: String) throws {
    let text = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    guard !["我", "可能是我"].contains(text) else {
      throw WorkdayError.invalid("标记本人请使用「是我」，其他发言人请填写名字。")
    }
    try transaction {
      try refreshExternalChanges()
      guard ownerProfiles[group] == nil else { return }
      try query(
        "UPDATE speakers SET name=? WHERE id=?", [text.isEmpty ? .null : .text(text), .int(group)])
    }
    try rank()
  }
  func undoConfirmation() throws {
    try exec("DELETE FROM owner_samples")
    try refresh()
  }
}

extension VoiceLibrary {
  func localGroup(for turn: String) throws -> Int64? {
    var group: Int64?
    try query("SELECT speaker FROM turns WHERE id=? AND speaker IS NOT NULL", [.text(turn)]) {
      group = sqlite3_column_int64($0, 0)
    }
    return group
  }

  func cachedArchiveVoices(_ recording: String) throws -> [String: (signature: String, voice: [Float]?)] {
    var cached: [String: (signature: String, voice: [Float]?)] = [:]
    try query("SELECT speaker,signature,voice FROM archive_speakers WHERE recording=?", [.text(recording)]) {
      cached[String(cString: sqlite3_column_text($0, 0))] =
        (String(cString: sqlite3_column_text($0, 1)), vector($0, 2))
    }
    return cached
  }

  func replaceArchiveSpeakers(_ speakers: [String: ArchiveSpeaker], recording: String) throws {
    try transaction {
      // Opening an unchanged library should not rewrite thousands of transcript rows.
      var existing: [String: String] = [:]
      try query("SELECT turn,speaker FROM archive_speaker_turns WHERE recording=?", [.text(recording)]) {
        existing[String(cString: sqlite3_column_text($0, 0))] = String(cString: sqlite3_column_text($0, 1))
      }
      let cached = try cachedArchiveVoices(recording)
      if existing.count == speakers.values.reduce(0, { $0 + $1.turns.count }),
         cached.count == speakers.count, speakers.allSatisfy({ key, evidence in
           cached[key]?.signature == evidence.signature && evidence.turns.allSatisfy { existing[$0] == key }
         }) { return }
      try query("DELETE FROM archive_speaker_turns WHERE recording=?", [.text(recording)])
      for (speaker, evidence) in speakers {
        try query("""
          INSERT INTO archive_speakers(recording,speaker,signature,voice) VALUES(?,?,?,?)
          ON CONFLICT(recording,speaker) DO UPDATE SET signature=excluded.signature,voice=excluded.voice
          """, [.text(recording), .text(speaker), .text(evidence.signature),
                evidence.voice.map(Value.vector) ?? .null])
        for turn in evidence.turns {
          try query("INSERT INTO archive_speaker_turns(turn,recording,speaker) VALUES(?,?,?)",
                    [.text(turn), .text(recording), .text(speaker)])
        }
      }
      try query("""
        DELETE FROM archive_speakers WHERE recording=? AND NOT EXISTS (
          SELECT 1 FROM archive_speaker_turns t
          WHERE t.recording=archive_speakers.recording AND t.speaker=archive_speakers.speaker)
        """, [.text(recording)])
    }
    try loadNamedProfiles()
  }

  func nameArchiveSpeaker(turn: String, name: String) throws {
    let text = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    guard text.isEmpty || VoiceLabel.acceptsName(text) else {
      throw WorkdayError.invalid("标记本人请使用「是我」，其他发言人请填写名字。")
    }
    try transaction {
      guard try label(turn)?.archiveSpeaker == true else {
        throw WorkdayError.invalid("发言人信息已变化，请重新选择。")
      }
      // An empty string suppresses the automatic name for this recording's speaker.
      try query("""
        UPDATE archive_speakers SET name=?, enrolled=CASE WHEN ?='' THEN NULL ELSE voice END
        WHERE (recording,speaker)=(
          SELECT recording,speaker FROM archive_speaker_turns WHERE turn=?)
        """, [.text(text), .text(text), .text(turn)])
    }
    try loadNamedProfiles()
  }

  private func loadNamedProfiles() throws {
    var profiles: [String: [[Float]]] = [:]
    try query("SELECT name,enrolled FROM archive_speakers WHERE name<>'' AND enrolled IS NOT NULL") {
      if let voice = vector($0, 1) {
        profiles[String(cString: sqlite3_column_text($0, 0)), default: []].append(voice)
      }
    }
    namedProfiles = profiles
  }

  private func matchingName(_ voice: [Float]) -> String? {
    var winner: String?
    var best: Float = -1
    var runnerUp = ownerScore(voice)
    for (name, samples) in namedProfiles {
      let score = samples.map { SpeakerEncoder.similarity($0, voice) }.max() ?? -1
      if score > best {
        runnerUp = max(runnerUp, best)
        best = score
        winner = name
      } else {
        runnerUp = max(runnerUp, score)
      }
    }
    return best >= Self.identityThreshold && best - runnerUp >= Self.matchMargin ? winner : nil
  }

  private func archiveLabel(_ turn: String, base: VoiceLabel?) throws -> VoiceLabel? {
    var result = base
    try query("""
      SELECT s.speaker,s.name,s.voice FROM archive_speaker_turns t JOIN archive_speakers s
      ON s.recording=t.recording AND s.speaker=t.speaker WHERE t.turn=?
      """, [.text(turn)]) { stmt in
      let key = String(cString: sqlite3_column_text(stmt, 0))
      let fallback = key.hasPrefix("asr:") ? String(key.dropFirst(4)) : VoiceLabel.unknown
      var label = base ?? VoiceLabel(title: fallback, canConfirm: false, group: nil)
      label.archiveSpeaker = true
      label.hasArchiveVoice = sqlite3_column_type(stmt, 2) != SQLITE_NULL
      if let raw = sqlite3_column_text(stmt, 1) {
        let name = String(cString: raw)
        label.savedName = name.isEmpty ? nil : name
        label.title = name.isEmpty ? fallback : name
        label.isSuggestion = false
        if !name.isEmpty { label.canConfirm = false }
      } else if label.savedName == nil, let voice = vector(stmt, 2), let name = matchingName(voice) {
        label.title = name
        label.inferredName = true
        label.isSuggestion = false
      }
      result = label
    }
    return result
  }
}
