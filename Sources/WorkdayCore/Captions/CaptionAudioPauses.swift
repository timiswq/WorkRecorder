import AVFoundation

/// Word timestamps sometimes include a long stretch of silence. Measure quiet on
/// the card's PCM timeline as well, recording a boundary only once speech resumes.
struct CaptionAudioPauses {
  private(set) var boundaries: [Double] = []
  private var frames = 0
  private var windowFrames = 0
  private var squares = 0.0
  private var quietStart: Double?
  private var heardSpeech = false

  mutating func append(_ buffer: AVAudioPCMBuffer) {
    let rate = buffer.format.sampleRate
    let window = max(1, Int(rate * 0.02))
    if let pcm = buffer.int16ChannelData?[0] {
      for i in 0..<Int(buffer.frameLength) {
        consume(Double(pcm[i]) / 32768, rate: rate, window: window)
      }
    } else if let pcm = buffer.floatChannelData?[0] {
      for i in 0..<Int(buffer.frameLength) {
        consume(Double(pcm[i]), rate: rate, window: window)
      }
    }
  }

  private mutating func consume(_ sample: Double, rate: Double, window: Int) {
    squares += sample * sample
    windowFrames += 1
    frames += 1
    guard windowFrames == window else { return }
    let start = Double(frames - window) * 1000 / rate
    if squares / Double(window) < 0.000016 { // RMS below approximately -48 dBFS
      if quietStart == nil { quietStart = start }
    } else {
      if heardSpeech, let quietStart, start - quietStart >= AppleCaptionPhrases.pauseMs {
        boundaries.append((quietStart + start) / 2)
      }
      quietStart = nil
      heardSpeech = true
    }
    windowFrames = 0
    squares = 0
  }
}
