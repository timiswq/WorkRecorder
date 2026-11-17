import Foundation
import NaturalLanguage
import QS668Core

public struct AppleBubblePhrase: Equatable {
  public let text: String
  public let continuesPrevious: Bool

  public init(text: String, continuesPrevious: Bool) {
    self.text = text
    self.continuesPrevious = continuesPrevious
  }
}

@MainActor public protocol AppleBubbleStreaming: LiveASRStreaming {
  func bubblePhrase(for sentence: Int) -> AppleBubblePhrase?
}

/// The transcript keeps revisions. The bubble only releases readable text in audio order.
public struct AppleCaptionPhrases {
  public init() {}
  static let pauseMs = 800.0
  static let characterLimit = 36
  private struct TimedWord {
    let word: ASRWord
    let position: Double

    init(_ word: ASRWord, in range: Range<Double>?) {
      self.word = word
      let middle = (word.startMs + word.endMs) / 2
      // A point-timed last word belongs to the result that reported it, even
      // when its timestamp equals the first instant of the next result.
      if let range, !range.isEmpty {
        position = min(max(middle, range.lowerBound), range.upperBound.nextDown)
      } else { position = middle }
    }
  }
  private var words: [TimedWord] = []
  private var cuts: [Double] = []
  private var firstID = 0
  private var published: [Int: ASREvent] = [:]
  private var confirmedThrough = -Double.infinity
  private var previousRange: Range<Double>?
  private var draftTiming = DraftTiming()
  public private(set) var bubblePhrases: [Int: AppleBubblePhrase] = [:]
  private var continuations = Set<Int>()
  private var drafts: [Int: BubbleDraft] = [:]

  /// Fast results may time the entire growing hypothesis as a single run. A
  /// sentence mark added after the words have stopped advancing gives us a
  /// boundary even if the next revision takes that mark away.
  private struct DraftTiming {
    private var rangeStart: Double?
    private var lastText = ""
    private var unchangedSince = 0.0
    private var ends: [(prefix: String, time: Double)] = []
    private static let sentenceEnds = "。！？!?"

    mutating func resolve(_ words: [ASRWord], range: Range<Double>?, final: Bool)
      -> (words: [ASRWord], pauses: [Double]) {
      if rangeStart != range?.lowerBound {
        self = DraftTiming()
        rangeStart = range?.lowerBound
      }
      defer { if final { self = DraftTiming() } }
      guard let range, words.count == 1, let word = words.first,
            word.startMs == range.lowerBound, word.endMs == range.upperBound
      else { return (words, []) }

      let content = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
      let terminal = content.last.map { Self.sentenceEnds.contains($0) } ?? false
      let priorText = lastText
      let prefix = terminal ? String(content.dropLast()) : content
      if prefix != lastText {
        lastText = prefix
        unchangedSince = word.endMs
      } else if terminal, !prefix.isEmpty, word.endMs - unchangedSince >= AppleCaptionPhrases.pauseMs,
                ends.last.map({ prefix != $0.prefix && unchangedSince > $0.time }) ?? true {
        ends.append((prefix, (unchangedSince + word.endMs) / 2))
      }
      guard !ends.isEmpty else { return (words, []) }
      var start = word.text.startIndex
      var startMs = word.startMs
      var pieces: [ASRWord] = []
      var pauses: [Double] = []
      let spoken = word.text.drop(while: \.isWhitespace)
      for i in ends.indices {
        let end = ends[i]
        guard startMs < end.time, end.time < word.endMs else { break }
        // A temporarily retracted hypothesis still belongs before its old cut.
        if !final, end.prefix.hasPrefix(content) {
          pieces.append(ASRWord(text: String(word.text[start...]), startMs: startMs, endMs: end.time))
          return (pieces, pauses)
        }
        guard var split = Self.boundary(after: end.prefix, in: spoken, from: max(start, spoken.startIndex),
                                        previous: priorText) else { break }
        guard split > start else { break }
        ends[i].prefix = String(spoken[..<split])
        while split < word.text.endIndex, Self.sentenceEnds.contains(word.text[split]) {
          split = word.text.index(after: split)
        }
        guard word.text[split...].contains(where: { !$0.isPunctuation && !$0.isWhitespace }) else { break }
        pieces.append(ASRWord(text: String(word.text[start..<split]), startMs: startMs, endMs: end.time))
        pauses.append(end.time)
        start = split
        startMs = end.time
      }
      pieces.append(ASRWord(text: String(word.text[start...]), startMs: startMs, endMs: word.endMs))
      return (pieces, pauses)
    }

