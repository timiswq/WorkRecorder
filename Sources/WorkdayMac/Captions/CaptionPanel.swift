import AppKit
import SwiftUI

/// A short, interruptible transition sampled by the feed and its native click targets on the same frame.
struct CaptionTransition {
  var from: CGFloat
  var to: CGFloat
  var start = Date.distantPast
  var duration: TimeInterval = 0
  var end: Date { start.addingTimeInterval(duration) }

  init(_ value: CGFloat) { from = value; to = value }

  static func progress(_ elapsed: TimeInterval, duration: TimeInterval) -> CGFloat {
    guard duration > 0 else { return 1 }
    let remaining = 1 - min(1, max(0, elapsed / duration))
    return 1 - remaining * remaining * remaining
  }

  func value(at now: Date) -> CGFloat {
    from + (to - from) * Self.progress(now.timeIntervalSince(start), duration: duration)
  }

  mutating func move(to target: CGFloat, at now: Date, duration: TimeInterval) {
    guard duration > 0 else { self = .init(target); return }
    guard to != target else { return }
    from = value(at: now)
    to = target
    start = now
    self.duration = duration
  }
}

@MainActor final class CaptionFeedPresentation: ObservableObject {
  struct Content: Equatable {
    var items: [DesktopCaption] = []
    var username = ""
    var preview = false
  }
  struct Row: Identifiable {
    var caption: DesktopCaption
    var id: String { caption.id }
    var presence: CaptionTransition
    var expansion: CaptionTransition
    var wave: CaptionTransition
    var reservesWave: Bool
  }

  private(set) var content = Content()
  private(set) var rows: [Row] = []
  private(set) var frameTime = Date()
  private(set) var reducesMotion = false
  var geometryDidChange: (() -> Void)?
  // The native hover button occupies the wave's trailing header space.
  var identityActionID: String? {
    willSet { if newValue != identityActionID { objectWillChange.send() } }
  }
  private var clock: Task<Void, Never>?
  private var layoutUntil = Date.distantPast
  private var paintUntil = Date.distantPast

  func update(_ items: [DesktopCaption], username: String, preview: Bool, animated: Bool = true,
              animateStack: Bool = true, reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
    let next = Content(items: items, username: username, preview: preview)
    guard next != content || (!animated && !rows.isEmpty && items.isEmpty) else { return }
    let now = Date()
    let motion = animated && !reduceMotion
    let stack = motion && animateStack
    let old = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    var visible = items.map { item in
      let hasWave = item.isSoundFeedback || (!item.isFinal && item.id == items.last(where: { $0.inputLabel == item.inputLabel })?.id)
      let open: CGFloat = item.isSoundFeedback ? 0 : 1
      var row = old[item.id] ?? Row(caption: item, presence: .init(stack ? 0 : 1), expansion: .init(open),
                                    wave: .init(hasWave ? 1 : 0), reservesWave: hasWave)
      row.caption = item
      row.reservesWave = row.reservesWave || hasWave
      row.presence.move(to: 1, at: now, duration: stack ? 0.18 : 0)
      row.expansion.move(to: open, at: now, duration: motion ? 0.18 : 0)
      row.wave.move(to: hasWave ? 1 : 0, at: now, duration: motion ? 0.10 : 0)
      return row
    }
    // Keep a departing row in its old gap while the rows below it settle. It owns no controls.
    if stack {
      let active = Set(items.map(\.id))
      var following: String?
      for var oldRow in rows.reversed() {
        if !active.contains(oldRow.id) {
          oldRow.presence.move(to: 0, at: now, duration: 0.12)
          let index = following.flatMap { id in visible.firstIndex { $0.id == id } } ?? visible.endIndex
          visible.insert(oldRow, at: index)
        }
        following = oldRow.id
      }
    }
    objectWillChange.send()
    content = next
    reducesMotion = reduceMotion
    rows = visible
    frameTime = now
    layoutUntil = rows.map { max($0.presence.end, $0.expansion.end) }.max() ?? .distantPast
    paintUntil = rows.map { $0.wave.end }.max() ?? .distantPast
    if !reduceMotion {
      for row in rows {
        if let last = row.caption.phrases.last {
          paintUntil = max(paintUntil, last.appearedAt.addingTimeInterval(CaptionPhrase.duration))
        }
        if let second = row.caption.phrases.first(where: { $0.line == 1 }) {
          layoutUntil = max(layoutUntil, second.appearedAt.addingTimeInterval(CaptionPhrase.duration))
        }
      }
    }
    if max(layoutUntil, paintUntil) > now, clock == nil {
      clock = Task { [weak self] in
        while !Task.isCancelled {
          do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
          guard let self else { return }
          let layoutChanged = frameTime < layoutUntil
          objectWillChange.send()
          frameTime = Date()
          rows.removeAll { $0.presence.to == 0 && $0.presence.end <= self.frameTime }
          if layoutChanged { geometryDidChange?() }
          if frameTime >= max(layoutUntil, paintUntil) { clock = nil; return }
        }
      }
    }
  }
}

