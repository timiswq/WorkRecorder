import Combine
import Foundation
import WorkdayCore

/// Local lines own the recording boundaries, replay clips and speaker evidence.
@MainActor final class LiveCaptionRouter {
  @Published private(set) var lines: [LiveLine] = []
  var onChange: ((LiveLine) -> Void)?
  private struct Choice {
    var localOnly = false
    var finalized = false
    var awaitingCloudTail = false
    var cloudID: String?
    var localPrefix = ""
    var cloudPrefix = ""
    var shown = ""
    var hasLocalTail = false
    var deadline: ContinuousClock.Instant?
  }

  private var choices: [String: Choice] = [:]
  private var local: [LiveLine] = []
  private var cloud: [LiveLine] = []
  private var lastCloudUpdate: [String: ContinuousClock.Instant] = [:]
  private var enabled = false
  private var available = false
  private var timer: Task<Void, Never>?
  private var scheduled: ContinuousClock.Instant?
  private let now: () -> ContinuousClock.Instant

  init(now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) { self.now = now }

  func configure(enabled: Bool) {
    guard self.enabled != enabled else { return }
    self.enabled = enabled
    update()
  }

  func receiveLocal(_ rows: [LiveLine]) {
    if rows.count < local.count || rows.first?.id != local.first?.id {
      let retained = Set(rows.map(\.id))
      choices = choices.filter { retained.contains($0.key) }
    }
    local = rows
    update()
  }

  func receiveCloud(_ rows: [LiveLine]) {
    let old = Dictionary(uniqueKeysWithValues: cloud.map { ($0.id, $0) })
    let instant = now()
    lastCloudUpdate = Dictionary(uniqueKeysWithValues: rows.map { row in
      (row.id, old[row.id] == row ? lastCloudUpdate[row.id] ?? instant : instant)
    })
    cloud = rows
    if enabled { update() }
  }

  func setAvailable(_ value: Bool) {
    guard available != value else { return }
    available = value
    if enabled { update() }
  }

  func cloudSource(for id: String) -> String? { choices[id]?.cloudID }

