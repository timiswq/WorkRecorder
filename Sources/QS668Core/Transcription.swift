import Foundation
import CoreFoundation

/// 一个连续的 Ogg 流；不重复发送文件头，分片边界不必与 BLE 通知重合。
public struct OggOpusStream {
    private var buffer = Data()
    private var sequence: UInt64 = 0
    private var packets: UInt64 = 0
    private var ended = false
    public init() {}

    public mutating func append(_ bytes: Data) throws -> [Data] {
        guard !ended else { throw ProtocolError.invalid("转写音频流已经结束") }
        buffer.append(bytes)
        var pages = headers()
        // 保留最后一页，结束时携带 EOS；正常接收时约每 200 ms 发出一页。
        while buffer.count > 400 { pages.append(try audioPage(count: 10, final: false)) }
        return pages
    }
    public mutating func finish() throws -> [Data] {
        guard !ended else { return [] }
        guard buffer.count % 40 == 0 else { throw ProtocolError.invalid("转写音频末尾不足一个完整 Opus 包，文字可能不完整") }
        var pages = headers()
        pages.append(try audioPage(count: buffer.count / 40, final: true))
        ended = true
        return pages
    }
    private mutating func headers() -> [Data] {
        guard sequence == 0 else { return [] }
        sequence = 2
        let head = Array("OpusHead".utf8) + [1, 1] + AudioEnvelope.le(312, count: 2) + AudioEnvelope.le(16000, count: 4) + [0, 0, 0]
        let tags = Array("OpusTags".utf8) + AudioEnvelope.le(5, count: 4) + Array("QS668".utf8) + [0, 0, 0, 0]
        return [AudioEnvelope.page([head], granule: 0, sequence: 0, flags: 2),
                AudioEnvelope.page([tags], granule: 0, sequence: 1, flags: 0)]
    }
    private mutating func audioPage(count: Int, final: Bool) throws -> Data {
        let bytes = Array(buffer.prefix(count * 40))
        let frames = stride(from: 0, to: bytes.count, by: 40).map { Array(bytes[$0..<($0 + 40)]) }
        guard frames.allSatisfy({ $0[0] >> 3 == 9 && $0[0] & 4 == 0 &&
            ($0[0] & 3 == 0 || ($0[0] & 3 == 3 && $0[1] & 0x3f == 1)) }) else {
            throw ProtocolError.invalid("录音卡音频格式不受实时转写支持")
        }
        buffer = Data(buffer.dropFirst(count * 40)); packets += UInt64(count)
        defer { sequence += 1 }
        return AudioEnvelope.page(frames, granule: packets * 960, sequence: sequence, flags: final ? 4 : 0)
    }
}

public struct ASRWord: Equatable, Codable, Sendable {
    public let text: String
    public let startMs: Double
    public let endMs: Double
    public init(text: String, startMs: Double, endMs: Double) {
        self.text = text; self.startMs = startMs; self.endMs = endMs
    }
}

public enum ASREvent: Equatable {
    case started, finished, ignored
    case sentence(id: Int, text: String, isFinal: Bool, startMs: Double? = nil, endMs: Double? = nil, words: [ASRWord]? = nil)
    case failed(code: String, message: String)

    public static func parse(_ data: Data) throws -> ASREvent {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = root["header"] as? [String: Any], let event = header["event"] as? String else {
            throw ProtocolError.invalid("转写服务返回了无法识别的响应")
        }
        switch event {
        case "task-started": return .started
        case "task-finished": return .finished
        case "task-failed": return .failed(code: header["error_code"] as? String ?? "Unknown",
                                           message: header["error_message"] as? String ?? "转写任务失败")
        case "result-generated":
            let payload = root["payload"] as? [String: Any]
            let output = payload?["output"] as? [String: Any]
            guard let sentence = output?["sentence"] as? [String: Any] else { return .ignored }
            if sentence["heartbeat"] as? Bool == true { return .ignored }
            guard let id = sentence["sentence_id"] as? Int, let text = sentence["text"] as? String else { return .ignored }
            func time(_ value: Any?) -> Double? {
                guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite, value.doubleValue >= 0, value.doubleValue <= 604_800_000 else { return nil }
                return value.doubleValue
            }
            let start = time(sentence["begin_time"]), end = time(sentence["end_time"])
            let valid = start != nil && (sentence["end_time"] == nil || sentence["end_time"] is NSNull || (end != nil && end! >= start!))
            let words = (sentence["words"] as? [[String: Any]] ?? []).compactMap { word -> ASRWord? in
                guard let text = word["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let start = time(word["begin_time"]), let end = time(word["end_time"]), end >= start else { return nil }
                let punctuation = word["punctuation"] as? String ?? ""
                return ASRWord(text: text.hasSuffix(punctuation) ? text : text + punctuation, startMs: start, endMs: end)
            }
            return .sentence(id: id, text: text, isFinal: sentence["sentence_end"] as? Bool == true,
                             startMs: valid ? start : nil, endMs: valid ? end : nil, words: words.isEmpty ? nil : words)
        default: return .ignored
        }
    }
}

public struct ASRSentence: Identifiable, Equatable, Codable, Sendable {
    public let segment: Int
    public let sentence: Int
    public let text: String
    public let isFinal: Bool
    public let startMs: Double?
    public let endMs: Double?
    public let words: [ASRWord]?
    public init(segment: Int, sentence: Int, text: String, isFinal: Bool, startMs: Double? = nil, endMs: Double? = nil, words: [ASRWord]? = nil) {
        self.segment = segment; self.sentence = sentence; self.text = text; self.isFinal = isFinal
        self.startMs = startMs; self.endMs = endMs
        self.words = words
    }
    public var id: String { "\(segment):\(sentence)" }
}

public struct ASRTranscript {
    public private(set) var sentences: [ASRSentence] = []
    public var text: String { sentences.map(\.text).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n") }
    public init() {}
    public mutating func apply(_ event: ASREvent, segment: Int, offsetMs: Double? = 0) {
        guard case let .sentence(id, text, isFinal, start, end, words) = event else { return }
        let offset = offsetMs.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let value = ASRSentence(segment: segment, sentence: id, text: text, isFinal: isFinal,
            startMs: offset.flatMap { shift in start.map { $0 + shift } },
            endMs: offset.flatMap { shift in end.map { $0 + shift } },
            words: offset.flatMap { shift in words.map { $0.map { ASRWord(text: $0.text, startMs: $0.startMs + shift, endMs: $0.endMs + shift) } } })
        if let index = sentences.firstIndex(where: { $0.id == value.id }) {
            guard !sentences[index].isFinal || isFinal else { return }
            sentences[index] = value
        } else if isFinal || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Empty final results are tombstones: late partials must not resurrect retracted text.
            sentences.append(value)
            sentences.sort { $0.segment == $1.segment ? $0.sentence < $1.sentence : $0.segment < $1.segment }
        }
    }
}
