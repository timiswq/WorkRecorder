import Foundation

public struct IPv4Link: Equatable {
  public let interface: String
  public let address: String
  public let netmask: String
  public init(interface: String, address: String, netmask: String) {
    self.interface = interface
    self.address = address
    self.netmask = netmask
  }
}
public enum DeviceNetworkGate {
  public static func select(
    _ links: [IPv4Link], wifiInterfaces: Set<String>, target: String = "192.168.200.1"
  ) -> IPv4Link? {
    guard let host = ipv4(target) else { return nil }
    return links.first { link in
      guard wifiInterfaces.contains(link.interface), let ip = ipv4(link.address),
        let mask = ipv4(link.netmask), mask != 0, ip != host
      else { return false }
      let inverse = ~mask
      guard inverse & (inverse &+ 1) == 0 else { return false }
      return ip & mask == host & mask
    }
  }
  private static func ipv4(_ text: String) -> UInt32? {
    let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
    guard pieces.count == 4 else { return nil }
    var value: UInt32 = 0
    for piece in pieces {
      guard !piece.isEmpty, piece.allSatisfy({ $0.isASCII && $0.isNumber }), let byte = UInt8(piece)
      else { return nil }
      value = (value << 8) | UInt32(byte)
    }
    return value
  }
}
