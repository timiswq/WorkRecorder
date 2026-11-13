import AppKit

/// Each visible bubble owns a click target; gaps in the read-only feed stay click-through.
@MainActor final class CaptionDismissPanel: CaptionControlPanel {
  let captionID: String
  var onDismiss: (() -> Void)?
  private let surface = CaptionDismissView()

  init(captionID: String) {
    self.captionID = captionID
    super.init(size: .zero)
    identifier = NSUserInterfaceItemIdentifier("workday.caption-dismiss.\(captionID)")
    // WindowServer skips fully transparent pixels during mouse hit testing.
    backgroundColor = NSColor.black.withAlphaComponent(0.01)
    surface.toolTip = "点击收起这条气泡"
    surface.setAccessibilityElement(false)
    surface.onDismiss = { [weak self] in self?.onDismiss?() }
    contentView = surface
  }

  func show(in panel: CaptionPanel, bubble: NSRect, identityFrame: NSRect?) {
    let rect = bubble.integral
    let excluded = identityFrame?.offsetBy(dx: -rect.minX, dy: -rect.minY)
    if frame != rect || surface.identityFrame != excluded { surface.cancelClick() }
    surface.identityFrame = excluded
    show(in: panel, at: rect)
  }

  override func detach() {
    surface.cancelClick()
    onDismiss = nil
    super.detach()
  }
}

private final class CaptionDismissView: NSView {
  var identityFrame: NSRect?
  var onDismiss: (() -> Void)?
  private var pressed = false

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    // A double-click must not close a second sentence that just moved into this position.
    pressed = event.clickCount == 1 && canDismiss(at: convert(event.locationInWindow, from: nil))
  }

  override func mouseUp(with event: NSEvent) {
    let wasPressed = pressed
    pressed = false
    guard wasPressed, canDismiss(at: convert(event.locationInWindow, from: nil)) else { return }
    onDismiss?()
  }

  func cancelClick() { pressed = false }

  private func canDismiss(at point: NSPoint) -> Bool {
    bounds.contains(point) && identityFrame?.contains(point) != true
  }
}
