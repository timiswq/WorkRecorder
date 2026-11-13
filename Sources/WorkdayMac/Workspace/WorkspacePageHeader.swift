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
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 12) {
        Button {
          showsDates.toggle()
        } label: {
          HStack(spacing: 7) {
            Text(WorkspaceDate.heading(model.selectedDay)).font(
              .system(size: 19, weight: .semibold))
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
          }
        }.accessibilityLabel(WorkspaceDate.heading(model.selectedDay, full: true) + "，选择日期")
          .accessibilityIdentifier("day-date-picker")
          .popover(isPresented: $showsDates) {
            VStack(alignment: .leading) {
              ArchiveMonthCalendar(selectedDay: model.selectedDay, recordedDays: Set(model.days)) {
                day in
                model.selectDay(day)
                showsDates = false
              }
              Divider()
              Text("有录音的日期").font(.caption).foregroundStyle(.secondary)
              ArchiveDates(model: model).frame(height: 135)
            }.padding(14).frame(width: 280)
          }
        Spacer(minLength: 4)
        Button {
          step(-1)
        } label: {
          Image(systemName: "chevron.left")
        }
        .accessibilityLabel("前一天").help("前一天")
        Button {
          step(1)
        } label: {
          Image(systemName: "chevron.right")
        }
        .accessibilityLabel("后一天").help("后一天")
      }.buttonStyle(.plain)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          Text(metadata).fixedSize()
          metadataActions
          Spacer(minLength: 0)
        }
        VStack(alignment: .leading, spacing: 6) {
          Text(metadata)
          metadataActions
        }
      }.font(.caption).foregroundStyle(Palette.muted)
    }.padding(.horizontal, 20).padding(.vertical, 16).background(Palette.surface)
      .accessibilityIdentifier("day-workspace-header")
      .onChange(of: model.selectedDay) { _, _ in showsDates = false }
  }

  private var metadataActions: some View {
    HStack(spacing: 12) {
      if !model.dayRecordings.isEmpty {
        Button("查看原件") { model.showOriginals(for: model.selectedDay) }
        if let route = model.player.route, route.day != model.selectedDay,
          !model.workspace.audio.spans.isEmpty
        {
          Button("回听这一天") { model.playDay() }
        }
      }
      if model.selectedDay != WorkdayDate.day(Date()) {
        Button("回到今天") { model.selectDay(WorkdayDate.day(Date())) }
      }
    }.buttonStyle(.link).fixedSize()
  }

  private var metadata: String {
    let year =
      model.selectedDay.flatMap { WorkspaceDate.date($0) }.map {
        String(WorkdayTimeline.calendar.component(.year, from: $0)) + "年 · "
      } ?? ""
    let today = model.selectedDay == WorkdayDate.day(Date()) ? "今天 · " : ""
    return year + today + "Mac 已保存 \(model.dayRecordings.count) 段录音"
  }

  private func step(_ delta: Int) {
    let date = WorkspaceDate.date(model.selectedDay) ?? Date()
    if let next = WorkdayTimeline.calendar.date(byAdding: .day, value: delta, to: date) {
      model.selectDay(WorkdayDate.day(next))
    }
  }
}
