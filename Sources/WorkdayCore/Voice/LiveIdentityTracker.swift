import Foundation

public struct LiveOwnerAssessment: Codable, Equatable, Sendable {
  public let ownerScore: Float
  public let negativeScore: Float
  public let threshold: Float
  public let margin: Float
  public init(ownerScore: Float, negativeScore: Float, threshold: Float = 0.62, margin: Float = 0.06) {
    self.ownerScore = ownerScore
    self.negativeScore = negativeScore
    self.threshold = threshold
    self.margin = margin
  }
  public var reason: LiveVoiceReason {
    if ownerScore < 0 { return .noOwnerProfile }
    if negativeScore >= threshold, ownerScore < negativeScore + margin { return .negativeMatch }
    return ownerScore >= threshold ? .matched : .belowThreshold
  }
}

public enum LiveIdentityStatus: String, Codable, Sendable { case pending, owner, unknown, notOwner }

public struct LiveIdentityDecision: Codable, Equatable, Sendable {
  public let range: Range<Int>
  public let status: LiveIdentityStatus
  public let reason: LiveVoiceReason
  public let track: Int
  public let ownerScore: Float
  public let negativeScore: Float
  public init(range: Range<Int>, status: LiveIdentityStatus, reason: LiveVoiceReason, track: Int,
              ownerScore: Float, negativeScore: Float) {
    self.range = range
    self.status = status
    self.reason = reason
    self.track = track
    self.ownerScore = ownerScore
    self.negativeScore = negativeScore
  }
}

/// Session-only continuity. It never changes enrolled owner or negative samples.
/// Overlapping windows are stability observations, not independent votes.
public struct LiveIdentityTracker: Sendable {
  private var reference: [Float]?
  private var last: LiveIdentityDecision?
  private var lastEnd: Int?
  private var ownerSince: Int?
  private var track = 0
  public private(set) var creditedFrames = 0
  public init() {}

  public mutating func reset() {
    reference = nil
    last = nil
    lastEnd = nil
    ownerSince = nil
    creditedFrames = 0
    track += 1
  }

  /// A VAD shortage suspends confirmation without declaring a new speaker.
  /// Keep the acoustic reference so speech after the pause is still checked
  /// for a real change, and require fresh supporting audio before confirming.
  public mutating func pause(range: Range<Int>) -> LiveIdentityDecision {
    ownerSince = nil
    lastEnd = max(lastEnd ?? range.lowerBound, range.upperBound)
    return .init(range: range, status: .unknown, reason: .insufficientSpeech,
                 track: track, ownerScore: -1, negativeScore: -1)
  }

  public mutating func observe(range: Range<Int>, voice: [Float], changeVoice: [Float]?,
                               assessment: LiveOwnerAssessment, changeAssessment: LiveOwnerAssessment?) -> LiveIdentityDecision {
    if let last, range.upperBound <= last.range.upperBound { return last }
    if let lastEnd, range.lowerBound > lastEnd { reset() }
    creditedFrames += max(0, range.upperBound - max(lastEnd ?? range.lowerBound, range.lowerBound))
    let changed = reference.map { previous in
      guard let changeVoice else { return SpeakerEncoder.similarity(previous, voice) < 0.40 }
      return SpeakerEncoder.similarity(previous, changeVoice) < 0.45
        || (last?.status == .owner && (changeAssessment?.ownerScore ?? 1) < 0.45)
    } ?? false
    var status: LiveIdentityStatus = .unknown
    var reason = assessment.reason
    if changed {
      track += 1
      ownerSince = nil
      reference = changeVoice ?? voice
      reason = .speakerChanged
    } else if assessment.reason == .negativeMatch || changeAssessment?.reason == .negativeMatch {
      status = .notOwner
      reason = .negativeMatch
      ownerSince = nil
    } else if assessment.reason == .matched {
      if ownerSince == nil { ownerSince = range.upperBound }
      // At least one second of genuinely new audio must support confirmation.
      status = range.upperBound - (ownerSince ?? range.upperBound) >= 16_000 ? .owner : .pending
      reason = status == .owner ? .matched : .pending
    } else {
      ownerSince = nil
    }
    if !changed {
      if let old = reference, old.count == voice.count {
        let sum = zip(old, voice).map { 0.9 * $0 + 0.1 * $1 }
        let norm = sqrt(sum.reduce(Float(0)) { $0 + $1 * $1 })
        reference = norm > 0 ? sum.map { $0 / norm } : voice
      } else { reference = voice }
    }
    let decision = LiveIdentityDecision(range: range, status: status, reason: reason, track: track,
                                        ownerScore: assessment.ownerScore, negativeScore: assessment.negativeScore)
    lastEnd = range.upperBound
    last = decision
    return decision
  }
}
