import Foundation

/// Packet-aligned Opus with a decoder preroll. Only the indicated PCM frames are audible.
struct CaptionReplay: Equatable {
  struct Frames: Codable, Equatable {
    let sessionStart: Int
    let start: Int
    let end: Int
  }
  let frames: Frames
  let packets: Data

  init?(audio: Data, startMs: Double?, endMs: Double?) {
    let completePackets = audio.count / 40
    guard let startMs, let endMs, startMs.isFinite, endMs.isFinite,
      startMs >= 0, endMs > startMs, endMs <= Double(completePackets) * 20 + 1
    else { return nil }
    let start = Int((startMs * 16).rounded())
    let end = min(completePackets * 320, Int((endMs * 16).rounded()))
    guard end > start else { return nil }
    // Opus seeks need 80 ms of prior packets to warm the decoder.
    let firstPacket = max(0, start / 320 - 4)
    // Core Audio trims decoder priming samples. One trailing packet supplies the
    // end of a phrase even when its last sample lies exactly on a packet edge.
    let lastPacket = min(completePackets, (end + 319) / 320 + 1)
    let base = audio.startIndex
    packets = audio.subdata(in: base + firstPacket * 40..<base + lastPacket * 40)
    frames = Frames(sessionStart: start, start: start - firstPacket * 320, end: end - firstPacket * 320)
  }
}
