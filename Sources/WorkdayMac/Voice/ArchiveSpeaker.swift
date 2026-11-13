import Foundation
import WorkdayCore

/// A speaker number returned by the transcriber is local to one chunk of one recording.
struct ArchiveSpeaker {
  var turns: [String] = []
  var windows: [Range<Double>] = []
  private(set) var indexedVoices: [Range<Double>: [Float]] = [:]
  var voice: [Float]?

  mutating func add(turn: String, start: Double, end: Double, overlap: Bool, indexedVoice: [Float]? = nil) {
    turns.append(turn)
    guard !overlap, start.isFinite, end.isFinite, start >= 0, end - start >= 3 else { return }
    let window = start..<min(end, start + 20)
    windows.append(window)
    // Reuse the encoder's result only when it covers exactly this window.
    if window.upperBound == end, let indexedVoice { indexedVoices[window] = indexedVoice }
    windows.sort {
      let lhs = $0.upperBound - $0.lowerBound, rhs = $1.upperBound - $1.lowerBound
      return lhs == rhs ? $0.lowerBound < $1.lowerBound : lhs > rhs
    }
    if windows.count > 3 { indexedVoices.removeValue(forKey: windows.removeLast()) }
  }

  var signature: String {
    windows.map { "\($0.lowerBound.bitPattern)-\($0.upperBound.bitPattern)" }.joined(separator: ",")
  }

  /// Prefer three agreeing samples or the only agreeing pair. An ambiguous set cannot teach a name.
  static func centroid(_ vectors: [[Float]]) -> [Float]? {
    guard !vectors.isEmpty else { return nil }
    var chosen = vectors
    if vectors.count > 1 {
      var pairs: [(Int, Int)] = []
      for i in vectors.indices {
        for j in vectors.indices where j > i && SpeakerEncoder.similarity(vectors[i], vectors[j]) >= 0.62 {
          pairs.append((i, j))
        }
      }
      if pairs.count == 1, let pair = pairs.first {
        chosen = [vectors[pair.0], vectors[pair.1]]
      } else if pairs.count != 3 {
        return nil
      }
    }
    var sum = chosen[0]
    for vector in chosen.dropFirst() {
      for i in sum.indices { sum[i] += vector[i] }
    }
    let norm = sqrt(sum.reduce(Float(0)) { $0 + $1 * $1 })
    return norm.isFinite && norm > 0 ? sum.map { $0 / norm } : nil
  }
}