  private func update() {
    let instant = now()
    var next: [LiveLine] = []
    var nextDeadline: ContinuousClock.Instant?
    var claimed = Set(choices.values.compactMap(\.cloudID))
    for line in local {
      let ready = line.bubblePhrase?.text ?? line.text
      var choice = choices[line.id] ?? Choice()
      var projected = line
      if line.bubblePhrase?.continuesPrevious == true, choice.cloudID == nil,
         let prior = next.last, prior.segment == line.segment, choices[prior.id]?.localOnly == true {
        choice.localOnly = true
      }
      if choice.awaitingCloudTail, let id = choice.cloudID,
         let remote = cloud.first(where: { $0.id == id && $0.isFinal }),
         let localSpan = line.recognitionRange, let cloudSpan = remote.recognitionRange,
         localSpan.overlaps(cloudSpan), abs(localSpan.upperBound - cloudSpan.upperBound) <= 1200,
         let final = remote.stableCloudText, final.hasPrefix(choice.shown) {
        choice.shown = final
        choice.hasLocalTail = false
        choice.awaitingCloudTail = false
        choice.localOnly = false
      }
      if !choice.finalized && !choice.localOnly {
        if let cloudID = choice.cloudID {
          advanceCloud(&choice, remote: cloud.first { $0.id == cloudID }, local: line, now: instant)
        } else if LiveLine.containsSpeech(ready) {
          if !enabled || line.recognitionRange == nil {
            choice.localOnly = true
          } else {
            // Only the first readable words open the window. Revisions cannot restart it.
            let until = choice.deadline ?? instant.advanced(by: .milliseconds(150))
            if instant >= until {
              choice.localOnly = true
            } else if let (id, prefix) = match(line, ready: ready, claimed: claimed) {
              claimed.insert(id)
              choice.cloudID = id
              choice.deadline = nil
              choice.shown = prefix
              choice.localPrefix = ready
              choice.cloudPrefix = prefix
            } else if !available {
              choice.localOnly = true
            } else {
              choice.deadline = until
            }
          }
        }
      }
      if choice.cloudID != nil {
        if choice.localOnly && !choice.finalized {
          // If the stream ends mid-turn, resume only at an identifiable boundary.
          // A timestamp alone cannot tell how much of a differently worded sentence was read.
          if choice.shown == choice.cloudPrefix, ready.hasPrefix(choice.localPrefix) {
            let tail = ready.dropFirst(choice.localPrefix.count)
            choice.hasLocalTail = choice.hasLocalTail || !tail.isEmpty
            choice.shown += tail
            choice.localPrefix = ready
            choice.cloudPrefix = choice.shown
          } else if let index = Self.localBoundary(after: choice.shown, in: ready) {
            let tail = ready[index...]
            choice.hasLocalTail = choice.hasLocalTail || !tail.isEmpty
            choice.shown += tail
            choice.localPrefix = ready
            choice.cloudPrefix = choice.shown
          } else if line.isFinal {
            // This bubble still consists entirely of cloud text. Its own late final
            // may append the missing tail if it covers the same recording interval.
            choice.awaitingCloudTail = true
          }
        }
        // Keep the complete local transcript for replay if the cloud broke off and
        // there was no reliable place to join the two versions of this final line.
        if !choice.awaitingCloudTail {
          projected.text = choice.shown
          projected.textSource = choice.hasLocalTail ? .mixed : .cloud
        }
        projected.bubblePhrase = .init(text: choice.shown, continuesPrevious: line.bubblePhrase?.continuesPrevious == true)
        projected.hasUnpublishedWords = !line.isFinal && ready != line.text
      } else if !choice.localOnly && enabled {
        projected.text = line.isFinal && ready.isEmpty ? line.text : ""
        projected.bubblePhrase = .init(text: "", continuesPrevious: line.bubblePhrase?.continuesPrevious == true)
        if choice.deadline != nil { projected.isFinal = false }
      }
      if choice.localOnly || !LiveLine.containsSpeech(ready) { choice.deadline = nil }
      if let until = choice.deadline {
        projected.isFinal = false
        projected.hasUnpublishedWords = true
        nextDeadline = min(nextDeadline ?? until, until)
      }
      if projected.isFinal { choice.finalized = true }
      choices[line.id] = choice
      next.append(projected)
    }

    if next != lines {
      let old = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })
      lines = next
      for row in next where old[row.id] != row { onChange?(row) }
    }
    if scheduled != nextDeadline {
      timer?.cancel()
      scheduled = nextDeadline
      if let nextDeadline {
        timer = Task { [weak self] in
          do { try await ContinuousClock().sleep(until: nextDeadline, tolerance: .zero) } catch { return }
          self?.update()
        }
      }
    }
  }

  private func advanceCloud(_ choice: inout Choice, remote: LiveLine?, local: LiveLine, now: ContinuousClock.Instant) {
    guard enabled, let remote, let range = remote.recognitionRange, let span = local.recognitionRange,
          let stable = remote.stableCloudText, range.overlaps(span),
          choice.deadline.map({ now < $0 }) ?? true else { choice.localOnly = true; return }
    // Draft times can run ahead of Apple. Wait for the local audio extent before
    // appending a longer cloud result, especially at a change of speaker.
    let sameEnd = abs(span.upperBound - range.upperBound) <= 1200 // 600 ms of card audio
    let withinTurn = range.upperBound <= span.upperBound || (local.isFinal && remote.isFinal && sameEnd)
    if withinTurn, stable.hasPrefix(choice.shown) { choice.shown = stable }

    if remote.isFinal && span.upperBound > range.upperBound + 600 {
      choice.localOnly = true
    } else if remote.isFinal && withinTurn {
      choice.deadline = nil
    } else if !available {
      choice.localOnly = true
    } else if local.isFinal || (span.upperBound > range.upperBound + 1200
                && lastCloudUpdate[remote.id].map { $0.duration(to: now) >= .milliseconds(600) } == true) {
      if choice.deadline == nil { choice.deadline = now.advanced(by: .milliseconds(150)) }
    } else {
      choice.deadline = nil
    }
  }

  private func match(_ line: LiveLine, ready: String, claimed: Set<String>)
    -> (String, String)? {
    guard let span = line.recognitionRange else { return nil }
    // A merged cloud turn, two overlapping hypotheses, or a neighbouring short reply is ambiguous.
    let overlapping = cloud.filter { $0.recognitionRange?.overlaps(span) == true }
    guard overlapping.count == 1, let other = overlapping.first, let range = other.recognitionRange,
          let stable = other.stableCloudText, LiveLine.containsSpeech(stable),
          !claimed.contains(other.id) else { return nil }
    let shorter = min(span.count, range.count)
    guard abs(span.lowerBound - range.lowerBound) <= min(440, shorter / 3),
          range.upperBound <= span.upperBound + min(600, shorter / 3) else { return nil }
    let prefix: String
    let endDifference = abs(span.upperBound - range.upperBound)
    if other.isFinal, line.isFinal || Self.spoken(ready) == Self.spoken(line.text),
       endDifference <= min(600, shorter / 4) {
      prefix = other.text
    } else {
      // Draft word times can be approximate. Only release through a shared, unique
      // textual endpoint inside the local phrase, never the rest of a longer cloud turn.
      let target = Self.spoken(ready)
      guard target.count >= 2 else { return nil }
      let letters = Self.spoken(stable)
      let anchor = String(target.suffix(min(3, target.count)))
      guard let end = letters.range(of: anchor),
            letters[end.upperBound...].range(of: anchor) == nil else { return nil }
      let count = letters.distance(from: letters.startIndex, to: end.upperBound)
      guard abs(count - target.count) <= min(5, target.count / 3) else { return nil }
      var consumed = 0
      let through = stable.firstIndex { character in
        guard !character.isWhitespace && !character.isPunctuation else { return false }
        consumed += 1
        return consumed > count
      } ?? stable.endIndex
      prefix = String(stable[..<through])
    }
    guard LiveLine.containsSpeech(prefix) else { return nil }
    return (other.id, prefix)
  }

  private static func localBoundary(after shown: String, in local: String) -> String.Index? {
    let visible = spoken(shown)
    let indices = local.indices.filter { !local[$0].isWhitespace && !local[$0].isPunctuation }
    let letters = indices.map { local[$0] }
    // The engines can disagree on a word immediately before this boundary.
    // Prefer the longest unique suffix close to the same reading position.
    for count in stride(from: min(6, visible.count, letters.count), through: 2, by: -1) {
      let anchor = visible.suffix(count)
      let hits = (count...letters.count).filter { end in
        abs(end - visible.count) <= max(2, min(6, visible.count / 4))
          && letters[(end - count)..<end].elementsEqual(anchor)
      }
      if hits.count == 1, let end = hits.first {
        if shown.last?.isPunctuation == true { return end == indices.count ? local.endIndex : indices[end] }
        return local.index(after: indices[end - 1])
      }
    }
    return nil
  }

  private static func spoken(_ text: String) -> String {
    text.filter { !$0.isWhitespace && !$0.isPunctuation }
  }
}
