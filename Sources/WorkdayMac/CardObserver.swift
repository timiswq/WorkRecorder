import Combine
import CoreBluetooth
import Foundation
import QS668Core
import WorkdayCore

struct CardChoice: Identifiable {
  let id: UUID
  let name: String
  let rssi: Int
}

/// A passive companion: the public write surface accepts read-only queries only.
final class CardObserver: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate
{
  @Published var state = CardState()
  @Published var status = "尚未连接录音卡"
  @Published var choices: [CardChoice] = []
  @Published var name = "AI 录音卡"
  @Published var scanning = false
  @Published private(set) var connectionPhase: CardConnectionPhase = .disconnected
  var onBound: ((String, String) -> Void)?
  var onPause: ((String, RecordingPause) -> Void)?
  private var pauseTracker = PauseTracker()
  var onInventory: ((DeviceInventory) -> Void)?
  private var listing = InventoryCollector()
  private var lastList = Date.distantPast
  private var listeningFilename: String?
  var onAudio: ((Data) -> Void)?
  var onStreamReset: ((LiveAudioBoundary) -> Void)?
  var boundID: String?
  var autoConnect = true
  private var manager: CBCentralManager?
  private var peripheral: CBPeripheral?
  private var writer: CBCharacteristic?
  private var discovered: [UUID: CBPeripheral] = [:]
  private var parsers: [String: FrameParser] = [:]
  private var queue: [(CardQuery, Data)] = []
  private var sequence: UInt8 = 0
  private var timer: Timer?
  private var desired = false
  private var suspended = false
  private var deadline = Date.distantPast
  private var lastPoll = Date.distantPast
  private var requests: [CardQuery: Date] = [:]
  private var lastInfo = Date.distantPast
  private var connectedAt = Date.distantPast

