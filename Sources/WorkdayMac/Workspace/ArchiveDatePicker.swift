import SwiftUI
import WorkdayCore

struct ArchiveDates: View {
  @ObservedObject var model: AppModel
  @State private var sidebarDay: String?
  init(model: AppModel) {
    self.model = model
    _sidebarDay = State(initialValue: model.selectedDay)
  }
  var body: some View {
    List(selection: $sidebarDay) {
      dateRow(WorkdayDate.day(Date()), icon: "sun.max", today: true)
      Section("工作记录") {
        ForEach(model.days.filter { $0 != WorkdayDate.day(Date()) }, id: \.self) { day in
          dateRow(day, icon: "calendar", today: false)
        }
      }
    }.listStyle(.inset).accessibilityIdentifier("workspace-dates")
      .onChange(of: model.selectedDay, initial: true) { _, day in sidebarDay = day }
      .onChange(of: sidebarDay) { _, day in
        guard day != model.selectedDay else { return }
        if let day {
          let previous = model.selectedDay
          Task { @MainActor in
            await Task.yield()
            guard sidebarDay == day, model.selectedDay == previous else { return }
            model.selectDay(day)
          }
        } else {
          sidebarDay = model.selectedDay
        }
      }
  }
  private func dateRow(_ day: String, icon: String, today: Bool) -> some View {
    Label {
      VStack(alignment: .leading, spacing: 4) {
        Text(WorkspaceDate.title(day)).font(.system(size: 13, weight: .medium))
        Text(model.dayStatus(day)).font(.system(size: 11)).foregroundStyle(.secondary)
      }.padding(.vertical, 4)
    } icon: {
      Image(systemName: icon)
    }
    .tag(day).accessibilityIdentifier(today ? "date-today" : "date-" + day)
  }
}

struct ArchiveMonthCalendar: View {
  let selectedDay: String?
  let recordedDays: Set<String>
  let select: (String) -> Void
  @State private var month: Date
  private let calendar = WorkdayTimeline.calendar

  init(selectedDay: String?, recordedDays: Set<String>, select: @escaping (String) -> Void) {
    self.selectedDay = selectedDay
    self.recordedDays = recordedDays
    self.select = select
    let date = WorkspaceDate.date(selectedDay) ?? Date()
    _month = State(initialValue: WorkdayTimeline.calendar.dateInterval(of: .month, for: date)?.start ?? date)
  }

  private var grid: [Date] {
    guard let days = calendar.range(of: .day, in: .month, for: month) else { return [] }
    let leading = (calendar.component(.weekday, from: month) + 5) % 7
    let cells = ((leading + days.count + 6) / 7) * 7
    return (0..<cells).compactMap { calendar.date(byAdding: .day, value: $0 - leading, to: month) }
  }

  var body: some View {
    VStack(spacing: 8) {
      HStack {
        Text("\(calendar.component(.year, from: month).formatted(.number.grouping(.never)))年\(calendar.component(.month, from: month))月").font(.headline)
        Spacer()
        monthButton(-1)
        monthButton(1)
      }
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 3) {
        ForEach(Array("一二三四五六日"), id: \.self) { Text(String($0)).font(.caption).foregroundStyle(Palette.muted) }
        ForEach(grid, id: \.self) { date in
          let key = WorkdayDate.day(date)
          let picked = selectedDay == key
          let hasAudio = recordedDays.contains(key)
          Button { select(key) } label: {
            Text(String(calendar.component(.day, from: date))).font(.callout.monospacedDigit())
              .frame(maxWidth: .infinity, minHeight: 28)
              .foregroundStyle(picked ? Palette.accent : (calendar.isDate(date, equalTo: month, toGranularity: .month) ? Palette.text : Palette.muted))
              .background(picked ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
              .overlay(alignment: .bottom) {
                if hasAudio { Circle().fill(Palette.accent).frame(width: 4, height: 4).padding(.bottom, 1) }
              }.contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityLabel(key + (hasAudio ? "，有录音" : ""))
            .accessibilityAddTraits(picked ? .isSelected : [])
        }
      }
      HStack {
        Label("有录音", systemImage: "circle.fill").font(.caption2).foregroundStyle(Palette.muted)
        Spacer()
        Button("回到今天") { select(WorkdayDate.day(Date())) }.buttonStyle(.link)
      }
    }
  }

  private func monthButton(_ delta: Int) -> some View {
    Button {
      if let next = calendar.date(byAdding: .month, value: delta, to: month) { month = next }
    } label: { Image(systemName: delta < 0 ? "chevron.left" : "chevron.right").padding(4) }
    .buttonStyle(.plain).accessibilityLabel(delta < 0 ? "上个月" : "下个月")
  }
}
