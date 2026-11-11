import Foundation

public enum RealtimePhase: String, Codable {
    case idle, starting, recording, pausing, paused, resuming, stopping, finalizing, saved, failed
    public var acceptsAudio: Bool { [.starting, .recording, .pausing, .paused, .resuming, .stopping].contains(self) }
    public var isActive: Bool { acceptsAudio || self == .finalizing }
}

/// The phase follows received device events; sending a command is not an acknowledgement.
public struct RealtimeSession {
    /// App 发起使用 TYPE 1；接入机身录音使用 TYPE 3 控制，不能混用开始命令。
    public enum ControlMode: String, Codable { case realtime, device }
    public private(set) var controlMode: ControlMode = .realtime
    public private(set) var phase: RealtimePhase = .idle
    public private(set) var receivedBytes = 0
    public private(set) var deviceFilename: String?
    public private(set) var stopConfirmed = false
    public private(set) var interruption: String?
    public var audioSeconds: Double { Double(receivedBytes / 40) * 0.02 }
    public init() {}
    /// 仅供设备空闲时的新录音使用；中途接入调用 adoptDeviceRecording，不调用 start。
    public mutating func start() throws -> [UInt8] {
        guard !phase.isActive else { throw ProtocolError.invalid("上一条实时录音尚未结束") }
        self = RealtimeSession(); phase = .starting
        return [1, 0]
    }
    /// Adopt an existing device recording without sending another start-recording command.
    public mutating func adoptDeviceRecording(paused: Bool) throws {
        guard !phase.isActive else { throw ProtocolError.invalid("上一条实时录音尚未结束") }
        self = RealtimeSession(); controlMode = .device; phase = paused ? .paused : .recording
    }
    public mutating func pause() throws -> [UInt8] {
        guard phase == .recording else { throw ProtocolError.invalid("当前不能暂停") }
        phase = .pausing; return controlMode == .device ? [3, 5] : [1, 3, 1]
    }
    public mutating func resume() throws -> [UInt8] {
        guard phase == .paused else { throw ProtocolError.invalid("当前不能继续") }
        phase = .resuming; return controlMode == .device ? [3, 7] : [1, 3, 0]
    }
    public mutating func stop() throws -> [UInt8] {
        guard phase.acceptsAudio else { throw ProtocolError.invalid("当前没有待结束的录音") }
        phase = .stopping; return controlMode == .device ? [3, 3] : [1, 2]
    }
    public mutating func filename(_ name: String) { if phase.acceptsAudio { deviceFilename = name } }
    @discardableResult public mutating func append(byteCount: Int) -> Bool {
        guard phase.acceptsAudio, byteCount > 0 else { return false }
        receivedBytes += byteCount
        if controlMode == .realtime && (phase == .starting || phase == .resuming) { phase = .recording }
        return true
    }
    /// 接收上层归一化状态：0 录音、1 暂停、2 停止；不是 TYPE 3 的原始状态值。
    public mutating func deviceStatus(_ value: UInt8) {
        guard phase.acceptsAudio else { return }
        switch value {
        case 0: if phase != .stopping { phase = .recording }
        case 1: if phase != .stopping { phase = .paused }
        case 2: phase = .stopping; stopConfirmed = true
        default: break
        }
    }
    public mutating func markInterrupted(_ reason: String) {
        if interruption == nil { interruption = reason }
    }
    public mutating func commandFailed(paused: Bool) {
        guard phase.acceptsAudio, !stopConfirmed else { return }
        phase = paused ? .paused : .recording
    }
    public mutating func beginFinalizing() { phase = .finalizing }
    public mutating func finish(success: Bool) { phase = success ? .saved : .failed }
}
