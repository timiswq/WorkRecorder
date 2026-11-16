import Foundation

public struct SyncBatch {
  public private(set) var completed = 0
  public let skipped: Int
  public let total: Int
  public private(set) var current: RecordingEntry?
  private var pending: [RecordingEntry]
  private var cancelled = false
  public init(files: [RecordingEntry], existing: [RecordingEntry]) {
    let unique = files.reduce(into: [RecordingEntry]()) { result, file in
      if !result.contains(file) { result.append(file) }
    }
    pending = unique.filter { !existing.contains($0) }
    skipped = unique.count - pending.count
    total = pending.count
  }
  public mutating func next() throws -> RecordingEntry? {
    guard !cancelled else { return nil }
    guard current == nil else { throw WiFiRecorderError.invalid("上一份录音尚未完成") }
    guard !pending.isEmpty else { return nil }
    current = pending.removeFirst()
    return current
  }
  public mutating func finish(_ item: RecordingEntry) throws {
    guard !cancelled, current == item else { throw WiFiRecorderError.invalid("下载完成项与同步队列不符") }
    completed += 1
    current = nil
  }
  public mutating func cancel() {
    cancelled = true
    pending.removeAll()
    current = nil
  }
}
