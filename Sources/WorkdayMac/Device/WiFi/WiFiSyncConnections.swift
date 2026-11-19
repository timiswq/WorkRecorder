import Foundation
import WiFiRecorderCore
import WorkdayCore

/// The sync coordinator owns timing; Bluetooth callbacks always belong to the selected peripheral.
protocol WiFiSyncBluetooth: AnyObject {
  var preferredKind: RecorderKind { get }
  var boundID: String? { get }
  var wifiBusy: Bool { get set }
  var holdReconnect: Bool { get set }
  var onWiFiState: ((UInt8) -> Void)? { get set }
  var onHotspot: ((HotspotCredentials) -> Void)? { get set }
  var onSocket: (() -> Void)? { get set }
  var onWiFiLost: (() -> Void)? { get set }
  var onWiFiFilePacket: ((Packet) -> Void)? { get set }
  func queryWiFiState()
  func openWiFiHotspot(for id: String)
  func releaseForWiFi()
  @MainActor func readWiFiFileList(for id: String, duringSync: Bool) async throws -> [RecordingEntry]
  func deleteWiFiFile(_ file: RecordingEntry, from id: String) -> Bool
}

extension CardObserver: WiFiSyncBluetooth {
  func queryWiFiState() {
    if let session = wifiSession, state.connected {
      session.queryState()
    } else {
      activate(.reconnectBound)
    }
  }
  func openWiFiHotspot(for id: String) {
    guard let session = wifiSession, session.peripheral.identifier.uuidString == id else { return }
    session.openHotspot()
  }
  @MainActor func readWiFiFileList(for id: String, duringSync: Bool) async throws -> [RecordingEntry] {
    guard let session = wifiSession, session.peripheral.identifier.uuidString == id else {
      throw WorkdayError.invalid("录音卡蓝牙未连接")
    }
    return try await session.readFileList {
      self.wifiSession === session && self.boundID == id && self.switchingTo == nil
        && self.wifiBusy == duringSync && self.state.connected
        && self.state.phase == .idle && self.state.isFresh()
    }
  }
  func deleteWiFiFile(_ file: RecordingEntry, from id: String) -> Bool {
    guard wifiBusy, state.connected, state.phase == .idle, state.isFresh(), boundID == id,
      let session = wifiSession, session.peripheral.identifier.uuidString == id
    else { return false }
    return session.deleteFile(file)
  }
}

protocol WiFiHotspotJoining: AnyObject {
  var permissionChanged: (Bool) -> Void { get set }
  func join(
    _ credentials: HotspotCredentials, completion: @escaping (Result<String, Error>) -> Void)
  func restore(completion: @escaping (String) -> Void)
  func requestLocationPermission()
  func cancel()
}

extension WifiJoiner: WiFiHotspotJoining {}
