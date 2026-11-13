import AppKit
import SwiftUI

@MainActor final class CaptionFeedPresentation: ObservableObject {
  struct Content: Equatable {
    var items: [DesktopCaption] = []
    var username = ""
    var preview = false
  }
  @Published private(set) var content = Content()

  func update(_ items: [DesktopCaption], username: String, preview: Bool, animated: Bool = true) {
    let next = Content(items: items, username: username, preview: preview)
    guard next != content else { return }
    let changedRows = content.items.map(\.id) != items.map(\.id)
    let hasButtons = (content.items + items).contains { $0.identityControls != nil }
    // Removing only the bottom bubble leaves every surviving native button in place.
    let removesBottomOnly = content.items.dropFirst().elementsEqual(items)
      && content.username == username && content.preview == preview
    if animated && changedRows && (!hasButtons || removesBottomOnly)
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    {
      withAnimation(.easeOut(duration: 0.24)) { content = next }
    } else {
      var transaction = Transaction(animation: nil)
      transaction.disablesAnimations = true
      withTransaction(transaction) { content = next }
    }
  }
}

struct CaptionFeedView: View {
  @ObservedObject var presentation: CaptionFeedPresentation
  var correct: ((DesktopCaption, CaptionVoiceActions.Action) -> Void)? = nil
  var dismiss: ((String) -> Void)? = nil
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      ForEach(presentation.content.items.reversed()) { caption in
        CaptionBubble(
          caption: caption, username: caption.speakerLabel ?? presentation.content.username,
          preview: presentation.content.preview
        )
        .accessibilityActions {
          if let dismiss { Button("关闭这条气泡") { dismiss(caption.id) } }
          if let controls = caption.identityControls, let correct {
            Button(controls.rawValue) { correct(caption, controls == .confirm ? .confirm : .reject) }
            if caption.markedHere { Button("撤销这句的标注") { correct(caption, .undo) } }
          }
        }
        .background(CaptionAnchor(id: caption.id))
        .transition(
          reduceMotion
            ? .opacity
            : .asymmetric(
              insertion: presentation.content.preview
                ? .offset(y: -6).combined(with: .opacity) : .offset(y: -6),
              removal: .opacity))
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
  static func frame(in visibleFrame: CGRect) -> CGRect {
    let width = min(360, max(1, visibleFrame.width - 32))
    let height = min(CGFloat(DesktopCaptionState.maximumVisible * 85 + 12), max(1, visibleFrame.height - 32))
    return CGRect(
      x: visibleFrame.maxX - width - 16, y: visibleFrame.maxY - height - 6,
      width: width, height: height)
  }

  static func coversDisplay(window: CGRect, display: CGRect) -> Bool {
    abs(window.minX - display.minX) <= 2 && abs(window.minY - display.minY) <= 2
      && window.width >= display.width - 2 && window.height >= display.height - 2
  }
}
