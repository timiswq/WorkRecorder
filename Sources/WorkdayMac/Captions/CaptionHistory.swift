import Combine
import Foundation
import SQLite3
import WorkdayCore

/// A bubble's complete text and its first receipt time, independent of its lifetime on screen.
struct CaptionRecord: Identifiable, Equatable, Codable {
  let id: String
  let time: Date
  var text: String
  var isFinal: Bool
  var localVoiceID: String?
  var evidenceID: String?
  var replay: CaptionReplay.Frames?
  var fileReview: CaptionFileReview?
  var textSource: CaptionTextSource?

  var readingAnchor: CaptionSelection { CaptionSelection(id: id, time: time) }

  var transcript: (text: String, source: CaptionTextSource?) {
    if case .complete(let reviewed) = fileReview { return (reviewed, .cloud) }
    return (text, textSource ?? (fileReview != nil ? .local : nil))
  }
}

enum CaptionFileReview: Codable, Equatable {
  case queued, submitted(String), complete(String), failed(taskID: String?), noSpeech

  var pending: Bool {
    switch self { case .queued, .submitted: return true; default: return false }
  }
}

enum CaptionReadingPosition: Hashable {
  case latest, scrolling, range(ClosedRange<Date>)

  var selectedRange: ClosedRange<Date>? {
    if case .range(let range) = self { return range }
    return nil
  }
}

struct CaptionSelection: Hashable {
  let id: String
  let time: Date
}

enum CaptionRangeEdge { case start, end }

struct CaptionWindow {
  static let duration: TimeInterval = 24 * 3600
  let now: Date
  var start: Date { now.addingTimeInterval(-Self.duration) }

  func time(atRulerFraction fraction: Double) -> Date {
    start.addingTimeInterval(min(1, max(0, fraction)) * Self.duration)
  }

  func rulerFraction(for time: Date) -> Double {
    min(1, max(0, time.timeIntervalSince(start) / Self.duration))
  }

  static func minute(_ date: Date) -> Date {
    Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
  }

  // Both endpoint labels denote whole minutes, including the minute on the right.
  var minutes: ClosedRange<Date> { Self.minute(start)...Self.minute(now) }

  func selection(_ selected: ClosedRange<Date>?) -> ClosedRange<Date> {
    (selected ?? minutes).clamped(to: minutes)
  }

  func moving(_ edge: CaptionRangeEdge, to date: Date, in selected: ClosedRange<Date>?) -> ClosedRange<Date> {
    let range = selection(selected)
    let minute = min(minutes.upperBound, max(minutes.lowerBound, Self.minute(date)))
    switch edge {
    case .start: return min(minute, range.upperBound)...range.upperBound
    case .end: return range.lowerBound...max(minute, range.lowerBound)
    }
  }

  /// A time-only editor can mean yesterday or today. At the repeated clock minute,
  /// choose the occurrence nearest the endpoint being edited.
  func resolve(clock: Date, near endpoint: Date) -> Date {
    let calendar = WorkdayTimeline.calendar
    let parts = calendar.dateComponents([.hour, .minute], from: clock)
    let candidates = [start, now].compactMap {
      calendar.date(bySettingHour: parts.hour!, minute: parts.minute!, second: 0, of: $0)
    }.filter(minutes.contains)
    return candidates.min { abs($0.timeIntervalSince(endpoint)) < abs($1.timeIntervalSince(endpoint)) } ?? endpoint
  }

  func visible(in records: [CaptionRecord], during range: ClosedRange<Date>? = nil) -> ArraySlice<CaptionRecord> {
    let lower = records.firstIndex(atOrAfter: max(start, range?.lowerBound ?? start))
    let latest = records.firstIndex(after: now)
    let upper = range.map { min(latest, records.firstIndex(atOrAfter: $0.upperBound.addingTimeInterval(60))) } ?? latest
    return records[lower..<max(lower, upper)]
  }
}

