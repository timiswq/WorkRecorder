import AppKit
import SwiftUI

/// Observe only the enclosing scroll view; programmatic scrolling never changes user intent.
struct ScrollGestureObserver: NSViewRepresentable {
  let onPosition: (Bool) -> Void
  func makeNSView(context: Context) -> ScrollGestureView {
    let view = ScrollGestureView()
    view.onPosition = onPosition
    return view
  }
  func updateNSView(_ view: ScrollGestureView, context: Context) {
    view.onPosition = onPosition
    view.attach()
  }
  static func dismantleNSView(_ view: ScrollGestureView, coordinator: ()) { view.detach() }
}

final class ScrollGestureView: NSView {
  var onPosition: (Bool) -> Void = { _ in }
  private weak var observed: NSScrollView?
  private var tokens: [NSObjectProtocol] = []
  private var pendingPosition: DispatchWorkItem?
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    attach()
  }
  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    attach()
  }
  func attach() {
    let scroll = enclosingScrollView
    guard scroll !== observed else { return }
    detach()
    guard let scroll else { return }
    observed = scroll
    for name in [
      NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification,
      NSScrollView.didEndLiveScrollNotification,
    ] {
      tokens.append(
        NotificationCenter.default.addObserver(forName: name, object: scroll, queue: .main) {
          [weak self] _ in
          self?.schedulePosition(gestureBegan: name == NSScrollView.willStartLiveScrollNotification)
        })
    }
    tokens.append(NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
    ) { [weak self] _ in
      // Wheels without gesture phases, scrollbar drags and keyboard navigation.
      guard let event = NSApp.currentEvent, [.scrollWheel, .leftMouseDragged, .keyDown].contains(event.type)
      else { return }
      self?.schedulePosition()
    })
  }

  private func schedulePosition(gestureBegan: Bool = false) {
    // AppKit can post these notifications synchronously inside a SwiftUI layout pass.
    pendingPosition?.cancel()
    let update = DispatchWorkItem { [weak self] in
      guard let self else { return }
      pendingPosition = nil
      guard let document = observed?.documentView else { return }
      let atTop = !gestureBegan && LiveReadingPosition.isAtTop(
        of: document.bounds, visible: document.visibleRect, flipped: document.isFlipped)
      onPosition(atTop)
    }
    pendingPosition = update
    DispatchQueue.main.async(execute: update)
  }
  func detach() {
    pendingPosition?.cancel()
    pendingPosition = nil
    tokens.forEach(NotificationCenter.default.removeObserver)
    tokens = []
    observed = nil
  }
  deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}