    private static func boundary(after prefix: String, in text: Substring, from start: String.Index,
                                 previous: String) -> String.Index? {
      if text.hasPrefix(prefix) { return text.index(text.startIndex, offsetBy: prefix.count) }
      // A revision can change words on the left while it appends on the right.
      // Prefer an explicit sentence ending, or align to the surviving right text.
      guard previous.hasPrefix(prefix) else { return nil }
      if let mark = text[start...].firstIndex(where: { sentenceEnds.contains($0) }),
         prefix.count >= 2, text[..<mark].hasSuffix(prefix.suffix(2)) { return mark }
      let suffix = previous.dropFirst(prefix.count).drop(while: { sentenceEnds.contains($0) })
      guard suffix.count >= 2 else { return nil }
      let anchor = String(suffix.prefix(6))
      guard let match = text[start...].range(of: anchor), match.lowerBound > start,
            text[match.upperBound...].range(of: anchor) == nil else { return nil }
      var split = match.lowerBound
      while split > text.startIndex, sentenceEnds.contains(text[text.index(before: split)]) {
        split = text.index(before: split)
      }
      return split
    }
  }

  /// Apple may attach one time range to an entire growing Chinese phrase.
  /// Track the read position in the hypothesis separately from the text on screen.
  public struct BubbleDraft {
    public init() {}
    var previous: [Character] = []
    var read = 0
    public private(set) var text = ""
    var carried = ""

    /// Cumulative hypotheses without a recognizer confirmation watermark.
    public mutating func update(text: String, final: Bool) {
      advance([ASRWord(text: text, startMs: 0, endMs: 0)], confirmed: -.infinity, final: final, alignPunctuation: true)
    }

    mutating func advance(_ words: [ASRWord], confirmed: Double, final: Bool, alignPunctuation: Bool = false) {
      let hypothesis = words.map(\.text).joined()
      let current = Array(hypothesis)
      let common = zip(previous, current).prefix(while: { $0 == $1 }).count
      if read > common {
        let suffix = zip(previous.dropFirst(common).reversed(), current.dropFirst(common).reversed())
          .prefix(while: { $0 == $1 }).count
        if alignPunctuation, let aligned = readAfterRepunctuation(current) { read = aligned }
        else if let anchor = anchorInRevision(current) { read = anchor }
        else if previous.count - read <= suffix { read = current.count - (previous.count - read) }
        else { read = min(read, current.count - suffix) }
      }
      // A volatile result can briefly retract to an empty or shorter prefix.
      // Restoring that prefix must not print words a second time.
      let seen = carried + text
      if !seen.isEmpty {
        if hypothesis.hasPrefix(seen) { read = seen.count }
        else if seen.hasPrefix(hypothesis) { read = current.count }
      }
      let changed = previous != current
      previous = current
      let confirmedCount = final ? current.count : words.prefix { $0.endMs <= confirmed }.reduce(0) { $0 + $1.text.count }
      let minimum = text.isEmpty ? 2 : 3
      var agreed = 0
      if changed && common - read >= minimum && common > confirmedCount {
        let safe = min(common, max(0, current.count - (text.isEmpty ? 0 : 2)))
        if safe > read { agreed = Self.wordBoundary(in: hypothesis, through: safe) }
      }
      // Adjacent timed runs can form a single extended grapheme when joined.
      let end = min(current.count, max(confirmedCount, agreed - read >= minimum ? agreed : 0))
      guard end > read else { return }
      text += String(current[read..<end])
      read = end
    }

    private func readAfterRepunctuation(_ current: [Character]) -> Int? {
      var cursor = 0
      for character in previous.prefix(read) where !character.isPunctuation && !character.isWhitespace {
        while cursor < current.count && (current[cursor].isPunctuation || current[cursor].isWhitespace) { cursor += 1 }
        guard cursor < current.count, current[cursor] == character else { return nil }
        cursor += 1
      }
      if read > 0 && (previous[read - 1].isPunctuation || previous[read - 1].isWhitespace) {
        while cursor < current.count && (current[cursor].isPunctuation || current[cursor].isWhitespace) { cursor += 1 }
      }
      return cursor
    }

    // A punctuation insertion near the beginning must not repeat the last word
    // the reader saw. Match the end of the read prefix close to its old position.
    private func anchorInRevision(_ current: [Character]) -> Int? {
      for length in stride(from: min(10, read), through: 2, by: -1) {
        let anchor = previous[(read - length)..<read]
        let lo = max(length, read - 24), hi = min(current.count, read + 24)
        guard lo <= hi else { continue }
        let hits = (lo...hi).filter { current[($0 - length)..<$0].elementsEqual(anchor) }
        if hits.count == 1 { return hits[0] }
      }
      return nil
    }

