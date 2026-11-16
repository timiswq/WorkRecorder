import Foundation
import Network
import WiFiRecorderCore

final class TransferClient {
  enum State {
    case disconnected, connecting, waitingPermission, listing, ready, downloading, recovering, downloaded
  }
  private(set) var state = State.disconnected
  private(set) var error = ""
  private var files: [RecordingEntry] = []
  var onConnected: () -> Void = {}
  var onFiles: ([RecordingEntry]) -> Void = { _ in }
  var onProgress: (UInt64, UInt64) -> Void = { _, _ in }
  var onDownloaded: (URL) -> Void = { _ in }
  var onFailure: (String) -> Void = { _ in }
  private var connection: NWConnection?
  private var generation = UUID()
  private var parser = TCPParser()
  private var incoming: [String: RecordingEntry] = [:]
  private var sink: DownloadSink?
  private let storage: DownloadStore
  private var active: RecordingEntry?
  private var heartbeat: Timer?
  private var deadline: DispatchWorkItem?
  private var recoveryTask: DispatchWorkItem?
  private var tailAttempts = 0
  private var deviceID = ""
  init(root: URL) { storage = DownloadStore(root: root) }
  var connected: Bool {
    state == .listing || state == .ready || state == .downloading || state == .recovering
      || state == .downloaded
  }
  private var busy: Bool {
    state == .connecting || state == .waitingPermission || state == .listing
      || state == .downloading || state == .recovering || state == .downloaded
  }

