import AppKit
import QS668Core
import WorkdayCore

struct CaptionPreferences: Codable, Equatable {
  var enabled = true
  var showInFullScreen = false
  var displayID: String?
  var username: String?

  func resolvedUsername(systemUsername: String = NSFullUserName()) -> String {
    let custom = (username ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if !custom.isEmpty { return custom }
    let system = systemUsername.trimmingCharacters(in: .whitespacesAndNewlines)
    return system.isEmpty ? NSUserName() : system
  }
}

enum CaptionIdentityControls: String {
  case confirm = "是我"
  case reject = "不是我"
}

struct DesktopCaption: Identifiable, Equatable {
  let id: String
  var text: String
  var isFinal: Bool
  var sourceLineID: String? = nil
  var speakerLabel: String? = nil
  var isMine = false
  var markedHere = false
  var hasSavedSample = false
  var voiceID: String? = nil
  var identityControls: CaptionIdentityControls? = nil
  var receivedAt: Date? = nil
  var isSoundFeedback = false
  var phrases: [CaptionPhrase] = []
  var reservesReadingWidth = false
}

struct CaptionPhrase: Equatable {
  static let duration: TimeInterval = 0.14
  let text: String
  let line: Int
  let appearedAt: Date
}

/// Page breaks and phrase timestamps belong to the desktop reader, independent of ASR revisions.
struct CaptionPages {
  static let readingWidth: CGFloat = 314
  private var published = ""
  private(set) var pages: [DesktopCaption] = []
  private var currentLine = ""
  private var lineWidth = readingWidth

  mutating func receive(_ row: DesktopCaption, now: Date) {
    let last = pages.last
    if last?.isFinal == true && !row.isFinal && last?.sourceLineID == row.sourceLineID { return }
    if row.text != published, row.text.hasPrefix(published) {
      let tail = row.text.dropFirst(published.count)
      if pages.isEmpty {
        guard LiveLine.containsSpeech(row.text) else { return }
        addPage(for: row)
      }
      var line = pages.last?.phrases.last?.line ?? 0
      let phrase = String(tail)
      if line == 0, lineWidth < Self.readingWidth, !fits(phrase) {
        // A short final may acquire another clause. Keep its first line intact and let the next use the available width.
        advanceLine(&line, for: row)
        lineWidth = Self.readingWidth
      }
      if fits(phrase) {
        // Carry a complete short phrase onto the next line without rewrapping any visible words.
        if !fits(currentLine + phrase) { advanceLine(&line, for: row) }
        currentLine += phrase
        append(phrase, line: line, at: now)
      } else {
        var run = ""
        for character in phrase {
          if !currentLine.isEmpty && !fits(currentLine + String(character)) {
            append(run, line: line, at: now)
            run = ""
            advanceLine(&line, for: row)
          }
          run.append(character)
          currentLine.append(character)
        }
        append(run, line: line, at: now)
      }
      if let page = pages.last, !page.reservesReadingWidth, lineWidth == Self.readingWidth {
        // A completed short bubble is right-aligned. Keep its existing body width on a late append.
        let widths = (0...line).map { number in
          Self.width(of: page.phrases.filter { $0.line == number }.map(\.text).joined())
        }
        lineWidth = min(Self.readingWidth, widths.max() ?? Self.readingWidth)
      }
      published = row.text
    }
    if !pages.isEmpty {
      pages[pages.count - 1].isFinal = row.isFinal
      pages[pages.count - 1].sourceLineID = row.sourceLineID
    }
  }

  private static func width(of text: String) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14)]).width
  }

  private func fits(_ text: String) -> Bool { Self.width(of: text) <= lineWidth }

  private mutating func advanceLine(_ line: inout Int, for row: DesktopCaption) {
    currentLine = ""
    if line == 0 { line = 1 }
    else {
      pages[pages.count - 1].isFinal = true
      addPage(for: row)
      line = 0
    }
  }

  private mutating func addPage(for row: DesktopCaption) {
    lineWidth = Self.readingWidth
    let id = pages.isEmpty ? row.id : "\(row.id)/page/\(pages.count + 1)"
    pages.append(DesktopCaption(id: id, text: "", isFinal: false, sourceLineID: row.sourceLineID,
                                receivedAt: row.receivedAt, reservesReadingWidth: !row.isFinal))
  }

  private mutating func append(_ text: String, line: Int, at time: Date) {
    guard !text.isEmpty else { return }
    let index = pages.count - 1
    pages[index].text += text
    pages[index].phrases.append(CaptionPhrase(text: text, line: line, appearedAt: time))
  }
}

