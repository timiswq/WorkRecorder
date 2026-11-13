import SwiftUI
import WorkdayCore

enum CaptionTime {
  private static func formatter(_ format: String) -> DateFormatter {
    let value = DateFormatter()
    value.locale = Locale(identifier: "zh_CN")
    value.timeZone = WorkdayTimeline.calendar.timeZone
    value.dateFormat = format
    return value
  }
  static let minutes = formatter("HH:mm")
  static let seconds = formatter("HH:mm:ss")
  static func day(_ date: Date, relativeTo now: Date) -> String {
    WorkdayTimeline.calendar.isDate(date, inSameDayAs: now) ? "今天" : "昨天"
  }
}

struct CaptionTimeRuler: View {
  let window: CaptionWindow
  let records: ArraySlice<CaptionRecord>
  let selected: ClosedRange<Date>?
  let select: (ClosedRange<Date>) -> Void
  @State private var drag: RangeDrag?

  private struct RangeDrag {
    enum Origin {
      case track(Date)
      case handle(CaptionRangeEdge, offset: CGFloat)
    }

    let window: CaptionWindow
    let initialRange: ClosedRange<Date>
    let origin: Origin
    var preview: ClosedRange<Date>
    var pointerX: CGFloat

    mutating func update(x: CGFloat, inset: CGFloat, width: CGFloat) {
      pointerX = x
      switch origin {
      case .track(let start):
        let end = CaptionWindow.minute(window.time(atRulerFraction: (x - inset) / width))
        preview = min(start, end)...max(start, end)
      case .handle(let edge, let offset):
        let fraction = (x - offset - inset) / width
        var time = window.time(atRulerFraction: fraction)
        // The right boundary represents the end of the inclusive minute.
        if edge == .end && fraction < 1 { time = time.addingTimeInterval(-0.001) }
        preview = window.moving(edge, to: time, in: initialRange)
      }
    }
  }