extension RandomAccessCollection where Element == CaptionRecord, Index == Int {
  func neighbors(of range: ClosedRange<Date>) -> (previous: CaptionRecord?, next: CaptionRecord?) {
    let lower = firstIndex(atOrAfter: range.lowerBound)
    let upper = firstIndex(atOrAfter: range.upperBound.addingTimeInterval(60))
    return (lower > startIndex ? self[lower - 1] : nil, upper < endIndex ? self[upper] : nil)
  }

  /// Retain the exact utterance when records share a timestamp.
  func nearest(to anchor: CaptionSelection) -> CaptionSelection? {
    let index = firstIndex(atOrAfter: anchor.time)
    if index < endIndex, self[index].time == anchor.time {
      return self[index..<firstIndex(after: anchor.time)].first { $0.id == anchor.id }?.readingAnchor
        ?? self[index].readingAnchor
    }
    if index == startIndex { return first?.readingAnchor }
    if index == endIndex { return last?.readingAnchor }
    let earlier = self[index - 1], later = self[index]
    return anchor.time.timeIntervalSince(earlier.time) <= later.time.timeIntervalSince(anchor.time)
      ? earlier.readingAnchor : later.readingAnchor
  }

  func firstIndex(atOrAfter time: Date) -> Int { boundary { $0.time < time } }
  func firstIndex(after time: Date) -> Int { boundary { $0.time <= time } }
  private func boundary(_ before: (CaptionRecord) -> Bool) -> Int {
    var low = startIndex, high = endIndex
    while low < high {
      let mid = low + (high - low) / 2
      if before(self[mid]) { low = mid + 1 } else { high = mid }
    }
    return low
  }
}

@MainActor final class CaptionHistory: ObservableObject {
  @Published private(set) var records: [CaptionRecord] = []
  @Published private(set) var issue: String?
  // Hold the list membership while reading. Late finals may arrive out of time order.
  private var heldRecords: [CaptionRecord]?
  var readingRecords: [CaptionRecord] { heldRecords ?? records }

  func holdReading(_ hold: Bool) {
    if !hold { heldRecords = nil }
    else if heldRecords == nil { heldRecords = records }
  }

  func unreadCount(in window: CaptionWindow) -> Int {
    guard let heldRecords else { return 0 }
    return window.visible(in: records).count - window.visible(in: heldRecords).count
  }

  private func updateHeldRecord(id: String, time: Date, with record: CaptionRecord?) {
    guard let lower = heldRecords?.firstIndex(atOrAfter: time), let upper = heldRecords?.firstIndex(after: time),
          let index = heldRecords?[lower..<upper].firstIndex(where: { $0.id == id }) else { return }
    if let record { heldRecords?[index] = record }
    else { heldRecords?.remove(at: index) }
  }

  let reviewCompleted = PassthroughSubject<Void, Never>()
  private let disk: CaptionJournal
  private let clock: () -> Date
  private var reviewConfiguration: LiveASRConfiguration?
  private var reviewer: (any CaptionFileTranscribing)?
  private var reviewWorker: Task<Void, Never>?

  init(root: URL, clock: @escaping () -> Date = Date.init) {
    self.clock = clock
    disk = CaptionJournal(root: root)
    do { records = try disk.load(since: CaptionWindow(now: clock()).start) }
    catch { issue = error.localizedDescription }
  }

  func reviewedText(for line: LiveLine) -> String? {
    guard line.isFinal, let time = line.receivedAt, let frames = line.replay?.frames else { return nil }
    let range = records.firstIndex(atOrAfter: time)..<records.firstIndex(after: time)
    guard let record = records[range].first(where: { $0.id == line.id && $0.replay == frames }),
          case .complete(let text) = record.fileReview else { return nil }
    return text
  }

