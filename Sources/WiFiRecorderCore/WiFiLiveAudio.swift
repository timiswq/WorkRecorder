import AVFoundation
import Foundation

/// 将 B0B3 的候选音频格式转换为字幕、声纹与回听共用的 40 字节 / 20 ms 时间轴。
/// 这里支持的是可回放验证的输入。实际 FW925 通知的分包方式见《Wi-Fi 录音卡开发指南》。
public final class WiFiLiveAudio {
  private var expectsPacketHeader = false
  private var buffer = Data()
  private var decoder: RecorderOpusDecoder?
  private var encoder: AVAudioConverter?

  public init() {}

  public func reset() {
    buffer.removeAll(keepingCapacity: true)
    expectsPacketHeader = false
    decoder = nil
    encoder = nil
  }

  public func append(_ notification: Data) throws -> Data {
    guard let first = notification.first else { return Data() }
    do {
      if !expectsPacketHeader && first != 0 {
        // 裸包模式仅接受单次通知恰好包含一包音频。
        guard [40, 80].contains(notification.count), Self.cardTOC(notification) else { throw formatError }
        return try adapt(notification, range: nil)
      }
      // 合法包长上限为 1500，其大端包头以零开头。后续分片可能从任意字节开始。
      expectsPacketHeader = true
      buffer.append(notification)
      var output = Data()
      while buffer.count >= RecordingPacketHeader.byteCount {
        guard let header = RecordingPacketHeader(buffer) else { throw formatError }
        let recordLength = RecordingPacketHeader.byteCount + header.payloadLength
        guard buffer.count >= recordLength else { break }
        let packet = buffer.dropFirst(RecordingPacketHeader.byteCount).prefix(header.payloadLength)
        output.append(try adapt(packet, range: header.finalRange))
        buffer.removeFirst(recordLength)
      }
      return output
    } catch {
      reset()
      throw error
    }
  }

  private var formatError: AudioError {
    .invalid("未能确认这段蓝牙音频的格式，完整录音仍可在保存后同步。")
  }

  private static func cardTOC(_ data: Data) -> Bool {
    guard let toc = data.first else { return false }
    // SILK wideband, mono, a single 20 ms frame (possibly padded).
    return toc == 0x48 || (toc == 0x4B && data.count > 1 && data[data.startIndex + 1] & 63 == 1)
  }

  private func adapt(_ packet: Data, range: UInt32?) throws -> Data {
    if decoder == nil { decoder = RecorderOpusDecoder() }
    guard let decoded = decoder?.decode(packet), range == nil || range == decoded.finalRange else {
      throw formatError
    }
    // 一旦开始重编码，同段录音须持续使用该编码器，避免中途切换预测状态。
    if encoder == nil && packet.count == 40 && Self.cardTOC(packet) { return packet }
    return try encode(decoded.samples)
  }

  private func encode(_ samples: [Int16]) throws -> Data {
    if encoder == nil {
      guard let input = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                      channels: 1, interleaved: true) else { throw formatError }
      var description = AudioStreamBasicDescription(
        mSampleRate: 16000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
        mFramesPerPacket: 320, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
      guard let output = AVAudioFormat(streamDescription: &description),
            let converter = AVAudioConverter(from: input, to: output) else { throw formatError }
      converter.bitRate = 16000
      converter.bitRateStrategy = AVAudioBitRateStrategy_Constant
      converter.primeMethod = .none
      encoder = converter
    }
    guard let encoder, let input = AVAudioPCMBuffer(pcmFormat: encoder.inputFormat, frameCapacity: 320),
          let channel = input.int16ChannelData?[0] else { throw formatError }
    input.frameLength = 320
    samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
    let output = AVAudioCompressedBuffer(format: encoder.outputFormat, packetCapacity: 1,
                                         maximumPacketSize: encoder.maximumOutputPacketSize)
    var supplied = false
    var error: NSError?
    let status = encoder.convert(to: output, error: &error) { _, state in
      state.pointee = supplied ? .noDataNow : .haveData
      if supplied { return nil }
      supplied = true
      return input
    }
    guard status != .error, supplied, output.packetCount == 1, output.byteLength == 40 else { throw formatError }
    let packet = Data(bytes: output.data, count: 40)
    guard Self.cardTOC(packet) else { throw formatError }
    return packet
  }
}
