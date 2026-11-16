import CoreLocation
import CoreWLAN
import Foundation
import WiFiRecorderCore

enum WifiJoinError: LocalizedError {
  case locationRequired, cancelled
  case message(String)
  var errorDescription: String? {
    switch self {
    case .locationRequired: return "macOS需要定位授权才能识别Wi-Fi热点。授权后将自动继续连接，不读取地理坐标。"
    case .cancelled: return "连接已取消"
    case .message(let text): return text
    }
  }
}

/// Passwords stay in memory and are passed only to the native association API.
final class WifiJoiner: NSObject, CLLocationManagerDelegate {
  var permissionChanged: (Bool) -> Void = { _ in }
  private let worker = DispatchQueue(label: "WorkRecorder.wifi-join", qos: .userInitiated)
  private let lock = NSLock()
  private var generation = UUID()
  private var locationManager: CLLocationManager?
  private var previousSSID: String?
  private var targetSSID: String?
  private var changedAssociation = false
  private var interfaceName: String?

  func requestLocationPermission() {
    let manager = locationManager ?? CLLocationManager()
    locationManager = manager
    manager.delegate = self
    switch manager.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse: permissionChanged(true)
    case .notDetermined: manager.requestWhenInUseAuthorization()
    default: permissionChanged(false)
    }
  }
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    switch manager.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse: permissionChanged(true)
    case .denied, .restricted: permissionChanged(false)
    default: break
    }
  }
  private func token() -> UUID {
    lock.lock()
    defer { lock.unlock() }
    generation = UUID()
    return generation
  }
  private func valid(_ token: UUID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return generation == token
  }
  func cancel() { _ = token() }

  func join(
    _ credentials: HotspotCredentials, completion: @escaping (Result<String, Error>) -> Void
  ) {
    let manager = locationManager ?? CLLocationManager()
    locationManager = manager
    switch manager.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse: break
    default:
      completion(.failure(WifiJoinError.locationRequired))
      return
    }
    let token = token()
    worker.async { [weak self] in
      guard let self else { return }
      do {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else {
          throw WifiJoinError.message("Mac Wi-Fi未开启或不可用")
        }
        let ssid = credentials.ssid
        let ssidData = Data(ssid.utf8)
        guard let name = interface.interfaceName else {
          throw WifiJoinError.message("无法识别 Wi-Fi 接口")
        }
        self.interfaceName = name
        if self.targetSSID == nil { self.targetSSID = ssid }
        if self.previousSSID == nil, let previous = interface.ssid(), previous != ssid {
          self.previousSSID = previous
        }
        if interface.ssidData() == ssidData,
          WifiNetworkInspector.read(interfaceName: name).recorderLink != nil
        {
          DispatchQueue.main.async { if self.valid(token) { completion(.success(name)) } }
          return
        }
        let limit = Date().addingTimeInterval(45)
        var joined = false
        while Date() < limit && self.valid(token) {
          let networks = try interface.scanForNetworks(withSSID: ssidData)
          if !networks.isEmpty, networks.allSatisfy({ $0.ssidData == nil }) {
            throw WifiJoinError.locationRequired
          }
          if let network = networks.filter({ $0.ssidData == ssidData }).max(by: {
            $0.rssiValue < $1.rssiValue
          }) {
            guard network.supportsSecurity(.wpa2Personal) || network.supportsSecurity(.wpa3Personal)
            else { throw WifiJoinError.message("设备热点安全类型与预期不符，未提交密码") }
            if let previous = self.previousSSID, let current = interface.ssid(),
              current != previous && current != ssid
            {
              throw WifiJoinError.message("Wi-Fi 已切换，已保留当前网络。")
            }
            guard self.valid(token) else { throw WifiJoinError.cancelled }
            do {
              try interface.associate(to: network, password: credentials.password)
              self.changedAssociation = true
            } catch {
              throw WifiJoinError.message("系统未能连接设备热点（CoreWLAN \((error as NSError).code)）")
            }
            joined = true
            break
          }
          Thread.sleep(forTimeInterval: 1)
        }
        guard self.valid(token) else { throw WifiJoinError.cancelled }
        guard joined else { throw WifiJoinError.message("未找到当前录音卡热点，请检查设备是否保持开机") }
        let addressLimit = Date().addingTimeInterval(20)
        while Date() < addressLimit && self.valid(token) {
          if interface.ssidData() == ssidData,
            WifiNetworkInspector.read(interfaceName: name).recorderLink != nil
          {
            DispatchQueue.main.async {
              if self.valid(token) {
                completion(.success(name))
              }
            }
            return
          }
          Thread.sleep(forTimeInterval: 0.3)
        }
        throw WifiJoinError.message("已尝试关联热点，但未取得正确设备地址")
      } catch {
        DispatchQueue.main.async { if self.valid(token) { completion(.failure(error)) } }
      }
    }
  }

  /// Rejoin only the prior saved network; never reads or exports its Keychain password.
  func restore(completion: @escaping (String) -> Void) {
    let token = token()
    worker.async { [weak self] in
      guard let self else { return }
      defer {
        self.previousSSID = nil
        self.targetSSID = nil
        self.changedAssociation = false
      }
      guard self.valid(token) else { return }
      guard self.changedAssociation, let target = self.targetSSID,
        let name = self.interfaceName,
        let interface = CWWiFiClient.shared().interface(withName: name)
      else {
        DispatchQueue.main.async { completion("已结束热点连接流程。") }
        return
      }
      guard interface.powerOn() else {
        DispatchQueue.main.async { completion("Wi-Fi 已关闭。") }
        return
      }
      guard let previous = self.previousSSID else {
        if interface.ssid() == target { interface.disassociate() }
        DispatchQueue.main.async { completion("系统将自动选择已保存的网络。") }
        return
      }
      let current = interface.ssid()
      guard current == nil || current == target || current == previous else {
        DispatchQueue.main.async { completion("检测到Wi-Fi已由用户切换，保留当前网络") }
        return
      }
      if current == previous {
        DispatchQueue.main.async { completion("已恢复原来的Wi-Fi网络") }
        return
      }
      // Release the explicitly selected card network so macOS can auto-join a saved network.
      if current == target { interface.disassociate() }
      let autoJoinLimit = Date().addingTimeInterval(20)
      while Date() < autoJoinLimit && self.valid(token) {
        if interface.ssid() == previous {
          DispatchQueue.main.async { completion("已恢复原来的Wi-Fi网络") }
          return
        }
        if let chosen = interface.ssid(), chosen != target, chosen != previous {
          DispatchQueue.main.async { completion("系统已连接另一个已知网络，保留当前网络") }
          return
        }
        Thread.sleep(forTimeInterval: 0.3)
      }
      guard self.valid(token) else { return }
      if let chosen = interface.ssid(), chosen != target, chosen != previous {
        DispatchQueue.main.async { completion("检测到Wi-Fi已切换，保留当前网络") }
        return
      }
      guard interface.powerOn() else {
        DispatchQueue.main.async { completion("Wi-Fi已关闭，保留当前设置；录音已保存") }
        return
      }
      DispatchQueue.main.async { completion("原 Wi-Fi 尚未恢复，可在系统 Wi-Fi 设置中重新连接。") }
    }
  }
}