/// A display policy only: it never owns audio, transcription, or transcript history.
struct DesktopCaptionState {
  static let maximumVisible = 4
  private static let exitSpacing: TimeInterval = 1.5
  private enum Visibility {
    case showing(until: Date)
    case expiredDraft
    case retired
  }

  private struct Entry {
    var caption: DesktopCaption
    var visibility: Visibility
  }

  // Keep one record per segment retained by LivePreview, in transcript order.
  private var entries: [Entry] = []
  private var pagesByID: [String: CaptionPages] = [:]

  /// A continuation inherits its predecessor's bubble ID. Only its own words retire its listening cue.
  func hasPublishedWords(for lineID: String) -> Bool {
    guard let place = placements[lineID] else { return false }
    return !place.text.isEmpty || (place.id == lineID && !place.prefix.isEmpty)
  }

  // Pin a transcript row to the bubble in which its first words were read.
  private struct Placement {
    let id: String
    let prefix: String
    let receivedAt: Date?
    // A final can explicitly move the entire preceding draft into this transcript row.
    var repeatedPrefix = ""
    var text = ""
    var audioRange: Range<Int>?
    var content: String { prefix + text }
  }
  private var placements: [String: Placement] = [:]
  private var nextExitAllowed = Date.distantPast

  fileprivate var nextExpiration: (index: Int, time: Date)? {
    for (index, entry) in entries.enumerated() {
      if case .showing(let until) = entry.visibility {
        return (index, max(until, nextExitAllowed))
      }
    }
    return nil
  }

  var items: [DesktopCaption] {
    entries.compactMap { entry in
      if case .showing = entry.visibility { return entry.caption }
      return nil
    }
  }

  mutating func dismiss(id: String) {
    guard let index = entries.firstIndex(where: { $0.caption.id == id }) else { return }
    entries[index].visibility = .retired
  }

  mutating func expireBehindPreview(at now: Date) {
    // Only visible removals need staggering. Do not replay overdue rows after the demo.
    for index in entries.indices {
      if case .showing(let until) = entries[index].visibility, until <= now {
        expire(at: index)
      }
    }
    nextExitAllowed = .distantPast
  }

  private mutating func expire(at index: Int) {
    entries[index].visibility = entries[index].caption.isFinal ? .retired : .expiredDraft
  }

  mutating func refresh(canPresent: Bool, now: Date) {
    guard canPresent else {
      for i in entries.indices { entries[i].visibility = .retired }
      nextExitAllowed = .distantPast
      return
    }
    guard let exit = nextExpiration, now >= exit.time else { return }
    expire(at: exit.index)
    // Measure the gap from the visible removal, including after a late timer tick.
    nextExitAllowed = now.addingTimeInterval(Self.exitSpacing)
  }

  /// Reconcile the current recognition buffer; the journal keeps earlier utterances.
  mutating func update(lines: [LiveLine], canPresent: Bool, now: Date,
                       speakersDiffer: (LiveLine, LiveLine) -> Bool = { _, _ in false }) {
    let captions = rows(for: lines, showsSoundFeedback: true, speakersDiffer: speakersDiffer) { line, _ in
      line.bubblePhrase?.text ?? line.captionText
    }
    update(rows: captions, canPresent: canPresent, now: now)
  }

  mutating func update(rows: [DesktopCaption], canPresent: Bool, now: Date) {
    refresh(canPresent: canPresent, now: now)
    let previous = Dictionary(uniqueKeysWithValues: entries.map { ($0.caption.id, $0) })
    let ids = Set(rows.map(\.id))
    pagesByID = pagesByID.filter { ids.contains($0.key) }
    let pages = rows.flatMap { row -> [DesktopCaption] in
      if row.isSoundFeedback {
        return pagesByID[row.id]?.pages ?? [row]
      }
      pagesByID[row.id, default: CaptionPages()].receive(row, now: now)
      return pagesByID[row.id]?.pages ?? []
    }
    entries = pages.compactMap { caption in
      let old = previous[caption.id]
      if let old, old.caption.isFinal && !caption.isFinal && old.caption.sourceLineID == caption.sourceLineID { return old }
      if let old, old.caption == caption { return old }
      let text = caption.text
      guard canPresent else { return Entry(caption: caption, visibility: .retired) }
      if let old, case .retired = old.visibility { return Entry(caption: caption, visibility: .retired) }
      guard LiveLine.containsSpeech(text) else {
        if caption.isFinal { return Entry(caption: caption, visibility: .retired) }
        return text.isEmpty ? nil : old
      }

      if let old, case .expiredDraft = old.visibility {
        let words = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        let lastWords = old.caption.text.filter { !$0.isWhitespace && !$0.isPunctuation }
        if lastWords.contains(words) {
          return Entry(caption: caption, visibility: caption.isFinal ? .retired : .expiredDraft)
        }
      }
      if let old, old.caption.isFinal, old.caption.sourceLineID == caption.sourceLineID {
        return Entry(caption: caption, visibility: old.visibility)
      }
      let hold = caption.isFinal ? min(16, max(12, Double(text.count) / 7)) : 10
      return Entry(caption: caption, visibility: .showing(until: now.addingTimeInterval(hold)))
    }
    var visible = 0
    for i in entries.indices.reversed() {
      if case .showing = entries[i].visibility {
        visible += 1
        if visible > Self.maximumVisible { entries[i].visibility = .retired }
      }
    }
  }

