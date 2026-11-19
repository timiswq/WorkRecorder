import Foundation

public struct TransferProgress: Equatable, Sendable {
  public enum Phase: Sendable { case copying, verifying }

  public let phase: Phase
  public let copied: Int64
  public let total: Int64
  public let bytesPerSecond: Double?
  public let recentBytesPerSecond: Double?
  public let uptime: TimeInterval

  public var fraction: Double { total > 0 ? min(1, Double(copied) / Double(total)) : 0 }

  public init(
    phase: Phase, copied: Int64, total: Int64, bytesPerSecond: Double?, uptime: TimeInterval,
    recentBytesPerSecond: Double? = nil
  ) {
    self.phase = phase
    self.copied = copied
    self.total = total
    self.bytesPerSecond = bytesPerSecond
    self.recentBytesPerSecond = recentBytesPerSecond
    self.uptime = uptime
  }
}

/// Samples cumulative bytes on a monotonic clock, starting at the actual resume offset.
public struct TransferMeter {
  let total: Int64
  private var samples: [(time: TimeInterval, bytes: Int64)]
  private var lastTime: TimeInterval
  private var lastBytes: Int64
  private var lastRateTime: TimeInterval
  private var recentRate: Double?

  public init(total: Int64, initialBytes: Int64 = 0, at time: TimeInterval) {
    self.total = total
    samples = [(time, initialBytes)]
    lastTime = time
    lastBytes = initialBytes
    lastRateTime = time
  }

  public mutating func update(_ copied: Int64, at time: TimeInterval) -> TransferProgress? {
    let interval = time - lastTime
    guard interval > 0, copied > lastBytes, interval >= 0.35 || copied == total else { return nil }
    let rate = Double(copied - lastBytes) / interval
    samples.append((time, copied))
    let cutoff = time - 2
    while samples.count > 2, samples[1].time <= cutoff { samples.removeFirst() }
    if time - lastRateTime >= 1 {
      let first = samples[0]
      let second = samples[1]
      let baselineTime = max(first.time, cutoff)
      let fraction = (baselineTime - first.time) / (second.time - first.time)
      let baselineBytes = Double(first.bytes) + Double(second.bytes - first.bytes) * fraction
      recentRate = (Double(copied) - baselineBytes) / (time - baselineTime)
      lastRateTime = time
    }
    lastTime = time
    lastBytes = copied
    return TransferProgress(
      phase: .copying, copied: copied, total: total, bytesPerSecond: rate, uptime: time,
      recentBytesPerSecond: recentRate)
  }
}
