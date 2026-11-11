import AVFoundation
import Foundation

/// Retain the Opus prediction state across successive 20 ms card packets.
final class CardOpusDecoder {
  private let converter: AVAudioConverter
  private let inputFormat: AVAudioFormat
  private let outputFormat: AVAudioFormat

  init(outputFormat: AVAudioFormat) throws {
    var description = AudioStreamBasicDescription(
      mSampleRate: 16000, mFormatID: kAudioFormatOpus,
      mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 320, mBytesPerFrame: 0,
      mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
    guard let inputFormat = AVAudioFormat(streamDescription: &description),
      let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    else { throw WorkdayError.invalid("无法解码录音卡音频") }
    self.inputFormat = inputFormat
    self.outputFormat = outputFormat
    self.converter = converter
  }

  func decode(_ packets: Data, endOfStream: Bool = false) throws -> AVAudioPCMBuffer {
    let n = AVAudioPacketCount(packets.count / 40)
    let capacity = AVAudioFrameCount(ceil(Double(n) * 0.02 * outputFormat.sampleRate)) + 1024
    guard n > 0, packets.count.isMultiple(of: 40),
      let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
    else { throw WorkdayError.invalid("录音卡音频包不完整") }
    let inputFormat = self.inputFormat
    var sent = 0
    var err: NSError?
    let status = converter.convert(to: output, error: &err) { requested, state in
      guard sent < n else {
        state.pointee = endOfStream ? .endOfStream : .noDataNow
        return nil
      }
      let count = max(1, min(Int(requested), Int(n) - sent))
      let buf = AVAudioCompressedBuffer(
        format: inputFormat, packetCapacity: UInt32(count), maximumPacketSize: 40)
      packets.copyBytes(
        to: buf.data.assumingMemoryBound(to: UInt8.self),
        from: packets.startIndex + sent * 40..<packets.startIndex + (sent + count) * 40)
      buf.packetCount = UInt32(count)
      buf.byteLength = UInt32(count * 40)
      for i in 0..<count {
        buf.packetDescriptions?[i] = AudioStreamPacketDescription(
          mStartOffset: Int64(i * 40), mVariableFramesInPacket: 320, mDataByteSize: 40)
      }
      sent += count
      state.pointee = .haveData
      return buf
    }
    if let err { throw err }
    guard status != .error else { throw WorkdayError.invalid("录音卡音频解码失败") }
    return output
  }
}