  mutating func rows(for lines: [LiveLine], showsSoundFeedback: Bool = false, retired: Set<String> = [],
                     speakersDiffer: (LiveLine, LiveLine) -> Bool,
                     readable: (LiveLine, String) -> String?) -> [DesktopCaption] {
    var rows: [DesktopCaption] = []
    var assignments: [String: Placement] = [:]
    for (index, line) in lines.enumerated() where !retired.contains(line.id) {
      let prior = placements[line.id]
      let candidate = readable(line, (prior?.repeatedPrefix ?? "") + (prior?.text ?? ""))
      var text = candidate?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
      let waiting = showsSoundFeedback && prior == nil && line.bubblePhrase != nil && text.isEmpty && !line.isFinal
      let previous = index > 0 ? lines[index - 1] : nil
      let carried = previous.map { retired.contains($0.id) } == true ? "" : line.bubblePhrase?.carriedText ?? ""
      guard waiting || prior != nil || LiveLine.containsSpeech(text)
              || (!carried.isEmpty && candidate != nil) else { continue }
      guard var place = prior ?? Self.firstPlacement(for: line, text: text, carried: carried, previous: previous,
        preceding: previous.flatMap { assignments[$0.id] }, speakersDiffer: speakersDiffer) else { continue }
      if !place.repeatedPrefix.isEmpty, text.hasPrefix(place.repeatedPrefix) {
        text = String(text.dropFirst(place.repeatedPrefix.count))
      }
      if !waiting {
        if text != place.text, text.hasPrefix(place.text) {
          place.text = text
          place.audioRange = line.recognitionRange
        }
        assignments[line.id] = place
      }
      let content = waiting ? "已收到声音" : place.content
      let caption = DesktopCaption(id: place.id, text: content, isFinal: line.isFinal,
        sourceLineID: waiting ? nil : line.id, receivedAt: place.receivedAt, isSoundFeedback: waiting)
      if rows.last?.id == place.id { rows[rows.count - 1] = caption } else { rows.append(caption) }
    }
    placements = assignments
    return rows
  }

  private static func firstPlacement(for line: LiveLine, text: String, carried: String,
                                     previous: LiveLine?, preceding: Placement?,
                                     speakersDiffer: (LiveLine, LiveLine) -> Bool) -> Placement? {
    // The recognizer can carry words across a cut before either row has published its first phrase.
    guard let previous, previous.segment == line.segment, previous.sentence + 1 == line.sentence,
          let preceding else { return Placement(id: line.id, prefix: carried, receivedAt: line.receivedAt) }

    let sameAudio = preceding.audioRange.flatMap { range in line.recognitionRange.map(range.overlaps) }
    let transferred = previous.isFinal && !LiveLine.containsSpeech(previous.text) && !preceding.text.isEmpty
      && line.textSource == .local && sameAudio != false
      ? repeatedPrefix(preceding.text, in: line.captionText) : nil
    let moved = transferred != nil
    guard moved || (line.bubblePhrase?.continuesPrevious == true && !speakersDiffer(previous, line)) else {
      return Placement(id: line.id, prefix: "", receivedAt: line.receivedAt)
    }
    // Wait until the previous draft has released its words before pinning the join.
    guard !text.isEmpty, moved || (!previous.hasUnpublishedWords
      && (previous.isFinal || !carried.isEmpty || previous.bubblePhrase?.text == previous.text)) else { return nil }

    var prefix = preceding.content
    if let released = previous.bubblePhrase?.text, released.hasPrefix(preceding.text) {
      let gap = released.dropFirst(preceding.text.count)
      if carried.hasSuffix(gap) { prefix += gap }
    }
    if !moved && carried.isEmpty && prefix.last?.isASCII == true && prefix.last?.isLetter == true
         && text.first?.isASCII == true && text.first?.isLetter == true { prefix += " " }
    return Placement(id: preceding.id, prefix: prefix, receivedAt: preceding.receivedAt,
                     repeatedPrefix: carried.isEmpty ? transferred ?? "" : "")
  }

