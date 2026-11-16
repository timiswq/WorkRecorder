import XCTest

@testable import WiFiRecorderCore

final class NetworkGateTests: XCTestCase {
  func testOfficeWifiDoesNotReachRecorder() {
    let links = [IPv4Link(interface: "en0", address: "172.16.70.248", netmask: "255.255.252.0")]
    XCTAssertNil(DeviceNetworkGate.select(links, wifiInterfaces: ["en0"], target: "192.168.200.1"))
  }
  func testDeviceSubnetSelectsWifiEvenWithVPNAndEthernet() {
    let links = [
      IPv4Link(interface: "utun5", address: "198.19.0.1", netmask: "255.255.255.0"),
      IPv4Link(interface: "en12", address: "172.16.14.46", netmask: "255.255.255.0"),
      IPv4Link(interface: "en0", address: "192.168.200.2", netmask: "255.255.255.0"),
    ]
    XCTAssertEqual(
      DeviceNetworkGate.select(links, wifiInterfaces: ["en0"], target: "192.168.200.1")?.address,
      "192.168.200.2")
  }
  func testEthernetOnDeviceSubnetDoesNotMasqueradeAsWifi() {
    let links = [
      IPv4Link(interface: "en0", address: "172.16.70.248", netmask: "255.255.252.0"),
      IPv4Link(interface: "en12", address: "192.168.200.2", netmask: "255.255.255.0"),
    ]
    XCTAssertNil(DeviceNetworkGate.select(links, wifiInterfaces: ["en0"], target: "192.168.200.1"))
  }
  func testInvalidAndUnconfiguredAddressesFailClosed() {
    for (ip, mask) in [
      ("169.254.12.3", "255.255.0.0"), ("192.168.200.2", "0.0.0.0"),
      ("192.168.200.2", "255.0.255.0"), ("192.168.200.1", "255.255.255.0"),
      ("999.168.200.2", "255.255.255.0"),
    ] {
      XCTAssertNil(
        DeviceNetworkGate.select(
          [IPv4Link(interface: "en0", address: ip, netmask: mask)], wifiInterfaces: ["en0"],
          target: "192.168.200.1"))
    }
  }
}
