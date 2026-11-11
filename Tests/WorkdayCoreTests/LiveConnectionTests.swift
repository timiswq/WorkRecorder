import Foundation
import QS668Core
import XCTest

@testable import WorkdayCore

final class LiveConnectionTests: XCTestCase {
  @MainActor func testStreamsBeforeOneSecondAndFinishesAfterTail() async throws {
    let socket = LiveSocketStub()
    let connection = QwenLiveConnection(socket: socket)
    var events: [ASREvent] = []
    connection.onEvent = { events.append($0) }
    connection.start()
    connection.append(audio())
    try await eventually { socket.sent.count == 1 }
    guard case .string(let run) = socket.sent[0] else { return XCTFail("先开启任务") }
    let request = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(run.utf8)) as? [String: Any])
    let payload = try XCTUnwrap(request["payload"] as? [String: Any])
    let params = try XCTUnwrap(payload["parameters"] as? [String: Any])
    XCTAssertEqual(payload["model"] as? String, "qwen-audio-3.1-asr-flash-message")
    XCTAssertEqual(params["intermediate_result_enabled"] as? Bool, true)
    XCTAssertEqual(params["disfluency_removal_enabled"] as? Bool, false)
    XCTAssertEqual(params["sample_rate"] as? Int, 16000)
    XCTAssertEqual(params["format"] as? String, "opus")
    socket.push(#"{"header":{"event":"task-started"},"payload":{}}"#)
    try await eventually { socket.sent.count == 4 }
    guard case .data(let ogg) = socket.sent[1] else { return XCTFail("发送二进制音频") }
    XCTAssertEqual(String(decoding: ogg.prefix(4), as: UTF8.self), "OggS")
    socket.push(
      #"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"sentence_id":0,"text":"实时","sentence_end":false,"begin_time":0,"end_time":null}}}}"#
    )
    try await eventually { events.count == 2 }
    XCTAssertEqual(events[1], .sentence(id: 0, text: "实时", isFinal: false, startMs: 0))
    connection.finish()
    try await eventually { socket.sent.count == 6 }
    guard case .data(let tail) = socket.sent[4], case .string(let finish) = socket.sent[5] else {
      return XCTFail("最后的 Ogg 页必须早于 finish-task")
    }
    XCTAssertEqual(tail[5] & 4, 4)
    XCTAssertTrue(finish.contains("finish-task"))
    socket.push(
      #"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"sentence_id":0,"text":"实时文字。","sentence_end":true,"begin_time":0,"end_time":400}}}}"#
    )
    socket.push(#"{"header":{"event":"task-finished"},"payload":{}}"#)
    try await eventually { events.contains(.finished) }
    XCTAssertTrue(
      events.contains(.sentence(id: 0, text: "实时文字。", isFinal: true, startMs: 0, endMs: 400)))
    XCTAssertTrue(socket.cancelled)
    connection.cancel()
  }
  @MainActor func testPendingAudioIsBoundedWhenServiceNeverStarts() {
    let socket = LiveSocketStub()
    let connection = QwenLiveConnection(socket: socket)
    var failure = ""
    connection.onEvent = { if case .failed(_, let message) = $0 { failure = message } }
    for _ in 0..<100 { connection.append(audio()) }
    XCTAssertTrue(socket.cancelled)
    XCTAssertTrue(failure.contains("积压"))
    XCTAssertTrue(socket.sent.isEmpty)
    connection.cancel()
  }
  @MainActor func testServerErrorDoesNotExposeUntrustedMessage() async throws {
    let socket = LiveSocketStub()
    let connection = QwenLiveConnection(socket: socket)
    var failure = ""
    connection.onEvent = { if case .failed(_, let message) = $0 { failure = message } }
    connection.start()
    socket.push(
      #"{"header":{"event":"task-failed","error_code":"InvalidApiKey","error_message":"private-server-content"},"payload":{}}"#
    )
    try await eventually { !failure.isEmpty }
    XCTAssertTrue(failure.contains("InvalidApiKey"))
    XCTAssertFalse(failure.contains("private-server-content"))
    connection.cancel()
  }
  func testCredentialHostAllowlist() throws {
    let request = try LiveASRConfiguration(
      key: "test-only", host: "sample.cn-beijing.maas.aliyuncs.com"
    ).request()
    XCTAssertEqual(request.url?.scheme, "wss")
    XCTAssertEqual(request.url?.host, "sample.cn-beijing.maas.aliyuncs.com")
    XCTAssertThrowsError(try LiveASRConfiguration(key: "test-only", host: "example.com").request())
    XCTAssertThrowsError(
      try LiveASRConfiguration(key: "test-only", host: "dashscope.aliyuncs.com@example.com")
        .request())
  }
  private func audio() -> Data {
    var packet = Data(repeating: 0, count: 40)
    packet[0] = 0x48
    return (0..<20).reduce(into: Data()) { data, _ in data.append(packet) }
  }
  @MainActor private func eventually(_ predicate: () -> Bool) async throws {
    for _ in 0..<200 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("等待异步协议事件超时")
    throw WorkdayError.invalid("测试等待超时")
  }
}

@MainActor private final class LiveSocketStub: LiveWebSocket {
  var response: URLResponse?
  var sent: [URLSessionWebSocketTask.Message] = []
  var incoming: [URLSessionWebSocketTask.Message] = []
  var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
  var cancelled = false
  func resume() {}
  func send(_ message: URLSessionWebSocketTask.Message) async throws { sent.append(message) }
  func receive() async throws -> URLSessionWebSocketTask.Message {
    if !incoming.isEmpty { return incoming.removeFirst() }
    if cancelled { throw CancellationError() }
    return try await withCheckedThrowingContinuation { waiter = $0 }
  }
  func push(_ value: String) {
    if let waiter {
      self.waiter = nil
      waiter.resume(returning: .string(value))
    } else {
      incoming.append(.string(value))
    }
  }
  func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
    cancelled = true
    let waiting = waiter
    waiter = nil
    waiting?.resume(throwing: CancellationError())
  }
}
