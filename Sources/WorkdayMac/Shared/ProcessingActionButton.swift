import AppKit
import SwiftUI

/// SwiftUI owns the command; a native NSButton preserves keyboard focus and accessibility.
struct ProcessingActionButton: NSViewRepresentable {
  let title: String
  let action: () -> Void
  @Environment(\.isEnabled) private var enabled

  func makeCoordinator() -> Coordinator { Coordinator(action) }

  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.press))
    button.setButtonType(.momentaryPushIn)
    button.bezelStyle = .rounded
    button.isBordered = false
    button.wantsLayer = true
    button.layer?.cornerRadius = 6
    button.focusRingType = .exterior
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentHuggingPriority(.required, for: .vertical)
    return button
  }

  func updateNSView(_ button: NSButton, context: Context) {
    context.coordinator.action = action
    button.title = title
    button.isEnabled = enabled
    button.setAccessibilityElement(true)
    button.setAccessibilityRole(.button)
    button.setAccessibilityLabel(title)
    button.attributedTitle = NSAttributedString(string: title, attributes: [
      .font: NSFont.systemFont(ofSize: 12, weight: .medium),
      .foregroundColor: enabled ? NSColor.white : NSColor.secondaryLabelColor,
    ])
    button.layer?.backgroundColor = NSColor(enabled ? Palette.accent : Palette.line).cgColor
    button.invalidateIntrinsicContentSize()
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> NSSize? {
    NSSize(width: max(64, nsView.attributedTitle.size().width + 22), height: 28)
  }

  @MainActor final class Coordinator: NSObject {
    var action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func press() { action() }
  }
}
