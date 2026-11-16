import AVFoundation
import Foundation
import SherpaOnnxC

public struct LiveVoiceEvidence: Sendable {
  public let generation: UUID
  public let range: Range<Int>
  public let quality: LiveVoiceQuality
  public let voice: [Float]?
  public let changeVoice: [Float]?
  public let pcm: [Float]
  public let packets: Data
  public let packetStartFrame: Int
  public let inferenceMilliseconds: Double
  public init(generation: UUID, range: Range<Int>, quality: LiveVoiceQuality, voice: [Float]?,
              changeVoice: [Float]?, pcm: [Float], packets: Data, packetStartFrame: Int,
              inferenceMilliseconds: Double) {
    self.generation = generation
    self.range = range
    self.quality = quality
    self.voice = voice
    self.changeVoice = changeVoice
    self.pcm = pcm
    self.packets = packets
    self.packetStartFrame = packetStartFrame
    self.inferenceMilliseconds = inferenceMilliseconds
  }
}

/// Separate bounded decode and inference queues: a slow network or ASR sentence
/// finalization never determines when the next voice window can be examined.
public final class LiveSpeakerStream {
  private struct Input: Sendable { let data: Data; let offset: Int }
  private struct Job: Sendable {
    let generation: UUID
    let window: LiveVoiceWindow
    let packets: Data
    let packetStartFrame: Int
  }
  private let input = AsyncStream<Input>.makeStream(bufferingPolicy: .bufferingNewest(128))
  private let decoderTask: Task<Void, Never>
  private let encoderTask: Task<Void, Never>

  public init(onReset: (@MainActor @Sendable (UUID) -> Void)? = nil,
              onFailure: (@MainActor @Sendable (String) -> Void)? = nil,
              onEvidence: @escaping @MainActor @Sendable (LiveVoiceEvidence) -> Void) {
    let jobs = AsyncStream<Job>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let stream = input.stream
    decoderTask = Task.detached(priority: .userInitiated) {
      defer { jobs.continuation.finish() }
      guard let processor = Processor() else {
        await onFailure?("实时声纹语音检测模型无法启动")
        return
      }
      for await chunk in stream {
        guard !Task.isCancelled else { return }
        do {
          if processor.expectedOffset != chunk.offset {
            processor.reset(at: chunk.offset)
            await onReset?(processor.generation)
          }
          for job in try processor.append(chunk.data, offset: chunk.offset) {
            jobs.continuation.yield(job)
          }
        } catch {
          processor.expectedOffset = nil
          await onFailure?("实时声纹音频暂不可用：" + error.localizedDescription)
        }
      }
    }
    encoderTask = Task.detached(priority: .userInitiated) {
      let encoder = SpeakerEncoder()
      for await job in jobs.stream {
        guard !Task.isCancelled else { return }
        do {
          let start = ContinuousClock.now
          let usable = job.window.quality.usableForIdentity
          let voice = usable ? try await encoder.pcm(job.window.samples) : nil
          let change = usable && !job.window.changeSamples.isEmpty
            ? try await encoder.pcm(job.window.changeSamples) : nil
          try Task.checkCancellation()
          let elapsed = start.duration(to: .now).components
          await onEvidence(.init(
            generation: job.generation, range: job.window.range, quality: job.window.quality,
            voice: voice, changeVoice: change, pcm: job.window.samples, packets: job.packets,
            packetStartFrame: job.packetStartFrame,
            inferenceMilliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15))
        } catch is CancellationError { return }
        catch { await onFailure?("实时声纹推理暂不可用：" + error.localizedDescription) }
      }
    }
  }

  public func append(_ data: Data, offset: Int) {
    guard !data.isEmpty else { return }
    input.continuation.yield(.init(data: data, offset: offset))
  }
  public func finish() async {
    input.continuation.finish()
    await decoderTask.value
    await encoderTask.value
  }
  public func cancel() {
    input.continuation.finish()
    decoderTask.cancel()
    encoderTask.cancel()
  }
  deinit { input.continuation.finish(); decoderTask.cancel(); encoderTask.cancel() }

  private final class Processor {
    let format: AVAudioFormat
    let vad: OpaquePointer
    var expectedOffset: Int?
    var generation = UUID()
    var decoder: CardOpusDecoder?
    var remainder = Data()
    var skip = 0
    var raw = Data()
    var rawOrigin = 0
    var decodedEnd: Int?
    var pendingPCM: [Float] = []
    var pendingStart = 0
    var windows = LiveVoiceBuffer()

