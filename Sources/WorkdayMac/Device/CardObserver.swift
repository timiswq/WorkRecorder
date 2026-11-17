import Combine
import CoreBluetooth
import Foundation
import OSLog
import QS668Core
import WorkdayCore
import WiFiRecorderCore

enum RecorderKind: String, Codable {
  case usb, wifi
  var label: String { self == .wifi ? "蓝牙 + Wi-Fi" : "蓝牙 + USB" }
}

struct CardChoice: Identifiable {
  let id: UUID
  let name: String
  let rssi: Int
  var kind: RecorderKind?
  var serial: String?
}

/// 工作留声负责发现、绑定和显示设备状态。机身按键的协议应答由 GATT 会话统一发送。
final class CardObserver: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  @Published var state = CardState()
  static let initialStatus = "尚未连接录音卡"
  @Published var status = CardObserver.initialStatus
  @Published var choices: [CardChoice] = []
  @Published var name = "AI 录音卡"
  private(set) var serial: String?
  @Published var scanning = false
  @Published private(set) var connectionPhase: CardConnectionPhase = .disconnected
  @Published private(set) var bluetoothBlock: BluetoothBlock?
  @Published private(set) var switchingTo: CardChoice?
  @Published private(set) var selectionError: String?
  var onSelectionFailed: (() -> Void)?
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
  private(set) var stateDeviceID: String?
  var boundID: String? {
    didSet {
      if oldValue != boundID, !state.connected, let stateDeviceID, stateDeviceID != boundID {
        state = CardState()
        self.stateDeviceID = nil
      }
    }
  }
  var autoConnect = true
  var preferredKind = RecorderKind.usb
  var wifiBusy = false
  var holdReconnect = false
  @Published private(set) var wifiAudioIssue: String?
  private let wifiAudio = WiFiLiveAudio()
  private(set) var wifiSession: WiFiCardSession?
  var onWiFiBound: ((String, String) -> Void)?
  var onWiFiState: ((UInt8) -> Void)?
  var onHotspot: ((HotspotCredentials) -> Void)?
  var onSocket: (() -> Void)?
  var onWiFiLost: (() -> Void)?
  private var cancellingConnection = false

  func releaseForWiFi() {
    guard let link = wifiSession else { return }
    holdReconnect = true
    link.handoff()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak link] in
      guard let self, let link, self.wifiSession === link else { return }
      self.manager?.cancelPeripheralConnection(link.peripheral)
    }
  }
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

  func activateAutomatically() {
    guard autoConnect, switchingTo == nil, search != .all else { return }
    activate()
  }

  func activate(_ search: Search = .preferred) {
    if search == .all { suspended = false }
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
      if let wifiSession { wifiSession.queryState() } else { session?.inspect() }
    } else {
      scan()
    }
  }
  func resumeAfterWake() {
    guard desired, !suspended else { return }
    if state.connected {
      lastPoll = .distantPast
      if let wifiSession { wifiSession.queryState() } else { session?.inspect() }
    } else {
      deadline = .distantPast
      scan()
    }
  }
  func disconnect() {
    desired = false
    switchingTo = nil
    selectionError = nil
    // Stay in manual selection until the user connects a card or explicitly reconnects.
    search = .all
    choices = []
    discovered.removeAll()
    stopBluetooth()
    status = "蓝牙已断开"
    connectionPhase = .disconnected
  }
  func suspendForUSB(_ value: Bool) {
    guard suspended != value else { return }
    suspended = value
    if value {
      stopBluetooth()
      status = "通过 USB 连接"
      connectionPhase = .usb
    } else {
      connectionPhase = .disconnected
      status = "蓝牙已断开"
      deadline = .distantPast
      scan()
    }
  }
  private func stopBluetooth() {
    manager?.stopScan()
    scanning = false
    endSession()
    // 等系统回调释放 peripheral，避免在上一个连接尚未断开时连接同一张卡。
    if let peripheral {
      cancellingConnection = true
      manager?.cancelPeripheralConnection(peripheral)
    }
  }
  private func endSession() {
    let wasConnected = state.connected
    serial = nil
    wifiAudio.reset()
    wifiAudioIssue = nil
    wifiSession?.close()
    wifiSession = nil
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
    guard desired, !suspended, !holdReconnect, peripheral == nil, manager?.state == .poweredOn else { return }
    // A bound recorder may already have a CoreBluetooth connection and stop
    // advertising. An explicit reconnect can reuse its cached peripheral.
    let target = switchingTo?.id ?? (search == .reconnectBound ? boundID.flatMap(UUID.init(uuidString:)) : nil)
    if let id = target,
       let device = manager?.retrievePeripherals(withIdentifiers: [id]).first {
      discovered[id] = device
      connect(id)
      return
    }
    manager?.stopScan()
    choices = []
    discovered = [:]
    scanning = true
    deadline = Date().addingTimeInterval(10)
    status = "正在寻找录音卡…"
    connectionPhase = .searching
    manager?.scanForPeripherals(
      withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
  }
  func switchConnection(to choice: CardChoice) {
    guard !wifiBusy, switchingTo == nil else { return }
    if let bluetoothBlock, bluetoothBlock != .preparing {
      selectionError = "未能连接 \(choice.name)。\(bluetoothBlock.title)"
      return
    }
    disconnect()
    switchingTo = choice
    activate(.all)
  }

  private func selectionFailed(_ message: String) {
    guard let target = switchingTo else { return }
    switchingTo = nil
    selectionError = "未能连接 \(target.name)。\(message)"
    desired = false
    onSelectionFailed?()
  }

  func connect(_ id: UUID) {
    guard !suspended, !wifiBusy || id.uuidString == boundID,
          switchingTo == nil || switchingTo?.id == id,
          peripheral == nil, let device = discovered[id] else { return }
    desired = true
    if search == .reconnectBound { search = .preferred }
    manager?.stopScan()
    scanning = false
    state = CardState()
    stateDeviceID = id.uuidString
    let advertised = choices.first { $0.id == id }
    serial = switchingTo?.serial ?? advertised?.serial
    name = switchingTo?.name ?? advertised?.name ?? device.name ?? "AI 录音卡"
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
      if bluetoothBlock != .preparing { selectionFailed(bluetoothBlock.title) }
      if bluetoothBlock != .preparing, search == .reconnectBound { search = .preferred }
      status = bluetoothBlock.instruction
      connectionPhase = suspended ? .usb : .unavailable
      scanning = false
      choices = []
      peripheral = nil
      cancellingConnection = false
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
    let index = choices.firstIndex { $0.id == peripheral.identifier }
    let row = CardChoice(peripheral: peripheral, advertisement: advertisementData,
                         rssi: rssi.intValue, previous: index.map { choices[$0] })
    guard search == .all || boundID == row.id.uuidString || row.kind != nil else { return }
    if let index { choices[index] = row } else { choices.append(row) }
    discovered[peripheral.identifier] = peripheral
    let shouldConnect = switchingTo.map { $0.id == row.id }
      ?? search.selects(row.id.uuidString, boundID: boundID, autoConnect: autoConnect)
    if shouldConnect { connect(row.id) }
  }
  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard self.peripheral?.identifier == peripheral.identifier else { return }
    guard desired, !suspended, !cancellingConnection, session == nil else { return }
    peripheral.delegate = self
    let usbServices = RecorderProfile.supported.map { CBUUID(string: $0.service) }
    peripheral.discoverServices(usbServices + [WiFiCardSession.serviceID])
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard self.peripheral === peripheral, desired, !suspended, !cancellingConnection else { return }
    guard error == nil, let services = peripheral.services else {
      fail("读取录音卡服务失败")
      return
    }
    if let service = services.first(where: { $0.uuid == WiFiCardSession.serviceID }) {
      openWiFiSession(peripheral, service: service)
      return
    }
    guard RecorderProfile.select(services: services.map { $0.uuid.uuidString }) != nil else {
      fail("未发现支持的录音卡服务")
      return
    }
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

  private func openWiFiSession(_ peripheral: CBPeripheral, service: CBService) {
    let link = WiFiCardSession(peripheral)
    wifiSession = link
    link.onReady = { [weak self] in
      guard let self else { return }
      self.switchingTo = nil
      self.selectionError = nil
      self.search = .preferred
      self.state.connected = true
      self.connectionPhase = .connected
      self.boundID = peripheral.identifier.uuidString
      self.status = "蓝牙已连接 · Wi-Fi 录音卡"
      self.onWiFiBound?(peripheral.identifier.uuidString, self.name)
    }
    link.onAudioAvailable = { [weak self] available in
      guard let self else { return }
      self.wifiAudioIssue = available ? nil : "未能订阅这张卡的蓝牙实时音频，可在录完后同步。"
      if !available && self.state.phase == .recording { self.wifiBoundary(.corrupted) }
    }
    link.onState = { [weak self] report in
      self?.receiveWiFiState(report.recordingCode, battery: report.battery, freeStorageFraction: report.freeStorageFraction)
    }
    link.onRecordingEvent = { [weak self] event, name in self?.receiveWiFiEvent(event, name: name) }
    link.onAudio = { [weak self] data in self?.receiveWiFiAudio(data) }
    link.onHotspot = { [weak self] in self?.onHotspot?($0) }
    link.onSocket = { [weak self] in self?.onSocket?() }
    link.onFailure = { [weak self] in self?.fail($0) }
    link.open(service)
  }

  func receiveWiFiState(_ raw: UInt8, battery: Int?, freeStorageFraction: Double? = nil) {
    let previous = state.phase
    state.updateWiFi(raw: raw, battery: battery, freeStorageFraction: freeStorageFraction)
    wifiPhaseChanged(from: previous)
    onWiFiState?(raw)
  }

  func receiveWiFiEvent(_ event: WiFiRecordingEvent, name: String?) {
    guard state.connected else { return }
    let previous = state.phase
    let changedFile = event == .started && name != nil && state.filename != nil && state.filename != name
    state.updateWiFi(event: event, filename: name)
    if changedFile && previous == .recording {
      wifiBoundary(.started)
      onRecordingStarted?()
    } else {
      wifiPhaseChanged(from: previous, explicitStart: event == .started)
    }
  }

  private func wifiPhaseChanged(from previous: CardState.Phase, explicitStart: Bool = false) {
    guard previous != state.phase else { return }
    switch state.phase {
    case .recording:
      wifiBoundary(previous == .paused ? .resumed : .started)
      // 中途连接也要初始化解码器；只有观察到新开录才让界面跳到实时字幕。
      if previous == .idle || explicitStart { onRecordingStarted?() }
    case .paused: wifiBoundary(.paused)
    case .idle where previous != .unknown: wifiBoundary(.ended)
    case .unknown where previous == .recording: wifiBoundary(.corrupted)
    default: break
    }
  }

  private func wifiBoundary(_ reason: LiveAudioBoundary) {
    wifiAudio.reset()
    onStreamReset?(reason)
  }

  func receiveWiFiAudio(_ data: Data) {
    guard state.connected, state.phase == .recording, !holdReconnect else { return }
    do {
      let packets = try wifiAudio.append(data)
      guard !packets.isEmpty else { return }
      if wifiAudioIssue != nil { wifiAudioIssue = nil }
      onAudio?(packets)
    } catch {
      let firstFailure = wifiAudioIssue == nil
      if firstFailure {
        wifiAudioIssue = error.localizedDescription
        onStreamReset?(.corrupted)
      }
    }
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
    let wasWiFi = wifiSession != nil
    endSession()
    peripheral = nil
    deadline = Date().addingTimeInterval(5)
    status = suspended ? "通过 USB 连接" : message
    connectionPhase = suspended ? .usb : .disconnected
    if wasWiFi { onWiFiLost?() }
    if cancellingConnection {
      cancellingConnection = false
      scan()
    } else {
      selectionFailed(message)
    }
  }
  private func fail(_ message: String) {
    selectionFailed(message)
    status = message
    connectionPhase = .unavailable
    if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
  }
  private func becameReady(hasKeys: Bool) {
    guard let peripheral else { return }
    switchingTo = nil
    selectionError = nil
    search = .preferred
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
    guard !suspended, !cancellingConnection else { return }
    let now = Date()
    if let wifiSession, state.connected {
      if !wifiBusy && now.timeIntervalSince(lastPoll) >= 5 { lastPoll = now; wifiSession.queryState() }
      return
    }
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
      selectionFailed("请确认设备已开启并靠近 Mac。")
      status = choices.isEmpty ? "未发现录音卡，正在等待" : "请选择录音卡"
      connectionPhase = .disconnected
      deadline = now.addingTimeInterval(5)
    } else if peripheral != nil, now > deadline {
      fail("连接超时，请检查手机是否占用设备")
    } else if desired, search != .all, autoConnect, boundID != nil, now > deadline {
      scan()
    }
  }
}
