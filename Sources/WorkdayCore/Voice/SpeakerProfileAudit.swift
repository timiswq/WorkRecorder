import Foundation

/// Audit against other samples only. A singleton has no consistency evidence.
public enum SpeakerProfileAudit {
  public static func consistency(_ samples: [[Float]]) -> [Float?] {
    samples.indices.map { heldOut in
      let others = samples.indices.filter { $0 != heldOut }.map { samples[$0] }
        .filter { $0.count == samples[heldOut].count && !$0.isEmpty && $0.allSatisfy(\.isFinite) }
      guard let first = others.first else { return nil }
      var sum = first
      for vector in others.dropFirst() { for i in sum.indices { sum[i] += vector[i] } }
      let norm = sqrt(sum.reduce(Float(0)) { $0 + $1 * $1 })
      guard norm.isFinite, norm > 0 else { return nil }
      return SpeakerEncoder.similarity(samples[heldOut], sum.map { $0 / norm })
    }
  }
}
