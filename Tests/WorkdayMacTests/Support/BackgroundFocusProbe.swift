import AppKit

/// Users may switch between their own apps while these tests run. Only our activation is a violation.
@MainActor final class BackgroundFocusProbe {
  private(set) var activatedTestApplication = false
  private var token: NSObjectProtocol?

  init() {
    let processID = ProcessInfo.processInfo.processIdentifier
    activatedTestApplication = NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
    token = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            app.processIdentifier == processID else { return }
      MainActor.assumeIsolated { self?.activatedTestApplication = true }
    }
  }

  func stop() {
    if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    token = nil
  }
}