  private var range: ClosedRange<Date> { drag?.preview ?? window.selection(selected) }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Text("最近 24 小时").font(.subheadline.weight(.semibold))
        Spacer(minLength: 4)
        clock(.start, time: range.lowerBound)
        Text("至").foregroundStyle(Palette.muted)
        clock(.end, time: range.upperBound)
      }.font(.callout)
      GeometryReader { geo in
        let inset: CGFloat = 34
        let width = max(1, geo.size.width - 2 * inset)
        let left = inset + width * window.rulerFraction(for: range.lowerBound)
        let right = range.upperBound == window.minutes.upperBound
          ? inset + width : inset + width * window.rulerFraction(for: range.upperBound.addingTimeInterval(60))
        ZStack(alignment: .topLeading) {
          ForEach(0...4, id: \.self) { index in
            let date = window.time(atRulerFraction: Double(index) / 4)
            let prefix = index == 0 ? CaptionTime.day(date, relativeTo: window.now) + " " : index == 4 ? "现在 " : ""
            Text(prefix + CaptionTime.minutes.string(from: date))
              .font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
              .fixedSize().position(x: inset + width * CGFloat(index) / 4, y: 9)
          }
          track(inset: inset, width: width, left: left, right: right)
          // The grips sit outside the band so both remain visible even for a single minute.
          grip(at: left - 3, edge: .start)
          grip(at: right + 3, edge: .end)
          if let drag {
            let count = records.firstIndex(atOrAfter: range.upperBound.addingTimeInterval(60))
              - records.firstIndex(atOrAfter: range.lowerBound)
            Text("\(CaptionTime.minutes.string(from: range.lowerBound))–\(CaptionTime.minutes.string(from: range.upperBound)) · \(count) 句")
              .font(.caption.monospacedDigit()).fixedSize()
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(Palette.surface, in: Capsule())
              .position(x: min(max(76, drag.pointerX), geo.size.width - 76), y: 10)
              .allowsHitTesting(false)
          }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 3).onChanged { event in
          let x = event.startLocation.x
          let edge: CaptionRangeEdge = x <= (left + right) / 2 ? .start : .end
          let boundary = edge == .start ? left : right
          let origin: RangeDrag.Origin
          if event.startLocation.y >= 20 && abs(x - boundary) <= 10 {
            origin = .handle(edge, offset: x - boundary)
          } else {
            origin = .track(CaptionWindow.minute(window.time(atRulerFraction: (x - inset) / width)))
          }
          var active = drag ?? RangeDrag(window: window, initialRange: range, origin: origin,
                                         preview: range, pointerX: x)
          active.update(x: event.location.x, inset: inset, width: width)
          drag = active
        }.onEnded { event in
          guard var active = drag else { return }
          active.update(x: event.location.x, inset: inset, width: width)
          drag = nil
          select(active.preview)
        })
        .accessibilityHidden(true) // Both bounds are editable using the native time fields.
      }.frame(height: 46)
      HStack(spacing: 4) {
        Rectangle().fill(Palette.muted).frame(width: 1, height: 7)
        Text("有字幕")
        Spacer()
        Text("拖动划选时段，拖动两端微调")
      }.font(.caption2).foregroundStyle(Palette.muted)
    }.accessibilityIdentifier("live-time-range")
  }

  private func clock(_ edge: CaptionRangeEdge, time: Date) -> some View {
    HStack(spacing: 4) {
      Text(CaptionTime.day(time, relativeTo: window.now)).foregroundStyle(Palette.muted)
      DatePicker(edge == .start ? "开始时间" : "结束时间", selection: Binding(
        get: { time },
        set: { value in
          let date = window.resolve(clock: value, near: time)
          select(window.moving(edge, to: date, in: selected))
        }), displayedComponents: .hourAndMinute)
        .labelsHidden().controlSize(.small).fixedSize()
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .environment(\.timeZone, WorkdayTimeline.calendar.timeZone)
        .accessibilityIdentifier(edge == .start ? "live-range-start" : "live-range-end")
    }
  }

  private func grip(at x: CGFloat, edge: CaptionRangeEdge) -> some View {
    RoundedRectangle(cornerRadius: 2)
      .fill(Palette.accent)
      .overlay { Capsule().fill(Palette.surface).frame(width: 1, height: 9) }
      .frame(width: 6, height: 20).position(x: x, y: 34)
      .help(edge == .start ? "拖动开始时间" : "拖动结束时间")
  }

  private func track(inset: CGFloat, width: CGFloat, left: CGFloat, right: CGFloat) -> some View {
    Canvas { canvas, _ in
      let y: CGFloat = 40
      canvas.fill(Path(CGRect(x: left, y: y - 14, width: max(1, right - left), height: 14)),
                  with: .color(Palette.selected))
      var ticks = Path()
      ticks.move(to: CGPoint(x: inset, y: y))
      ticks.addLine(to: CGPoint(x: inset + width, y: y))
      for index in 0...8 {
        let x = inset + width * CGFloat(index) / 8
        ticks.move(to: CGPoint(x: x, y: y))
        ticks.addLine(to: CGPoint(x: x, y: y - (index.isMultiple(of: 2) ? 10 : 5)))
      }
      canvas.stroke(ticks, with: .color(Palette.muted.opacity(0.4)), lineWidth: 1)
      var marks = Path()
      var previousX: CGFloat = -2
      for line in records {
        let x = inset + width * window.rulerFraction(for: line.time)
        if x - previousX < 1 { continue }
        marks.move(to: CGPoint(x: x, y: y))
        marks.addLine(to: CGPoint(x: x, y: y - 7))
        previousX = x
      }
      canvas.stroke(marks, with: .color(Palette.muted), lineWidth: 1)
      var band = Path()
      band.move(to: CGPoint(x: left, y: y))
      band.addLine(to: CGPoint(x: right, y: y))
      canvas.stroke(band, with: .color(Palette.accent), lineWidth: 2)
    }
  }
}
