import AppKit
import SwiftUI

/// Observe only the enclosing scroll view; programmatic scrolling never changes user intent.
struct ScrollGestureObserver: NSViewRepresentable {
  let onBegin: () -> Void
  let onEnd: () -> Void
  func makeNSView(context: Context) -> ScrollGestureView {
    let view = ScrollGestureView()
    view.onBegin = onBegin
    view.onEnd = onEnd
    return view
  }
  func updateNSView(_ view: ScrollGestureView, context: Context) {
    view.onBegin = onBegin
    view.onEnd = onEnd
    view.attach()
  }
  static func dismantleNSView(_ view: ScrollGestureView, coordinator: ()) { view.detach() }
}

final class ScrollGestureView: NSView {
  var onBegin: () -> Void = {}
  var onEnd: () -> Void = {}
  private weak var observed: NSScrollView?
  private var tokens: [NSObjectProtocol] = []
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    attach()
  }
  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    attach()
  }
  func attach() {
    guard let scroll = enclosingScrollView, scroll !== observed else { return }
    detach()
    observed = scroll
    for (name, beginning) in [
      (NSScrollView.willStartLiveScrollNotification, true),
      (NSScrollView.didEndLiveScrollNotification, false),
    ] {
      tokens.append(
        NotificationCenter.default.addObserver(forName: name, object: scroll, queue: .main) {
          [weak self] _ in
          if beginning { self?.onBegin() } else { self?.onEnd() }
        })
    }
  }
  func detach() {
    tokens.forEach(NotificationCenter.default.removeObserver)
    tokens = []
    observed = nil
  }
  deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}
