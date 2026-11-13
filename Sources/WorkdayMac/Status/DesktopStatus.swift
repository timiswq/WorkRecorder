import Foundation
import WorkdayCore

enum CardConnectionPhase { case disconnected, searching, connecting, connected, unavailable, usb }

enum BluetoothBlock {
  case poweredOff, unauthorized, unsupported, preparing

  var title: String {
    switch self {
    case .poweredOff: return "Mac 蓝牙已关闭"
    case .unauthorized: return "未获蓝牙权限"
    case .unsupported: return "此 Mac 不支持蓝牙"
    case .preparing: return "蓝牙准备中"
    }
  }
  var instruction: String {
    switch self {
    case .poweredOff: return "在系统设置的「蓝牙」中打开蓝牙。"
    case .unauthorized: return "在系统设置的「隐私与安全性 → 蓝牙」中允许「工作留声」访问蓝牙。"
    case .unsupported: return "可用 USB 连接录音卡，导入已保存的录音。"
    case .preparing: return "请稍候，蓝牙就绪后会更新连接状态。"
    }
  }
  var usesSettings: Bool { self == .poweredOff || self == .unauthorized }
}

struct DesktopStatus: Equatable {
  enum Kind: CaseIterable {
    case disconnected, connecting, unknown, idle, recording, paused, saving, usb
  }
  static let usbRecordingHint = "实时字幕暂停"
  let kind: Kind
  let title: String
  let detail: String
  var warning = false
  var bluetoothBlock: BluetoothBlock?
  var elapsed: Double?
  var battery: Int?

  var canConnect: Bool { kind == .disconnected && bluetoothBlock == nil }
  var isUSB: Bool { kind == .usb }

  var instruction: String {
    if let bluetoothBlock { return bluetoothBlock.instruction }
    switch kind {
    case .idle: return "在录音卡上按键开始录音。"
    case .recording: return "可查看实时字幕；暂停或结束录音请在卡上操作。"
    case .paused: return "在卡上继续录音，或结束并保存这段录音。"
    case .saving: return "正在保存到录音卡，等待卡上确认完成。"
    case .usb:
      return "卡上是否仍在录音请看卡上指示。完成文件操作并在访达中推出 USB 磁盘后，可断开 USB，重新通过蓝牙接收字幕。"
    case .unknown: return "正在等待设备回复；请查看卡上指示，不能据此判断录音已经停止。"
    case .connecting: return "请保持录音卡开启并靠近 Mac。连接成功后会自动更新状态。"
    case .disconnected: return "连接后可查看录音状态和实时字幕；已有的本地录音仍可查看。"
    }
  }

  static func resolve(
    card: CardState, connection: CardConnectionPhase, usbConnected: Bool = false,
    bluetoothBlock: BluetoothBlock? = nil, now: Date = Date()
  ) -> DesktopStatus {
    if usbConnected {
      return .init(kind: .usb, title: "USB 文件连接",
                   detail: "实时字幕暂停；USB 无法确认卡上是否正在录音。")
    }
    if let bluetoothBlock {
      return .init(kind: .disconnected, title: bluetoothBlock.title, detail: bluetoothBlock.instruction,
                   warning: bluetoothBlock != .preparing, bluetoothBlock: bluetoothBlock)
    }
    guard card.connected else {
      let detail =
        card.confirmedAt.map {
          "最后确认：\(phaseTitle(card.phase)) · \($0.formatted(date: .omitted, time: .shortened))"
        } ?? "尚未获取设备状态"
      if connection == .searching || connection == .connecting {
        let title = connection == .searching ? "正在寻找录音卡" : "正在连接录音卡"
        return .init(kind: .connecting, title: title, detail: detail)
      }
      return .init(
        kind: .disconnected, title: "录音卡未连接", detail: detail,
        warning: connection == .unavailable)
    }
    let battery = card.currentBattery(at: now)
    guard card.isFresh(at: now) else {
      return .init(kind: .unknown, title: "录音状态待确认", detail: "蓝牙已连接，等待新的设备状态",
                   battery: battery)
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
      detail: "蓝牙已连接", elapsed: card.currentDuration(at: now), battery: battery)
  }

  private static func phaseTitle(_ phase: CardState.Phase) -> String {
    switch phase {
    case .unknown: return "录音状态待确认"
    case .idle: return "未录音"
    case .recording: return "正在录音"
    case .paused: return "录音已暂停"
    case .saving: return "正在保存录音"
    }
  }
}

extension AppModel {
  func deviceStatus(at date: Date) -> DesktopStatus {
    let status = DesktopStatus.resolve(
      card: card.state, connection: card.connectionPhase,
      usbConnected: !usb.volumes.isEmpty,
      bluetoothBlock: card.bluetoothBlock, now: date)
    if status.canConnect && preferences.boundID == nil {
      return .init(kind: .disconnected, title: "尚未绑定录音卡", detail: "绑定后可查看录音状态和实时字幕。")
    }
    return status
  }

}
