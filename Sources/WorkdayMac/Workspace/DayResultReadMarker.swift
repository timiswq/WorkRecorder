import AppKit
import SwiftUI

/// A sidebar click is not a receipt: acknowledge after the actual summary is visible
/// in the key window for a short reading interval. Hidden/background windows never clear it.
struct DayResultReadMarker: NSViewRepresentable {
  let signature: String
  let onRead: () -> Void

  func makeNSView(context: Context) -> ReadView { ReadView() }
  func updateNSView(_ view: ReadView, context: Context) {
    view.configure(signature: signature, onRead: onRead)
  }
  static func dismantleNSView(_ view: ReadView, coordinator: ()) { view.cancel() }

  final class ReadView: NSView {
    private var signature = ""
    private var onRead: (() -> Void)?
    private var pending: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    func configure(signature: String, onRead: @escaping () -> Void) {
      let changed = self.signature != signature
      self.signature = signature
      self.onRead = onRead
      if changed { schedule() }
    }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      for observer in observers { NotificationCenter.default.removeObserver(observer) }
      observers = []
      for name in [
        NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
        NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
        NSView.boundsDidChangeNotification,
      ] {
        observers.append(
          NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
          })
      }
      schedule()
    }
    override func layout() {
      super.layout()
      if pending == nil { schedule() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func schedule() {
      pending?.cancel()
      guard onRead != nil, let window, window.isVisible, window.isKeyWindow,
        !window.isMiniaturized, NSApp.isActive, !visibleRect.isEmpty
      else {
        pending = nil
        return
      }
      let version = signature
      pending = Task { @MainActor [weak self] in
        do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
        guard let self, self.signature == version, let window = self.window,
          window.isVisible, window.isKeyWindow, !window.isMiniaturized, NSApp.isActive,
          self.visibleRect.height >= min(60, self.bounds.height), self.visibleRect.width > 0
        else { return }
        let callback = self.onRead
        self.onRead = nil
        callback?()
      }
    }
    func cancel() {
      pending?.cancel()
      pending = nil
      onRead = nil
    }
    deinit {
      pending?.cancel()
      for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
  }
}
