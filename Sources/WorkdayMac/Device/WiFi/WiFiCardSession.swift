import CoreBluetooth
import Foundation
import WiFiRecorderCore
import WorkdayCore

/// CardObserver 管理连接。这个会话负责 B3085 特征订阅、控制应答和实时音频分流。
final class WiFiCardSession: NSObject, CBPeripheralDelegate {
  static let serviceID = CBUUID(string: Profile.b3085.service)
  private static let writeID = CBUUID(string: "B0B1")
  private static let controlID = CBUUID(string: "B0B2")
  private static let audioID = CBUUID(string: "B0B3")
  private static let fileID = CBUUID(string: "B0B4")

  let peripheral: CBPeripheral
  var onReady: () -> Void = {}
  var onState: (WiFiCardStatus) -> Void = { _ in }
  var onRecordingEvent: (WiFiRecordingEvent, String?) -> Void = { _, _ in }
  var onAudio: (Data) -> Void = { _ in }
  var onAudioAvailable: (Bool) -> Void = { _ in }
  var onHotspot: (HotspotCredentials) -> Void = { _ in }
  var onSocket: () -> Void = {}
  var onFilePacket: (Packet) -> Void = { _ in }
  var onFailure: (String) -> Void = { _ in }
  private var control: CBCharacteristic?
  private var audio: CBCharacteristic?
  private var output: CBCharacteristic?
  private var subscriptions: [CBCharacteristic] = []
  private var parser = BLEParser()
  private let fileList = BluetoothRecordingList()
  private var writes: [Data] = []
  private var writing = false
  private var openRequest = false
  private var openConfirmed = false
  private var credentials: HotspotCredentials?
  private var active = true

  init(_ peripheral: CBPeripheral) { self.peripheral = peripheral }
  func open(_ service: CBService) {
    peripheral.delegate = self
    peripheral.discoverCharacteristics(
      [Self.writeID, Self.controlID, Self.audioID, Self.fileID], for: service)
  }
  func peripheral(
    _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
  ) {
    guard active else { return }
    let chars = service.characteristics ?? []
    output = chars.first { $0.uuid == Self.writeID }
    audio = chars.first { $0.uuid == Self.audioID }
    control = chars.first { $0.uuid == Self.controlID }
    guard error == nil, let control, control.properties.contains(.notify), let output,
      !output.properties.intersection([.write, .writeWithoutResponse]).isEmpty
    else {
      onFailure("录音卡缺少必要的蓝牙特征")
      return
    }
    // 先订阅必要的控制通道。实时音频是可选通知，订阅失败时仍可查询状态和同步文件。
    subscriptions = [control] + chars.filter { $0 !== control && $0.properties.contains(.notify) }
    subscribe()
  }
  private func subscribe() {
    if let next = subscriptions.first {
      peripheral.setNotifyValue(true, for: next)
    } else {
      onAudioAvailable(audio?.isNotifying == true)
      send(2)
      onReady()
      queryState()
    }
  }
  func peripheral(
    _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard active else { return }
    if characteristic === audio && characteristic !== subscriptions.first {
      onAudioAvailable(error == nil && characteristic.isNotifying)
      return
    }
    guard characteristic === subscriptions.first else { return }
    if characteristic === control && (error != nil || !characteristic.isNotifying) {
      onFailure("无法订阅录音卡状态")
      return
    }
    subscriptions.removeFirst()
    subscribe()
  }
  func queryState() { send(5) }
  func openHotspot() {
    openRequest = true
    openConfirmed = false
    send(2)
    send(27, [1])
  }
  func handoff() { send(12) }
  @MainActor func readFileList(when ready: () -> Bool) async throws -> [RecordingEntry] {
    try await fileList.read {
      guard ready(), self.active, self.output != nil else { return false }
      self.send(10)
      return true
    }
  }
  func deleteFile(_ file: RecordingEntry) -> Bool {
    guard active, output != nil, file.supportsCardCleanup else { return false }
    send(13, file.wireName)
    return true
  }
  private func send(_ key: UInt8, _ payload: [UInt8] = []) {
    guard active else { return }
    let frame = Wire.ble(.b3085, key, payload)
    // The control characteristic supports writes as small as 20 bytes.
    for start in stride(from: 0, to: frame.count, by: 20) {
      writes.append(frame.subdata(in: start..<min(start + 20, frame.count)))
    }
    pump()
  }
  private func pump() {
    guard active, !writing, let output, !writes.isEmpty else { return }
    let mode: CBCharacteristicWriteType =
      output.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
    guard mode == .withResponse || peripheral.canSendWriteWithoutResponse else { return }
    writing = true
    peripheral.writeValue(writes.removeFirst(), for: output, type: mode)
    if mode == .withoutResponse {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) { [weak self] in
        self?.writing = false
        self?.pump()
      }
    }
  }
  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { pump() }
  func peripheral(
    _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    guard active else { return }
    writing = false
    if error != nil { onFailure("录音卡蓝牙写入失败") } else { pump() }
  }
  func peripheral(
    _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    guard active, characteristic === control || characteristic === audio else { return }
    guard let data = characteristic.value, error == nil else {
      if characteristic === control { fileList.invalidate("蓝牙清单接收中断。") }
      return
    }
    if characteristic === audio {
      onAudio(data)
      return
    }
    let rejected = parser.rejectedCRC
    let frames = parser.feed(data)
    if rejected != parser.rejectedCRC { fileList.invalidate("蓝牙清单校验失败。") }
    for frame in frames where frame.profile == .b3085 {
      let payload = frame.payload
      // 录音应答可只有成功状态字节，也可附 14 字节的文件名和固件扩展字段。
      if let event = WiFiRecordingEvent(rawValue: frame.key), payload.first == 0,
        payload.count == 1 || payload.count >= 15
      {
        let name = payload.count >= 15
          ? String(bytes: payload[1..<15].prefix { $0 != 0 }, encoding: .utf8) : nil
        fileList.invalidate("录音状态已改变，请重新读取清单。")
        onRecordingEvent(event, name)
      }
      switch frame.key {
      case 5:
        if let report = WiFiCardStatus(payload) {
          if report.recordingCode != 0 { fileList.invalidate("请在录音保存后读取清单。") }
          onState(report)
        }
      case 31: credentials = try? HotspotCredentials(payload)
      case 27 where openRequest:
        guard payload.first == 0 else {
          openRequest = false
          onFailure("录音卡未确认开启热点")
          return
        }
        openConfirmed = true
      case 32: onSocket()
      case 10: fileList.accept(payload)
      case 13: onFilePacket(frame)
      default: break
      }
      // 热点开启应答和凭据可先后互换，二者都属于本次蓝牙连接才可切网。
      if openRequest, openConfirmed, let credentials {
        openRequest = false
        onHotspot(credentials)
      }
    }
  }
  func close() {
    active = false
    fileList.close()
    writes.removeAll()
    subscriptions.removeAll()
    credentials = nil
    if peripheral.delegate === self { peripheral.delegate = nil }
  }
}
