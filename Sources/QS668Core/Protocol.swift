import Foundation

public enum ProtocolError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

/// QS668 控制帧与字段编码；这里只处理字节，不访问蓝牙或磁盘。
/// CRC/长度是小端，录音列表的计数与条目数值是大端，不可统一交换字节序。
public enum Wire {
    static let headerLength = 6
    static let maximumPayloadLength = 8192

    /// 校时帧只传年月日时分秒。App 显式传入本地时区，旧调用仍默认北京时间。
    public static func timeSyncPayload(_ date: Date, timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai")!) throws -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = parts.year, (1...65535).contains(year),
              let month = parts.month, let day = parts.day, let hour = parts.hour,
              let minute = parts.minute, let second = parts.second else {
            throw ProtocolError.invalid("Mac 时间无法编码为设备时间")
        }
        return [0, 0, UInt8(year & 255), UInt8(year >> 8), UInt8(month), UInt8(day), UInt8(hour), UInt8(minute), UInt8(second)]
    }
    /// CRC-16/XMODEM：初值 0、生成多项式 0x1021，范围为长度字段和 payload。
    public static func crc(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = (crc & 0x8000 != 0) ? (crc &<< 1) ^ 0x1021 : crc &<< 1 }
        }
        return crc
    }
    /// 0x5A | seq | CRC_LE16 | payloadLength_LE16 | TYPE | CMD | body。
    public static func frame(_ payload: [UInt8], seq: UInt8) -> Data {
        precondition(payload.count <= maximumPayloadLength)
        let length = [UInt8(payload.count & 255), UInt8(payload.count >> 8)]
        let checksum = crc(length + payload)
        return Data([0x5a, seq, UInt8(checksum & 255), UInt8(checksum >> 8)] + length + payload)
    }
    /// Demo 2-2：偏移 LE32 + 固定 24 字节文件名，一次写完 36 字节。
    public static func importPayload(_ name: String, offset: UInt32 = 0) throws -> [UInt8] {
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= 24, !bytes.contains(0), !name.contains("/"), !name.contains("\\") else {
            throw ProtocolError.invalid("设备文件名无效或超过 24 字节")
        }
        return [2, 2] + le32Bytes(offset) + bytes + Array(repeating: 0, count: 24 - bytes.count)
    }
    static func le32Bytes(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    public static func segmentPayload(_ name: String, start: UInt32, end: UInt32) throws -> [UInt8] {
        let bytes = Array(name.utf8)
        // 类型、命令和两个 LE32 偏移共占 10 字节。
        guard !bytes.isEmpty, bytes.count <= maximumPayloadLength - 10, !bytes.contains(0), !name.contains("/"), !name.contains("\\"),
              end >= start else { throw ProtocolError.invalid("分段文件名或偏移无效") }
        return [2, 12] + le32Bytes(start) + le32Bytes(end) + bytes
    }
    public static func text(_ bytes: some Sequence<UInt8>) -> String {
        String(decoding: Array(bytes.prefix { $0 != 0 }), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func be32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }
    public static func le32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

public struct Frame: Equatable {
    public let sequence: UInt8
    public let payload: [UInt8]
    public var type: UInt8? { payload.first }
    public var command: UInt8? { payload.count > 1 ? payload[1] : nil }
    public var body: [UInt8] { Array(payload.dropFirst(2)) }
}

/// 每个通知特征独立持有一个解析器；一次通知可以只含半帧，也可含多帧。
/// 长度越界时重新找帧头。长度合法时先消费整帧，再校验非零 CRC，避免把坏帧内的 0x5A 当成新帧头。
public struct FrameParser {
    private var buffer: [UInt8] = []
    public private(set) var corruptionCount = 0
    public init() {}
    public mutating func push(_ data: Data) -> [Frame] {
        buffer.append(contentsOf: data)
        var frames: [Frame] = []
        while buffer.count >= Wire.headerLength {
            guard let start = buffer.firstIndex(of: 0x5a) else { buffer.removeAll(); break }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= Wire.headerLength else { break }
            let length = Int(buffer[4]) | Int(buffer[5]) << 8
            guard length <= Wire.maximumPayloadLength else { buffer.removeFirst(); corruptionCount += 1; continue }
            let frameLength = Wire.headerLength + length
            guard buffer.count >= frameLength else { break }
            let expected = UInt16(buffer[2]) | UInt16(buffer[3]) << 8
            let packet = Array(buffer.prefix(frameLength))
            buffer.removeFirst(frameLength)
            guard expected == 0 || Wire.crc(packet.dropFirst(4)) == expected else {
                corruptionCount += 1; continue
            }
            frames.append(Frame(sequence: packet[1], payload: Array(packet.dropFirst(Wire.headerLength))))
        }
        return frames
    }
}

/// 容量应答 0-2：剩余、总容量各 LE32；单位沿用公开协议及配套示例的 KiB。
public struct DeviceStorage: Equatable {
    public let freeBytes: Int64
    public let totalBytes: Int64

    public static func parse(_ body: [UInt8]) throws -> DeviceStorage {
        guard body.count == 8 else { throw ProtocolError.invalid("设备容量应答长度无效") }
        let free = Wire.le32(body[0..<4]), total = Wire.le32(body[4..<8])
        guard total > 0, free <= total else { throw ProtocolError.invalid("设备容量应答数值无效") }
        return DeviceStorage(freeBytes: Int64(free) * 1024, totalBytes: Int64(total) * 1024)
    }
}

public struct DeviceRecording: Identifiable, Codable, Equatable {
    // 时长和大小各 4 字节，文件名 20 字节。删除单条时需回送整条原始记录。
    static let entryLength = 28
    public let duration: UInt32
    public let size: UInt32
    public let name: String
    public let revision: String?
    public var id: String { "\(name)|\(duration)|\(size)" + (revision.map { "|\($0)" } ?? "") }
    public init(duration: UInt32, size: UInt32, name: String, revision: String? = nil) {
        self.duration = duration; self.size = size; self.name = name; self.revision = revision
    }
    public var stem: String {
        if let dot = name.lastIndex(of: ".") { return String(name[..<dot]) }
        return name
    }
    public var candidates: [String] { [stem + ".wav", stem + ".opus", name].reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
    public var recordingDate: Date? {
        guard let range = name.range(of: #"\d{8}-\d{6}"#, options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.isLenient = false
        return formatter.date(from: String(name[range]))
    }
    /// BLE 列表字段 duration 是录音时长，不能当 Unix 时间戳；日期来自文件名。
    public static func parse(_ body: [UInt8]) throws -> [DeviceRecording] {
        guard body.count >= 4 else { throw ProtocolError.invalid("录音列表缺少条目数量") }
        let count = Int(Wire.be32(body[0..<4]))
        guard count <= Wire.maximumPayloadLength / entryLength, body.count == 4 + count * entryLength else { throw ProtocolError.invalid("录音列表长度与条目数量不符") }
        return try (0..<count).map { index in
            let start = 4 + index * entryLength
            let name = Wire.text(body[(start + 8)..<(start + entryLength)])
            guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else {
                throw ProtocolError.invalid("设备返回不安全的文件名")
            }
            return DeviceRecording(duration: Wire.be32(body[start..<(start + 4)]), size: Wire.be32(body[(start + 4)..<(start + 8)]), name: name)
        }
    }
}

/// 验证设备 PCM WAV，或将固定 40 字节 OPUS 包封装为 Ogg；不做语音识别。
public enum AudioEnvelope {
    public static func validateWAV(_ data: Data) throws {
        let b = Array(data)
        guard b.count >= 44, String(decoding: b[0..<4], as: UTF8.self) == "RIFF", String(decoding: b[8..<12], as: UTF8.self) == "WAVE",
              Int(Wire.le32(b[4..<8])) + 8 == b.count else { throw ProtocolError.invalid("WAV 文件不完整，未加入录音库") }
        var offset = 12
        var alignment: Int?
        var payloadSize: Int?
        while offset + 8 <= b.count {
            let length = Int(Wire.le32(b[(offset + 4)..<(offset + 8)]))
            let start = offset + 8
            guard length <= b.count - start else { throw ProtocolError.invalid("WAV 音频块长度不完整") }
            let kind = String(decoding: b[offset..<(offset + 4)], as: UTF8.self)
            if kind == "fmt " {
                guard length >= 16 else { throw ProtocolError.invalid("WAV 格式块无效") }
                let format = Int(b[start]) | Int(b[start + 1]) << 8
                let channels = Int(b[start + 2]) | Int(b[start + 3]) << 8
                let bits = Int(b[start + 14]) | Int(b[start + 15]) << 8
                let block = Int(b[start + 12]) | Int(b[start + 13]) << 8
                let rate = Wire.le32(b[(start + 4)..<(start + 8)])
                let pcmGUID: [UInt8] = [1, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71]
                let extensiblePCM = format == 0xfffe && length >= 40 &&
                    Array(b[(start + 24)..<(start + 40)]) == pcmGUID
                guard format == 1 || extensiblePCM, channels > 0, [8, 16, 24, 32].contains(bits), rate > 0,
                      block == channels * bits / 8,
                      UInt64(Wire.le32(b[(start + 8)..<(start + 12)])) == UInt64(rate) * UInt64(block) else {
                    throw ProtocolError.invalid("WAV 不是有效的 PCM 录音")
                }
                alignment = block
            } else if kind == "data" { payloadSize = length }
            offset = start + length + (length % 2)
        }
        guard offset == b.count, let alignment, let payloadSize, payloadSize > 0, payloadSize % alignment == 0 else {
            throw ProtocolError.invalid("WAV 缺少完整音频数据")
        }
    }
    // Follows the supplied qs668-raw-opus-to-ogg.py (40 bytes / 20 ms, mono).
    public static func wrapOpus(_ raw: Data) throws -> Data {
        guard !raw.isEmpty, raw.count % 40 == 0 else { throw ProtocolError.invalid("原始 OPUS 长度不是 40 字节的整数倍") }
        let b = Array(raw)
        // The documented QS668 stream is config 9, one 20 ms frame per packet.
        guard stride(from: 0, to: b.count, by: 40).allSatisfy({
            b[$0] >> 3 == 9 && b[$0] & 4 == 0 &&
                (b[$0] & 3 == 0 || (b[$0] & 3 == 3 && b[$0 + 1] & 0x3f == 1))
        }) else {
            throw ProtocolError.invalid("音频不符合已知 QS668 OPUS 格式，保留原始文件供检查")
        }
        var result = Data()
        var head = Array("OpusHead".utf8) + [1, 1]
        head += le(312, count: 2) + le(16000, count: 4) + [0, 0, 0]
        let tags = Array("OpusTags".utf8) + le(5, count: 4) + Array("QS668".utf8) + [0, 0, 0, 0]
        result.append(page([head], granule: 0, sequence: 0, flags: 2))
        result.append(page([tags], granule: 0, sequence: 1, flags: 0))
        // Ogg Opus 的 granule 始终用 48 kHz 计数：20 ms = 960；不是输出 WAV 的 16 kHz。
        let count = b.count / 40
        for start in stride(from: 0, to: count, by: 50) {
            let end = min(start + 50, count)
            let packets = (start..<end).map { Array(b[($0 * 40)..<(($0 + 1) * 40)]) }
            result.append(page(packets, granule: UInt64(end * 960), sequence: UInt64(start / 50 + 2), flags: end == count ? 4 : 0))
        }
        return result
    }
    static func le(_ value: UInt64, count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
    static func page(_ packets: [[UInt8]], granule: UInt64, sequence: UInt64, flags: UInt8) -> Data {
        var bytes = Array("OggS".utf8) + [0, flags] + le(granule, count: 8)
        bytes += le(0x51533638, count: 4) + le(sequence, count: 4) + [0, 0, 0, 0, UInt8(packets.count)]
        bytes += packets.map { UInt8($0.count) }
        bytes += packets.flatMap { $0 }
        var crc: UInt32 = 0
        for byte in bytes {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = (crc & 0x80000000 != 0) ? (crc &<< 1) ^ 0x04c11db7 : crc &<< 1 }
        }
        bytes.replaceSubrange(22..<26, with: le(UInt64(crc), count: 4))
        return Data(bytes)
    }
}
