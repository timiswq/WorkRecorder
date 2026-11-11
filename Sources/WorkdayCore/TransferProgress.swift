import Foundation

public struct TransferProgress: Equatable, Sendable {
  public enum Phase: Sendable { case copying, verifying }

  public let phase: Phase
  public let copied: Int64
  public let total: Int64
  public let bytesPerSecond: Double?
  public let uptime: TimeInterval

  public var fraction: Double { total > 0 ? min(1, Double(copied) / Double(total)) : 0 }

  public init(
    phase: Phase, copied: Int64, total: Int64, bytesPerSecond: Double?, uptime: TimeInterval
  ) {
    self.phase = phase
    self.copied = copied
    self.total = total
    self.bytesPerSecond = bytesPerSecond
    self.uptime = uptime
  }
}

/// Samples cumulative bytes written for the WAV and its optional companion on a monotonic clock.
struct TransferMeter {
  let total: Int64
  var lastTime: TimeInterval
  private var lastBytes: Int64 = 0
  init(total: Int64, at time: TimeInterval) {
    self.total = total
    lastTime = time
  }
  mutating func update(_ copied: Int64, at time: TimeInterval) -> TransferProgress? {
    let interval = time - lastTime
    guard interval > 0, copied > lastBytes, interval >= 0.35 || copied == total else { return nil }
    let rate = Double(copied - lastBytes) / interval
    lastTime = time
    lastBytes = copied
    return TransferProgress(
      phase: .copying, copied: copied, total: total, bytesPerSecond: rate, uptime: time)
  }
}
