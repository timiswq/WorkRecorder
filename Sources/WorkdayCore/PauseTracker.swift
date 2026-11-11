import Foundation

/// A gap is recorded only when both physical pause and resume were observed in one connection.
public struct PauseTracker {
  private var pending: (name: String, offset: Double, at: Date)?
  public init() {}
  public mutating func pause(name: String, offset: Double?, at date: Date) {
    guard let offset, offset.isFinite, offset >= 0 else {
      pending = nil
      return
    }
    pending = (InventoryEntry.stem(name), offset, date)
  }
  public mutating func confirmOffset(_ seconds: Double?) {
    guard let seconds, seconds.isFinite, seconds >= 0 else { return }
    pending?.offset = seconds
  }
  public mutating func resume(name: String, at date: Date) -> RecordingPause? {
    defer { pending = nil }
    guard let pending, pending.name == InventoryEntry.stem(name), date > pending.at else {
      return nil
    }
    return RecordingPause(offset: pending.offset, duration: date.timeIntervalSince(pending.at))
  }
  public mutating func cancel() { pending = nil }
}

public struct ObservedTiming: Codable, Sendable {
  public var pauses: [RecordingPause] = []
  public var updatedAt: Date = Date()
  public init() {}
}

extension ArchiveStore {
  public func applyPauses(_ pauses: [RecordingPause], to recording: Recording) throws -> Recording {
    var updated = recording
    updated.pauses = pauses.filter {
      $0.offset.isFinite && $0.offset >= 0 && $0.offset < recording.duration && $0.duration.isFinite
        && $0.duration > 0
    }
    try Files.writeJSON(
      updated,
      to: root.appendingPathComponent(recording.folder).appendingPathComponent("recording.json"))
    return updated
  }
}
