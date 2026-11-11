import Foundation

/// 即时热词使用 vocabulary 对象传入，与受 400 字符限制的上下文独立。
public struct ASRHotwords: Equatable, Sendable {
    public static let maximumCount = 2000
    public static let recommendedWeight = 4
    public static let empty = ASRHotwords()
    public let words: [String]
    public let weight: Int
    public var isEmpty: Bool { words.isEmpty }
    public var text: String { words.joined(separator: "\n") }
    public var vocabulary: [String: Int] { Dictionary(uniqueKeysWithValues: words.map { ($0, weight) }) }

    private init() { words = []; weight = Self.recommendedWeight }

    public init(text: String, weight: Int = Self.recommendedWeight) throws {
        guard (1...5).contains(weight) else { throw ProtocolError.invalid("热词识别偏好请选择 1–5，推荐使用 4。") }
        let words = Self.parse(text)
        guard words.count <= Self.maximumCount else {
            throw ProtocolError.invalid("最多支持 2000 个热词，请精简后再保存。")
        }
        for (index, word) in words.enumerated() {
            let prefix = "第 \(index + 1) 个热词"
            guard !word.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ProtocolError.invalid("\(prefix)包含控制字符，请删除后再保存。")
            }
            if word.unicodeScalars.contains(where: { !$0.isASCII }) {
                guard word.unicodeScalars.count <= 15 else {
                    throw ProtocolError.invalid("\(prefix)含中文或其他非 ASCII 字符，总长度不能超过 15 个字符。")
                }
            } else {
                guard word.split(separator: " ").count <= 7 else {
                    throw ProtocolError.invalid("\(prefix)过长，英文词组最多支持 7 个空格分隔的单词。")
                }
            }
        }
        self.words = words; self.weight = words.isEmpty ? Self.recommendedWeight : weight
    }

    public static func parse(_ text: String) -> [String] {
        let separators = CharacterSet.newlines.union(CharacterSet(charactersIn: ",，;；、"))
        var seen = Set<String>()
        return text.components(separatedBy: separators).compactMap { part in
            let word = part.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            guard !word.isEmpty, seen.insert(word).inserted else { return nil }
            return word
        }
    }
}
