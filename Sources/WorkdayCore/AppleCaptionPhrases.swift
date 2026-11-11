import Foundation
import QS668Core

/// Bubble boundaries belong to the recording timeline. Apple can still revise words
/// on either side of a boundary until the recognizer finalizes that audio.
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

  public mutating func update(_ input: [ASRWord], final: Bool, pauses: [Double] = [],
                              replacing range: Range<Double>? = nil,
                              finalizedThrough: Double? = nil) -> [ASREvent] {
    let previousEnd = words.last?.word.endMs ?? -Double.infinity
    let fresh = input.flatMap(Self.sentenceRuns).map { TimedWord($0, in: range) }
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
    return render(pauses: pauses, previousEnd: previousEnd, finishing: false)
  }

  public mutating func finish() -> [ASREvent] {
    let events = render(pauses: [], previousEnd: .infinity, finishing: true)
    self = AppleCaptionPhrases()
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
            cuts.append(silence ?? boundary)
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
        endsLongSentence = count >= Self.characterLimit && (ending == "。" || ending == ".")
      }
    }

    var events: [ASREvent] = []
    let completed = cuts.prefix { $0 <= confirmedThrough }.count
    for (offset, group) in groups.enumerated() {
      let id = firstID + offset
      guard !group.isEmpty || published[id] != nil else { continue }
      let event = ASREvent.sentence(id: id, text: group.map(\.text).joined(),
                                    isFinal: finishing || offset < completed,
                                    startMs: group.first?.startMs, endMs: group.last?.endMs)
      if published[id] != event {
        events.append(event)
        published[id] = event
      }
    }
    // Only discard groups whose *entire* time interval is irrevocable.
    if completed > 0 {
      let retiredWords = groups.prefix(completed).reduce(0) { $0 + $1.count }
      words.removeFirst(retiredWords)
      cuts.removeFirst(completed)
      for id in firstID..<(firstID + completed) { published.removeValue(forKey: id) }
      firstID += completed
    }
    return events
  }

  // A timed run can contain a whole clause. Preserve every character and keep
  // adjacent pieces contiguous when the engine supplied only a range for the run.
  private static func sentenceRuns(_ word: ASRWord) -> [ASRWord] {
    guard word.text.dropLast().contains(where: { $0 == "。" || $0 == "." }) else { return [word] }
    let characters = Array(word.text)
    var start = 0
    var runs: [ASRWord] = []
    func piece(through end: Int) -> ASRWord {
      let unit = (word.endMs - word.startMs) / Double(characters.count)
      return ASRWord(text: String(characters[start..<end]),
                     startMs: word.startMs + unit * Double(start),
                     endMs: word.startMs + unit * Double(end))
    }
    for i in characters.indices.dropLast() {
      let next = characters[i + 1]
      let stop = characters[i] == "。" || (characters[i] == "." && next.isWhitespace)
      if stop {
        runs.append(piece(through: i + 1))
        start = i + 1
      }
    }
    if start == 0 { return [word] }
    runs.append(piece(through: characters.count))
    return runs
  }
}
