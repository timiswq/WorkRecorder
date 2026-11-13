import CoreBluetooth
import Foundation

/// 管理一次连接的订阅、收包、应答和写队列。所有调用和回调都在中央管理器的主队列上。
/// 调用方持有会话，负责连接和断开外设。每次重连创建新实例。
public final class RecorderGATTSession: NSObject, CBPeripheralDelegate {
    private let device: CBPeripheral
    private var profile: RecorderProfile?
    private var writer: CBCharacteristic?
    private var primary: CBCharacteristic?
    private var keys: CBCharacteristic?
    private var writes: RecorderWriter?
    private var opened = false
    private var notifications = RecorderNotifications()
    private var earlyFrames: [(Frame, String)] = []
    private var active = true
    private var dataSubscribed = false
    public private(set) var ready = false
    public var inspecting: Bool { writes?.inspecting == true }
    /// 就绪之后的按键订阅变化。主通知仍然可用时，调用方可改为查询录音状态。
    public var onKeyAvailability: ((Bool) -> Void)?
    /// 主通知已开启。布尔值表示专用按键通知是否可用，首次巡检由会话随后启动。
    public var onReady: ((Bool) -> Void)?
    /// 交付帧和来源特征 UUID。合法按键的确认先入队，业务层可直接处理事件。
    public var onFrame: ((Frame, String) -> Void)?
    /// 一帧已提交给 CoreBluetooth，参数为 payload 和整帧。设备执行结果由 onFrame 交付。
    public var onWrite: (([UInt8], Data) -> Void)?
    public var onWarning: ((String) -> Void)?
    /// 必要服务、写特征或主通知不可用。会话已关闭，由中央管理器取消外设连接。
    public var onFailure: ((String) -> Void)?
    public var onCorruption: (() -> Void)?

    public init(device: CBPeripheral) { self.device = device }
    public func open() {
        guard active, !opened else { return }
        opened = true
        device.delegate = self
        device.discoverServices(RecorderProfile.supported.map { CBUUID(string: $0.service) })
    }
    /// 释放本次会话。主动断开还需要调用 CBCentralManager.cancelPeripheralConnection。
    public func close() {
        active = false
        ready = false
        writes?.close()
        writes = nil
        earlyFrames.removeAll()
        if device.delegate === self { device.delegate = nil }
    }
    private func fail(_ message: String) {
        guard active else { return }
        close()
        onFailure?(message)
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard active else { return }
        let services = peripheral.services ?? []
        guard error == nil, let profile = RecorderProfile.select(services: services.map { $0.uuid.uuidString }),
              let service = services.first(where: { $0.uuid.uuidString == profile.service }) else {
            fail(error?.localizedDescription ?? "未找到 AE20 或 AD40 录音服务")
            return
        }
        self.profile = profile
        peripheral.discoverCharacteristics([profile.write, profile.data, profile.keys].map { CBUUID(string: $0) }, for: service)
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard active, let profile, service.uuid.uuidString == profile.service else { return }
        let chars = service.characteristics ?? []
        guard error == nil, let writer = chars.first(where: { $0.uuid.uuidString == profile.write }),
              let data = chars.first(where: { $0.uuid.uuidString == profile.data }),
              Self.supportsNotifications(data) else { fail("无法取得录音卡的收发特征"); return }
        let writeType: CBCharacteristicWriteType
        if writer.properties.contains(.writeWithoutResponse) { writeType = .withoutResponse }
        else if writer.properties.contains(.write) { writeType = .withResponse }
        else { fail("录音卡特征不支持写入"); return }
        primary = data
        self.writer = writer
        let writes = RecorderWriter(maximumLength: peripheral.maximumWriteValueLength(for: writeType),
                                    needsResponse: writeType == .withResponse,
                                    canWrite: { writeType == .withResponse || peripheral.canSendWriteWithoutResponse },
                                    submit: { peripheral.writeValue($0, for: writer, type: writeType) })
        writes.onWrite = { [weak self] payload, bytes in self?.onWrite?(payload, bytes) }
        writes.onWarning = { [weak self] message in self?.onWarning?(message) }
        self.writes = writes
        keys = chars.first { $0.uuid.uuidString == profile.keys && Self.supportsNotifications($0) }
        peripheral.setNotifyValue(true, for: data)
    }
    private static func supportsNotifications(_ characteristic: CBCharacteristic) -> Bool {
        characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard active else { return }
        if ch === primary {
            guard error == nil, ch.isNotifying else { fail("无法订阅录音卡数据通知"); return }
            guard !dataSubscribed else { return }
            dataSubscribed = true
            if let keys { peripheral.setNotifyValue(true, for: keys); return }
            finishSetup(hasKeys: false)
        } else if ch === keys {
            let available = error == nil && ch.isNotifying
            if !available { onWarning?("按键通知不可用") }
            if ready { onKeyAvailability?(available) } else { finishSetup(hasKeys: available) }
        }
    }
    private func finishSetup(hasKeys: Bool) {
        guard dataSubscribed, !ready else { return }
        ready = true
        onReady?(hasKeys)
        // 主通知可能在可选按键订阅完成前到达。按键已交给写队列，业务帧在 onReady 后依次交付。
        for (frame, channel) in earlyFrames where active { onFrame?(frame, channel) }
        earlyFrames.removeAll()
        if active { inspect() }
    }
    public func inspect() { if ready { writes?.inspect() } }
    public func cancelInspection() { writes?.cancelInspection() }
    public func containsPending(_ payload: [UInt8]) -> Bool { writes?.contains(payload) == true }
    public func send(_ command: RecorderCommand) throws { try send(command.payload()) }
    public func send(_ payload: [UInt8]) throws {
        guard ready, let writes else { throw ProtocolError.invalid("录音卡尚未连接") }
        try writes.send(payload)
    }
    /// 调试时按原样写入整帧，保留调用方提供的帧头、校验和及序号。
    public func sendRawFrame(_ bytes: Data) throws {
        guard ready, let writes else { throw ProtocolError.invalid("录音卡尚未连接") }
        try writes.sendRaw(bytes)
    }
    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { writes?.flush() }
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic === writer { writes?.wrote(error: error) }
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard active, characteristic === primary || characteristic === keys else { return }
        guard let profile, let bytes = characteristic.value, error == nil else {
            if let error { onWarning?(error.localizedDescription) }
            return
        }
        let channel = characteristic.uuid.uuidString
        notifications.receive(bytes, from: channel, profile: profile, acknowledge: { payload in
            do { try self.writes?.send(payload, acknowledgment: true) }
            catch { self.onWarning?(error.localizedDescription) }
        }, deliver: { frame in
            guard self.active else { return }
            if self.ready { self.onFrame?(frame, channel) }
            else { self.earlyFrames.append((frame, channel)) }
        }, corrupted: { self.onCorruption?() })
    }
}