  func accept(_ line: LiveLine, evidenceID: String?) {
    guard let time = line.receivedAt else { return }
    let start = CaptionWindow(now: clock()).start
    guard time >= start else { return }
    let expired = records.firstIndex(atOrAfter: start)
    if expired > 0 {
      records.removeFirst(expired)
      if let count = heldRecords?.firstIndex(atOrAfter: start), count > 0 { heldRecords?.removeFirst(count) }
    }
    // Use the timestamp index; only lines first received at exactly the same time can match.
    let lower = records.firstIndex(atOrAfter: time), upper = records.firstIndex(after: time)
    let index = records[lower..<upper].firstIndex { $0.id == line.id }
    let text = line.captionText
    var update: CaptionRecord?
    if LiveLine.containsSpeech(text) {
      var next = CaptionRecord(id: line.id, time: time, text: text, isFinal: line.isFinal,
                               localVoiceID: line.voiceID, evidenceID: evidenceID, replay: line.replay?.frames,
                               textSource: line.textSource)
      if let index, next.replay != nil, records[index].replay == next.replay {
        next.fileReview = records[index].fileReview
      }
      if next.fileReview == nil, line.fileReviewEligible, line.isFinal, next.replay != nil, reviewer != nil {
        next.fileReview = .queued
      }
      if let index {
        guard next != records[index] else { return }
        records[index] = next
        updateHeldRecord(id: line.id, time: time, with: next)
      } else {
        records.insert(next, at: upper)
      }
      update = next
    } else {
      guard line.isFinal || text.isEmpty, let index else { return }
      records.remove(at: index)
      updateHeldRecord(id: line.id, time: time, with: nil)
    }
    disk.save(id: line.id, record: update, audio: line.replay?.packets) { [weak self] error in
      if self?.issue != error { self?.issue = error }
    }
    if update?.fileReview?.pending == true { startReviewWorker() }
  }

  func configureReview(_ config: LiveASRConfiguration?, reviewer: (any CaptionFileTranscribing)?) {
    guard config != reviewConfiguration else { return }
    reviewWorker?.cancel()
    reviewWorker = nil
    reviewConfiguration = config
    self.reviewer = reviewer
    if reviewer != nil { startReviewWorker() }
  }

  func retryReview(_ record: CaptionRecord) {
    guard reviewer != nil, case .failed(let taskID) = record.fileReview,
          setReview(taskID.map(CaptionFileReview.submitted) ?? .queued, for: record) else { return }
    startReviewWorker()
  }

  private func startReviewWorker() {
    guard reviewWorker == nil, let reviewer else { return }
    reviewWorker = Task { [weak self] in
      while !Task.isCancelled, let self {
        let start = CaptionWindow(now: clock()).start
        guard var record = records[records.firstIndex(atOrAfter: start)...].first(where: { $0.fileReview?.pending == true })
        else { break }
        var taskID: String?
        do {
          if case .submitted(let id) = record.fileReview {
            taskID = id
          } else {
            let wav = try await replayAudio(for: record)
            guard !Task.isCancelled, reviewIndex(for: record) != nil else { continue }
            let id = try await reviewer.submitCaption(wav: wav)
            guard !Task.isCancelled, setReview(.submitted(id), for: record) else { continue }
            taskID = id
            record.fileReview = .submitted(id)
          }
          guard let taskID else { continue }
          let text = try await reviewer.captionResult(taskID: taskID)
          guard !Task.isCancelled else { break }
          _ = setReview(LiveLine.containsSpeech(text) ? .complete(text) : .noSpeech, for: record)
        } catch {
          guard !Task.isCancelled else { break }
          _ = setReview(.failed(taskID: error is FileTransTaskFailed ? nil : taskID), for: record)
        }
      }
      if !Task.isCancelled { self?.reviewWorker = nil }
    }
  }

  private func reviewIndex(for record: CaptionRecord) -> Int? {
    guard record.time >= CaptionWindow(now: clock()).start else { return nil }
    let range = records.firstIndex(atOrAfter: record.time)..<records.firstIndex(after: record.time)
    return records[range].firstIndex { $0.id == record.id && $0.replay == record.replay && $0.fileReview == record.fileReview }
  }