  func activate() {
    desired = true
    if manager == nil {
      status = "正在准备蓝牙…"
      connectionPhase = .connecting
      manager = CBCentralManager(delegate: self, queue: .main)
      timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
        self?.tick()
      }
    } else {
      scan()
    }
  }
  func resumeAfterWake() {
    guard desired, !suspended else { return }
    if state.connected {
      lastPoll = .distantPast
      lastList = .distantPast
      tick()
    } else {
      deadline = .distantPast
      scan()
    }
  }
  func disconnect() {
    desired = false
    manager?.stopScan()
    scanning = false
    if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
    listing.cancel()
    pauseTracker.cancel()
    state.disconnect()
    status = "蓝牙已断开"
    connectionPhase = .disconnected
    onStreamReset?(.disconnected)
  }
  func suspendForUSB(_ value: Bool) {
    guard suspended != value else { return }
    suspended = value
    if value {
      manager?.stopScan()
      scanning = false
      if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
      listing.cancel()
      pauseTracker.cancel()
      state.disconnect()
      onStreamReset?(.disconnected)
      status = "通过 USB 连接"
      connectionPhase = .usb
    } else if desired {
      connectionPhase = .disconnected
      deadline = .distantPast
      scan()
    }
  }
  private func scan() {
    guard desired, !suspended, peripheral == nil, manager?.state == .poweredOn else { return }
    manager?.stopScan()
    choices = []
    discovered = [:]
    scanning = true
    deadline = Date().addingTimeInterval(10)
    status = "正在寻找录音卡…"
    connectionPhase = .searching
    manager?.scanForPeripherals(
      withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
  }
  func connect(_ id: UUID) {
    guard !suspended, peripheral == nil, let device = discovered[id] else { return }
    desired = true
    manager?.stopScan()
    scanning = false
    state = CardState()
    name = choices.first(where: { $0.id == id })?.name ?? "AI 录音卡"
    peripheral = device
    writer = nil
    device.delegate = self
    deadline = Date().addingTimeInterval(20)
    status = "正在连接 \(name)…"
    connectionPhase = .connecting
    manager?.connect(device, options: nil)
  }
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn: scan()
    case .unauthorized: status = "请在系统设置中允许工作留声访问蓝牙"
    case .poweredOff: status = "Mac 蓝牙已关闭"
    case .unsupported: status = "此 Mac 不支持蓝牙"
    default: status = "正在准备蓝牙…"
    }
    if central.state != .poweredOn {
      connectionPhase = .unavailable
      listing.cancel()
      pauseTracker.cancel()
      state.disconnect()
      scanning = false
      peripheral = nil
      writer = nil
      queue = []
      parsers = [:]
      requests = [:]
      onStreamReset?(.disconnected)
    }
  }
  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi: NSNumber
  ) {
    guard scanning, !suspended else { return }
    let services =
      (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
      + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
    let name =
      advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "AI 录音卡"
    guard
      services.contains(CBUUID(string: "AE20")) || name.lowercased().contains("cb08")
        || name.lowercased().contains("qs668")
    else { return }
    if discovered[peripheral.identifier] == nil {
      choices.append(CardChoice(id: peripheral.identifier, name: name, rssi: rssi.intValue))
    }
    discovered[peripheral.identifier] = peripheral
    if autoConnect, boundID == peripheral.identifier.uuidString { connect(peripheral.identifier) }
  }
  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard self.peripheral?.identifier == peripheral.identifier else { return }
    peripheral.discoverServices([CBUUID(string: "AE20")])
  }
  func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
  ) { lost(peripheral, message: error?.localizedDescription ?? "连接失败，稍后重试") }
  func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
  ) { lost(peripheral, message: "连接已断开，等待重新连接") }
  private func lost(_ device: CBPeripheral, message: String) {
    guard peripheral?.identifier == device.identifier else { return }
    listing.cancel()
    pauseTracker.cancel()
    state.disconnect()
    peripheral = nil
    writer = nil
    queue = []
    parsers = [:]
    requests = [:]
    deadline = Date().addingTimeInterval(5)
    status = suspended ? "通过 USB 连接" : message
    connectionPhase = suspended ? .usb : .disconnected
    onStreamReset?(.disconnected)
  }
  private func fail(_ message: String) {
    status = message
    connectionPhase = .unavailable
    if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
  }
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard error == nil,
      let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: "AE20") })
    else {
      fail("未找到录音服务")
      return
    }
    peripheral.discoverCharacteristics(nil, for: service)
  }
  func peripheral(
    _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
  ) {
    guard error == nil, let chars = service.characteristics else {
      fail("无法读取设备服务")
      return
    }
    writer = chars.first { $0.uuid == CBUUID(string: "AE21") }
    guard writer?.properties.contains(.writeWithoutResponse) == true,
      let notify = chars.first(where: { $0.uuid == CBUUID(string: "AE22") }),
      notify.properties.contains(.notify)
    else {
      fail("设备不支持状态连接")
      return
    }
    peripheral.setNotifyValue(true, for: notify)
    if let events = chars.first(where: { $0.uuid == CBUUID(string: "AE23") }),
      events.properties.contains(.notify)
    {
      peripheral.setNotifyValue(true, for: events)
    }
  }
  func peripheral(
    _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard characteristic.uuid == CBUUID(string: "AE22") else { return }
    guard error == nil, characteristic.isNotifying else {
      fail("无法接收设备通知")
      return
    }
    state.connected = true
    connectionPhase = .connected
    connectedAt = Date()
    lastPoll = .distantPast
    lastInfo = .distantPast
    lastList = .distantPast
    status = "\(name) 已连接"
    boundID = peripheral.identifier.uuidString
    onBound?(boundID!, name)
    query(.firmware)
    tick()
  }
  private func query(_ query: CardQuery) {
    guard state.connected, let peripheral, writer != nil, queue.count < 16 else { return }
    // Keep one outstanding query of each kind. Hardware events cannot replace
    // the timestamp belonging to an older response still in flight.
    guard !queue.contains(where: { $0.0 == query }) else { return }
    if let sent = requests[query], Date().timeIntervalSince(sent) < 4 { return }
    let frame = Wire.frame(query.payload, seq: sequence)
    sequence &+= 1
    guard frame.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) else {
      fail("蓝牙写入长度不足")
      return
    }
    queue.append((query, frame))
    flush()
  }
  private func flush() {
    guard state.connected, let peripheral, let writer else { return }
    while peripheral.canSendWriteWithoutResponse, !queue.isEmpty {
      let (query, frame) = queue.removeFirst()
      requests[query] = Date()
      if query == .files, let boundID {
        listing.begin(sourceID: "ble:\(boundID)", at: Date())
        lastList = Date()
      }
      peripheral.writeValue(frame, for: writer, type: .withoutResponse)
    }
  }
  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { flush() }
  func peripheral(
    _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    guard self.peripheral?.identifier == peripheral.identifier, state.connected, error == nil,
      let data = characteristic.value
    else { return }
    let channel = characteristic.uuid.uuidString
    var parser = parsers[channel] ?? FrameParser()
    let previous = parser.corruptionCount
    let frames = parser.push(data)
    parsers[channel] = parser
    if parser.corruptionCount != previous { onStreamReset?(.corrupted) }
    for frame in frames {
      if frame.type == 2 {
        do {
          if let inventory = try listing.receive(frame, at: Date()) {
            requests[.files] = nil
            onInventory?(inventory)
          }
        } catch {
          listing.cancel()
          requests[.files] = nil
          status = "清单暂未完整读取，稍后自动重试"
        }
        continue
      }
      let oldFilename = listeningFilename
      let oldPhase = state.phase
      let replyTo: CardQuery?
      switch (frame.type, frame.command) {
      case (3, 20): replyTo = .state
      case (3, 22): replyTo = .duration
      case (3, 24): replyTo = .filename
      case (0, 4): replyTo = .battery
      case (0, 2): replyTo = .storage
      case (0, 11): replyTo = .firmware
      default: replyTo = nil
      }
      let sent = replyTo.flatMap { requests.removeValue(forKey: $0) }
      if replyTo == .state || replyTo == .duration || replyTo == .filename, sent == nil { continue }
      state.apply(frame, channel: channel, querySentAt: sent)
      if replyTo == .duration, state.phase == .paused { pauseTracker.confirmOffset(state.seconds) }
      if let newFilename = state.filename {
        if let oldFilename, InventoryEntry.stem(oldFilename) != InventoryEntry.stem(newFilename) {
          onStreamReset?(.started)
        }
        listeningFilename = newFilename
      }
      if frame.type == 3, channel == "AE23", [1, 3, 5, 7].contains(frame.command ?? 255) {
        switch frame.command {
        case 1:
          listeningFilename = nil
          pauseTracker.cancel()
          onStreamReset?(.started)
        case 3: onStreamReset?(.saving)
        case 5:
          if let name = state.filename {
            pauseTracker.pause(name: name, offset: state.seconds, at: Date())
          }
          onStreamReset?(.paused)
        default:
          if let name = state.filename, let gap = pauseTracker.resume(name: name, at: Date()) {
            onPause?(name, gap)
          }
          onStreamReset?(.resumed)
        }
        query(.state)
        query(.filename)
        query(.duration)
      }
      if oldPhase != .idle, state.phase == .idle {
        onStreamReset?(.ended)
        pauseTracker.cancel()
        lastList = .distantPast
      }
      if state.phase != .idle, listing.running {
        listing.cancel()
        requests[.files] = nil
        queue.removeAll { $0.0 == .files }
      }
      if frame.type == 1, frame.command == 1, channel == "AE22", !frame.body.isEmpty {
        onAudio?(Data(frame.body))
      }
    }
  }
  private func tick() {
    guard !suspended else { return }
    let now = Date()
    if state.connected {
      if let partial = listing.expire(at: now) {
        requests[.files] = nil
        onInventory?(partial)
      }
      if state.isFresh(), state.phase == .idle, !listing.running,
        now.timeIntervalSince(lastList) > 30
      {
        query(.files)
      }
      if now.timeIntervalSince(state.confirmedAt ?? connectedAt) > 15 {
        fail("设备状态未更新，正在重新连接")
        return
      }
      if now.timeIntervalSince(lastPoll) >= 2 {
        lastPoll = now
        query(.state)
        query(.duration)
        query(.filename)
      }
      if now.timeIntervalSince(lastInfo) >= 30 {
        lastInfo = now
        query(.battery)
        query(.storage)
      }
    } else if scanning, now > deadline {
      manager?.stopScan()
      scanning = false
      status = choices.isEmpty ? "未发现录音卡，正在等待" : "请在设置中选择录音卡"
      connectionPhase = .disconnected
      deadline = now.addingTimeInterval(5)
    } else if peripheral != nil, now > deadline {
      fail("连接超时，请检查手机是否占用设备")
    } else if desired, autoConnect, boundID != nil, now > deadline {
      scan()
    }
  }
}
