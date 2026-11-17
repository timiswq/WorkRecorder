import AppKit
import SwiftUI

struct WorkdayCommands: Commands {
  @ObservedObject var model: AppModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings

  var body: some Commands {
    CommandGroup(replacing: .appSettings) {
      Button("设置…") { show(.settings) }.keyboardShortcut(",")
    }
    CommandGroup(after: .newItem) {
      Button("导入本地音频文件…") { model.chooseFiles() }.keyboardShortcut("o").disabled(
        model.importLabel != nil)
    }
    CommandMenu("导航") {
      Button("今天") { show(.current) }.keyboardShortcut("1")
      Button("最近的工作记录") { show(.history) }.keyboardShortcut("2")
      Button("设置") { show(.settings) }.keyboardShortcut("3")
      Divider()
      let target = model.recorderSyncTarget
      Button(model.recorderName.map { "同步 \($0) 的录音" } ?? "同步录音") {
        model.syncRecorder(target)
      }.keyboardShortcut("r").disabled(target == nil || (model.usesWiFiCard && !model.canUseWiFiSync))
      Button("打开资料库") { model.reveal() }
    }
  }

  private func show(_ destination: Destination) {
    if destination == .settings {
      openSettings()
      return
    }
    if destination == .current {
      model.openDefaultWorkspace()
    } else if let day = model.days.first {
      model.selectDay(day)
    }
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
  }
}