  /// Return the recognizer's spelling of the visible prefix so a new comma or space cannot replay it.
  private static func repeatedPrefix(_ visible: String, in final: String) -> String? {
    if final.hasPrefix(visible) { return visible }
    var index = final.startIndex
    for letter in visible where !letter.isPunctuation && !letter.isWhitespace {
      while index < final.endIndex && (final[index].isPunctuation || final[index].isWhitespace) {
        final.formIndex(after: &index)
      }
      guard index < final.endIndex, final[index] == letter else { return nil }
      final.formIndex(after: &index)
    }
    if visible.last?.isPunctuation == true {
      while index < final.endIndex && (final[index].isPunctuation || final[index].isWhitespace) {
        final.formIndex(after: &index)
      }
    }
    return String(final[..<index])
  }
}

/// Accelerated local demonstration using the same phrase boundaries as Apple speech.
enum CaptionPreview {
  static var duration: TimeInterval { frames.last?.time ?? 0 }
  static var changeTimes: [TimeInterval] { frames.map(\.time) }
  private static let script: [(time: Double, word: ASRWord, final: Bool)] = [
    (0, ASRWord(text: "先", startMs: 0, endMs: 100), false),
    (0.45, ASRWord(text: "先开会。", startMs: 0, endMs: 350), true),
    (1.2, ASRWord(text: "再核对时间。", startMs: 450, endMs: 1200), true),
    (2.6, ASRWord(text: "明天先确认会议室", startMs: 2300, endMs: 3500), false),
    (4, ASRWord(text: "明天先确认会议室和到场人数，再把需要讨论的三个问题写进议程，最后把更新后的安排发给大家。", startMs: 2300, endMs: 11900), true),
    (4.8, ASRWord(text: "接着发通知。", startMs: 12000, endMs: 13000), true),
    (5.4, ASRWord(text: "明早再核对。", startMs: 14500, endMs: 15500), true),
  ]

  private static let frames: [(time: TimeInterval, items: [DesktopCaption])] = {
    var frames: [(time: TimeInterval, items: [DesktopCaption])] = []
    var phrases = AppleCaptionPhrases()
    var state = DesktopCaptionState()
    var lines: [LiveLine] = []
    func expire(through deadline: Date) {
      while let exit = state.nextExpiration, exit.time <= deadline {
        state.refresh(canPresent: true, now: exit.time)
        frames.append((exit.time.timeIntervalSince1970, state.items))
      }
    }
    func display(_ events: [ASREvent], at time: Double) {
      let now = Date(timeIntervalSince1970: time)
      expire(through: now)
      for case .sentence(let id, let text, let final, _, _, _) in events {
        let key = "preview:\(id)"
        let index = lines.firstIndex { $0.id == key }
        let line = LiveLine(id: key, segment: 0, sentence: id, text: text, isFinal: final,
                            receivedAt: index.flatMap { lines[$0].receivedAt } ?? now,
                            bubblePhrase: phrases.bubblePhrases[id])
        if let index { lines[index] = line } else { lines.append(line) }
      }
      state.update(lines: lines, canPresent: true, now: now)
      frames.append((time, state.items))
    }
    for event in script {
      display(phrases.update([event.word], final: event.final), at: event.time)
    }
    display(phrases.finish(), at: 6.8)
    expire(through: .distantFuture)
    return frames
  }()

  static func items(at elapsed: TimeInterval, startedAt: Date = Date(timeIntervalSince1970: 0)) -> [DesktopCaption] {
    let items = frames.last { $0.time <= elapsed }?.items ?? []
    return items.map { item in
      var caption = item
      caption.reservesReadingWidth = true
      let index = Int(item.id.split(separator: ":").last ?? "") ?? 0
      caption.isMine = index.isMultiple(of: 2)
      caption.speakerLabel = caption.isMine ? nil : "同事"
      caption.phrases = item.phrases.map { phrase in
        CaptionPhrase(text: phrase.text, line: phrase.line,
                      appearedAt: startedAt.addingTimeInterval(phrase.appearedAt.timeIntervalSince1970))
      }
      caption.receivedAt = item.receivedAt.map { startedAt.addingTimeInterval($0.timeIntervalSince1970) }
      return caption
    }
  }
}
