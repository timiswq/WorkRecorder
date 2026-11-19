import Foundation
import WiFiRecorderCore
import WorkdayCore

/// One reader per BLE connection. Core Bluetooth delivers its packets and close callback on the main queue.
final class BluetoothRecordingList {
  private var request: Task<Void, Never>?
  private var packets: AsyncThrowingStream<[UInt8], Error>.Continuation?
  private var awaitingEnd = false

  @MainActor func read(timeout: Duration = .seconds(20), send: () -> Bool) async throws -> [RecordingEntry] {
    // Key 10 has no request ID. Finish the preceding reply before sending a new command.
    while let request {
      await request.value
      try Task.checkCancellation()
    }
    try Task.checkCancellation()
    guard !awaitingEnd else { throw WorkdayError.invalid("上次清单尚未读完，请稍后重试或重新连接录音卡。") }

    let (stream, sink) = AsyncThrowingStream<[UInt8], Error>.makeStream()
    packets = sink
    awaitingEnd = true
    guard send() else {
      close()
      throw WorkdayError.invalid("请在录音卡蓝牙已连接且空闲时重试。")
    }
    let (result, reply) = AsyncThrowingStream<[RecordingEntry], Error>.makeStream()
    request = Task { @MainActor in
      let timer = Task {
        do { try await Task.sleep(for: timeout) } catch { return }
        sink.finish(throwing: WorkdayError.invalid("读取卡内清单超时。"))
      }
      defer {
        timer.cancel()
        sink.finish()
        packets = nil
        request = nil
        reply.finish()
      }
      var list = RecordingList()
      do {
        for try await payload in stream {
          if let files = try list.accept(payload) {
            reply.yield(files)
            return
          }
        }
      } catch { reply.finish(throwing: error) }
    }
    // A disappearing page can stop waiting immediately. The connection still consumes the old reply.
    for try await files in result {
      try Task.checkCancellation()
      return files
    }
    throw CancellationError()
  }

  func accept(_ payload: [UInt8]) {
    guard awaitingEnd else { return }
    packets?.yield(payload)
    if payload.first == 2 {
      awaitingEnd = false
      packets?.finish()
    }
  }

  func invalidate(_ reason: String) {
    guard awaitingEnd else { return }
    packets?.finish(throwing: WorkdayError.invalid(reason))
    // Keep draining this response through END even if the page starts a new read.
  }

  func close() {
    awaitingEnd = false
    packets?.finish(throwing: WorkdayError.invalid("录音卡蓝牙连接中断。"))
    packets = nil
  }
}