    init?() {
      guard let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
            let url = Bundle.module.url(forResource: "silero_vad", withExtension: "onnx") else { return nil }
      self.format = format
      let instance = url.path.withCString { path in
        "cpu".withCString { provider in
          var config = SherpaOnnxVadModelConfig()
          config.silero_vad.model = path
          config.silero_vad.threshold = 0.5
          config.silero_vad.min_speech_duration = 0.128
          config.silero_vad.min_silence_duration = 0.4
          config.silero_vad.max_speech_duration = 120
          config.silero_vad.window_size = 512
          config.sample_rate = 16000
          config.num_threads = 1
          config.provider = provider
          return SherpaOnnxCreateVoiceActivityDetector(&config, 10)
        }
      }
      guard let instance else { return nil }
      vad = instance
    }
    deinit { SherpaOnnxDestroyVoiceActivityDetector(vad) }

    func reset(at offset: Int) {
      generation = UUID()
      expectedOffset = offset
      decoder = nil
      remainder.removeAll(keepingCapacity: true)
      raw.removeAll(keepingCapacity: true)
      skip = (40 - offset % 40) % 40
      rawOrigin = offset + skip
      decodedEnd = nil
      pendingPCM.removeAll(keepingCapacity: true)
      windows.reset()
      SherpaOnnxVoiceActivityDetectorReset(vad)
    }

    func append(_ input: Data, offset: Int) throws -> [Job] {
      expectedOffset = offset + input.count
      let ignored = min(skip, input.count)
      skip -= ignored
      remainder.append(input.dropFirst(ignored))
      let count = remainder.count / 40 * 40
      guard count > 0 else { return [] }
      let packets = remainder.prefix(count)
      guard stride(from: 0, to: packets.count, by: 40).allSatisfy({ index in
        let toc = packets[packets.startIndex + index]
        return toc >> 3 == 9 && toc & 4 == 0
          && (toc & 3 == 0 || (toc & 3 == 3 && packets[packets.startIndex + index + 1] & 63 == 1))
      }) else { throw WorkdayError.invalid("实时音频包格式不符合录音卡配置") }
      raw.append(packets)
      if decoder == nil { decoder = try CardOpusDecoder(outputFormat: format) }
      guard let output = try decoder?.decode(packets), let pcm = output.floatChannelData?[0] else { return [] }
      remainder.removeFirst(count)
      let frames = Int(output.frameLength)
      guard frames > 0 else { return [] }
      // Core Audio removes initial priming. Account for it once, rather than
      // restarting the decoder and its clock at every voice window.
      if decodedEnd == nil { decodedEnd = (rawOrigin + raw.count) * 8 - frames }
      if pendingPCM.isEmpty { pendingStart = decodedEnd! }
      pendingPCM.append(contentsOf: UnsafeBufferPointer(start: pcm, count: frames))
      decodedEnd! += frames
      var jobs: [Job] = []
      var consumed = 0
      while pendingPCM.count - consumed >= 512 {
        let block = Array(pendingPCM[consumed..<consumed + 512])
        block.withUnsafeBufferPointer { SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, $0.baseAddress, 512) }
        let speech = SherpaOnnxVoiceActivityDetectorDetected(vad) != 0
        for window in windows.append(block, speech: speech, startFrame: pendingStart + consumed) {
          let first = max(rawOrigin, max(0, window.range.lowerBound / 320 - 4) * 40)
          let last = min(rawOrigin + raw.count, ((window.range.upperBound + 319) / 320 + 1) * 40)
          guard last > first else { continue }
          let base = raw.startIndex - rawOrigin
          jobs.append(.init(generation: generation, window: window,
                            packets: raw.subdata(in: base + first..<base + last), packetStartFrame: first * 8))
        }
        while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 { SherpaOnnxVoiceActivityDetectorPop(vad) }
        consumed += 512
      }
      pendingPCM.removeFirst(consumed)
      pendingStart += consumed
      if raw.count > 40_000 {
        let removed = (raw.count - 40_000) / 40 * 40
        raw.removeFirst(removed)
        rawOrigin += removed
      }
      return jobs
    }
  }
}
