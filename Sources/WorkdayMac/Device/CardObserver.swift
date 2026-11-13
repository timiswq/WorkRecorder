import Combine
import CoreBluetooth
import Foundation
import OSLog
import QS668Core
import WorkdayCore

struct CardChoice: Identifiable {
  let id: UUID
  let name: String
  let rssi: Int
}

/// 工作留声负责发现、绑定和显示设备状态。机身按键的协议应答由 GATT 会话统一发送。
final class CardObserver: NSObject, ObservableObject, CBCentralManagerDelegate {
  @Published var state = CardState()
  static let initialStatus = "尚未连接录音卡"
  @Published var status = CardObserver.initialStatus
  @Published var choices: [CardChoice] = []
  @Published var name = "AI 录音卡"
  @Published var scanning = false
  @Published private(set) var connectionPhase: CardConnectionPhase = .disconnected
  @Published private(set) var bluetoothBlock: BluetoothBlock?
  var onBound: ((String, String) -> Void)?
  var onPause: ((String, RecordingPause) -> Void)?
  private var pauseTracker = PauseTracker()
  var onInventory: ((DeviceInventory) -> Void)?
  private var listing = InventoryCollector()
  private var listeningFilename: String?
  var onAudio: ((Data) -> Void)?
  var onStreamReset: ((LiveAudioBoundary) -> Void)?
  /// A start key or confirmed idle-to-recording transition, independent of audio/file boundaries.
  var onRecordingStarted: (() -> Void)?
  var boundID: String?
  var autoConnect = true
  private var manager: CBCentralManager?
  private var peripheral: CBPeripheral?
  private var session: RecorderGATTSession?
  private let log = Logger(subsystem: "WorkRecorder", category: "RecorderBLE")
  private var discovered: [UUID: CBPeripheral] = [:]
  private var timer: Timer?
  enum Search {
    case preferred, all, reconnectBound

    func selects(_ id: String, boundID: String?, autoConnect: Bool) -> Bool {
      id == boundID && (self == .reconnectBound || self == .preferred && autoConnect)
    }
  }
  private var search = Search.preferred
  private var desired = false
  private var suspended = false
  private var deadline = Date.distantPast
  private var lastPoll = Date.distantPast
  var monitorsWindowBattery = false
  var monitorsMenuBattery = false
  private var lastBatteryQuery = Date.distantPast
  private var requests: [CardQuery: Date] = [:]
  private var needsInventory = false

