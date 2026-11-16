import Foundation

/// Menu commands select a destination; looking at a failure never starts a recovery job.
enum MenuBarDestination: Equatable {
  case main, live, device, originals, day(String)
}

struct MenuBarTaskSummary {
  let headline: String
  let detail: String
  let fullDetail: String
  let attentionCount: Int
  let destination: MenuBarDestination?

  init(_ presentation: StatusPresentation) {
    let tasks = presentation.activities.filter { $0.id != "caption" }
    let liveFailure = presentation.hardware.kind == .recording
      && presentation.caption.state == .needsAction ? presentation.caption : nil
    let attention = tasks.filter { $0.state == .needsAction }
    attentionCount = attention.count + (liveFailure == nil ? 0 : 1)
    let first = liveFailure ?? attention.first ?? tasks.first(where: \.isWorking)
      ?? tasks.first(where: { $0.state == .waiting }) ?? tasks.first
    headline = attentionCount > 0 ? "\(attentionCount) 项待处理" : "后台任务"
    fullDetail = first?.title ?? "暂无进行中的任务"
    detail = Self.short(fullDetail)
    destination = first.map { activity in
      if activity.id == "caption" { return .live }
      if activity.id.hasPrefix("summary:") {
        return .day(String(activity.id.dropFirst("summary:".count)))
      }
      if activity.id == "sync" || activity.id == "sync-failure" || activity.id == "previous-sync" {
        return .device
      }
      if activity.id == "import" || activity.id.hasPrefix("processing") { return .originals }
      return .main
    }
  }

  static func short(_ text: String) -> String {
    text.count <= 30 ? text : String(text.prefix(29)) + "…"
  }
}

extension AppModel {
  func selectMenuBarDestination(_ destination: MenuBarDestination) {
    switch destination {
    case .main: break // Reopening the app preserves the current page and reading position.
    case .live: showLiveCaptions()
    case .device: area = .device
    case .originals: showOriginals()
    case .day(let day): selectDay(day)
    }
  }

  /// False means recognition is disabled; the caller can offer its settings instead.
  @discardableResult func toggleMenuBarCaptionVisibility() -> Bool {
    guard preferences.captions.enabled else { return false }
    if desktop.isSnoozed { desktop.resume() } else { desktop.snooze() }
    return true
  }
}
