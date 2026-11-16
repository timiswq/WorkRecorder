import SwiftUI
import WorkdayCore

struct DaySummaryView: View {
  @ObservedObject var model: AppModel
  @State private var expanded = false
  @State private var showsNotes = false

  var body: some View {
    let day = model.selectedDay ?? ""
    let value = model.summaries[day]
    let overview = DayReviewText.overview(value?.overview ?? "", day: day)
    let state = model.dayOverviewState(for: day)
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Text("概述").font(.headline)
        Spacer()
        if !overview.isEmpty && overview.count > 70 {
          Button(expanded ? "收起" : "展开") { expanded.toggle() }.buttonStyle(.link)
            .font(.caption).accessibilityLabel(expanded ? "收起概述" : "展开概述")
        }
      }
      if !overview.isEmpty {
        Text(overview).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
          .lineLimit(expanded ? nil : 4)
      }
      if let message = state.message {
        ProcessingStatusView(message: message, kind: state.kind, actionTitle: state.actionTitle) {
          recover(state, day: day)
        }.accessibilityIdentifier("day-overview-processing-status")
      }
      if expanded, let value, !value.decisions.isEmpty || !value.tasks.isEmpty {
        DisclosureGroup("更多信息", isExpanded: $showsNotes) {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(value.decisions) { Text($0.text).textSelection(.enabled) }
            ForEach(value.tasks) { Text($0.text).textSelection(.enabled) }
          }.font(.callout).padding(.top, 6)
        }.font(.caption).foregroundStyle(Palette.muted)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
      .background {
        if model.dayUpdates.isUnseen(day), let signature = model.dayUpdates.signature(for: day) {
          DayResultReadMarker(signature: day + ":" + signature) {
            model.markDayViewed(day, signature: signature)
          }
        }
      }
      .padding(.bottom, 18).overlay(alignment: .bottom) { Divider() }
      .onChange(of: model.selectedDay) { _, _ in expanded = false; showsNotes = false }
  }

  private func recover(_ state: DayOverviewState, day: String) {
    switch state {
    case .outdated, .summaryFailed: model.retryProcessing(scope: .summary(day))
    case .unconfigured: model.requestSettings(.recognition)
    default: model.requestDayProcessing(day)
    }
  }
}
