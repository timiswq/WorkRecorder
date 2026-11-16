import AppKit
import Combine
import SwiftUI
import WorkdayCore

struct CaptionDisplay: Identifiable, Equatable {
  let id: String
  let name: String
}

/// Owns desktop windows only. AppModel remains the owner of recording and ASR.
@MainActor final class DesktopCompanion: ObservableObject {
  @Published private(set) var status = DesktopStatus(
    kind: .disconnected, title: "录音卡未连接", detail: "尚未获取设备状态")
  private(set) lazy var menuBarLabel = MenuBarLabelState(status)
  @Published private(set) var snoozedUntil: Date?
  @Published private(set) var displays: [CaptionDisplay] = []
  private(set) var panel: CaptionPanel?
  private(set) var voiceActions: [String: CaptionVoiceActions] = [:]
  private(set) var closeButton: CaptionClosePanel?
  private var dismissPanels: [String: CaptionDismissPanel] = [:]
  private weak var model: AppModel?
  private var subscription: AnyCancellable?
  private var speechSubscription: AnyCancellable?
  private var refreshTask: Task<Void, Never>?
  private var animationTask: Task<Void, Never>?
  private var hoverTask: Task<Void, Never>?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  private var captions = DesktopCaptionState()
  private var lastTranscript: [LiveLine] = []
  private var qualified: [String: LiveLine] = [:]
  private var retiredLineIDs = Set<String>()
  private var identityRevision = -1
  private let presentation = CaptionFeedPresentation()
  private var rendered = CaptionFeedPresentation.Content()
  private var screenLocked = false
  private var screenSleeping = false
  private var sessionInactive = false
  private let checkFullScreen: @MainActor (CGDirectDisplayID) -> Bool
  private var fullScreenSample: (display: CGDirectDisplayID, time: Date, result: Bool)?
  private var previewStartedAt: Date?
  private var dismissedPreviewIDs = Set<String>()
  private var lastHoverPoint: NSPoint?
  private var transition = 0
  var isSnoozed: Bool { snoozedUntil.map { $0 > Date() } == true }

  init(checkFullScreen: @escaping @MainActor (CGDirectDisplayID) -> Bool = { hasFullScreenWindow(on: $0) }) {
    self.checkFullScreen = checkFullScreen
  }

