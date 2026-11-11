import AppKit

extension DesktopCaption {
  var actionAnchor: String { "buttons.\(id).\(voiceID ?? "").\(identityControls?.rawValue ?? "")" }
}

/// A click surface sized to exactly the inline controls of one bubble.
@MainActor final class CaptionVoiceActions: NSPanel {
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
    didSet {
      guard canUndo != oldValue, let button = contentView?.subviews.first as? NSButton else { return }
      let menu = NSMenu()
      let item = menu.addItem(withTitle: "撤销这句的标注", action: #selector(undoMark), keyEquivalent: "")
      item.target = self
      button.menu = canUndo ? menu : nil
    }
  }
  var perform: ((Action) -> Void)?
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init(turn: String, controls: CaptionIdentityControls, sentence: String) {
    turnID = turn
    self.controls = controls
    self.sentence = sentence
    super.init(
      contentRect: NSRect(
        x: 0, y: 0, width: Self.width(for: controls), height: Self.height),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isReleasedWhenClosed = false
    isFloatingPanel = true
    level = .floating
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false
    let surface = NSView(frame: NSRect(origin: .zero, size: frame.size))
    contentView = surface
    let isMine = controls == .reject
    addButton(controls.rawValue, hint: isMine ? "纠正这句话为非本人" : "标记这句话为本人",
              x: 0, width: Self.width(for: controls), selector: isMine ? #selector(reject) : #selector(confirm), to: surface)
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
