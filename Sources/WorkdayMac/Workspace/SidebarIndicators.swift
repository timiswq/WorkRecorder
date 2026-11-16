import SwiftUI

enum DaySidebarState: Equatable { case none, working, updated, failed }

extension AppModel {
  var daySidebarState: DaySidebarState {
    if !dayUpdates.unseenDays.isEmpty { return .updated }
    if processingID != nil { return .working }
    if !summaryErrors.isEmpty || documents.values.contains(where: { $0.error != nil }) {
      return .failed
    }
    return .none
  }
}

struct PendingSyncBadge: View {
  let model: AppModel
  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { _ in
      if let text = model.pendingSyncBadgeText {
        Text(text)
          .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
          .foregroundStyle(Palette.text)
          .padding(.horizontal, 4).frame(minWidth: 18, minHeight: 16)
          .background(Palette.line.opacity(0.65), in: Capsule())
          .help(model.pendingSyncBadgeHint ?? "待同步录音")
          .accessibilityLabel(model.pendingSyncBadgeHint ?? "待同步录音")
      }
    }.frame(width: 22, height: 18)
  }
}

struct SidebarLiveIndicator: View {
  let model: AppModel
  @ObservedObject var meter: LiveAudioMeter
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.5)) { context in
      // Audio can arrive between timeline ticks; its timestamp must not look "in the future".
      let now = max(context.date, Date())
      let status = model.deviceStatus(at: now)
      let state = LiveSidebarState.resolve(status: status, sample: meter.sample, now: now)
      artwork(state).frame(width: 22, height: 18)
        .help(
          status.kind == .usb || status.kind == .disconnected
            ? status.title + " · " + status.instruction : state.description
        )
        .accessibilityLabel(state.description)
    }
  }

  @ViewBuilder private func artwork(_ state: LiveSidebarState) -> some View {
    switch state {
    case .level(let count):
      HStack(spacing: 2) {
        ForEach(0..<4) { index in
          RoundedRectangle(cornerRadius: 0.8)
            .fill(.foreground.opacity(index < count ? 1 : 0.10))
            .overlay(
              RoundedRectangle(cornerRadius: 0.8).stroke(.foreground.opacity(0.40), lineWidth: 0.7)
            )
            .frame(width: 4, height: 5)
        }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: count)
    case .idle: Image(systemName: "text.bubble")
    case .paused: Image(systemName: "pause.fill")
    case .noAudio: Image(systemName: "minus").foregroundStyle(Palette.muted)
    case .saving, .connecting: ProgressView().controlSize(.mini)
    case .unknown: Image(systemName: "questionmark.bubble").foregroundStyle(Palette.muted)
    }
  }
}
