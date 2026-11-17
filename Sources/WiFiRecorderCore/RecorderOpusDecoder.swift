import CRecorderOpus
import Foundation

/// FW925 的设备文件和已验证的 B0B3 实时样本都使用该包头。一个记录可以跨越多条蓝牙通知。
struct RecordingPacketHeader {
  static let byteCount = 8
  let payloadLength: Int
  let finalRange: UInt32

  init?(_ bytes: Data) {
    guard bytes.count >= Self.byteCount else { return nil }
    let length = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard (1...1500).contains(length) else { return nil }
    payloadLength = Int(length)
    // Opus 参考编码器的区间终值，解码同一包后可逐包比对。
    finalRange = bytes.dropFirst(4).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  }
}

/// 每一段连续音频持有自己的 Opus 预测状态。实时录音边界或损坏包之后重新创建。
final class RecorderOpusDecoder {
  static let samplesPerPacket = 320  // 16 kHz、单声道、20 ms
  private let handle: UnsafeMutableRawPointer

  init?() {
    guard let handle = cr_opus_create() else { return nil }
    self.handle = handle
  }

  deinit { cr_opus_destroy(handle) }

  func decode(_ packet: Data) -> (samples: [Int16], finalRange: UInt32)? {
    var samples = [Int16](repeating: 0, count: Self.samplesPerPacket)
    var finalRange: UInt32 = 0
    let capacity = Int32(samples.count)
    let count = packet.withUnsafeBytes { raw -> Int32 in
      guard !raw.isEmpty, let bytes = raw.bindMemory(to: UInt8.self).baseAddress,
        let length = Int32(exactly: raw.count),
        cr_opus_packet_channels(bytes) == 1,
        cr_opus_packet_samples(bytes, length) == capacity
      else { return -1 }
      return cr_opus_decode(handle, bytes, length, &samples, capacity, &finalRange)
    }
    guard count == capacity else { return nil }
    return (samples, finalRange)
  }
}
