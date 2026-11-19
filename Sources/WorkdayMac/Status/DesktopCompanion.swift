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
  private var speechSubscriptions = Set<AnyCancellable>()
  private var refreshTask: Task<Void, Never>?
  private var animationTask: Task<Void, Never>?
  private var hoverTask: Task<Void, Never>?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  private var cardFeed = DesktopCaptionFeed()
  private var micFeed = DesktopCaptionFeed()
  private var comparing = false
  private var displayLines: [String: LiveLine] = [:]
  private var identityRevision = -1
  private let presentation = CaptionFeedPresentation()
  private var rendered = CaptionFeedPresentation.Content()
  private var screenLocked = false
  private var screenSleeping = false
  private var sessionInactive = false
  private let checkFullScreen: @MainActor (CGDirectDisplayID) -> Bool
  private var fullScreenSample: (display: CGDirectDisplayID, time: Date, result: Bool)?
  private var previewTask: Task<Void, Never>?
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
    presentation.geometryDidChange = { [weak self] in
      guard let self, let panel, panel.isVisible, !rendered.items.isEmpty else { return }
      updateDismissPanels(for: rendered.items, in: panel)
      updateActions(for: rendered.items, pointer: NSEvent.mouseLocation)
    }
    updateDisplays()
    comparing = model.preferences.useMacMicrophone && model.preferences.captions.enabled
    cardFeed.receive(comparing ? model.localCaptions.lines : model.captionSelection.lines, pending: nil)
    cardFeed.retireTranscript()
    model.captionSelection.$lines.dropFirst().sink { [weak self, weak model] lines in
      guard model?.preferences.useMacMicrophone != true else { return }
      self?.refresh(transcript: lines)
    }.store(in: &speechSubscriptions)
    model.localCaptions.$lines.dropFirst().sink { [weak self, weak model] lines in
      guard model?.preferences.useMacMicrophone == true else { return }
      self?.refresh(transcript: lines)
    }.store(in: &speechSubscriptions)
    model.microphone.preview.$lines.dropFirst().sink { [weak self] lines in
      self?.refresh(microphoneTranscript: lines)
    }.store(in: &speechSubscriptions)
    model.microphone.preview.$pendingSpeech.removeDuplicates().dropFirst().receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.refresh() }.store(in: &speechSubscriptions)
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
    previewTask?.cancel()
    previewTask = nil
    presentation.geometryDidChange = nil
    subscription = nil
    speechSubscriptions.removeAll()
    for (center, token) in observers { center.removeObserver(token) }
    observers = []
    transition += 1
    panel?.orderOut(nil)
    clearHoverControls()
    clearDismissPanels()
    lastHoverPoint = nil
    panel?.close()
    panel = nil
    cardFeed = DesktopCaptionFeed()
    micFeed = DesktopCaptionFeed()
    displayLines = [:]
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
    previewTask?.cancel()
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
    // Run the preview on its phrase timestamps. The half-second status tick can skip an entire fade.
    previewTask?.cancel()
    previewTask = Task { [weak self] in
      for time in CaptionPreview.changeTimes {
        let delay = now.addingTimeInterval(time).timeIntervalSinceNow
        guard delay > 0 else { continue }
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        guard self?.previewStartedAt == now else { return }
        self?.refresh()
      }
    }
  }

  private func dismissCaption(id: String) {
    guard rendered.items.contains(where: { $0.id == id }) else { return }
    if rendered.preview {
      dismissedPreviewIDs.insert(id)
    } else if let item = rendered.items.first(where: { $0.id == id }) {
      let feed = item.inputLabel == .microphone ? micFeed : cardFeed
      feed.dismiss(id: id, isSoundFeedback: item.isSoundFeedback)
    }
    refresh(animateStack: false)
  }

  func refresh(now: Date = Date(), transcript: [LiveLine]? = nil, microphoneTranscript: [LiveLine]? = nil,
               pointer: NSPoint = NSEvent.mouseLocation,
               animateStack: Bool = true) {
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
    if elapsed != nil {
      cardFeed.state.expireBehindPreview(at: now)
      micFeed.state.expireBehindPreview(at: now)
    }
    if let elapsed, elapsed >= CaptionPreview.duration { previewStartedAt = nil }
    let preferences = model.preferences.captions
    let compare = model.preferences.useMacMicrophone && preferences.enabled
    let switched = comparing != compare
    if switched {
      comparing = compare
      micFeed = DesktopCaptionFeed()
      // A bubble already published from the cloud must never be relabelled as local.
      if model.preferences.cloudEnabled && model.preferences.realtime {
        cardFeed = DesktopCaptionFeed()
        cardFeed.receive(model.localCaptions.lines.filter(\.isFinal), pending: nil)
        cardFeed.retireTranscript()
      }
    }
    let cardTranscript = transcript ?? (switched ? (compare ? model.localCaptions.lines : model.captionSelection.lines) : nil)
    if let cardTranscript { cardFeed.receive(cardTranscript, pending: model.localCaptions.pendingSpeech) }
    if compare, let microphoneTranscript { micFeed.receive(microphoneTranscript, pending: model.microphone.preview.pendingSpeech) }
    let recheck = identityRevision != model.voices.captionIdentityRevision
    identityRevision = model.voices.captionIdentityRevision
    let rows = cardTranscript != nil || recheck ? desktopRows() : nil
    let micRows = compare && microphoneTranscript != nil ? micFeed.rows(for: micFeed.transcript) : nil
    let liveEnabled = preferences.enabled && snoozedUntil == nil
    let cardEnabled = liveEnabled && model.localCaptions.phase != .disabled
    let micEnabled = liveEnabled && compare && model.microphone.preview.phase != .disabled
    let pending = cardFeed.pending(from: model.localCaptions, now: now)
    let micPending = compare ? micFeed.pending(from: model.microphone.preview, now: now) : nil
    let needsDisplay = previewStartedAt != nil
      || (cardEnabled && (pending != nil || rows?.isEmpty == false || !cardFeed.state.items.isEmpty))
      || (micEnabled && (micPending != nil || micRows?.isEmpty == false || !micFeed.state.items.isEmpty))
    let screen = needsDisplay && !suppressed ? selectedScreen(preferred: preferences.displayID) : nil
    let allowedSpace = !suppressed && (!needsDisplay || preferences.showInFullScreen
      || screen.map { !isFullScreen(on: $0, at: now) } == true)
    let previewing = previewStartedAt != nil && allowedSpace
    var content = cardFeed.items(rows: rows, pending: pending, enabled: cardEnabled, allowedSpace: allowedSpace,
                                 suppressed: suppressed, now: now)
    let micContent = micFeed.items(rows: micRows, pending: micPending, enabled: micEnabled, allowedSpace: allowedSpace,
                                   suppressed: suppressed, now: now)
    if previewing {
      content = CaptionPreview.items(at: elapsed ?? 0, startedAt: previewStartedAt ?? now)
        .filter { !dismissedPreviewIDs.contains($0.id) }
    }
    if !previewing {
      for index in content.indices {
        content[index].inputLabel = compare ? .card : nil
        guard let id = content[index].sourceLineID, let line = displayLines[id] else { continue }
        let evidence = model.voices.usableVoiceID(for: line)
        let speaker = model.voices.captionSpeaker(lineID: line.id, evidenceID: evidence)
        content[index].speakerLabel = speaker.title(using: preferences)
        content[index].isMine = speaker.label.isMine
        content[index].markedHere = speaker.markedHere
        content[index].hasSavedSample = speaker.hasSavedSample
        content[index].voiceID = evidence
        content[index].identityControls = speaker.controls
      }
    }
    if !previewing, !micContent.isEmpty {
      content += micContent.map { item in
        var bubble = item
        bubble.inputLabel = .microphone
        return bubble
      }
      content.sort { ($0.receivedAt ?? .distantPast) < ($1.receivedAt ?? .distantPast) }
    }
    render(
      content, username: previewing ? model.preferences.captions.resolvedUsername() : VoiceLabel.unknown,
      on: screen,
      preview: previewing, immediately: !allowedSpace || transcript?.isEmpty == true || microphoneTranscript?.isEmpty == true,
      pointer: pointer, animateStack: animateStack)
    updateActions(for: content, pointer: pointer)
  }

  private func desktopRows() -> [DesktopCaption] {
    guard let model else { return [] }
    displayLines.removeAll(keepingCapacity: true)
    let lines = cardFeed.transcript.map(model.voices.presentationLine)
    for line in lines where !cardFeed.retired.contains(line.id) {
      displayLines[line.id] = line
    }
    return cardFeed.rows(for: lines) { previous, line in
      let voices = model.voices
      if !LiveLine.containsSpeech(previous.text), line.bubblePhrase?.carriedText.isEmpty == false { return false }
      let older = voices.captionSpeaker(lineID: previous.id, evidenceID: previous.bubbleVoiceID).label
      let newer = voices.captionSpeaker(lineID: line.id, evidenceID: line.bubbleVoiceID).label
      if older.isMine && newer.isMine { return false }
      if (older.isMine && newer.excluded) || (newer.isMine && older.excluded) { return true }
      if let left = older.group, let right = newer.group { return left != right }
      // A missing voice on either half cannot establish a speaker change.
      guard voices.hasLiveVoice(previous.bubbleVoiceID), voices.hasLiveVoice(line.bubbleVoiceID) else { return false }
      // Words carried across an ASR cut refer to the same audio even when the window IDs change.
      return line.bubblePhrase?.carriedText.isEmpty != false && previous.bubbleVoiceID != line.bubbleVoiceID
    }
  }

  private func clearVoiceActions() {
    presentation.identityActionID = nil
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
      if !captions.isEmpty { panel?.setHovered(false) }
      clearHoverControls()
      return
    }
    // Fade the entire caption feed, keeping its separate native action buttons legible.
    panel.setHovered(true)
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
    guard let source = caption.sourceLineID, let controls = caption.identityControls,
      let anchor = panel.anchor(for: caption.actionAnchor), bubble.insetBy(dx: -1, dy: -1).contains(anchor),
      anchor.width >= CaptionVoiceActions.width(for: controls) - 1
    else {
      clearVoiceActions()
      return
    }
    let turn = caption.voiceID ?? VoiceRecognition.captionMark(source, evidence: nil)
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
    }
    actions.perform = { [weak self, weak actions] action in
      guard let self, let actions, self.voiceActions[caption.id] === actions else { return }
      self.apply(action, to: caption)
    }
    actions.canUndo = caption.markedHere
    actions.show(in: panel, at: anchor)
    presentation.identityActionID = caption.id
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
          let id = current.sourceLineID, id == caption.sourceLineID, let line = displayLines[id] else { return }
    let evidence = model.voices.usableVoiceID(for: line)
    guard evidence == caption.voiceID else { return }
    let speaker = model.voices.captionSpeaker(lineID: line.id, evidenceID: evidence)
    guard speaker.controls == caption.identityControls else { return }
    switch action {
    case .confirm, .reject:
      model.voices.setCaptionMark(lineID: id, mine: action == .confirm, evidence: evidence, packets: line.bubblePackets)
    case .undo:
      guard let mark = speaker.markID else { return }
      if speaker.label.isMine { model.voices.undoConfirmation(for: mark) }
      else { model.voices.setExcluded(false, for: mark) }
    }
    refresh()
  }

  private func render(
    _ content: [DesktopCaption], username: String, on screen: NSScreen?, preview: Bool,
    immediately: Bool, pointer: NSPoint, animateStack: Bool
  ) {
    guard !content.isEmpty, let screen else {
      hide(immediately: immediately)
      return
    }
    let frame = CaptionPlacement.frame(in: screen.visibleFrame, comparing: comparing && !preview)
    if panel == nil {
      let feed = CaptionFeedView(
        presentation: presentation, meter: model?.audioMeter, micMeter: model?.microphone.meter,
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
        animated: wasPresenting && panel.isVisible && rendered.preview == preview,
        animateStack: animateStack && !panel.frame.contains(pointer) && lastHoverPoint == nil)
      rendered = next
    }
    if !wasPresenting || !panel.isVisible {
      let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      if !panel.isVisible { panel.alphaValue = !reduceMotion && (preview || content.last?.isSoundFeedback == true) ? 0.45 : 1 }
      panel.orderFrontRegardless()
      animateAlpha(to: 1, duration: !reduceMotion && panel.alphaValue < 1 ? 0.12 : 0)
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
    animateAlpha(to: 0, duration: immediately ? 0 : 0.12)
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
        let eased = CaptionTransition.progress(progress, duration: 1)
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
