import Foundation
import QS668Core

public enum CardQuery: CaseIterable, Hashable {
  case battery, storage, firmware, state, duration, filename, files
  public var payload: [UInt8] {
    switch self {
    case .battery: return [0, 3]
    case .storage: return [0, 1]
    case .firmware: return [0, 10]
    case .state: return [3, 19]
    case .duration: return [3, 21]
    case .filename: return [3, 23]
    case .files: return [2, 0]
    }
  }
}

public struct CardState {
  public enum Phase: String { case unknown, recording, paused, idle, saving }
  public var connected = false
  public private(set) var phase: Phase = .unknown
  public private(set) var seconds: Double?
  public private(set) var confirmedAt: Date?
  public private(set) var durationAt: Date?
  public private(set) var battery: Int?
  public private(set) var charging = false
  public private(set) var freeBytes: Int64?
  public private(set) var totalBytes: Int64?
  public private(set) var filename: String?
  public private(set) var firmware: String?
  private var lastHardwareEvent = Date.distantPast
  public init() {}
  public func isFresh(at date: Date = Date()) -> Bool {
    connected && confirmedAt.map { date.timeIntervalSince($0) < 10 } == true
  }
  public mutating func disconnect() {
    connected = false
    battery = nil
    charging = false
    freeBytes = nil
    totalBytes = nil
    firmware = nil
  }
  public mutating func apply(
    _ frame: Frame, channel: String = "AE22", at date: Date = Date(), querySentAt: Date? = nil
  ) {
    guard connected, channel == "AE22" || channel == "AE23" else { return }
    if frame.type == 0 {
      if frame.command == 4, let value = frame.body.first {
        charging = value == 110
        battery = value <= 100 ? Int(value) : nil
      } else if frame.command == 2, let storage = try? DeviceStorage.parse(frame.body) {
        freeBytes = storage.freeBytes
        totalBytes = storage.totalBytes
      } else if frame.command == 11 {
        firmware = Wire.text(frame.body)
      }
      return
    }
    guard frame.type == 3 else { return }
    if channel == "AE23", let command = frame.command, [1, 3, 5, 7].contains(command) {
      lastHardwareEvent = date
      confirmedAt = date
      switch command {
      case 1:
        phase = .recording
        seconds = nil
        filename = nil
        durationAt = nil
      case 3: phase = .saving
      case 5: phase = .paused
      default: phase = .recording
      }
      return
    }
    switch frame.command {
    case 20:
      if let sent = querySentAt, sent < lastHardwareEvent { return }
      guard let value = frame.body.first, [1, 2, 3].contains(value) else { return }
      if phase == .saving && value != 2 { return }
      switch value {
      case 1: phase = .recording
      case 2: phase = .idle
      default: phase = .paused
      }
      confirmedAt = date
    case 22:
      if let sent = querySentAt, sent < lastHardwareEvent { return }
      guard frame.body.count >= 6 else { return }
      seconds = Double(UInt16(frame.body[0]) | UInt16(frame.body[1]) << 8)
      durationAt = date
    case 24:
      if let sent = querySentAt, sent < lastHardwareEvent { return }
      let name = Wire.text(frame.body)
      guard !name.isEmpty else { return }
      if let old = filename, old != name {
        seconds = nil
        durationAt = nil
      }
      filename = name
    default: break
    }
  }
}
