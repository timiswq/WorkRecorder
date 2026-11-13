import AVFoundation
import SherpaOnnxC

/// Reads a copy of incoming card audio. This queue never gates the recognizers.
public final class CardSpeechActivity {
  public enum Event: Sendable {
    case began(offset: Int)
    case ended
  }

  private struct Chunk: Sendable {
    let packets: Data
    let offset: Int
  }
  private let input = AsyncStream<Chunk>.makeStream(bufferingPolicy: .bufferingNewest(32))
  private let worker: Task<Void, Never>

  /// A pause is acknowledged only once the recognizer can close at the analyzed
  /// audio position. If capture is ahead, check again as the detector catches up.
  public init(onEvent: @escaping @MainActor @Sendable (Event) -> Void,
              onConfirmedPause: (@MainActor @Sendable (Range<Int>) -> Bool)? = nil) {
    let stream = input.stream
    worker = Task.detached(priority: .userInitiated) {
      guard let detector = Detector() else { return }
      var expectedOffset: Int?
      for await chunk in stream {
        guard !Task.isCancelled else { return }
        // A dropped batch must never join two unrelated Opus byte fragments.
        if chunk.offset != expectedOffset {
          if detector.speaking { await onEvent(.ended) }
          detector.reset(at: chunk.offset)
        }
        do {
          for event in try detector.append(chunk.packets) { await onEvent(event) }
          if let onConfirmedPause, let start = detector.confirmedPauseStart,
             await onConfirmedPause(start..<(chunk.offset + chunk.packets.count - detector.remainder.count)) {
            detector.endedAtFrame = nil
          }
          expectedOffset = chunk.offset + chunk.packets.count
        } catch { expectedOffset = nil }
      }
    }
  }
  public func append(_ packets: Data, offset: Int) {
    input.continuation.yield(Chunk(packets: packets, offset: offset))
  }
  public func cancel() -> Task<Void, Never> {
    input.continuation.finish()
    worker.cancel()
    return worker
  }
  deinit { input.continuation.finish(); worker.cancel() }

  final class Detector {
    let vad: OpaquePointer
    let format: AVAudioFormat
    var decoder: CardOpusDecoder?
    var remainder = Data()
    var skip = 0
    var origin = 0
    var frames = 0
    var speaking = false
    var endedAtFrame: Int?
    var confirmedPauseStart: Int? {
      // Give a resumed utterance time to reactivate the VAD, including at its
      // maximum speech duration. Measure this on decoded audio, even during replay.
      guard let endedAtFrame, frames - endedAtFrame >= 6400 else { return nil }
      return origin + endedAtFrame / 8
    }

    init?() {
      guard let url = Bundle.module.url(forResource: "silero_vad", withExtension: "onnx"),
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1) else { return nil }
      self.format = format
      let instance = url.path.withCString { path in
        "cpu".withCString { cpu in
          var config = SherpaOnnxVadModelConfig()
          config.silero_vad.model = path
          config.silero_vad.threshold = 0.5
          config.silero_vad.min_speech_duration = 0.128
          config.silero_vad.min_silence_duration = 0.8
          config.silero_vad.max_speech_duration = 30
          config.silero_vad.window_size = 512
          config.sample_rate = 16000
          config.num_threads = 1
          config.provider = cpu
          return SherpaOnnxCreateVoiceActivityDetector(&config, 40)
        }
      }
      guard let instance else { return nil }
      vad = instance
    }
    deinit { SherpaOnnxDestroyVoiceActivityDetector(vad) }
    func reset(at offset: Int) {
      SherpaOnnxVoiceActivityDetectorReset(vad)
      decoder = nil
      remainder.removeAll(keepingCapacity: true)
      skip = (40 - offset % 40) % 40
      origin = offset + skip
      frames = 0
      speaking = false
      endedAtFrame = nil
    }
    func append(_ packets: Data) throws -> [Event] {
      let skipped = min(skip, packets.count)
      skip -= skipped
      remainder.append(packets.dropFirst(skipped))
      let count = remainder.count / 40 * 40
      guard count > 0 else { return [] }
      if decoder == nil { decoder = try CardOpusDecoder(outputFormat: format) }
      guard let decoder else { return [] }
      let buffer = try decoder.decode(remainder.prefix(count))
      remainder.removeFirst(count)
      guard let samples = buffer.floatChannelData?[0] else { return [] }
      return detect(samples, count: Int(buffer.frameLength))
    }
    func detect(_ samples: UnsafePointer<Float>, count: Int) -> [Event] {
      var events: [Event] = []
      for i in stride(from: 0, to: count, by: 512) {
        let length = min(512, count - i)
        SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, samples + i, Int32(length))
        frames += length
        let active = SherpaOnnxVoiceActivityDetectorDetected(vad) != 0
        if active != speaking {
          speaking = active
          endedAtFrame = active ? nil : frames
          // 16 kHz PCM and 2,000 Opus bytes/s. Include the onset confirmation window.
          events.append(active ? .began(offset: origin + max(0, frames - 2560) / 8) : .ended)
        }
        while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 { SherpaOnnxVoiceActivityDetectorPop(vad) }
      }
      return events
    }
  }
}
