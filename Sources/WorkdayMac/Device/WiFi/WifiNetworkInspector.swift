import Darwin
import Foundation
import SystemConfiguration
import WiFiRecorderCore

struct WifiNetworkSnapshot {
  let wifiNames: Set<String>
  let links: [IPv4Link]
  let recorderLink: IPv4Link?
  func message(ssid: String? = nil) -> String {
    if let link = recorderLink { return "Wi-Fi已取得设备网段地址：\(link.interface) · \(link.address)" }
    let target = ssid ?? "录音卡热点"
    let actual = links.filter { wifiNames.contains($0.interface) }.map {
      "\($0.interface) · \($0.address)"
    }.joined(separator: ", ")
    if wifiNames.isEmpty { return "未发现Wi-Fi接口；请检查Mac Wi-Fi是否开启" }
    if actual.isEmpty { return "Wi-Fi尚未取得IPv4地址；请在系统设置连接 \(target)，等待分配设备网段地址" }
    return "当前Wi-Fi：\(actual)，不在设备网段。请在系统设置连接 \(target)（通常为192.168.200.x）"
  }
}
enum WifiNetworkInspector {
  static func read(target: String = "192.168.200.1", interfaceName: String? = nil)
    -> WifiNetworkSnapshot
  {
    let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
    let names = Set(
      all.compactMap { iface -> String? in
        guard SCNetworkInterfaceGetInterfaceType(iface) == kSCNetworkInterfaceTypeIEEE80211 else {
          return nil
        }
        return SCNetworkInterfaceGetBSDName(iface) as String?
      })
    var pointer: UnsafeMutablePointer<ifaddrs>?
    var links: [IPv4Link] = []
    if getifaddrs(&pointer) == 0 {
      defer { freeifaddrs(pointer) }
      var cursor = pointer
      while let entry = cursor {
        let value = entry.pointee
        cursor = value.ifa_next
        guard value.ifa_flags & UInt32(IFF_UP) != 0, let address = value.ifa_addr,
          address.pointee.sa_family == sa_family_t(AF_INET), let mask = value.ifa_netmask
        else { continue }
        if let ip = numeric(address), let netmask = numeric(mask) {
          links.append(
            IPv4Link(interface: String(cString: value.ifa_name), address: ip, netmask: netmask))
        }
      }
    }
    return WifiNetworkSnapshot(
      wifiNames: names, links: links,
      recorderLink: DeviceNetworkGate.select(
        links, wifiInterfaces: interfaceName.map { names.intersection([$0]) } ?? names,
        target: target))
  }
  private static func numeric(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
    var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard
      getnameinfo(
        address, socklen_t(address.pointee.sa_len), &text, socklen_t(text.count), nil, 0,
        NI_NUMERICHOST) == 0
    else { return nil }
    return String(cString: text)
  }
}
