import SwiftUI
import WorkdayCore

/// Separate native toolbar items keep hardware on the leading side and Mac tasks on the trailing side.
struct DeviceStatusBar: View {
  enum Component { case hardware, activity }
  @ObservedObject var model: AppModel
  @ObservedObject var desktop: DesktopCompanion
  let component: Component
  @State private var showsActivity = false

  var body: some View {
    let presentation = model.statusPresentation(at: Date())
    Group {
      switch component {
      case .hardware:
        hardware(presentation)
          .onAppear { model.card.monitorsWindowBattery = true }
          .onDisappear { model.card.monitorsWindowBattery = false }
      case .activity:
        activity(presentation)
      }
    }.font(.system(size: 12))
  }

  private func hardware(_ presentation: StatusPresentation) -> some View {
    let status = presentation.hardware
    return HStack(spacing: 10) {
      hardwareButton(status)
      if !status.isUSB, let battery = status.battery {
        Divider().frame(height: 13)
        batteryLabel(battery)
      }
    }.fixedSize().frame(width: 300, height: 24, alignment: .leading)
      .accessibilityElement(children: .contain).accessibilityIdentifier("workspace-hardware-status")
      .help(status.detail + "\n" + status.instruction)
  }

  // Keep each builder small enough for the Xcode 26.2 SwiftUI type checker.
  private func hardwareButton(_ status: DesktopStatus) -> some View {
    let elapsed = status.elapsed.map { "，已录 " + WorkdayDate.clock($0) } ?? ""
    let accessibility = "录音卡：" + status.title + elapsed + "，查看设备详情"
    return Button {
      model.area = .device
    } label: {
      hardwareLabel(status)
    }.buttonStyle(.plain).help("查看录音卡详情")
      .accessibilityLabel(accessibility)
      .accessibilityHint(status.instruction)
  }

  private func hardwareLabel(_ status: DesktopStatus) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "externaldrive").foregroundStyle(Palette.muted)
      Text("录音卡").foregroundStyle(Palette.muted)
      Image(systemName: StatusStyle.symbol(status.kind))
        .foregroundStyle(StatusStyle.color(status)).accessibilityHidden(true)
      Text(status.title).fontWeight(.semibold).foregroundStyle(StatusStyle.color(status))
      if let seconds = status.elapsed {
        Text(WorkdayDate.clock(seconds)).monospacedDigit().foregroundStyle(StatusStyle.color(status))
      } else if status.kind == .recording || status.kind == .paused {
        Text("时长待更新").foregroundStyle(Palette.muted)
      }
    }
  }

  private func batteryLabel(_ battery: Int) -> some View {
    let charging = model.card.state.charging
    let level = min(100, max(0, (battery + 12) / 25 * 25))
    return Label(
      charging ? "充电中" : "电量 \(battery)%",
      systemImage: "battery.\(level)percent"
    ).labelStyle(.titleAndIcon)
      .monospacedDigit().foregroundStyle(battery <= 10 ? Palette.amber : Palette.muted)
      .accessibilityLabel(charging ? "录音卡充电中" : "录音卡电量百分之\(battery)")
  }

  private func activity(_ presentation: StatusPresentation) -> some View {
    Button {
      showsActivity.toggle()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: presentation.attention.isEmpty ? "list.bullet" : "exclamationmark.circle")
        Text("Mac · " + presentation.summary).lineLimit(1)
        Image(systemName: "chevron.down").font(.system(size: 9))
      }.foregroundStyle(presentation.attention.isEmpty ? Palette.muted : Palette.amber)
    }.buttonStyle(.plain).frame(width: 190, alignment: .trailing)
      .help("Mac · " + presentation.summary)
      .accessibilityIdentifier("workspace-app-status")
      .popover(isPresented: $showsActivity) {
        ScrollView { AppActivityList(model: model, desktop: desktop).padding(18) }
          .frame(width: 360).frame(maxHeight: 480)
      }
  }
}
