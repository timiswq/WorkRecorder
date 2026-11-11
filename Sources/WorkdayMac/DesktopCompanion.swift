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
  @Published private(set) var snoozedUntil: Date?
  @Published private(set) var displays: [CaptionDisplay] = []
  private(set) var panel: CaptionPanel?
  private(set) var voiceActions: [String: CaptionVoiceActions] = [:]
  private weak var model: AppModel?
  private var subscription: AnyCancellable?
  private var speechSubscription: AnyCancellable?
  private var refreshTask: Task<Void, Never>?
  private var animationTask: Task<Void, Never>?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  private var captions = DesktopCaptionState()
  private let presentation = CaptionFeedPresentation()
  private var rendered = CaptionFeedPresentation.Content()
  private var screenLocked = false
  private var screenSleeping = false
  private var sessionInactive = false
  private var previewStartedAt: Date?
  private var transition = 0
  var isSnoozed: Bool { snoozedUntil.map { $0 > Date() } == true }

  func start(model: AppModel) {
    guard self.model == nil else { return }
    self.model = model
    updateDisplays()
    captions.update(lines: model.localCaptions.lines, canPresent: false, now: Date())
    speechSubscription = model.localCaptions.$lines.dropFirst().sink { [weak self] lines in
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
    subscription = nil
    speechSubscription = nil
    for (center, token) in observers { center.removeObserver(token) }
    observers = []
    transition += 1
    panel?.orderOut(nil)
    removeActions(except: [])
    panel?.close()
    panel = nil
    captions = DesktopCaptionState()
    rendered = .init()
    presentation.update([], username: "", preview: false, animated: false)
    previewStartedAt = nil
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
    previewStartedAt = now
    refresh()
  }

  func refresh(now: Date = Date(), transcript: [LiveLine]? = nil, pointer: NSPoint = NSEvent.mouseLocation) {
    guard let model else { return }
    let next = DesktopStatus.resolve(
      card: model.card.state, connection: model.card.connectionPhase,
      usbConnected: !model.usb.volumes.isEmpty, importLabel: model.sync.usbLabel,
      transcriptionFailed: model.live.phase == .failed, now: now)
    if next != status { status = next }
    if let deadline = snoozedUntil, deadline <= now { snoozedUntil = nil }
    let screen = selectedScreen(preferred: model.preferences.captions.displayID)
    let suppressed = screenLocked || screenSleeping || sessionInactive
    let allowedSpace =
      !suppressed
      && (model.preferences.captions.showInFullScreen
        || screen.map { !isFullScreen(on: $0) } == true)
    if suppressed { previewStartedAt = nil }
    let elapsed = previewStartedAt.map { now.timeIntervalSince($0) }
    if let elapsed, elapsed >= CaptionPreview.duration { previewStartedAt = nil }
    let previewing = previewStartedAt != nil && allowedSpace
    let canPresent =
      allowedSpace && !previewing && model.preferences.captions.enabled && snoozedUntil == nil
      && model.localCaptions.phase != .disabled
    if let transcript {
      captions.update(lines: transcript, canPresent: canPresent, now: now)
    } else {
      captions.refresh(canPresent: canPresent, now: now)
    }
    var content =
      previewing
      ? CaptionPreview.items(at: elapsed ?? 0, startedAt: previewStartedAt ?? now)
      : captions.items
    if !previewing {
      for index in content.indices {
        guard let source = content[index].sourceLineID else { continue }
        let speaker = model.captionSpeaker(for: source)
        content[index].speakerLabel = speaker.label.captionTitle(using: model.preferences.captions)
        content[index].isMine = speaker.label.isMine
        content[index].markedHere = speaker.markedHere
        content[index].voiceID = speaker.id
        content[index].identityControls = speaker.controls
      }
    }
    render(
      content, username: previewing ? model.preferences.captions.resolvedUsername() : VoiceLabel.unknown,
      on: screen,
      preview: previewing, immediately: suppressed)
    updateActions(for: content, pointer: pointer)
  }

  private func removeActions(except visible: Set<String>) {
    for id in Array(voiceActions.keys) where !visible.contains(id) {
      guard let actions = voiceActions.removeValue(forKey: id) else { continue }
      actions.parent?.removeChildWindow(actions)
      actions.close()
    }
  }

  private func updateActions(for captions: [DesktopCaption], pointer: NSPoint) {
    guard let panel, panel.isVisible, panel.frame.contains(pointer) else {
      removeActions(except: [])
      return
    }
    var visible = Set<String>()
    for caption in captions {
      guard let turn = caption.voiceID, let controls = caption.identityControls,
        let bubble = panel.anchor(for: caption.id), bubble.contains(pointer),
        let anchor = panel.anchor(for: caption.actionAnchor),
        panel.frame.contains(anchor),
        anchor.width >= CaptionVoiceActions.width(for: controls) - 1
      else { continue }
      visible.insert(caption.id)
      let actions: CaptionVoiceActions
      if let existing = voiceActions[caption.id], existing.turnID == turn,
        existing.controls == controls
      {
        actions = existing
        actions.sentence = caption.text
      } else {
        if let old = voiceActions.removeValue(forKey: caption.id) {
          old.parent?.removeChildWindow(old)
          old.close()
        }
        actions = CaptionVoiceActions(
          turn: turn, controls: controls, sentence: caption.text)
        voiceActions[caption.id] = actions
        actions.perform = { [weak self, weak actions] action in
          guard let self, let actions, self.voiceActions[caption.id] === actions else { return }
          self.apply(action, to: caption)
        }
        actions.setFrame(anchor, display: false)
        panel.addChildWindow(actions, ordered: .above)
      }
      actions.canUndo = caption.markedHere
      if actions.frame != anchor { actions.setFrame(anchor, display: true) }
      if !actions.isVisible { actions.orderFrontRegardless() }
      break
    }
    removeActions(except: visible)
  }

  private func apply(_ action: CaptionVoiceActions.Action, to caption: DesktopCaption) {
    guard let model, rendered.items.contains(where: { $0.id == caption.id }),
          let source = caption.sourceLineID else { return }
    let speaker = model.captionSpeaker(for: source)
    guard speaker.id == caption.voiceID, speaker.controls == caption.identityControls else { return }
    switch action {
    case .confirm where speaker.controls == .confirm: model.confirmCaption(source)
    case .reject where speaker.controls == .reject: model.correctCaption(source, expectedTurn: speaker.id)
    case .undo where speaker.markedHere:
      let mark = "caption:" + source
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
    if panel == nil {
      let newPanel = CaptionPanel()
      newPanel.contentView = NSHostingView(rootView: CaptionFeedView(presentation: presentation, correct: { [weak self] caption, action in
        self?.apply(action, to: caption)
      }))
      panel = newPanel
    }
    guard let panel else { return }
    let frame = CaptionPlacement.frame(in: screen.visibleFrame, count: content.count)
    if panel.frame != frame { panel.setFrame(frame, display: false) }
    let wasPresenting = !rendered.items.isEmpty
    let next = CaptionFeedPresentation.Content(items: content, username: username, preview: preview)
    if rendered != next {
      // A reopened panel must not animate its previously hidden rows back into view.
      presentation.update(
        content, username: username, preview: preview, animated: wasPresenting && panel.isVisible)
      rendered = next
    }
    if !wasPresenting || !panel.isVisible {
      if !panel.isVisible { panel.alphaValue = preview ? 0 : 1 }
      panel.orderFrontRegardless()
      animateAlpha(to: 1, duration: preview ? 0.18 : 0)
    }
  }

  private func hide(immediately: Bool) {
    guard let panel, !rendered.items.isEmpty || (immediately && panel.isVisible) else { return }
    rendered = .init()
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
    change: @escaping @MainActor (DesktopCompanion) -> Void
  ) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
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

  private func isFullScreen(on screen: NSScreen) -> Bool {
    guard
      let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    else { return false }
    let display = CGDisplayBounds(number.uint32Value)
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
