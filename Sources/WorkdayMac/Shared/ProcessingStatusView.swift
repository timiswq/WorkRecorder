import SwiftUI

/// Status is noninteractive; only an explicit, filled action button starts or resumes work.
struct ProcessingStatusView: View {
  let message: String
  let kind: ProcessingStatusKind
  var actionTitle: String? = nil
  var action: () -> Void = {}

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        status
        if let actionTitle { actionButton(actionTitle) }
      }
      VStack(alignment: .leading, spacing: 9) {
        status
        if let actionTitle { actionButton(actionTitle) }
      }
    }.accessibilityElement(children: .contain)
  }

  private var status: some View {
    HStack(alignment: .center, spacing: 7) {
      if kind == .working {
        ProgressView().controlSize(.mini).tint(Palette.accent).accessibilityLabel("正在执行")
      } else {
        Image(systemName: kind == .queued ? "clock" : kind == .failure ? "exclamationmark.circle" : kind == .actionRequired ? "hand.tap" : "info.circle")
          .accessibilityHidden(true)
      }
      Text(message).fixedSize(horizontal: false, vertical: true)
    }.font(.caption).foregroundStyle(kind == .failure ? Palette.amber : Palette.muted)
  }

  private func actionButton(_ title: String) -> some View {
    ProcessingActionButton(title: title, action: action).fixedSize()
  }
}