struct CaptionFeedView: View {
  @ObservedObject var presentation: CaptionFeedPresentation
  var meter: LiveAudioMeter?
  var micMeter: LiveAudioMeter?
  var correct: ((DesktopCaption, CaptionVoiceActions.Action) -> Void)? = nil
  var dismiss: ((String) -> Void)? = nil
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let now = reduceMotion || presentation.reducesMotion ? Date.distantFuture : presentation.frameTime
    VStack(alignment: .trailing, spacing: 0) {
      ForEach(presentation.rows.reversed()) { row in
        let caption = row.caption
        let presence = row.presence.value(at: now)
        let wave = presentation.identityActionID == row.id ? 0 : row.wave.value(at: now)
        CaptionReveal(progress: CaptionReveal.envelope(presence)) {
          CaptionBubble(
            caption: caption, username: caption.speakerLabel ?? presentation.content.username,
            preview: presentation.content.preview, meter: presentation.content.preview ? nil : (caption.inputLabel == .microphone ? micMeter : meter), time: now,
            expansion: row.expansion.value(at: now),
            waveOpacity: wave, reservesWave: row.reservesWave,
            inkOpacity: row.presence.to == 1 ? CaptionReveal.ink(presence) : presence)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(presence)
        .accessibilityActions {
          if let dismiss { Button("关闭这条气泡") { dismiss(caption.id) } }
          if let controls = caption.identityControls, let correct {
            Button(controls.rawValue) { correct(caption, controls == .confirm ? .confirm : .reject) }
            if caption.markedHere { Button("撤销这句的标注") { correct(caption, .undo) } }
          }
        }
        .accessibilityHidden(row.presence.to == 0)
        .background(CaptionAnchor(id: caption.id))
        .padding(.bottom, 6 * presence)
      }
    }
    .padding(6)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
  }
}

/// A read-only geometric anchor for the separate click target, including older visible rows.
struct CaptionAnchor: NSViewRepresentable {
  let id: String
  func makeNSView(context: Context) -> NSView { NSView() }
  func updateNSView(_ view: NSView, context: Context) {
    view.identifier = NSUserInterfaceItemIdentifier("voice-anchor." + id)
  }
}

final class CaptionPanel: NSPanel {
  let feedView: NSHostingView<CaptionFeedView>

  private var hovered = false
  func setHovered(_ value: Bool) {
    guard hovered != value else { return }
    hovered = value
    NSAnimationContext.runAnimationGroup { context in
      context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.10
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      feedView.animator().alphaValue = value ? 0.65 : 1
    }
  }

  func anchor(for id: String) -> NSRect? {
    let target = NSUserInterfaceItemIdentifier("voice-anchor." + id)
    func locate(_ view: NSView) -> NSView? {
      if view.identifier == target { return view }
      for child in view.subviews { if let found = locate(child) { return found } }
      return nil
    }
    guard let contentView else { return nil }
    contentView.layoutSubtreeIfNeeded()
    guard let view = locate(contentView), view.bounds.height > 0 else { return nil }
    return convertToScreen(view.convert(view.bounds, to: nil))
  }
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
  init(frame: CGRect, feed: CaptionFeedView) {
    feedView = NSHostingView(rootView: feed)
    super.init(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    // A hosting view used as window.contentView can animate the window's size during row transitions.
    // Keep that animation inside an AppKit view whose frame is owned by the panel.
    let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
    contentView = container
    feedView.sizingOptions = []
    feedView.frame = container.bounds
    feedView.autoresizingMask = [.width, .height]
    container.addSubview(feedView)
    identifier = NSUserInterfaceItemIdentifier("workday.desktop-caption")
    title = "工作留声桌面弹幕"
    isFloatingPanel = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    hidesOnDeactivate = false
    ignoresMouseEvents = true
    isReleasedWhenClosed = false
    isMovable = false
  }
}

enum CaptionPlacement {
  static func frame(in visibleFrame: CGRect, comparing: Bool = false) -> CGRect {
    let width = min(360, max(1, visibleFrame.width - 32))
    let rows = DesktopCaptionState.maximumVisible * (comparing ? 2 : 1)
    let height = min(CGFloat(rows * 85 + 12), max(1, visibleFrame.height - 32))
    return CGRect(
      x: visibleFrame.maxX - width - 16, y: visibleFrame.maxY - height - 6,
      width: width, height: height)
  }

  static func coversDisplay(window: CGRect, display: CGRect) -> Bool {
    abs(window.minX - display.minX) <= 2 && abs(window.minY - display.minY) <= 2
      && window.width >= display.width - 2 && window.height >= display.height - 2
  }
}
