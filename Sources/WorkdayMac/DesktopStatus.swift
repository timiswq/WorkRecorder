import Foundation
import WorkdayCore

enum CardConnectionPhase { case disconnected, searching, connecting, connected, unavailable, usb }

struct DesktopStatus: Equatable {
  enum Kind: CaseIterable {
    case disconnected, connecting, unknown, idle, recording, paused, saving, usb, syncing
  }
  let kind: Kind
  let title: String
  let detail: String
  var warning = false

  static func resolve(
    card: CardState, connection: CardConnectionPhase, usbConnected: Bool = false,
    importLabel: String? = nil, transcriptionFailed: Bool = false, now: Date = Date()
  ) -> DesktopStatus {
    if usbConnected {
      if let importLabel {
        return .init(kind: .syncing, title: "USB 同步中", detail: importLabel)
      }
      return .init(kind: .usb, title: "USB 已连接", detail: "蓝牙监听暂歇，原件通过 USB 同步")
    }
    guard card.connected else {
      let detail =
        card.confirmedAt.map {
          "最后确认：\(phaseTitle(card.phase)) · \($0.formatted(date: .omitted, time: .shortened))"
        } ?? "尚未获取设备状态"
      if connection == .searching || connection == .connecting {
        return .init(kind: .connecting, title: "正在连接录音卡", detail: detail)
      }
      return .init(
        kind: .disconnected, title: "录音卡未连接", detail: detail,
        warning: connection == .unavailable)
    }
    guard card.isFresh(at: now) else {
      return .init(kind: .unknown, title: "正在确认设备状态", detail: "蓝牙已连接，等待新的设备状态")
    }
    let kind: Kind
    switch card.phase {
    case .unknown: kind = .unknown
    case .idle: kind = .idle
    case .recording: kind = .recording
    case .paused: kind = .paused
    case .saving: kind = .saving
    }
    return .init(
      kind: kind, title: phaseTitle(card.phase),
      detail: transcriptionFailed ? "实时转写异常 · 设备状态独立更新" : "蓝牙已连接",
      warning: transcriptionFailed)
  }

  private static func phaseTitle(_ phase: CardState.Phase) -> String {
    switch phase {
    case .unknown: return "状态待确认"
    case .idle: return "设备待机"
    case .recording: return "正在录音"
    case .paused: return "录音已暂停"
    case .saving: return "设备正在保存"
    }
  }
}