  @discardableResult private func setReview(_ review: CaptionFileReview, for record: CaptionRecord) -> Bool {
    guard let index = reviewIndex(for: record) else { return false }
    records[index].fileReview = review
    updateHeldRecord(id: record.id, time: record.time, with: records[index])
    disk.save(id: record.id, record: records[index], audio: nil, keepAudio: true) { [weak self] error in
      if self?.issue != error { self?.issue = error }
    }
    if case .complete = review { reviewCompleted.send() }
    return true
  }

  func flush() async {
    let error = await disk.flush()
    if issue != error { issue = error }
  }

  func replayAudio(for record: CaptionRecord) async throws -> Data {
    guard let frames = record.replay, frames.start >= 0, frames.end > frames.start,
      record.time >= CaptionWindow(now: clock()).start
    else { throw WorkdayError.invalid("这句话没有可回听的音频。") }
    let packets = try await disk.audio(for: record, since: CaptionWindow(now: clock()).start)
    try Task.checkCancellation()
    return try await Task.detached(priority: .userInitiated) {
      try AudioFiles.cardWAV(packets: packets, frames: frames.start..<frames.end)
    }.value
  }
}

// Each recognition update replaces one row. Disk work is serialized off the audio/UI thread.
private final class CaptionJournal: @unchecked Sendable {
  private let url: URL
  private let queue = DispatchQueue(label: "workday.caption-journal", qos: .utility)
  private var db: OpaquePointer?
  private enum Change { case write(CaptionRecord, Data?, keepAudio: Bool), remove }
  private var pending: [String: Change] = [:]
  private let expiry: DispatchSourceTimer

  init(root: URL) {
    url = root.appendingPathComponent("Sync/recent-captions.sqlite")
    expiry = DispatchSource.makeTimerSource(queue: queue)
    expiry.schedule(deadline: .now() + 60, repeating: 60)
    expiry.setEventHandler { [weak self] in
      guard let self, db != nil else { return }
      try? expireAudio(before: CaptionWindow(now: Date()).start)
    }
    expiry.resume()
  }

  deinit { expiry.cancel(); sqlite3_close(db) }

