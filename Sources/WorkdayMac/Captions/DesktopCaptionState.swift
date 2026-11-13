import Foundation
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
  let isFinal: Bool
  var sourceLineID: String? = nil
  var speakerLabel: String? = nil
  var isMine = false
  var markedHere = false
  var voiceID: String? = nil
  var identityControls: CaptionIdentityControls? = nil
  var receivedAt: Date? = nil
  var isSoundFeedback = false
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
  // Pin a transcript row to the bubble in which its first words were read.
  private struct Placement {
    let id: String
    let prefix: String
    let receivedAt: Date?
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
    let captions = rows(for: lines, speakersDiffer: speakersDiffer)
    update(rows: captions, canPresent: canPresent, now: now)
  }

  mutating func update(rows: [DesktopCaption], canPresent: Bool, now: Date) {
    refresh(canPresent: canPresent, now: now)
    let previous = Dictionary(uniqueKeysWithValues: entries.map { ($0.caption.id, $0) })
    entries = rows.compactMap { caption in
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

  private mutating func rows(for lines: [LiveLine],
                             speakersDiffer: (LiveLine, LiveLine) -> Bool) -> [DesktopCaption] {
    var rows: [DesktopCaption] = []
    var assignments: [String: Placement] = [:]
    var previousLine: LiveLine?
    for line in lines {
      let phrase = line.bubblePhrase
      let text = phrase.map { $0.text.split(whereSeparator: \.isWhitespace).joined(separator: " ") } ?? line.captionText
      let waiting = line.isSoundFeedback || (phrase != nil && text.isEmpty && !line.isFinal)
      var place = placements[line.id] ?? Placement(id: line.id, prefix: "", receivedAt: line.receivedAt)
      if placements[line.id] == nil, phrase?.continuesPrevious == true, let previousLine,
         previousLine.segment == line.segment, let preceding = rows.last {
        // The next transcript segment can arrive while the preceding draft is still settling.
        // Wait before fixing its visible prefix, even if both segments arrive in one callback.
        if waiting || text.isEmpty { continue }
        if !speakersDiffer(previousLine, line) {
          if previousLine.hasUnpublishedWords || (!previousLine.isFinal && previousLine.bubblePhrase?.text != previousLine.text) { continue }
          let prefix = preceding.isSoundFeedback ? "" : preceding.text
          let space = prefix.last?.isASCII == true && prefix.last?.isLetter == true
            && text.first?.isASCII == true && text.first?.isLetter == true ? " " : ""
          place = Placement(id: preceding.id, prefix: prefix + space, receivedAt: preceding.receivedAt)
        }
      }
      if !waiting { assignments[line.id] = place }
      previousLine = line
      let content = waiting ? (line.isSoundFeedback ? line.captionText : "已收到声音") : place.prefix + text
      let caption = DesktopCaption(id: place.id, text: content, isFinal: line.isFinal,
        sourceLineID: waiting ? nil : line.id, receivedAt: place.receivedAt, isSoundFeedback: waiting)
      if rows.last?.id == place.id { rows[rows.count - 1] = caption } else { rows.append(caption) }
    }
    placements = assignments
    return rows
  }
}

/// Accelerated local demonstration using the same phrase boundaries as Apple speech.
enum CaptionPreview {
  static var duration: TimeInterval { frames.last?.time ?? 0 }
  private static let script: [(time: Double, word: ASRWord, final: Bool)] = [
    (0, ASRWord(text: "先开会。", startMs: 0, endMs: 350), true),
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
      let index = Int(item.id.split(separator: ":").last ?? "") ?? 0
      caption.isMine = index.isMultiple(of: 2)
      caption.speakerLabel = caption.isMine ? nil : "同事"
      caption.receivedAt = item.receivedAt.map { startedAt.addingTimeInterval($0.timeIntervalSince1970) }
      return caption
    }
  }
}
