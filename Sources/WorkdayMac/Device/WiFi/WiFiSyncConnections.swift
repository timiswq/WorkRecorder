import Foundation
import WiFiRecorderCore

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
  func queryWiFiState()
  func openWiFiHotspot(for id: String)
  func releaseForWiFi()
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