  func activate(_ search: Search = .preferred) {
    self.search = search
    desired = true
    if manager == nil {
      status = "正在准备蓝牙…"
      connectionPhase = .connecting
      manager = CBCentralManager(delegate: self, queue: .main)
      timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
        self?.tick()
      }
    } else if state.connected {
      session?.inspect()
    } else {
      scan()
    }
  }
  func resumeAfterWake() {
    guard desired, !suspended else { return }
    if state.connected {
      lastPoll = .distantPast
      session?.inspect()
    } else {
      deadline = .distantPast
      scan()
    }
  }
  func disconnect() {
    desired = false
    search = .preferred
    stopBluetooth()
    status = "蓝牙已断开"
    connectionPhase = .disconnected
  }
  func suspendForUSB(_ value: Bool) {
    guard suspended != value else { return }
    suspended = value
    if value {
      search = .preferred
      stopBluetooth()
      status = "通过 USB 连接"
      connectionPhase = .usb
    } else if desired {
      connectionPhase = .disconnected
      deadline = .distantPast
      scan()
    }
  }
  private func stopBluetooth() {
    manager?.stopScan()
    scanning = false
    endSession()
    // 等系统回调释放 peripheral，避免在上一个连接尚未断开时连接同一张卡。
    if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
  }
  private func endSession() {
    let wasConnected = state.connected
    session?.close()
    session = nil
    listing.cancel()
    pauseTracker.cancel()
    requests.removeAll()
    state.disconnect()
    // 手动断开和 USB 切换也会触发系统回调，每次就绪连接只交付一次音频结束边界。
    if wasConnected { onStreamReset?(.disconnected) }
  }
  func synchronizeClock() {
    guard let session, state.phase == .idle, state.isFresh() else { return }
    do {
      try session.send(.synchronizeClock(Date(), .current))
      status = "已请求校时"
    } catch { status = error.localizedDescription }
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
    search = .preferred
    manager?.stopScan()
    scanning = false
    state = CardState()
    name = choices.first(where: { $0.id == id })?.name ?? "AI 录音卡"
    peripheral = device
    session = nil
    listeningFilename = nil
    deadline = Date().addingTimeInterval(25)
    status = "正在连接 \(name)…"
    connectionPhase = .connecting
    manager?.connect(device, options: nil)
  }
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    updateBluetoothState(central.state)
  }

  func updateBluetoothState(_ adapter: CBManagerState) {
    switch adapter {
    case .poweredOn: bluetoothBlock = nil
    case .unauthorized: bluetoothBlock = .unauthorized
    case .poweredOff: bluetoothBlock = .poweredOff
    case .unsupported: bluetoothBlock = .unsupported
    default: bluetoothBlock = .preparing
    }
    if let bluetoothBlock {
      if bluetoothBlock != .preparing { search = .preferred }
      status = bluetoothBlock.instruction
      connectionPhase = suspended ? .usb : .unavailable
      scanning = false
      choices = []
      peripheral = nil
      endSession()
    } else if !suspended, !state.connected {
      connectionPhase = .disconnected
      status = "蓝牙已就绪"
      scan()
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
    guard search == .all || boundID == peripheral.identifier.uuidString || RecorderProfile.matches(name: name, services: services.map { $0.uuidString }) else { return }
    if discovered[peripheral.identifier] == nil {
      choices.append(CardChoice(id: peripheral.identifier, name: name, rssi: rssi.intValue))
    }
    discovered[peripheral.identifier] = peripheral
    if search.selects(peripheral.identifier.uuidString, boundID: boundID, autoConnect: autoConnect) {
      connect(peripheral.identifier)
    }
  }
  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard self.peripheral?.identifier == peripheral.identifier else { return }
    guard desired, !suspended, session == nil else { return }
    let link = RecorderGATTSession(device: peripheral)
    session = link
    link.onKeyAvailability = { [weak self] available in self?.state.receivesKeyEvents = available }
    link.onReady = { [weak self] keys in self?.becameReady(hasKeys: keys) }
    link.onFrame = { [weak self] frame, channel in self?.receive(frame, channel: channel) }
    link.onWrite = { [weak self] payload, _ in self?.didWrite(payload) }
    link.onWarning = { [weak self] reason in self?.log.warning("\(reason, privacy: .public)") }
    link.onCorruption = { [weak self] in self?.onStreamReset?(.corrupted) }
    link.onFailure = { [weak self] reason in self?.fail(reason) }
    link.open()
  }
  func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
  ) {
    guard self.peripheral === peripheral else { return }
    let message = error?.localizedDescription ?? "连接失败，稍后重试"
    log.info("BLE connect failed: \(message, privacy: .public)")
    lost(message)
  }
  func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
  ) {
    guard self.peripheral === peripheral else { return }
    let message = error?.localizedDescription ?? (desired ? "连接已断开，等待重新连接" : "蓝牙已断开")
    log.info("BLE disconnected: \(message, privacy: .public)")
    lost(message)
  }
  private func lost(_ message: String) {
    endSession()
    peripheral = nil
    deadline = Date().addingTimeInterval(5)
    status = suspended ? "通过 USB 连接" : message
    connectionPhase = suspended ? .usb : .disconnected
  }
  private func fail(_ message: String) {
    status = message
    connectionPhase = .unavailable
    if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
  }
  private func becameReady(hasKeys: Bool) {
    guard let peripheral else { return }
    state.connected = true
    state.receivesKeyEvents = hasKeys
    connectionPhase = .connected
    lastPoll = Date()
    needsInventory = false
    status = hasKeys ? "\(name) 已连接" : "\(name) 已连接，按键通知不可用"
    boundID = peripheral.identifier.uuidString
    onBound?(peripheral.identifier.uuidString, name)
  }
  func didWrite(_ payload: [UInt8]) {
    if let query = CardQuery.allCases.first(where: { $0.payload == payload }) {
      requests[query] = Date()
      if query == .battery { lastBatteryQuery = Date() }
      if query == .files, let boundID {
        listing.begin(sourceID: "ble:\(boundID)", at: Date())
      }
    } else if RecorderKey.allCases.contains(where: { $0.acknowledgment == payload }) {
      log.info("BLE key acknowledgment 3-\(payload[1])")
    }
  }
  private func query(_ query: CardQuery) {
    guard let session, state.connected, !session.containsPending(query.payload) else { return }
    if let sent = requests[query], Date().timeIntervalSince(sent) < 4 { return }
    do { try session.send(.query(query)) }
    catch { log.warning("\(error.localizedDescription, privacy: .public)") }
  }
  func receive(_ frame: Frame, channel: String) {
    if frame.type == 1, frame.command == 1 {
      let audio = frame.payload.dropFirst(2)
      if !audio.isEmpty { onAudio?(Data(audio)) }
      return
    }
    if frame.type == 2 {
      do {
        if let inventory = try listing.receive(frame, at: Date()) {
          requests[.files] = nil
          onInventory?(inventory)
        }
      } catch {
        listing.cancel()
        requests[.files] = nil
        status = "清单暂未完整读取，可在设置中刷新"
      }
      return
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
    if replyTo == .state || replyTo == .duration || replyTo == .filename, sent == nil { return }
    state.apply(frame, channel: channel, querySentAt: sent)
    if replyTo == .duration, state.phase == .paused { pauseTracker.confirmOffset(state.seconds) }
    if let newFilename = state.filename {
      if let oldFilename, InventoryEntry.stem(oldFilename) != InventoryEntry.stem(newFilename) {
        onStreamReset?(.started)
      }
      listeningFilename = newFilename
    }
    if let key = RecorderKey(frame: frame) {
      log.info("BLE key RX \(channel, privacy: .public) 3-\(key.rawValue)")
      switch key {
      case .start:
        listeningFilename = nil
        pauseTracker.cancel()
        onStreamReset?(.started)
        if state.connected && !suspended { onRecordingStarted?() }
      case .save: onStreamReset?(.saving)
      case .pause:
        if let name = state.filename {
          pauseTracker.pause(name: name, offset: state.seconds, at: Date())
        }
        onStreamReset?(.paused)
      case .resume:
        if let name = state.filename, let gap = pauseTracker.resume(name: name, at: Date()) {
          onPause?(name, gap)
        }
        onStreamReset?(.resumed)
      }
      lastPoll = .distantPast
    }
    if oldPhase != .idle, state.phase == .idle {
      onStreamReset?(.ended)
      pauseTracker.cancel()
      needsInventory = oldPhase != .unknown
    }
    if state.phase != .idle, listing.running {
      listing.cancel()
      requests[.files] = nil
    }
    if replyTo == .state, oldPhase == .idle, state.phase == .recording,
       state.connected, !suspended {
      onRecordingStarted?()
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
      guard session?.inspecting == false else { return }
      if monitorsWindowBattery || monitorsMenuBattery, now.timeIntervalSince(lastBatteryQuery) >= 60 {
        lastBatteryQuery = now
        query(.battery)
      }
      if needsInventory, state.phase == .idle, !listing.running {
        needsInventory = false
        query(.files)
      }
      // 空闲时由按键唤起，录音中则需要设备时长。缺少按键订阅时，轮询负责发现新录音。
      if (!state.receivesKeyEvents || state.phase != .idle), now.timeIntervalSince(lastPoll) >= 4 {
        lastPoll = now
        query(.state)
        if state.phase == .recording || state.phase == .paused {
          query(.duration)
          if state.filename == nil { query(.filename) }
        }
      }
    } else if scanning, now > deadline {
      if search == .reconnectBound { search = .preferred }
      manager?.stopScan()
      scanning = false
      status = choices.isEmpty ? "未发现录音卡，正在等待" : "请在设置中选择录音卡"
      connectionPhase = .disconnected
      deadline = now.addingTimeInterval(5)
    } else if peripheral != nil, now > deadline {
      fail("连接超时，请检查手机是否占用设备")
    } else if desired, search != .all, autoConnect, boundID != nil, now > deadline {
      scan()
    }
  }
}
