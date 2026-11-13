import Foundation
import QS668Core

public struct InventoryEntry: Codable, Equatable, Sendable {
  public var name: String
  public var duration: Double?
  public var bytes: Int64
  public var isOpusOnly: Bool
  public var stem: String { Self.stem(name) }
  public var day: String {
    DeviceRecording(duration: 0, size: 0, name: name).recordingDate.map(WorkdayDate.day) ?? "日期未知"
  }
  public init(name: String, duration: Double?, bytes: Int64, isOpusOnly: Bool = false) {
    self.name = name
    self.duration = duration
    self.bytes = bytes
    self.isOpusOnly = isOpusOnly
  }
  public static func stem(_ name: String) -> String {
    let value = name.lowercased()
    if let range = value.range(of: #"^(note|call)\d{8}-\d{6}"#, options: .regularExpression) {
      return String(value[range])
    }
    return URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent
  }
}

public struct InventoryCount: Equatable, Sendable {
  public init() {}
  public var today = 0
  public var earlier = 0
  public var unknownDate = 0
  public var unverified = 0
  public var unsupported = 0
  public var total: Int { today + earlier + unknownDate }
}

public struct DeviceInventory: Codable, Equatable, Sendable {
  public var sourceID: String
  public var entries: [InventoryEntry]
  public var observedAt: Date
  public var complete: Bool
  public init(sourceID: String, entries: [InventoryEntry], observedAt: Date, complete: Bool) {
    self.sourceID = sourceID
    self.entries = entries
    self.observedAt = observedAt
    self.complete = complete
  }
  public func count(
    recordings: [Recording], linkedSources: Set<String>, activeName: String?, today: String
  ) -> InventoryCount {
    var result = InventoryCount()
    let sources = linkedSources.union([sourceID])
    let groups = Dictionary(grouping: entries, by: \.stem)
    for (stem, files) in groups where activeName.map(InventoryEntry.stem) != stem {
      let sameNames = recordings.filter { InventoryEntry.stem($0.originalName) == stem }
      let confirmed = sameNames.contains { record in
        guard !sources.isDisjoint(with: Set([record.sourceID] + (record.sourceAliases ?? [])))
        else { return false }
        return files.contains { entry in
          if entry.name.lowercased().hasSuffix(".wav") { return entry.bytes == record.bytes }
          guard let opusBytes = record.companionBytes else { return false }
          return opusBytes == entry.bytes
            && entry.duration.map { abs($0 - record.duration) <= 2 } != false
        }
      }
      if confirmed { continue }
      if !sameNames.isEmpty { result.unverified += 1 }
      if files.allSatisfy(\.isOpusOnly) { result.unsupported += 1 }
      let day = files[0].day
      if day == today {
        result.today += 1
      } else if day == "日期未知" {
        result.unknownDate += 1
      } else {
        result.earlier += 1
      }
    }
    return result
  }
}

/// Only an explicit successful end frame proves a complete directory.
public struct InventoryCollector {
  private var sourceID: String?
  private var entries: [InventoryEntry] = []
  private var lastActivity = Date.distantPast
  public var running: Bool { sourceID != nil }
  public init() {}
  public mutating func begin(sourceID: String, at date: Date) {
    self.sourceID = sourceID
    entries = []
    lastActivity = date
  }
  public mutating func cancel() {
    sourceID = nil
    entries = []
  }
  public mutating func receive(_ frame: Frame, at date: Date) throws -> DeviceInventory? {
    guard sourceID != nil, frame.type == 2 else { return nil }
    if frame.command == 1 {
      let incoming = try DeviceRecording.parse(frame.body)
      guard entries.count + incoming.count <= 100_000 else { throw WorkdayError.invalid("录音清单过大") }
      entries += incoming.map {
        InventoryEntry(name: $0.name, duration: Double($0.duration), bytes: Int64($0.size))
      }
      lastActivity = date
    } else if frame.command == 18 {
      guard frame.body.isEmpty || frame.body == [0] else { throw WorkdayError.invalid("录音清单未完整返回") }
      return finish(complete: true, at: date)
    }
    return nil
  }
  public mutating func expire(at date: Date) -> DeviceInventory? {
    guard sourceID != nil, date.timeIntervalSince(lastActivity) > (entries.isEmpty ? 12 : 1.2)
    else { return nil }
    return finish(complete: false, at: date)
  }
  private mutating func finish(complete: Bool, at date: Date) -> DeviceInventory? {
    guard let sourceID else { return nil }
    let snapshot = DeviceInventory(
      sourceID: sourceID, entries: entries, observedAt: date, complete: complete)
    cancel()
    return snapshot
  }
}

public struct DeviceCatalog: Codable, Sendable {
  public var snapshots: [String: DeviceInventory] = [:]
  public var bindings: [String: String] = [:]
  public var timings: [String: ObservedTiming]?
  public init() {}
}
extension ArchiveStore {
  public func loadDeviceCatalog() throws -> DeviceCatalog {
    let url = root.appendingPathComponent("Sync/devices.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return DeviceCatalog() }
    return try JSONDecoder().decode(DeviceCatalog.self, from: Data(contentsOf: url))
  }
  public func saveDeviceCatalog(_ catalog: DeviceCatalog) throws {
    try Files.writeJSON(catalog, to: root.appendingPathComponent("Sync/devices.json"))
  }
}