  func connect(
    deviceID: String, host: String = "192.168.200.1", port: UInt16 = 8475, wifiOnly: Bool = true,
    interfaceName: String? = nil
  ) {
    guard !busy else { return }
    disconnect()
    self.deviceID = deviceID
    error = ""
    let params = NWParameters.tcp
    if wifiOnly {
      let network = WifiNetworkInspector.read(target: host, interfaceName: interfaceName)
      guard let link = network.recorderLink else {
        fail(network.message())
        return
      }
      params.requiredInterfaceType = .wifi
      params.requiredLocalEndpoint = .hostPort(host: .init(link.address), port: .any)
    }
    let c = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: params)
    connection = c
    let token = generation
    state = .connecting
    arm(8, "TCP连接超时，请确认系统已连当前卡热点")
    c.stateUpdateHandler = { [weak self] status in
      guard let self, self.generation == token else { return }
      switch status {
      case .ready:
        self.deadline?.cancel()
        self.error = ""
        self.heartbeat = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
          self?.send(53)
        }
        self.state = .ready
        self.onConnected()
        self.refresh()
        self.receive(c, token)
      case .failed(let e): self.networkEnded("TCP失败：\(e.localizedDescription)")
      case .waiting:
        if c.currentPath?.unsatisfiedReason == .localNetworkDenied {
          self.deadline?.cancel()
          self.state = .waitingPermission
          self.error = "系统未允许本地网络访问。请在系统设置 → 隐私与安全 → 本地网络，允许工作留声；允许后连接会自动重试。"
        }
      case .preparing:
        if self.state == .waitingPermission {
          self.state = .connecting
          self.error = ""
          self.arm(8, "本地网络授权后TCP仍未建立，请检查设备热点")
        }
      default: break
      }
    }
    c.start(queue: .main)
  }
  private func refresh() {
    guard state == .ready else { return }
    state = .listing
    incoming.removeAll()
    files.removeAll()
    arm(10, "未收到完整列表结束标记")
    send(10)
  }
  private func receive(_ c: NWConnection, _ token: UUID) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
      [weak self] data, _, ended, error in
      guard let self, self.generation == token else { return }
      do {
        if let data {
          for f in try self.parser.feed(data) {
            guard self.generation == token else { return }
            try self.accept(f)
          }
        }
      } catch {
        self.fail(error.localizedDescription)
        return
      }
      guard self.generation == token else { return }
      if let error {
        self.networkEnded(error.localizedDescription)
      } else if ended {
        self.networkEnded("设备关闭TCP；未完成文件已保留")
      } else {
        self.receive(c, token)
      }
    }
  }
  private func accept(_ frame: Packet) throws {
    let b = frame.payload
    if frame.key == 11 && state == .recovering {
      throw WiFiRecorderError.invalid("设备在结束标记后仍发文件数据，已保留断点，请重新连接")
    }
    if frame.key == 10 && state == .listing {
      guard let status = b.first else { throw WiFiRecorderError.invalid("列表应答没有状态") }
      if status == 0 {
        let f = try RecordingEntry(b)
        if let previous = incoming[f.id], previous != f {
          throw WiFiRecorderError.invalid("同一录音在清单中的大小发生变化，请重试")
        }
        incoming[f.id] = f
        arm(10, "列表无进展，未允许下载")
      } else {
        // Fail closed for statuses not actually observed on this device generation.
        guard status == 2 else { throw WiFiRecorderError.invalid("未知列表结束状态\(status)，请核对固件") }
        deadline?.cancel()
        files = incoming.values.sorted { $0.name > $1.name }
        state = .ready
        onFiles(files)
      }
    } else if frame.key == 11 && state == .downloading, let sink, let active {
      if b == [2], sink.received < sink.expected {
        try recoverTail(sink, item: active)
        return
      }
      let done = try sink.accept(b)
      onProgress(sink.received, sink.expected)
      guard state == .downloading else { return }
      if done {
        deadline?.cancel()
        self.sink = nil
        self.active = nil
        state = .downloaded
        // Finish processing this receive batch before requesting another file.
        let token = generation
        DispatchQueue.main.async { [weak self] in
          guard let self, self.generation == token else { return }
          self.state = self.connection == nil ? .disconnected : .ready
          self.onDownloaded(sink.destination)
        }
      } else {
        arm(20, "下载20秒无进展；断点已保留")
      }
    }
  }
  func download(_ item: RecordingEntry, resume: Bool = true) {
    guard state == .ready, files.contains(item) else { return }
    tailAttempts = 0
    error = ""
    do { try beginDownload(item, resume: resume) } catch { fail(error.localizedDescription) }
  }
  private func beginDownload(_ item: RecordingEntry, resume: Bool) throws {
    guard files.contains(item) else {
      throw WiFiRecorderError.invalid("文件列表已变化，请重新读取")
    }
    if let existing = storage.completed(device: deviceID, file: item) {
      onDownloaded(existing)
      return
    }
    let s = try storage.begin(device: deviceID, file: item, resume: resume)
    active = item
    sink = s
    state = .downloading
    arm(20, "下载无进展，断点保留")
    send(11, try Wire.download(item, s.offset))
  }
  private func recoverTail(_ old: DownloadSink, item: RecordingEntry) throws {
    let detail = "提前结束：\(old.received)/\(old.expected)字节"
    guard old.received > old.offset else {
      throw WiFiRecorderError.invalid(detail + "；补传没有新数据，断点已保留")
    }
    guard tailAttempts < 2 else { throw WiFiRecorderError.invalid(detail + "；两次自动补传后仍不完整，断点已保留") }
    tailAttempts += 1
    deadline?.cancel()
    old.close()
    sink = nil
    active = nil
    state = .recovering
    let token = generation
    let task = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token, self.state == .recovering else { return }
      do { try self.beginDownload(item, resume: true) } catch {
        self.fail(error.localizedDescription)
      }
    }
    recoveryTask = task
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: task)
  }
  func cancelDownload(whenClosed: @escaping () -> Void = {}) {
    guard state == .downloading || state == .recovering, let old = connection else { return }
    connection = nil
    generation = UUID()
    cleanup()
    state = .disconnected
    files.removeAll()
    finishConnection(old, command: 12, then: whenClosed)
  }
  func closeHotspot(whenClosed: @escaping () -> Void = {}) {
    guard state == .ready, let old = connection else {
      whenClosed()
      return
    }
    connection = nil
    generation = UUID()
    cleanup()
    state = .disconnected
    files.removeAll()
    finishConnection(old, command: 33, then: whenClosed)
  }
  private func finishConnection(
    _ old: NWConnection, command: UInt8, then completion: @escaping () -> Void
  ) {
    var finished = false
    let close = {
      guard !finished else { return }
      finished = true
      old.cancel()
      completion()
    }
    old.send(content: Wire.wifi(command), completion: .contentProcessed { _ in close() })
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: close)
  }
  func disconnect() {
    generation = UUID()
    connection?.cancel()
    connection = nil
    cleanup()
    state = .disconnected
    files.removeAll()
    incoming.removeAll()
    parser = TCPParser()
  }
  private func cleanup() {
    deadline?.cancel()
    recoveryTask?.cancel()
    recoveryTask = nil
    tailAttempts = 0
    heartbeat?.invalidate()
    heartbeat = nil
    sink?.close()
    sink = nil
    active = nil
  }
  private func send(_ key: UInt8, _ payload: [UInt8] = []) {
    guard let c = connection else { return }
    let token = generation
    c.send(
      content: Wire.wifi(key, payload),
      completion: .contentProcessed { [weak self] error in
        guard let self, self.generation == token else { return }
        if let error { self.fail("发送失败：\(error.localizedDescription)") }
      })
  }
  private func arm(_ seconds: Double, _ reason: String) {
    deadline?.cancel()
    let token = generation
    let task = DispatchWorkItem { [weak self] in
      guard let self, self.generation == token else { return }
      self.fail(reason)
    }
    deadline = task
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
  }
  private func networkEnded(_ message: String) {
    if state == .downloaded {
      connection?.cancel()
      connection = nil
      heartbeat?.invalidate()
      heartbeat = nil
      return
    }
    fail(message)
  }
  private func fail(_ message: String) {
    error = message
    disconnect()
    onFailure(message)
  }
}
