import Foundation
import QS668Core

public struct SyncFile: Codable, Equatable, Identifiable, Sendable {
  public var sourceID: String
  public var path: String
  public var size: Int64
  public var modified: Date
  public var companionName: String?
  public var companionSize: Int64?
  public var companionModified: Date?
  public var name: String { URL(fileURLWithPath: path).lastPathComponent }
  public var stem: String { InventoryEntry.stem(name) }
  public var day: String {
    DeviceRecording(duration: 0, size: 0, name: name).recordingDate.map(WorkdayDate.day) ?? "日期未知"
  }
  public var supported: Bool {
    ["wav", "m4a", "mp3", "aiff", "aif"].contains(
      URL(fileURLWithPath: path).pathExtension.lowercased())
  }
  public var id: String {
    Files.digest(
      Data(
        "\(sourceID)|\(name)|\(size)|\(modified.timeIntervalSince1970)|\(companionSize ?? -1)|\(companionModified?.timeIntervalSince1970 ?? -1)"
          .utf8))
  }
  public init(
    sourceID: String, path: String, size: Int64, modified: Date, companionName: String? = nil,
    companionSize: Int64? = nil,
    companionModified: Date? = nil
  ) {
    self.sourceID = sourceID
    self.path = path
    self.size = size
    self.modified = modified
    self.companionName = companionName
    self.companionSize = companionSize
    self.companionModified = companionModified
  }
}

public struct SyncEntry: Codable, Identifiable, Equatable, Sendable {
  public var file: SyncFile
  public var recordingID: String?
  public var attempts = 0
  public var retryAt: Date?
  public var error: String?
  public var id: String { file.id }
}

public struct SyncLedger: Codable, Sendable {
  public var entries: [SyncEntry] = []
  public init() {}
  public mutating func discover(_ files: [SyncFile]) {
    for file in files {
      if let i = entries.firstIndex(where: { $0.id == file.id }) {
        // Mount paths can change between connections; they are not file identity.
        entries[i].file = file
      } else {
        entries.removeAll {
          $0.recordingID == nil && $0.file.sourceID == file.sourceID && $0.file.name == file.name
        }
        entries.append(SyncEntry(file: file))
      }
    }
  }
  public func next(available: Set<String>, at now: Date) -> SyncEntry? {
    let today = WorkdayDate.day(now)
    return entries.filter {
      $0.recordingID == nil && $0.file.supported && available.contains($0.id)
        && ($0.retryAt ?? .distantPast) <= now
    }.sorted {
      if ($0.file.day == today) != ($1.file.day == today) { return $0.file.day == today }
      if $0.file.day != $1.file.day { return $0.file.day > $1.file.day }
      return $0.file.name < $1.file.name
    }.first
  }
  public mutating func complete(_ id: String, recordingID: String) {
    guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
    entries[i].recordingID = recordingID
    entries[i].error = nil
    entries[i].retryAt = nil
  }
  public mutating func fail(_ id: String, message: String, at now: Date) {
    guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
    entries[i].attempts += 1
    entries[i].error = message
    entries[i].retryAt = now.addingTimeInterval(
      min(300, 30 * pow(2, Double(min(4, entries[i].attempts - 1)))))
  }
  public mutating func retry() {
    for i in entries.indices where entries[i].recordingID == nil { entries[i].retryAt = nil }
  }
}

extension ArchiveStore {
  public func loadSyncLedger() throws -> SyncLedger {
    let url = root.appendingPathComponent("Sync/queue.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return SyncLedger() }
    return try JSONDecoder().decode(SyncLedger.self, from: Data(contentsOf: url))
  }
  public func saveSyncLedger(_ ledger: SyncLedger) throws {
    try Files.writeJSON(ledger, to: root.appendingPathComponent("Sync/queue.json"))
  }
  public func archivedFileExists(_ id: String) throws -> Bool {
    guard let item = try load().first(where: { $0.id == id }) else { return false }
    let url = root.appendingPathComponent(item.folder).appendingPathComponent(item.originalFile)
    guard let stamp = try? FileStamp(url) else { return false }
    return stamp.size == item.bytes
  }
}
