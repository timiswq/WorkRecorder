import AppKit
import SwiftUI

public struct WorkdayApp: App {
  public init() {}

  @NSApplicationDelegateAdaptor(Lifecycle.self) private var lifecycle
  private var model: AppModel { lifecycle.model }
  public var body: some Scene {
    Window("工作留声", id: "main") {
      RootView(model: model)
        .background(MainWindowReader { model.desktop.attachMainWindow($0) })
    }.defaultSize(width: 1140, height: 760).windowStyle(.hiddenTitleBar)
      .commands { WorkdayCommands(model: model) }
    Settings {
      SettingsView(model: model)
    }.defaultSize(width: 740, height: 670)
    MenuBarExtra {
      MenuBarPanel(model: model, desktop: model.desktop)
    } label: {
      MenuBarStatusLabel(desktop: model.desktop)
    }.menuBarExtraStyle(.window)
  }
}

@MainActor final class Lifecycle: NSObject, NSApplicationDelegate {
  let model = AppModel()
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    model.start()
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Task {
      await model.shutdown()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if let main = sender.windows.first(where: { $0.identifier?.rawValue == "workday.main" }) {
      if main.isMiniaturized { main.deminiaturize(nil) }
      main.makeKeyAndOrderFront(nil)
    }
    return true
  }
}
