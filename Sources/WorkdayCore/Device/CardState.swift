import Foundation
import QS668Core

public typealias CardQuery = RecorderQuery

public enum WiFiRecordingEvent: UInt8 { case started = 6, ended = 7, paused = 8, resumed = 9 }

public struct CardState {
  public enum Phase: String { case unknown, recording, paused, idle, saving }
  public var connected = false
  public var receivesKeyEvents = false
  public private(set) var phase: Phase = .unknown
  public private(set) var seconds: Double?
  public private(set) var confirmedAt: Date?
  public private(set) var durationAt: Date?
  // 暂停和恢复只移动显示时钟，seconds 和 durationAt 始终保留设备读数。
  private var displayAnchor: (seconds: TimeInterval, date: Date)?
  public private(set) var battery: Int?
  private var batteryAt: Date?
  public private(set) var charging = false
  public private(set) var freeBytes: Int64?
  public private(set) var totalBytes: Int64?
  public private(set) var filename: String?
  public private(set) var firmware: String?
  private var starting = false
  private var lastHardwareEvent = Date.distantPast
  public init() {}
  public mutating func updateWiFi(raw: UInt8, battery: Int?, at date: Date = Date()) {
    // FW925 的状态应答只有 0 能确认空闲。暂停由成功的按键应答确认，非零轮询保留暂停状态。
    let next: Phase
    switch raw {
    case 0: next = .idle
    case _ where phase == .paused: next = .paused
    case 1: next = .recording
    default: next = .unknown
    }
    setPhase(next, at: date)
    if next == .idle { filename = nil }
    confirmedAt = date
    self.battery = battery
    batteryAt = date
  }
  public mutating func updateWiFi(event: WiFiRecordingEvent, filename: String?, at date: Date = Date()) {
    switch event {
    case .started, .resumed: setPhase(.recording, at: date)
    case .paused: setPhase(.paused, at: date)
    case .ended: setPhase(.idle, at: date)
    }
    self.filename = event == .ended ? nil : filename ?? self.filename
    confirmedAt = date
  }
  public func isFresh(at date: Date = Date()) -> Bool {
    guard connected, let confirmedAt else { return false }
    // 有按键订阅时，已确认的空闲状态可一直显示。录音时长仍以近期设备回复为准。
    return (receivesKeyEvents && phase == .idle) || date.timeIntervalSince(confirmedAt) < 10
  }
  public func currentDuration(at date: Date) -> Double? {
    guard isFresh(at: date), phase == .recording || phase == .paused,
      let durationAt, (0..<10).contains(date.timeIntervalSince(durationAt))
    else { return nil }
    return displayDuration(at: date)?.rounded(.down)
  }
  private func displayDuration(at date: Date) -> TimeInterval? {
    guard let displayAnchor else { return nil }
    let runningTime = phase == .recording ? max(0, date.timeIntervalSince(displayAnchor.date)) : 0
    return displayAnchor.seconds + runningTime
  }
  private mutating func setPhase(_ next: Phase, at date: Date) {
    guard phase != next else { return }
    if (next == .recording || next == .paused), phase != .idle, phase != .saving,
       let elapsed = displayDuration(at: date) {
      displayAnchor = (elapsed, date)
    } else {
      displayAnchor = nil
    }
    phase = next
  }
  public func currentBattery(at date: Date) -> Int? {
    guard connected, let batteryAt, (0..<120).contains(date.timeIntervalSince(batteryAt))
    else { return nil }
    return battery
  }
  public mutating func disconnect() {
    connected = false
    displayAnchor = nil
    receivesKeyEvents = false
    battery = nil
    batteryAt = nil
    charging = false
    freeBytes = nil
    totalBytes = nil
    firmware = nil
  }
  public mutating func apply(
    _ frame: Frame, channel: String = "AE22", at date: Date = Date(), querySentAt: Date? = nil
  ) {
    guard connected, RecorderProfile.isNotify(channel) else { return }
    if frame.type == 0 {
      if frame.command == 4, let value = frame.body.first {
        charging = value == 110
        battery = value == 110 ? 100 : value <= 100 ? Int(value) : nil
        batteryAt = date
      } else if frame.command == 2, let storage = try? DeviceStorage.parse(frame.body) {
        freeBytes = storage.freeBytes
        totalBytes = storage.totalBytes
      } else if frame.command == 11 {
        firmware = Wire.text(frame.body)
      }
      return
    }
    guard frame.type == 3 else { return }
    if let event = RecorderKey(frame: frame) {
      starting = event == .start
      lastHardwareEvent = date
      confirmedAt = date
      switch event {
      case .start:
        phase = .recording
        displayAnchor = nil
        seconds = nil
        filename = nil
        durationAt = nil
      case .save: setPhase(.saving, at: date)
      case .pause: setPhase(.paused, at: date)
      case .resume: setPhase(.recording, at: date)
      }
      return
    }
    // 按键前发出的查询可能晚到，不能覆盖新录音的状态、时长或文件名。
    if let sent = querySentAt, sent < lastHardwareEvent { return }
    switch frame.command {
    case 20:
      guard let value = frame.body.first, [1, 2, 3].contains(value) else { return }
      if starting && value == 2 && date.timeIntervalSince(lastHardwareEvent) < 5 { return }
      starting = false
      if phase == .saving && value != 2 { return }
      switch value {
      case 1: setPhase(.recording, at: date)
      case 2: setPhase(.idle, at: date)
      default: setPhase(.paused, at: date)
      }
      confirmedAt = date
    case 22:
      guard frame.body.count >= 6 else { return }
      let reported = Double(UInt16(frame.body[0]) | UInt16(frame.body[1]) << 8)
      seconds = reported
      durationAt = date
      displayAnchor = (reported, date)
    case 24:
      let name = Wire.text(frame.body)
      guard !name.isEmpty else { return }
      if let old = filename, old != name {
        seconds = nil
        durationAt = nil
        displayAnchor = nil
      }
      filename = name
    default: break
    }
  }
}
