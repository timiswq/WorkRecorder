import Foundation

/// Carries the exact source ID through a menu or button's lifetime, even if selection changes.
enum RecorderSyncTarget: Equatable {
  case wifi(String), usb(String)
}

extension AppModel {
  var connectedRecorderName: String? {
    if !usesWiFiCard, let volume = usb.volumes.first { return volume.name }
    if card.state.connected { return card.name }
    if usesWiFiCard, let id = wifiSync.connectedDeviceID, id == preferences.wifiBoundID {
      return preferences.selectedRecorderName
    }
    return nil
  }

  var recorderSidebarTitle: String { connectedRecorderName ?? "录音卡" }

  var recorderName: String? {
    if let choice = card.switchingTo { return choice.name }
    if let connectedRecorderName { return connectedRecorderName }
    if preferences.selectedRecorderID != nil { return preferences.selectedRecorderName }
    if !usesWiFiCard, let id = preferences.usbOnlyVolumeID {
      return preferences.usbOnlyVolumeName ?? "USB 录音卡 · \(id.suffix(4))"
    }
    return nil
  }

  func recorderConnectionDetail(_ status: DesktopStatus) -> String {
    if status.isUSB { return "USB 已连接" }
    if wifiSync.usingNetwork { return "Wi-Fi 同步" }
    if card.switchingTo != nil { return status.detail }
    if !card.state.connected {
      return !usesWiFiCard && preferences.usbOnlyVolumeID != nil ? "USB 未连接" : "蓝牙未连接"
    }
    var parts = ["蓝牙已连接"]
    if let battery = status.battery {
      parts.append((card.state.charging ? "充电中 " : "电量 ") + "\(battery)%")
    }
    return parts.joined(separator: " · ")
  }

  var recorderSyncTarget: RecorderSyncTarget? {
    guard card.switchingTo == nil, !wifiSync.busy else { return nil }
    if usesWiFiCard {
      if card.state.isFresh(), [.recording, .paused, .saving].contains(card.state.phase) { return nil }
      guard !sync.isBusy, let id = preferences.wifiBoundID, card.boundID == id,
            card.bluetoothBlock == nil else { return nil }
      return .wifi(id)
    }
    guard let volume = usb.volumes.first, !usb.needsSaveConfirmation else { return nil }
    if sync.activeFile != nil || sync.cleaningFile != nil {
      guard cardSyncFailure?.action == .retry else { return nil }
    }
    return .usb(volume.id)
  }

  func showRecorderPicker() {
    guard canChangeCard else { return }
    area = .device
    showsRecorderPicker = true
  }

  @discardableResult func chooseRecorder(_ choice: CardChoice) -> Bool {
    guard canChangeCard, !isolated else { return false }
    card.switchConnection(to: choice)
    guard card.switchingTo != nil else { return false }
    usb.select(nil)
    return true
  }

  /// Explicitly switching to a disk is distinct from associating it with a Bluetooth identity.
  @discardableResult func chooseRecorder(_ volume: USBVolume) -> Bool {
    guard canChangeCard, usb.mountedVolume(withID: volume.id) == volume else { return false }
    card.disconnect()
    selectUSB(volume, associateWithBoundCard: false)
    return usb.volumes.contains(volume)
  }
}