  func start(model: AppModel) {
    guard self.model == nil else { return }
    self.model = model
    updateDisplays()
    lastTranscript = model.captionSelection.lines
    retiredLineIDs = Set(lastTranscript.map(\.id))
    captions.update(rows: eligibleCaptions(), canPresent: false, now: Date())
    speechSubscription = model.captionSelection.$lines.dropFirst().sink { [weak self] lines in
      self?.refresh(transcript: lines)
    }
    subscription = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
      self?.refresh()
    }
    refreshTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        self?.refresh()
      }
    }
    observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) {
      $0.updateDisplays()
    }
    let workspace = NSWorkspace.shared.notificationCenter
    observe(workspace, NSWorkspace.activeSpaceDidChangeNotification)
    observe(workspace, NSWorkspace.didActivateApplicationNotification)
    observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.screenSleeping = true }
    observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.screenSleeping = false }
    observe(workspace, NSWorkspace.willSleepNotification) { $0.screenSleeping = true }
    observe(workspace, NSWorkspace.didWakeNotification) { $0.screenSleeping = false }
    observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
    observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) {
      $0.sessionInactive = false
    }
    observe(DistributedNotificationCenter.default(), .init("com.apple.screenIsLocked")) {
      $0.screenLocked = true
    }
    observe(DistributedNotificationCenter.default(), .init("com.apple.screenIsUnlocked")) {
      $0.screenLocked = false
    }
    refresh()
  }

  func stop() {
    refreshTask?.cancel()
    refreshTask = nil
    animationTask?.cancel()
    animationTask = nil
    hoverTask?.cancel()
    hoverTask = nil
    subscription = nil
    speechSubscription = nil
    for (center, token) in observers { center.removeObserver(token) }
    observers = []
    transition += 1
    panel?.orderOut(nil)
    clearHoverControls()
    clearDismissPanels()
    lastHoverPoint = nil
    panel?.close()
    panel = nil
    captions = DesktopCaptionState()
    lastTranscript = []
    qualified = [:]
    retiredLineIDs = []
    rendered = .init()
    presentation.update([], username: "", preview: false, animated: false)
    previewStartedAt = nil
    fullScreenSample = nil
    model = nil
  }

  func attachMainWindow(_ window: NSWindow) {
    window.identifier = NSUserInterfaceItemIdentifier("workday.main")
  }

  func snooze() {
    snoozedUntil = Date().addingTimeInterval(15 * 60)
    previewStartedAt = nil
    refresh()
  }

  func resume() {
    snoozedUntil = nil
    refresh()
  }

  func preview(now: Date = Date()) {
    dismissedPreviewIDs.removeAll()
    previewStartedAt = now
    refresh()
  }

  private func dismissCaption(id: String) {
    guard rendered.items.contains(where: { $0.id == id }) else { return }
    if rendered.preview {
      dismissedPreviewIDs.insert(id)
    } else {
      retiredLineIDs.insert(id)
      captions.dismiss(id: id)
    }
    refresh()
  }

  func refresh(now: Date = Date(), transcript: [LiveLine]? = nil, pointer: NSPoint = NSEvent.mouseLocation) {
    guard let model else { return }
    let next = model.deviceStatus(at: now)
    if next != status {
      status = next
      menuBarLabel.update(next)
    }
    if let deadline = snoozedUntil, deadline <= now { snoozedUntil = nil }
    let suppressed = screenLocked || screenSleeping || sessionInactive
    if suppressed { previewStartedAt = nil }
    let elapsed = previewStartedAt.map { now.timeIntervalSince($0) }
    // Live rows age behind the demo, including the tick that returns to live captions.
    if elapsed != nil { captions.expireBehindPreview(at: now) }
    if let elapsed, elapsed >= CaptionPreview.duration { previewStartedAt = nil }
    let preferences = model.preferences.captions
    if let transcript {
      lastTranscript = transcript
      retiredLineIDs.formIntersection(transcript.map(\.id))
    }
    let recheck = identityRevision != model.voices.captionIdentityRevision
    identityRevision = model.voices.captionIdentityRevision
    let rows = transcript != nil || recheck ? eligibleCaptions() : nil
    let liveEnabled = preferences.enabled && snoozedUntil == nil && model.localCaptions.phase != .disabled
    let needsDisplay = previewStartedAt != nil
      || (liveEnabled && (rows?.isEmpty == false || !captions.items.isEmpty))
    let screen = needsDisplay && !suppressed ? selectedScreen(preferred: preferences.displayID) : nil
    let allowedSpace = !suppressed && (!needsDisplay || preferences.showInFullScreen
      || screen.map { !isFullScreen(on: $0, at: now) } == true)
    let previewing = previewStartedAt != nil && allowedSpace
    let canPresent = allowedSpace && liveEnabled
    if !liveEnabled || suppressed { retiredLineIDs.formUnion(lastTranscript.map(\.id)) }
    if let rows {
      captions.update(rows: rows, canPresent: canPresent, now: now)
    } else {
      captions.refresh(canPresent: canPresent, now: now)
    }
    var content =
      previewing
      ? CaptionPreview.items(at: elapsed ?? 0, startedAt: previewStartedAt ?? now)
        .filter { !dismissedPreviewIDs.contains($0.id) }
      : captions.items
    if !previewing {
      for index in content.indices {
        guard let id = content[index].sourceLineID, let line = qualified[id],
              let evidence = line.bubbleVoiceID else { continue }
        if let reviewed = model.captionHistory.reviewedText(for: line) {
          content[index].text = reviewed
        }
        let speaker = model.voices.captionSpeaker(lineID: line.id, evidenceID: evidence)
        content[index].speakerLabel = speaker.label.captionTitle(using: preferences)
        content[index].isMine = speaker.label.isMine
        content[index].markedHere = speaker.markedHere
          && (speaker.label.sampleID == evidence || speaker.label.isNegativeSample || evidence.hasPrefix("realtime:"))
        content[index].voiceID = evidence
        content[index].identityControls = speaker.controls
      }
    }
    render(
      content, username: previewing ? model.preferences.captions.resolvedUsername() : VoiceLabel.unknown,
      on: screen,
      preview: previewing, immediately: suppressed || rows?.isEmpty == true)
    updateActions(for: content, pointer: pointer)
  }

  private func eligibleCaptions() -> [DesktopCaption] {
    guard let model else { return [] }
    qualified.removeAll(keepingCapacity: true)
    return lastTranscript.compactMap { original in
      let line = model.voices.presentationLine(original)
      guard !retiredLineIDs.contains(line.id), !line.isSoundFeedback, LiveLine.containsSpeech(line.text),
            model.voices.hasLiveVoice(line.bubbleVoiceID) else { return nil }
      qualified[line.id] = line
      return DesktopCaption(id: line.id, text: line.captionText, isFinal: line.isFinal,
                            sourceLineID: line.id, receivedAt: line.receivedAt)
    }
  }

  private func clearVoiceActions() {
    for action in voiceActions.values { action.detach() }
    voiceActions.removeAll()
  }

  private func clearHoverControls() {
    clearVoiceActions()
    closeButton?.detach()
    closeButton = nil
  }

  private func clearDismissPanels() {
    for target in dismissPanels.values { target.detach() }
    dismissPanels.removeAll()
  }

  private func updateDismissPanels(for content: [DesktopCaption], in panel: CaptionPanel) {
    let visible = Set(content.map(\.id))
    for id in dismissPanels.keys.filter({ !visible.contains($0) }) {
      dismissPanels.removeValue(forKey: id)?.detach()
    }
    for caption in content {
      guard let bubble = panel.anchor(for: caption.id), panel.frame.contains(bubble) else {
        dismissPanels.removeValue(forKey: caption.id)?.detach()
        continue
      }
      let target: CaptionDismissPanel
      if let existing = dismissPanels[caption.id] {
        target = existing
      } else {
        target = CaptionDismissPanel(captionID: caption.id)
        dismissPanels[caption.id] = target
        target.onDismiss = { [weak self, weak target] in
          guard let self, let target, self.dismissPanels[target.captionID] === target else { return }
          self.lastHoverPoint = NSEvent.mouseLocation
          self.dismissCaption(id: target.captionID)
        }
      }
      // Reserve the identity region even during the interval before its hover control appears.
      let identity = caption.identityControls == nil ? nil : panel.anchor(for: caption.actionAnchor)
      target.show(in: panel, bubble: bubble, identityFrame: identity)
    }
  }

  private func hoveredCaption(in panel: CaptionPanel, captions: [DesktopCaption], at pointer: NSPoint)
    -> (DesktopCaption, NSRect)? {
    // The badge is a child window. Its outer edge can extend past the caption panel,
    // and it must keep its owner even where it overlaps a neighboring row.
    if let closeButton, closeButton.frame.contains(pointer),
       let caption = captions.first(where: { $0.id == closeButton.captionID }),
       let bubble = panel.anchor(for: caption.id), CaptionClosePanel.frame(on: bubble).contains(pointer) {
      return (caption, bubble)
    }
    guard panel.frame.contains(pointer) else { return nil }
    for caption in captions {
      if let bubble = panel.anchor(for: caption.id), bubble.contains(pointer) { return (caption, bubble) }
    }
    return nil
  }

  private func updateActions(for captions: [DesktopCaption], pointer: NSPoint) {
    let previousHoverPoint = lastHoverPoint
    if previousHoverPoint != pointer { lastHoverPoint = nil }
    guard let panel, panel.isVisible,
          let (caption, bubble) = hoveredCaption(in: panel, captions: captions, at: pointer) else {
      // Preserve the hovered opacity while the last sentence finishes fading out.
      if !captions.isEmpty { panel?.feedView.alphaValue = 1 }
      clearHoverControls()
      return
    }
    // Fade the entire caption feed, keeping its separate native action buttons legible.
    panel.feedView.alphaValue = 0.65
    lastHoverPoint = pointer
    // Reflow can replace a hovered sentence. Wait for re-entry before arming its replacement.
    if closeButton?.captionID != caption.id, previousHoverPoint.map(bubble.contains) == true {
      clearHoverControls()
      return
    }
    if closeButton?.captionID != caption.id {
      clearHoverControls()
      let button = CaptionClosePanel(captionID: caption.id)
      button.onDismiss = { [weak self, weak button] in
        guard let self, let button, self.closeButton === button else { return }
        let pointer = NSEvent.mouseLocation
        if button.frame.contains(pointer) { self.lastHoverPoint = pointer }
        self.dismissCaption(id: button.captionID)
      }
      closeButton = button
    }
    closeButton?.show(in: panel, bubble: bubble, sentence: caption.text)
    guard let turn = caption.voiceID, let controls = caption.identityControls,
      let anchor = panel.anchor(for: caption.actionAnchor), panel.frame.contains(anchor),
      anchor.width >= CaptionVoiceActions.width(for: controls) - 1
    else {
      clearVoiceActions()
      return
    }
    let actions: CaptionVoiceActions
    if let existing = voiceActions[caption.id], existing.turnID == turn,
      existing.controls == controls
    {
      actions = existing
      actions.sentence = caption.text
    } else {
      if let old = voiceActions.removeValue(forKey: caption.id) {
        old.detach()
      }
      actions = CaptionVoiceActions(
        turn: turn, controls: controls, sentence: caption.text)
      voiceActions[caption.id] = actions
      actions.perform = { [weak self, weak actions] action in
        guard let self, let actions, self.voiceActions[caption.id] === actions else { return }
        self.apply(action, to: caption)
      }
    }
    actions.canUndo = caption.markedHere
    actions.show(in: panel, at: anchor)
  }

  private func trackHover() {
    hoverTask?.cancel()
    hoverTask = Task { [weak self] in
      var previous = NSEvent.mouseLocation
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        guard let self else { return }
        let pointer = NSEvent.mouseLocation
        if pointer != previous { self.updateActions(for: self.rendered.items, pointer: pointer) }
        previous = pointer
      }
    }
  }

  private func apply(_ action: CaptionVoiceActions.Action, to caption: DesktopCaption) {
    guard let model, let current = rendered.items.first(where: { $0.id == caption.id }),
          current.voiceID == caption.voiceID, current.identityControls == caption.identityControls,
          let id = caption.sourceLineID, let line = qualified[id],
          let evidence = line.bubbleVoiceID, evidence == caption.voiceID, model.voices.hasLiveVoice(evidence) else { return }
    let speaker = model.voices.captionSpeaker(lineID: line.id, evidenceID: evidence)
    guard speaker.controls == caption.identityControls else { return }
    switch action {
    case .confirm, .reject:
      guard let packets = line.bubblePackets else { return }
      model.voices.markBubble(lineID: line.id, evidence: evidence, packets: packets, mine: action == .confirm)
    case .undo where speaker.markedHere:
      let mark = VoiceRecognition.captionMark(line.id, evidence: evidence)
      if speaker.label.isMine { model.voices.undoConfirmation(for: mark) }
      else { model.voices.setExcluded(false, for: mark) }
    default: return
    }
    refresh()
  }

  private func render(
    _ content: [DesktopCaption], username: String, on screen: NSScreen?, preview: Bool,
    immediately: Bool
  ) {
    guard !content.isEmpty, let screen else {
      hide(immediately: immediately)
      return
    }
    let frame = CaptionPlacement.frame(in: screen.visibleFrame)
    if panel == nil {
      let feed = CaptionFeedView(
        presentation: presentation,
        correct: { [weak self] caption, action in self?.apply(action, to: caption) },
        dismiss: { [weak self] id in self?.dismissCaption(id: id) })
      panel = CaptionPanel(frame: frame, feed: feed)
    }
    guard let panel else { return }
    if panel.frame != frame { panel.setFrame(frame, display: false) }
    let wasPresenting = !rendered.items.isEmpty
    let next = CaptionFeedPresentation.Content(items: content, username: username, preview: preview)
    if rendered != next {
      // A reopened panel must not animate its previously hidden rows back into view.
      presentation.update(
        content, username: username, preview: preview,
        animated: wasPresenting && panel.isVisible && !(preview && closeButton != nil))
      rendered = next
    }
    if !wasPresenting || !panel.isVisible {
      if !panel.isVisible { panel.alphaValue = preview ? 0 : 1 }
      panel.orderFrontRegardless()
      animateAlpha(to: 1, duration: preview ? 0.18 : 0)
      trackHover()
    }
    updateDismissPanels(for: content, in: panel)
  }

  private func hide(immediately: Bool) {
    guard let panel, !rendered.items.isEmpty || (immediately && panel.isVisible) else { return }
    rendered = .init()
    clearHoverControls()
    clearDismissPanels()
    if immediately { presentation.update([], username: "", preview: false, animated: false) }
    hoverTask?.cancel()
    hoverTask = nil
    animateAlpha(to: 0, duration: immediately ? 0 : 0.22)
  }

  private func animateAlpha(to target: CGFloat, duration: Double) {
    animationTask?.cancel()
    transition += 1
    let generation = transition
    guard let panel else { return }
    // Opacity alone is also appropriate with Reduce Motion; row movement is disabled separately.
    guard duration > 0 else {
      panel.alphaValue = target
      if target == 0 { panel.orderOut(nil) }
      return
    }
    // One cancellable transition owns alpha. A superseded fade cannot hide a new sentence,
    // and completion does not depend on AppKit's current animation/run-loop transaction.
    let initial = panel.alphaValue
    let started = ProcessInfo.processInfo.systemUptime
    animationTask = Task { [weak self, weak panel] in
      while !Task.isCancelled {
        guard let self, let panel, self.transition == generation else { return }
        let progress = min(1, (ProcessInfo.processInfo.systemUptime - started) / duration)
        let eased = progress * progress * (3 - 2 * progress)
        panel.alphaValue = initial + (target - initial) * eased
        if progress >= 1 {
          if target == 0 { panel.orderOut(nil) }
          return
        }
        do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
      }
    }
  }

  private func observe(
    _ center: NotificationCenter, _ name: Notification.Name,
    change: @escaping @MainActor (DesktopCompanion) -> Void = { _ in }
  ) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.fullScreenSample = nil
        change(self)
        self.refresh()
      }
    }
    observers.append((center, token))
  }

  private func updateDisplays() {
    displays = NSScreen.screens.map { CaptionDisplay(id: displayKey($0), name: $0.localizedName) }
  }

  private func selectedScreen(preferred: String?) -> NSScreen? {
    guard let preferred else { return NSScreen.screens.first }
    return NSScreen.screens.first { displayKey($0) == preferred } ?? NSScreen.screens.first
  }

  private func displayKey(_ screen: NSScreen) -> String {
    let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    guard let number,
      let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
    else {
      return screen.localizedName
    }
    return CFUUIDCreateString(nil, uuid) as String
  }

  private func isFullScreen(on screen: NSScreen, at now: Date) -> Bool {
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
      return false
    }
    let display = number.uint32Value
    if let sample = fullScreenSample, sample.display == display,
       (0..<0.5).contains(now.timeIntervalSince(sample.time)) { return sample.result }
    let result = checkFullScreen(display)
    fullScreenSample = (display, now, result)
    return result
  }

  private static func hasFullScreenWindow(on displayID: CGDirectDisplayID) -> Bool {
    guard
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else { return false }
    let display = CGDisplayBounds(displayID)
    return windows.contains { window in
      guard (window[kCGWindowLayer as String] as? Int) == 0,
        let bounds = window[kCGWindowBounds as String] as? NSDictionary,
        let rect = CGRect(dictionaryRepresentation: bounds)
      else { return false }
      return CaptionPlacement.coversDisplay(window: rect, display: display)
    }
  }
}

struct MainWindowReader: NSViewRepresentable {
  let onWindow: (NSWindow) -> Void
  func makeNSView(context: Context) -> NSView { WindowReaderView(onWindow: onWindow) }
  func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowReaderView: NSView {
  let onWindow: (NSWindow) -> Void
  init(onWindow: @escaping (NSWindow) -> Void) {
    self.onWindow = onWindow
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let window { onWindow(window) }
  }
}
