import Combine
import CoreBluetooth
import QS668Core
import WiFiRecorderCore

extension CardChoice {
  init(peripheral: CBPeripheral, advertisement: [String: Any], rssi: Int, previous: CardChoice?) {
    let name = advertisement[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "AI 录音卡"
    let services = (advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
      + (advertisement[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
    let advertised = services.map { $0.uuidString.uppercased() }
    let manufacturer = advertisement[CBAdvertisementDataManufacturerDataKey] as? Data
    let identity = manufacturer.flatMap { DeviceIdentity.manufacturer(Array($0)) }
    let wifi = advertised.contains("B0B0") || identity != nil
      || ["doway", "ainote", "x95", "k95", "fw925", "b3085"].contains { name.lowercased().contains($0) }
    let usb = RecorderProfile.matches(name: name, services: advertised)
    let serial = identity?.serial
    self.init(id: peripheral.identifier, name: name, rssi: rssi, kind: wifi ? .wifi : usb ? .usb : previous?.kind,
              serial: serial?.isEmpty == false ? serial : previous?.serial)
  }
}

/// Discovery has no connection delegate or binding side effects. Closing the picker stops only this scan.
final class RecorderDiscovery: NSObject, ObservableObject, CBCentralManagerDelegate {
  @Published private(set) var choices: [CardChoice] = []
  @Published private(set) var message = "正在寻找附近的录音卡…"
  @Published private(set) var canRescan = false
  private var manager: CBCentralManager?
  private var scanTimeout: Timer?

  func start() {
    if let manager { centralManagerDidUpdateState(manager); return }
    manager = CBCentralManager(delegate: self, queue: .main)
  }

  func stop() {
    scanTimeout?.invalidate()
    manager?.stopScan()
    manager?.delegate = nil
    manager = nil
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    scanTimeout?.invalidate()
    canRescan = false
    choices = []
    switch central.state {
    case .poweredOn:
      message = "正在寻找附近的录音卡…"
      central.scanForPeripherals(withServices: nil)
      scanTimeout = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
        guard let self else { return }
        self.manager?.stopScan()
        self.message = self.choices.isEmpty ? "未发现附近的蓝牙设备。" : "已完成查找。"
        self.canRescan = true
      }
    case .unauthorized: message = BluetoothBlock.unauthorized.instruction
    case .poweredOff: message = BluetoothBlock.poweredOff.title
    case .unsupported: message = BluetoothBlock.unsupported.title
    default: message = BluetoothBlock.preparing.title
    }
  }

  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any], rssi: NSNumber) {
    let index = choices.firstIndex { $0.id == peripheral.identifier }
    let row = CardChoice(peripheral: peripheral, advertisement: advertisementData,
                         rssi: rssi.intValue, previous: index.map { choices[$0] })
    if let index { choices[index] = row } else { choices.append(row) }
  }
}
