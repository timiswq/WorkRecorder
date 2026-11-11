import Foundation
import QS668Core

public struct LiveASRConfiguration: Equatable {
  public let key: String
  public let host: String
  public init(key: String, host: String = "dashscope.aliyuncs.com") {
    self.key = key
    self.host = host
  }
  public func request() throws -> URLRequest {
    guard !key.isEmpty,
      host == "dashscope.aliyuncs.com"
        || host.range(
          of: #"^[a-zA-Z0-9-]+\.cn-beijing\.maas\.aliyuncs\.com$"#, options: .regularExpression)
          != nil,
      let url = URL(string: "wss://\(host)/api-ws/v1/inference")
    else { throw WorkdayError.invalid("实时转写配置无效，请检查百炼密钥和业务空间") }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("WorkdayMac", forHTTPHeaderField: "User-Agent")
    return request
  }
}

@MainActor public protocol LiveASRStreaming: AnyObject {
  var onEvent: ((ASREvent) -> Void)? { get set }
  func start()
  func append(_ data: Data)
  func finish()
  func cancel()
}

@MainActor protocol LiveWebSocket: AnyObject {
  var response: URLResponse? { get }
  func resume()
  func send(_ message: URLSessionWebSocketTask.Message) async throws
  func receive() async throws -> URLSessionWebSocketTask.Message
  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}
extension URLSessionWebSocketTask: LiveWebSocket {}

/// Continuous Ogg Opus, with a single serial send queue and bounded buffering.
@MainActor public final class QwenLiveConnection: LiveASRStreaming {
  public var onEvent: ((ASREvent) -> Void)?
  private let socket: LiveWebSocket
  private let network: URLSession?
  private let taskID = UUID().uuidString
  private var ogg = OggOpusStream()
  private var pending: [Data] = []
  private var pendingBytes = 0
  private var started = false
  private var closed = false
  private var finishing = false
  private var finishSent = false
  private var sending = false
  private var receiver: Task<Void, Never>?
  private var sender: Task<Void, Never>?
  private var timeout: Task<Void, Never>?
  private var sendTimeout: Task<Void, Never>?

