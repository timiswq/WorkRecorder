import SwiftUI

enum StatusStyle {
  static func color(_ status: DesktopStatus) -> Color {
    if status.warning || status.kind == .unknown { return Palette.amber }
    switch status.kind {
    case .recording: return Palette.red
    case .paused: return Palette.amber
    case .disconnected, .connecting: return Palette.muted
    default: return Palette.text
    }
  }

  /// In-window hardware states keep their native symbols; the assistant belongs to the menu bar.
  static func symbol(_ kind: DesktopStatus.Kind) -> String {
    switch kind {
    case .recording: return "record.circle.fill"
    case .paused: return "pause.circle.fill"
    case .saving: return "square.and.arrow.down"
    case .idle: return "stop.circle"
    case .connecting: return "antenna.radiowaves.left.and.right"
    case .disconnected: return "circle.dashed"
    case .unknown: return "questionmark.circle"
    case .usb: return "cable.connector"
    }
  }
}

struct StatusActivityRow: View {
  let activity: StatusActivity
  let perform: (StatusAction) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        if activity.isWorking {
          ProgressView().controlSize(.mini).accessibilityLabel("任务进行中")
        } else {
          Image(systemName: symbol)
            .accessibilityHidden(true)
        }
        Text(activity.title).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
      }.foregroundStyle(activity.state == .needsAction ? Palette.amber : Palette.text)
      if !activity.detail.isEmpty {
        Text(activity.detail).font(.caption).foregroundStyle(Palette.muted)
          .fixedSize(horizontal: false, vertical: true)
          .help(activity.error ?? activity.detail)
      }
      if let action = activity.action {
        if action.isSecondary {
          Button(activity.actionLabel ?? action.title) { perform(action) }.buttonStyle(.bordered)
            .controlSize(.small).accessibilityIdentifier("status-action-" + activity.id)
        } else {
          ProcessingActionButton(title: activity.actionLabel ?? action.title) { perform(action) }
            .fixedSize().accessibilityIdentifier("status-action-" + activity.id)
        }
      }
      if activity.day == nil, let error = activity.error { ErrorDetailsButton(message: error) }
    }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .contain)
  }

  private var symbol: String {
    switch activity.state {
    case .needsAction: return "exclamationmark.circle"
    case .manual: return "circle"
    case .complete: return "checkmark.circle"
    default: return "clock"
    }
  }
}

struct AppActivityList: View {
  @ObservedObject var model: AppModel

  var body: some View {
    let status = model.statusPresentation(at: Date())
    let rows = status.activities
    VStack(alignment: .leading, spacing: 14) {
      Text("后台任务").font(.headline)
      if rows.isEmpty {
        Text("无进行中的任务").font(.callout).foregroundStyle(Palette.muted)
      }
      ForEach(rows) { row in StatusActivityRow(activity: row, perform: model.performStatusAction) }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