  private func open() throws {
    guard db == nil else { return }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
      sqlite3_close(handle)
      throw WorkdayError.invalid("无法打开本机字幕记录。")
    }
    db = handle
    sqlite3_busy_timeout(handle, 2000)
    do {
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      let schema = """
        CREATE TABLE IF NOT EXISTS captions(id TEXT PRIMARY KEY, time REAL NOT NULL, record BLOB NOT NULL);
        CREATE INDEX IF NOT EXISTS captions_by_time ON captions(time);
        """
      guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { throw failure() }
      // Serialize first-open upgrades when two windows/processes use the same library.
      guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw failure() }
      defer { if sqlite3_get_autocommit(db) == 0 { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
      let columns = try statement("SELECT count(*) FROM pragma_table_info('captions') WHERE name='audio'")
      let hasColumn = sqlite3_step(columns) == SQLITE_ROW && sqlite3_column_int(columns, 0) == 1
      sqlite3_finalize(columns)
      if !hasColumn, sqlite3_exec(db, "ALTER TABLE captions ADD COLUMN audio BLOB", nil, nil, nil) != SQLITE_OK {
        throw failure()
      }
      guard sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS caption_audio_time ON captions(time) WHERE audio IS NOT NULL; COMMIT",
                         nil, nil, nil) == SQLITE_OK else { throw failure() }
    } catch {
      sqlite3_close(db)
      db = nil
      throw error
    }
  }

  private func failure() -> Error {
    WorkdayError.invalid("本机字幕记录读写失败：" + String(cString: sqlite3_errmsg(db)))
  }

  private func statement(_ sql: String) throws -> OpaquePointer {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
    return stmt
  }

  func load(since start: Date) throws -> [CaptionRecord] {
    try queue.sync {
      guard FileManager.default.fileExists(atPath: url.path) else { return [] }
      try open()
      try expireAudio(before: start)
      let stmt = try statement("SELECT record FROM captions WHERE time >= ? ORDER BY time, rowid")
      defer { sqlite3_finalize(stmt) }
      guard sqlite3_bind_double(stmt, 1, start.timeIntervalSince1970) == SQLITE_OK else { throw failure() }
      var records: [CaptionRecord] = []
      let decoder = JSONDecoder()
      while true {
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return records }
        guard result == SQLITE_ROW, let blob = sqlite3_column_blob(stmt, 0) else { throw failure() }
        records.append(try decoder.decode(CaptionRecord.self, from:
          Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))))
      }
    }
  }

  private func expireAudio(before time: Date) throws {
    let stmt = try statement("UPDATE captions SET audio=NULL WHERE audio IS NOT NULL AND time < ?")
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_bind_double(stmt, 1, time.timeIntervalSince1970) == SQLITE_OK,
          sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
  }

  func audio(for record: CaptionRecord, since start: Date) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in queue.async {
      continuation.resume(with: Result {
        try self.open()
        let stmt = try self.statement("SELECT record,audio FROM captions WHERE id=? AND time>=?")
        defer { sqlite3_finalize(stmt) }
        let copy = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(stmt, 1, record.id, -1, copy) == SQLITE_OK,
          sqlite3_bind_double(stmt, 2, start.timeIntervalSince1970) == SQLITE_OK else { throw self.failure() }
        let status = sqlite3_step(stmt)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw self.failure() }
        guard status == SQLITE_ROW, let metadata = sqlite3_column_blob(stmt, 0),
          try JSONDecoder().decode(CaptionRecord.self, from: Data(bytes: metadata, count: Int(sqlite3_column_bytes(stmt, 0)))).replay == record.replay,
          let audio = sqlite3_column_blob(stmt, 1)
        else { throw WorkdayError.invalid("这句话的缓存音频已不可用。") }
        return Data(bytes: audio, count: Int(sqlite3_column_bytes(stmt, 1)))
      })
    } }
  }

  func save(id: String, record: CaptionRecord?, audio: Data?, keepAudio: Bool = false,
            report: @escaping @MainActor (String?) -> Void) {
    queue.async {
      if keepAudio, let record, case .write(_, let prior, let keep) = self.pending[id] {
        self.pending[id] = .write(record, prior, keepAudio: keep)
      } else {
        self.pending[id] = record.map { .write($0, audio, keepAudio: keepAudio) } ?? .remove
      }
      let error = self.drain()
      DispatchQueue.main.async { report(error) }
    }
  }

  func flush() async -> String? {
    await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: self.drain()) } }
  }

  private func drain() -> String? {
    guard !pending.isEmpty else { return nil }
    do {
      try open()
      let copy = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
      for (id, change) in pending {
        let sql: String
        switch change {
        case .write(_, _, let keepAudio):
          sql = """
            INSERT INTO captions(id,time,record,audio) VALUES(?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET record=excluded.record,audio=\(keepAudio ? "captions.audio" : "excluded.audio")
            """
        case .remove: sql = "DELETE FROM captions WHERE id=?"
        }
        let stmt = try statement(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_text(stmt, 1, id, -1, copy) == SQLITE_OK else { throw failure() }
        if case .write(let record, let audio, _) = change {
          let data = try JSONEncoder().encode(record)
          let bound = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(data.count), copy) }
          guard bound == SQLITE_OK, sqlite3_bind_double(stmt, 2, record.time.timeIntervalSince1970) == SQLITE_OK
          else { throw failure() }
          if let audio {
            let bound = audio.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32(audio.count), copy) }
            guard bound == SQLITE_OK else { throw failure() }
          }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        pending.removeValue(forKey: id)
      }
      return nil
    } catch { return error.localizedDescription }
  }
}
