import Foundation

public enum LiveVoiceReason: String, Codable, Sendable {
  case matched, pending, noOwnerProfile, belowThreshold, negativeMatch, speakerChanged
  case insufficientSpeech, clipped, invalidAudio, discontinuity, mixedSpeakers, staleEvidence
}

public struct LiveVoiceQuality: Codable, Equatable, Sendable {
  public let voicedSeconds: Double
  public let duration: Double
  public let rmsDBFS: Double
  public let clippedFraction: Double
  public let finite: Bool
  public init(voicedSeconds: Double, duration: Double, rmsDBFS: Double, clippedFraction: Double, finite: Bool) {
    self.voicedSeconds = voicedSeconds
    self.duration = duration
    self.rmsDBFS = rmsDBFS
    self.clippedFraction = clippedFraction
    self.finite = finite
  }
  public var reason: LiveVoiceReason? {
    if !finite { return .invalidAudio }
    if clippedFraction > 0.01 { return .clipped }
    if voicedSeconds < 3 { return .insufficientSpeech }
    return nil
  }
  public var usableForIdentity: Bool { reason == nil }
}

public struct LiveVoiceWindow: Sendable {
  public let range: Range<Int>
  public let samples: [Float]
  public let changeSamples: [Float]
  public let quality: LiveVoiceQuality
}

/// Continuous PCM, with VAD used as a quality mask rather than concatenating
/// unrelated voiced fragments. Offsets always refer to the original audio.
public struct LiveVoiceBuffer: Sendable {
  public static let sampleRate = 16_000
  private var samples: [Float] = []
  private var speech: [UInt8] = []
  private var origin = 0
  private var nextEnd: Int?
  public var retainedFrames: Int { samples.count }
  public init() {}

  public mutating func reset() {
    samples.removeAll(keepingCapacity: true)
    speech.removeAll(keepingCapacity: true)
    nextEnd = nil
  }

  public mutating func append(_ input: [Float], speech active: Bool, startFrame: Int) -> [LiveVoiceWindow] {
    guard !input.isEmpty else { return [] }
    if !samples.isEmpty, origin + samples.count != startFrame { reset() }
    if samples.isEmpty {
      origin = startFrame
      nextEnd = startFrame + 80_000
    }
    samples.append(contentsOf: input)
    speech.append(contentsOf: repeatElement(active ? 1 : 0, count: input.count))
    var windows: [LiveVoiceWindow] = []
    while let end = nextEnd, end <= origin + samples.count {
      let lower = end - 80_000 - origin, upper = end - origin
      let audio = Array(samples[lower..<upper])
      let voiced = speech[lower..<upper].reduce(0) { $0 + Int($1) }
      let finite = audio.allSatisfy(\.isFinite)
      let energy = finite ? audio.reduce(Double(0)) { $0 + Double($1) * Double($1) } : 0
      let quality = LiveVoiceQuality(
        voicedSeconds: Double(voiced) / 16_000, duration: 5,
        rmsDBFS: 10 * log10(max(energy / 80_000, 1e-12)),
        clippedFraction: Double(audio.filter { abs($0) >= 0.98 }.count) / 80_000, finite: finite)
      let changeVoiced = speech[(upper - 32_000)..<upper].reduce(0) { $0 + Int($1) }
      windows.append(.init(range: (end - 80_000)..<end, samples: audio,
                           changeSamples: changeVoiced >= 24_000 ? Array(audio.suffix(32_000)) : [],
                           quality: quality))
      nextEnd = end + 16_000
    }
    // Keep only what the next window needs. Large replay batches are also bounded
    // after their windows are returned to the caller.
    if let end = nextEnd {
      let remove = max(0, end - 80_000 - origin)
      if remove > 0 {
        samples.removeFirst(remove)
        speech.removeFirst(remove)
        origin += remove
      }
    }
    return windows
  }
}
