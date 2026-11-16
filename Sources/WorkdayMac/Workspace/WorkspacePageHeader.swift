import SwiftUI
import WorkdayCore

/// Page scope stays with the content; device and background task state live in the global toolbar.
struct WorkspacePageHeader<Actions: View>: View {
  let title: String
  let subtitle: String?
  @ViewBuilder var actions: Actions

  init(title: String, subtitle: String? = nil, @ViewBuilder actions: () -> Actions) {
    self.title = title
    self.subtitle = subtitle
    self.actions = actions()
  }

  var body: some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.system(size: 19, weight: .semibold)).lineLimit(1)
        if let subtitle {
          Text(subtitle).font(.caption).foregroundStyle(Palette.muted).lineLimit(2)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      actions
    }.padding(.horizontal, 22).padding(.vertical, 16)
      .background(Palette.surface)
  }
}

extension WorkspacePageHeader where Actions == EmptyView {
  init(title: String, subtitle: String? = nil) {
    self.init(title: title, subtitle: subtitle) { EmptyView() }
  }
}

struct DayWorkspaceHeader: View {
  @ObservedObject var model: AppModel
  @State private var showsDates = false

  var body: some View {
    HStack(spacing: 14) {
      Button { showsDates.toggle() } label: {
        HStack(spacing: 7) {
          Text(WorkspaceDate.heading(model.selectedDay)).font(.system(size: 21, weight: .semibold))
            .lineLimit(1).minimumScaleFactor(0.85)
          Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
        }
      }
      .accessibilityLabel(WorkspaceDate.heading(model.selectedDay, full: true) + "，选择日期")
      .accessibilityIdentifier("day-date-picker")
      .popover(isPresented: $showsDates) {
        VStack(alignment: .leading) {
          ArchiveMonthCalendar(selectedDay: model.selectedDay, recordedDays: Set(model.days)) { day in
            model.selectDay(day)
            showsDates = false
          }
          Divider()
          ArchiveDates(model: model).frame(height: 135)
        }.padding(14).frame(width: 280)
      }
      Spacer(minLength: 4)
      Button { step(-1) } label: { Image(systemName: "chevron.left") }
        .accessibilityLabel("前一天").help("前一天")
      Button { step(1) } label: { Image(systemName: "chevron.right") }
        .accessibilityLabel("后一天").help("后一天")
      if model.selectedDay != WorkdayDate.day(Date()) {
        Button("今天") { model.selectDay(WorkdayDate.day(Date())) }
          .buttonStyle(.bordered).controlSize(.small).fixedSize()
      }
    }.buttonStyle(.plain)
      .padding(.horizontal, 20).padding(.vertical, 18).background(Palette.surface)
      .accessibilityIdentifier("day-workspace-header")
      .onChange(of: model.selectedDay) { _, _ in showsDates = false }
  }

  private func step(_ delta: Int) {
    let date = WorkspaceDate.date(model.selectedDay) ?? Date()
    if let next = WorkdayTimeline.calendar.date(byAdding: .day, value: delta, to: date) {
      model.selectDay(WorkdayDate.day(next))
    }
  }
}
