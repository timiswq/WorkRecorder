import AVFoundation

/// Recognition offsets are byte positions in the selected input's own timeline.
public enum CaptionAudioInput: Sendable {
  case cardOpus, microphonePCM

  public var bytesPerSecond: Int { self == .cardOpus ? 2_000 : 32_000 }
  public var packetBytes: Int { self == .cardOpus ? 40 : 2 }

  func byteOffset(frames: Int) -> Int { frames * bytesPerSecond / 16_000 }
}

/// The microphone provides uncompressed 16 kHz mono samples, preserving its signal for the comparison.
final class CaptionAudioDecoder {
  private enum Input {
    case opus(CardOpusDecoder)
    case pcm(AVAudioFormat, AVAudioConverter)
  }
  private let input: Input

  init(input: CaptionAudioInput, outputFormat: AVAudioFormat) throws {
    switch input {
    case .cardOpus:
      self.input = .opus(try CardOpusDecoder(outputFormat: outputFormat))
    case .microphonePCM:
      guard let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: pcm, to: outputFormat)
      else { throw WorkdayError.invalid("无法转换 Mac 麦克风音频") }
      self.input = .pcm(pcm, converter)
    }
  }

  func decode(_ data: Data) throws -> AVAudioPCMBuffer {
    switch input {
    case .opus(let decoder): return try decoder.decode(data)
    case .pcm(let format, let converter):
      let frames = AVAudioFrameCount(data.count / 2)
      guard frames > 0, data.count.isMultiple(of: 2),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
            let channel = buffer.int16ChannelData?[0]
      else { throw WorkdayError.invalid("Mac 麦克风音频不完整") }
      buffer.frameLength = frames
      data.copyBytes(to: UnsafeMutableRawBufferPointer(start: channel, count: data.count))
      if format == converter.outputFormat { return buffer }
      let capacity = AVAudioFrameCount(ceil(Double(frames) * converter.outputFormat.sampleRate / format.sampleRate)) + 1024
      guard let result = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity)
      else { throw WorkdayError.invalid("无法分配麦克风字幕缓冲区") }
      var supplied = false
      var error: NSError?
      let status = converter.convert(to: result, error: &error) { _, state in
        state.pointee = supplied ? .noDataNow : .haveData
        if supplied { return nil }
        supplied = true
        return buffer
      }
      if let error { throw error }
      guard status != .error else { throw WorkdayError.invalid("麦克风采样转换失败") }
      return result
    }
  }
}