  public convenience init(configuration: LiveASRConfiguration) throws {
    let request = try configuration.request()
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 20
    let session = URLSession(configuration: config)
    self.init(socket: session.webSocketTask(with: request), network: session)
  }
  init(socket: LiveWebSocket, network: URLSession? = nil) {
    self.socket = socket
    self.network = network
  }
  public func start() {
    guard receiver == nil, !closed else { return }
    socket.resume()
    sending = true
    armTimeout("连接识别服务超时，请检查网络。")
    let socket = socket
    receiver = Task { @MainActor [weak self] in
      do {
        while !Task.isCancelled {
          let message = try await socket.receive()
          let data: Data
          switch message {
          case .data(let value): data = value
          case .string(let value): data = Data(value.utf8)
          @unknown default: continue
          }
          guard let self, !self.closed else { return }
          guard data.count <= 1_000_000 else {
            self.fail("实时识别返回异常，已保留已有文字。")
            return
          }
          self.receive(try ASREvent.parse(data))
        }
      } catch { self?.networkFailed(error) }
    }
    sender = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await socket.send(.string(try self.command(finish: false)))
        guard !self.closed else { return }
        self.sending = false
        self.pump()
      } catch { self.networkFailed(error) }
    }
  }
  public func append(_ data: Data) {
    guard !closed, !finishing, !data.isEmpty else { return }
    do {
      // BLE frames are small. Reject oversized input before the Ogg buffer grows.
      guard data.count <= 16_384 else { throw WorkdayError.invalid("收到异常音频数据块") }
      try enqueue(ogg.append(data))
      pump()
    } catch { fail(error.localizedDescription) }
  }
  public func finish() {
    guard !closed, !finishing else { return }
    finishing = true
    do {
      try enqueue(ogg.finish())
      armTimeout("尾句识别超时，已返回的文字保留，完整录音可稍后整理。")
      pump()
    } catch { fail(error.localizedDescription) }
  }
  public func cancel() {
    guard !closed else { return }
    closed = true
    receiver?.cancel()
    sender?.cancel()
    timeout?.cancel()
    sendTimeout?.cancel()
    socket.cancel(with: .normalClosure, reason: nil)
    network?.invalidateAndCancel()
    pending = []
    pendingBytes = 0
  }
  private func command(finish: Bool) throws -> String {
    var payload: [String: Any] = ["input": [String: Any]()]
    if !finish {
      payload.merge([
        "task_group": "audio", "task": "asr", "function": "recognition",
        "model": "qwen-audio-3.1-asr-flash-message",
        "parameters": [
          "format": "opus", "sample_rate": 16000,
          "intermediate_result_enabled": true, "disfluency_removal_enabled": false,
          "heartbeat": true,
        ],
      ]) { _, value in value }
    }
    let object: [String: Any] = [
      "header": [
        "action": finish ? "finish-task" : "run-task", "task_id": taskID, "streaming": "duplex",
      ],
      "payload": payload,
    ]
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
  }
  private func enqueue(_ pages: [Data]) throws {
    let size = pages.reduce(0) { $0 + $1.count }
    guard pendingBytes + size <= 64 * 1024 else {
      throw WorkdayError.invalid("实时识别网络积压，部分文字可能缺失；设备录音继续保存。")
    }
    pending.append(contentsOf: pages)
    pendingBytes += size
  }
  private func pump() {
    guard started, !closed, !sending, !pending.isEmpty || (finishing && !finishSent) else { return }
    sending = true
    sendTimeout = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(15)) } catch { return }
      self?.fail("发送音频超时，请检查网络。")
    }
    sender = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        if !self.pending.isEmpty {
          let page = self.pending.removeFirst()
          self.pendingBytes -= page.count
          try await self.socket.send(.data(page))
        } else {
          self.finishSent = true
          try await self.socket.send(.string(try self.command(finish: true)))
        }
        guard !self.closed else { return }
        self.sendTimeout?.cancel()
        self.sending = false
        self.pump()
      } catch { self.networkFailed(error) }
    }
  }
  private func receive(_ event: ASREvent) {
    switch event {
    case .started:
      started = true
      if !finishing { timeout?.cancel() }
      onEvent?(event)
      pump()
    case .finished:
      guard finishSent else {
        fail("识别服务提前结束，正在等待重新连接。")
        return
      }
      let callback = onEvent
      cancel()
      callback?(event)
    case .failed(let code, _):
      let safeCode = String(
        code.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }.prefix(64))
      let lower = safeCode.lowercased()
      let configurationError = [
        "auth", "invalid", "forbidden", "quota", "accessdenied", "payment", "modelnotfound",
      ].contains { lower.contains($0) }
      fail(
        "百炼实时识别失败（\(safeCode)），请检查密钥、实时模型权限及额度。",
        code: configurationError ? "configuration" : "service")
    default: onEvent?(event)
    }
  }
  private func networkFailed(_ error: Error) {
    guard !closed else { return }
    let status = (socket.response as? HTTPURLResponse)?.statusCode
    if status == 401 || status == 403 {
      fail("百炼认证失败（HTTP \(status!)），请检查北京地域密钥及实时模型权限。", code: "configuration")
    } else {
      fail("实时识别连接中断（\((error as NSError).code)），请检查网络。")
    }
  }
  private func fail(_ message: String, code: String = "network") {
    guard !closed else { return }
    let callback = onEvent
    cancel()
    callback?(.failed(code: code, message: message))
  }
  private func armTimeout(_ message: String) {
    timeout?.cancel()
    timeout = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(20)) } catch { return }
      self?.fail(message)
    }
  }
}
