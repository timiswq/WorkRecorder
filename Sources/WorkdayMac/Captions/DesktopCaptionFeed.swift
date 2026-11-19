import Foundation

/// A single input owns its listening cue, page layout, dismissal and expiry.
@MainActor final class DesktopCaptionFeed {
  var state = DesktopCaptionState()
  private(set) var transcript: [LiveLine] = []
  private(set) var retired = Set<String>()
  private var listening: PendingCaption?

  func receive(_ lines: [LiveLine], pending: PendingCaption?) {
    transcript = lines
    var retained = Set(lines.map(\.id))
    if let current = pending ?? listening { retained.insert(current.id) }
    retired.formIntersection(retained)
  }

  func retireTranscript() { retired.formUnion(transcript.map(\.id)) }

  func pending(from recognition: LivePreview, now: Date) -> PendingCaption? {
    if let pending = recognition.pendingSpeech {
      listening = pending
    } else if let current = listening {
      let receiving = recognition.lastAudioAt.map { now.timeIntervalSince($0) < 1.5 } ?? false
      if !receiving || !recognition.isAwaitingFinal(current.id) || state.hasPublishedWords(for: current.id) {
        listening = nil
      }
    }
    return listening.flatMap { retired.contains($0.id) ? nil : $0 }
  }

  func dismiss(id: String, isSoundFeedback: Bool) {
    if isSoundFeedback { retired.insert(id) }
    state.dismiss(id: id)
  }

  func items(rows: [DesktopCaption]?, pending: PendingCaption?, enabled: Bool, allowedSpace: Bool,
             suppressed: Bool, now: Date) -> [DesktopCaption] {
    if !enabled || suppressed { retireTranscript() }
    let visible = enabled && allowedSpace
    if !visible, let pending { retired.insert(pending.id) }
    if let rows { state.update(rows: rows, canPresent: visible, now: now) }
    else { state.refresh(canPresent: visible, now: now) }
    var items = state.items
    if visible, let pending, !state.hasPublishedWords(for: pending.id) {
      if items.count == DesktopCaptionState.maximumVisible { state.dismiss(id: items.removeFirst().id) }
      items.append(DesktopCaption(id: pending.id, text: "", isFinal: false, receivedAt: pending.startedAt,
                                  isSoundFeedback: true))
    }
    return items
  }

  func rows(for lines: [LiveLine], speakersDiffer: (LiveLine, LiveLine) -> Bool = { _, _ in false }) -> [DesktopCaption] {
    state.rows(for: lines, retired: retired, speakersDiffer: speakersDiffer) { line, published in
      if line.isFinal, line.textSource == .local, line.bubblePhrase?.continuesPrevious != true,
         line.captionText.hasPrefix(published) {
        return line.captionText
      }
      return line.bubblePhrase?.text ?? line.stableCloudText ?? line.text
    }
  }
}
