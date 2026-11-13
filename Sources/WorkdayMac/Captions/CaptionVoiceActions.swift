import AppKit
import SwiftUI

extension DesktopCaption {
  var actionAnchor: String { "buttons.\(id).\(voiceID ?? "").\(identityControls?.rawValue ?? "")" }
}

/// A nonactivating mouse target limited to the visible bubble or one of its controls.
@MainActor class CaptionControlPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init(size: NSSize) {
    super.init(contentRect: NSRect(origin: .zero, size: size),
               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isReleasedWhenClosed = false
    isFloatingPanel = true
    level = .floating
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false
  }

  func show(in panel: CaptionPanel, at rect: NSRect) {
    if frame != rect { setFrame(rect, display: true) }
    if parent !== panel { panel.addChildWindow(self, ordered: .above) }
    if !isVisible { orderFrontRegardless() }
  }

  func detach() {
    parent?.removeChildWindow(self)
    close()
  }
}

@MainActor final class CaptionClosePanel: CaptionControlPanel {
  private static let side: CGFloat = 18
  let captionID: String
  let button = NSButton()
  var onDismiss: (() -> Void)?

  init(captionID: String) {
    self.captionID = captionID
    super.init(size: NSSize(width: Self.side, height: Self.side))
    button.title = ""
    button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
    button.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
    button.imagePosition = .imageOnly
    button.contentTintColor = .white
    button.isBordered = false
    button.wantsLayer = true
    button.layer?.cornerRadius = Self.side / 2
    button.layer?.backgroundColor = NSColor(Palette.captionSolidBackground).cgColor
    button.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
    button.layer?.borderWidth = 1
    button.toolTip = "关闭这条气泡"
    button.target = self
    button.action = #selector(dismissCaption)
    contentView = button
  }

  static func frame(on bubble: NSRect) -> NSRect {
    // The visible arc of the rounded corner is slightly inside the bounding rectangle.
    return NSRect(x: bubble.maxX - 2 - side / 2, y: bubble.maxY - 3 - side / 2,
                  width: side, height: side)
  }

  func show(in panel: CaptionPanel, bubble: NSRect, sentence: String) {
    button.setAccessibilityLabel("关闭这条气泡：\(sentence)")
    show(in: panel, at: Self.frame(on: bubble))
  }

  @objc private func dismissCaption() { onDismiss?() }
}

@MainActor final class CaptionVoiceActions: CaptionControlPanel {
  enum Action { case confirm, reject, undo }
  static let height: CGFloat = 20
  nonisolated static func width(for controls: CaptionIdentityControls) -> CGFloat {
    controls == .reject ? 48 : 34
  }
  let turnID: String
  let controls: CaptionIdentityControls
  var sentence: String {
    didSet {
      guard sentence != oldValue else { return }
      for case let button as NSButton in contentView?.subviews ?? [] {
        button.setAccessibilityLabel("\(button.toolTip ?? button.title)：\(sentence)")
      }
    }
  }
  var canUndo = false {
    didSet { if canUndo != oldValue { updateMenu() } }
  }
  private func updateMenu() {
    guard let button = contentView?.subviews.first as? NSButton else { return }
    let menu = NSMenu()
    if canUndo {
      menu.addItem(withTitle: "撤销这句的标注", action: #selector(undoMark), keyEquivalent: "").target = self
    } else {
      let title = controls == .confirm ? "不是我" : "是我"
      let action = controls == .confirm ? #selector(reject) : #selector(confirm)
      menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
    }
    button.menu = menu
  }
  var perform: ((Action) -> Void)?
  init(turn: String, controls: CaptionIdentityControls, sentence: String) {
    turnID = turn
    self.controls = controls
    self.sentence = sentence
    super.init(size: NSSize(width: Self.width(for: controls), height: Self.height))
    let surface = NSView(frame: NSRect(origin: .zero, size: frame.size))
    contentView = surface
    let isMine = controls == .reject
    addButton(controls.rawValue, hint: isMine ? "纠正这句话为非本人" : "标记这句话为本人",
              x: 0, width: Self.width(for: controls), selector: isMine ? #selector(reject) : #selector(confirm), to: surface)
    updateMenu()
  }
  private func addButton(
    _ title: String, hint: String, x: CGFloat, width: CGFloat, selector: Selector, to view: NSView
  ) {
    let button = NSButton(title: title, target: self, action: selector)
    button.frame = NSRect(x: x, y: 0, width: width, height: Self.height)
    button.isBordered = false
    button.attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
      ])
    button.wantsLayer = true
    button.layer?.cornerRadius = 5
    button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
    button.toolTip = hint
    button.setAccessibilityLabel("\(hint)：\(sentence)")
    view.addSubview(button)
  }
  @objc private func confirm() { perform?(.confirm) }
  @objc private func reject() { perform?(.reject) }
  @objc private func undoMark() { perform?(.undo) }
}
