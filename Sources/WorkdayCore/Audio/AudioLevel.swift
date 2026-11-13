import AVFoundation
import Foundation

/// Ten RMS windows/second; fast attack and a one-segment/window release.
public struct AudioLevelEnvelope {
  private var squares: Double = 0
  private var frames = 0
  private var segments = 0
  public init() {}

  public mutating func append(_ samples: UnsafeBufferPointer<Float>) -> [Int] {
    var values: [Int] = []
    for sample in samples {
      let value = sample.isFinite ? Double(sample) : 0
      squares += value * value
      frames += 1
      if frames == 1600 {
        let decibels = 10 * log10(max(squares / 1600, 1e-12))
        let target = [-54.0, -42, -30, -18].filter { decibels >= $0 }.count
        segments = max(target, segments - 1)
        values.append(segments)
        frames = 0
        squares = 0
      }
    }
    return values
  }
}

/// Independent of recognition settings. Decodes off-main and bounds queued audio.
public final class CardAudioMeter {
  private struct Chunk: Sendable {
    let data: Data
    let offset: Int
    let at: Date
  }
  private let input = AsyncStream<Chunk>.makeStream(bufferingPolicy: .bufferingNewest(8))
  private let worker: Task<Void, Never>

  public init(onLevel: @escaping @MainActor @Sendable (Int, Date) -> Void) {
    let stream = input.stream
    worker = Task.detached(priority: .utility) {
      guard let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1) else {
        return
      }
      var decoder: CardOpusDecoder?
      var envelope = AudioLevelEnvelope()
      var remainder = Data()
      var expected: Int?
      var skip = 0
      var publishedAt = Date.distantPast
      for await chunk in stream {
        guard !Task.isCancelled else { return }
        var data = chunk.data
        if expected != chunk.offset {
          decoder = nil
          envelope = AudioLevelEnvelope()
          remainder.removeAll(keepingCapacity: true)
          skip = (40 - chunk.offset % 40) % 40
        }
        let skipped = min(skip, data.count)
        data = Data(data.dropFirst(skipped))
        skip -= skipped
        expected = chunk.offset + chunk.data.count
        remainder.append(data)
        let count = remainder.count / 40 * 40
        guard count > 0 else { continue }
        do {
          if decoder == nil { decoder = try CardOpusDecoder(outputFormat: format) }
          guard let pcm = try decoder?.decode(remainder.prefix(count)) else { continue }
          remainder.removeFirst(count)
          guard let samples = pcm.floatChannelData?[0] else { continue }
          let levels = envelope.append(
            UnsafeBufferPointer(start: samples, count: Int(pcm.frameLength)))
          if let level = levels.last, !Task.isCancelled,
            chunk.at.timeIntervalSince(publishedAt) >= 0.095
          {
            publishedAt = chunk.at
            await onLevel(level, chunk.at)
          }
        } catch {
          expected = nil
        }
      }
    }
  }

  public func append(_ data: Data, offset: Int, at: Date = Date()) {
    guard !data.isEmpty else { return }
    input.continuation.yield(.init(data: data, offset: offset, at: at))
  }
  public func cancel() {
    input.continuation.finish()
    worker.cancel()
  }
  deinit {
    input.continuation.finish()
    worker.cancel()
  }
}