    func alreadyShown(after left: String) -> String? {
      let seen = previous.prefix(read)
      var index = seen.startIndex
      // A new comma at the cut does not make the following, already read words new.
      for character in left where !character.isPunctuation && !character.isWhitespace {
        while index < seen.endIndex && (seen[index].isPunctuation || seen[index].isWhitespace) { index += 1 }
        guard index < seen.endIndex, seen[index] == character else { return nil }
        index += 1
      }
      let remainder = seen[index...].drop { $0.isWhitespace || $0.isPunctuation }
      return remainder.isEmpty ? nil : String(remainder)
    }

    private static func wordBoundary(in text: String, through count: Int) -> Int {
      let end = text.index(text.startIndex, offsetBy: count)
      if end == text.endIndex { return count }
      let tokenizer = NLTokenizer(unit: .word)
      tokenizer.setLanguage(.simplifiedChinese)
      tokenizer.string = text
      let token = tokenizer.tokenRange(at: text.index(before: end))
      return token.lowerBound < end && token.upperBound > end
        ? text.distance(from: text.startIndex, to: token.lowerBound) : count
    }
  }

  public mutating func update(_ input: [ASRWord], final: Bool, pauses: [Double] = [],
                              replacing range: Range<Double>? = nil,
                              finalizedThrough: Double? = nil) -> [ASREvent] {
    if words.isEmpty && published.isEmpty && firstID == 0 { bubblePhrases.removeAll() }
    let previousEnd = words.last?.word.endMs ?? -Double.infinity
    let timed = draftTiming.resolve(input, range: range, final: final)
    let fresh = timed.words.flatMap(Self.sentenceRuns).map { TimedWord($0, in: range) }
    if let range {
      // A final can move the first token forward or shorten the last draft.
      // Replace its previous extent as well when it completes that hypothesis.
      var lower = range.lowerBound
      var upper = range.upperBound
      if let previousRange, previousRange.overlaps(range) {
        if previousRange.lowerBound == lower {
          upper = max(previousRange.upperBound, upper)
        } else if final, upper >= previousRange.upperBound {
          lower = min(previousRange.lowerBound, lower)
        }
      }
      lower = max(lower, confirmedThrough)
      let before = words.prefix { $0.position < lower }
      let after = words.dropFirst(before.count).drop { $0.position < upper }
      words = Array(before) + fresh + after
      previousRange = final ? nil : range
    } else {
      // Legacy dictation sends a cumulative hypothesis. Preview events use the
      // same convention, starting a fresh hypothesis after each recognizer final.
      let stable = words.prefix { $0.word.endMs <= confirmedThrough }
      if !stable.isEmpty, stable.count == words.count, let start = fresh.first?.word.startMs {
        confirmedThrough = max(confirmedThrough, start)
      }
      words = Array(stable) + fresh
    }
    let resultEnd = range?.upperBound ?? fresh.last?.word.endMs
    if let watermark = finalizedThrough ?? (final ? resultEnd : nil), watermark.isFinite {
      confirmedThrough = max(confirmedThrough, watermark)
    }
    return render(pauses: timed.pauses.isEmpty ? pauses : (pauses + timed.pauses).sorted(),
                  previousEnd: previousEnd, finishing: false)
  }

  public mutating func finish() -> [ASREvent] {
    let events = render(pauses: [], previousEnd: .infinity, finishing: true)
    let finalBubbles = bubblePhrases
    self = AppleCaptionPhrases()
    bubblePhrases = finalBubbles
    return events
  }

