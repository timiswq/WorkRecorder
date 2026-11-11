import Foundation

/// 领域提示按单轮 user/input_text 发送；避免服务端把超过 400 字符的内容静默截断。
public struct ASRContext: Equatable, Sendable {
    public static let characterLimit = 400
    public static let empty = ASRContext()
    public let text: String
    public var isEmpty: Bool { text.isEmpty }
    public var characterCount: Int { text.unicodeScalars.count }

    private init() { text = "" }

    public init(text: String) throws {
        let normalized = Self.normalize(text)
        guard normalized.unicodeScalars.count <= Self.characterLimit else {
            throw ProtocolError.invalid("上下文最多支持 400 个字符，请精简后再应用；不会自动截断内容。")
        }
        guard !normalized.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
        }) else { throw ProtocolError.invalid("上下文包含不可用的控制字符，请使用纯文本。") }
        self.text = normalized
    }

    public static func normalize(_ text: String) -> String {
        let value = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        return value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var messages: [[String: Any]] {
        isEmpty ? [] : [["role": "user", "content": [["type": "input_text", "text": text]]]]
    }
}
