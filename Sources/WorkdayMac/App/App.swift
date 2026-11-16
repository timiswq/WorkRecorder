import AppKit
import SwiftUI

public struct WorkdayApp: App {
  public init() {}

  @NSApplicationDelegateAdaptor(Lifecycle.self) private var lifecycle
  private var model: AppModel { lifecycle.model }
  public var body: some Scene {
    Window("工作留声", id: "main") {
      RootView(model: model)
        .background(
          MainWindowReader {
            model.desktop.attachMainWindow($0)
            SceneWindowCapture.start(window: $0, model: model)
          })
    }.defaultSize(width: 1140, height: 760).windowStyle(.hiddenTitleBar)
      .windowToolbarStyle(.unifiedCompact)
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
  private var dockBadge: DockBadgeController?
  func applicationDidFinishLaunching(_ notification: Notification) {
    let capture =
      model.isolated && ProcessInfo.processInfo.environment["WORKDAY_SCENE_CAPTURE"] != nil
    NSApp.setActivationPolicy(capture || model.liveVoiceValidation ? .accessory : .regular)
    if !capture && !model.liveVoiceValidation { dockBadge = DockBadgeController(model: model, tile: NSApp.dockTile) }
    model.start()
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    dockBadge?.stop()
    dockBadge = nil
    Task {
      await model.shutdown()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if let main = sender.windows.first(where: { $0.identifier?.rawValue == "workday.main" }) {
      if !main.isVisible && !main.isMiniaturized { model.openDefaultWorkspace() }
      if main.isMiniaturized { main.deminiaturize(nil) }
      main.makeKeyAndOrderFront(nil)
    } else {
      model.openDefaultWorkspace()
    }
    return true
  }
}