  private mutating func render(pauses: [Double], previousEnd: Double, finishing: Bool) -> [ASREvent] {
    var groups = Array(repeating: [ASRWord](), count: cuts.count + 1)
    var index = 0
    var count = 0
    var endsLongSentence = false
    var lastSpoken: TimedWord?
    for timed in words {
      let word = timed.word
      let characters = word.text.filter { !$0.isWhitespace && !$0.isPunctuation }
      if !characters.isEmpty {
        let time = timed.position
        var next = index
        while next < cuts.count && time >= cuts[next] { next += 1 }
        if next == index, index == cuts.count, let lastSpoken, let last = groups[index].last {
          let prior = lastSpoken.position
          let previousStop = lastSpoken.word.endMs
          let silence = pauses.first { $0 > prior && $0 <= time }
          let decimal = last.text.hasSuffix(".") && characters.first?.isNumber == true
            && groups[index].lazy.reversed().flatMap { $0.text.reversed() }.dropFirst().first?.isNumber == true
          let splitLong = endsLongSentence && word.endMs > previousEnd && !decimal && last.endMs > 0
          if time > prior, silence != nil || word.startMs - previousStop >= Self.pauseMs || splitLong {
            let boundary = previousStop <= word.startMs
              ? (previousStop + word.startMs) / 2 : (prior + time) / 2
            let cut = silence ?? boundary
            let newID = firstID + index + 1
            if silence == nil && word.startMs - previousStop < Self.pauseMs {
              continuations.insert(newID)
            }
            // A new pause can be discovered inside text already shown on screen.
            // Carry exactly that text across the transcript cut without displaying it twice.
            if let carry = drafts[firstID + index]?.alreadyShown(after: groups[index].map(\.text).joined()) {
              continuations.insert(newID)
              var draft = BubbleDraft()
              draft.previous = Array(carry)
              draft.read = carry.count
              draft.carried = carry
              drafts[newID] = draft
            }
            cuts.append(cut)
            groups.append([])
            next += 1
          }
        }
        if next != index {
          index = next
          count = 0
          endsLongSentence = false
        }
        lastSpoken = timed
      }
      groups[index].append(word)
      count += characters.count
      if let ending = word.text.last(where: { !$0.isWhitespace && !"”’」』）".contains($0) }) {
        endsLongSentence = count >= Self.characterLimit && (Self.clauseEnds.contains(ending) || ending == ".")
      }
    }

    var events: [ASREvent] = []
    let previousBubbles = bubblePhrases
    bubblePhrases.removeAll(keepingCapacity: true)
    let completed = cuts.prefix { $0 <= confirmedThrough }.count
    for (offset, group) in groups.enumerated() {
      let id = firstID + offset
      guard !group.isEmpty || published[id] != nil else { continue }
      let event = ASREvent.sentence(id: id, text: group.map(\.text).joined(),
                                    isFinal: finishing || offset < completed,
                                    startMs: group.first?.startMs, endMs: group.last?.endMs)
      // A late cut may move a word that the reader already saw into the next
      // transcript row. Only release audio beyond what was shown in the old row.
      var draft = drafts[id] ?? BubbleDraft()
      draft.advance(group, confirmed: confirmedThrough, final: finishing || offset < completed)
      drafts[id] = draft
      let bubble = AppleBubblePhrase(text: draft.text, continuesPrevious: continuations.contains(id))
      bubblePhrases[id] = bubble
      if published[id] != event || previousBubbles[id] != bubble {
        events.append(event)
        published[id] = event
      }
    }
    // Only discard groups whose *entire* time interval is irrevocable.
    if completed > 0 {
      let retiredWords = groups.prefix(completed).reduce(0) { $0 + $1.count }
      words.removeFirst(retiredWords)
      cuts.removeFirst(completed)
      for id in firstID..<(firstID + completed) {
        published.removeValue(forKey: id)
        drafts.removeValue(forKey: id)
        continuations.remove(id)
      }
      firstID += completed
    }
    return events
  }

  // A timed run can contain a whole clause. Preserve every character and keep
  // adjacent pieces contiguous when the engine supplied only a range for the run.
  private static let clauseEnds = "。，；！？!?"
  private static func sentenceRuns(_ word: ASRWord) -> [ASRWord] {
    guard word.text.dropLast().contains(where: { clauseEnds.contains($0) || $0 == "." }) else { return [word] }
    let characters = Array(word.text)
    var start = 0
    var runs: [ASRWord] = []
    func piece(through end: Int) -> ASRWord {
      let unit = (word.endMs - word.startMs) / Double(characters.count)
      return ASRWord(text: String(characters[start..<end]),
                     startMs: word.startMs + unit * Double(start),
                     endMs: word.startMs + unit * Double(end))
    }
    var hasSpokenText = false
    for i in characters.indices.dropLast() {
      let next = characters[i + 1]
      if !characters[i].isWhitespace && !characters[i].isPunctuation { hasSpokenText = true }
      let stop = clauseEnds.contains(characters[i]) || (characters[i] == "." && next.isWhitespace)
      if stop && hasSpokenText {
        runs.append(piece(through: i + 1))
        start = i + 1
        hasSpokenText = false
      }
    }
    if start == 0 { return [word] }
    runs.append(piece(through: characters.count))
    return runs
  }
}
