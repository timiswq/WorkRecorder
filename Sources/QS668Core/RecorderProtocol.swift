import Foundation

/// 网页 Demo 支持的两组服务和特征。发现顺序不影响选择，AE20 优先。
public struct RecorderProfile: Equatable {
    public let service: String
    public let write: String
    public let data: String
    public let keys: String

    public static let supported = [
        Self(service: "AE20", write: "AE21", data: "AE22", keys: "AE23"),
        Self(service: "AD40", write: "AD41", data: "AD42", keys: "AD43")
    ]
    public static func select(services: [String]) -> Self? {
        supported.first { services.contains($0.service) }
    }
    public static func matches(name: String, services: [String]) -> Bool {
        let name = name.lowercased()
        return select(services: services) != nil || name.hasPrefix("cb08") || name.hasPrefix("qs668")
    }
    public static func isNotify(_ id: String) -> Bool {
        supported.contains { $0.data == id || $0.keys == id }
    }
}

public enum RecorderQuery: CaseIterable {
    // allCases 的声明顺序就是网页首次连接和手动巡检的发送顺序。
    case battery, storage, firmware, authorization, state, duration, filename, gain, files
    public var payload: [UInt8] {
        switch self {
        case .battery: return [0, 3]
        case .storage: return [0, 1]
        case .firmware: return [0, 10]
        case .authorization: return [0, 12]
        case .state: return [3, 19]
        case .duration: return [3, 21]
        case .filename: return [3, 23]
        case .gain: return [3, 25]
        case .files: return [2, 0]
        }
    }
}

public enum RecorderKey: UInt8, CaseIterable {
    case start = 1, save = 3, pause = 5, resume = 7

    /// 机身按键只有类型和命令两个字节。有参数的回复或回显不应再次触发确认。
    public init?(frame: Frame) {
        guard frame.payload.count == 2, frame.type == 3, let command = frame.command else { return nil }
        self.init(rawValue: command)
    }
    public var acknowledgment: [UInt8] { [3, rawValue + 1, 1] }
}

/// 两个通知特征可以交错传来半帧。各自拆帧，并在交付合法按键前先将应答入队。
public struct RecorderNotifications {
    private var parsers: [String: FrameParser] = [:]
    public init() {}
    public mutating func receive(_ bytes: Data, from characteristic: String, profile: RecorderProfile,
                                 acknowledge: ([UInt8]) -> Void, deliver: (Frame) -> Void,
                                 corrupted: () -> Void) {
        guard characteristic == profile.data || characteristic == profile.keys else { return }
        var parser = parsers[characteristic] ?? FrameParser()
        let before = parser.corruptionCount
        let frames = parser.push(bytes)
        parsers[characteristic] = parser
        if parser.corruptionCount != before { corrupted() }
        for frame in frames {
            if let key = RecorderKey(frame: frame) { acknowledge(key.acknowledgment) }
            deliver(frame)
        }
    }
}

/// 网页使用的命令。主动发起普通录音使用 recording，回复机身操作使用 RecorderKey.acknowledgment。
public enum RecorderCommand {
    case query(RecorderQuery)
    case synchronizeClock(Date, TimeZone)
    case realtimeStart, realtimePause, realtimeResume, realtimeStop
    case recording(RecorderKey)
    case setGain(UInt8)
    case download(String, offset: UInt32)
    case segment(String, start: UInt32, end: UInt32)
    case abortDownload, deleteAll
    case deleteEntry(Data)

    public func payload() throws -> [UInt8] {
        switch self {
        case .query(let query): return query.payload
        case .synchronizeClock(let date, let zone): return try Wire.timeSyncPayload(date, timeZone: zone)
        case .realtimeStart: return [1, 0]
        case .realtimePause: return [1, 3, 1]
        case .realtimeResume: return [1, 3, 0]
        case .realtimeStop: return [1, 2]
        case .recording(let action): return [3, action.rawValue]
        case .setGain(let value):
            guard (1...3).contains(value) else { throw ProtocolError.invalid("增益只支持 1、2、3") }
            return [3, 27, value]
        case .download(let name, let offset): return try Wire.importPayload(name, offset: offset)
        case .segment(let name, let start, let end): return try Wire.segmentPayload(name, start: start, end: end)
        case .abortDownload: return [2, 7]
        case .deleteAll: return [2, 9]
        case .deleteEntry(let entry):
            guard entry.count == DeviceRecording.entryLength else { throw ProtocolError.invalid("删除单条录音需要原始 28 字节条目") }
            return [2, 8] + Array(entry)
        }
    }
}
