import AVFoundation
import Foundation
import SherpaOnnxC

/// Serializes local ONNX inference; no audio or embedding leaves the process.
public actor SpeakerEncoder {
  private var extractor: OpaquePointer?
  public init() {}
  deinit { if let extractor { SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor) } }

  public func archived(file: URL, start: Double, end: Double) throws -> [Float]? {
    guard (2...120).contains(end - start) else { return nil }
    let data = try AudioFiles.wavChunk(file, start: start, duration: end - start)
    let samples = data.dropFirst(44).withUnsafeBytes { bytes -> [Float] in
      stride(from: 0, to: bytes.count - 1, by: 2).map {
        Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: Int16.self))) / 32768
      }
    }
    return try embedding(samples)
  }

  public func live(packets: Data) throws -> [Float]? {
    guard (4000...240000).contains(packets.count), packets.count.isMultiple(of: 40) else {
      return nil
    }
    let valid = packets.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      stride(from: 0, to: raw.count, by: 40).allSatisfy { i in
        let toc = raw[i]
        return toc >> 3 == 9 && toc & 4 == 0
          && (toc & 3 == 0 || (toc & 3 == 3 && raw[i + 1] & 63 == 1))
      }
    }
    guard valid else { return nil }
    return try embedding(Self.decode(packets))
  }

  /// Realtime windows have already passed continuous VAD/quality checks. Keep
  /// their original PCM timeline; do not splice frames or apply the legacy
  /// per-sentence half-agreement gate a second time.
  public func pcm(_ samples: [Float]) throws -> [Float]? {
    guard samples.count >= 25_600, samples.count <= 160_000,
          samples.allSatisfy(\.isFinite) else { return nil }
    return try vector(samples)
  }

  // The card sends one 20 ms mono Opus packet per 40 bytes. Decode in memory;
  // the ASR timestamps and the ring both use the start of this cloud session.
  static func decode(_ packets: Data) throws -> [Float] {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1) else {
      throw WorkdayError.invalid("无法创建声纹音频格式")
    }
    let output = try CardOpusDecoder(outputFormat: format).decode(packets, endOfStream: true)
    guard let ptr = output.floatChannelData?[0] else { throw WorkdayError.invalid("声纹音频解码失败") }
    return Array(UnsafeBufferPointer(start: ptr, count: Int(output.frameLength)))
  }

  private func embedding(_ samples: [Float]) throws -> [Float]? {
    guard samples.count >= 31000 else { return nil }
    // Ignore near-silent frames. Adjacent voiced halves must agree before a
    // turn can be used to enroll or identify anyone.
    var speech = [Float]()
    for offset in stride(from: 0, to: samples.count - 319, by: 320) {
      let frame = samples[offset..<offset + 320]
      if frame.reduce(Float(0), { $0 + $1 * $1 }) > 0.0013 { speech.append(contentsOf: frame) }
    }
    guard speech.count >= 25600 else { return nil }
    if speech.count > 160_000 {
      // For a long utterance, compare consecutive windows before combining them.
      // This bounds each network input and prevents a changed speaker in the
      // middle of a long turn from being silently assigned to the first.
      let count = (speech.count + 95_999) / 96_000
      var reference: [Float]?
      var sum: [Float] = []
      for i in 0..<count {
        try Task.checkCancellation()
        let window = speech[(i * speech.count / count)..<((i + 1) * speech.count / count)]
        guard let v = try vector(Array(window)) else { return nil }
        if let reference {
          guard Self.similarity(reference, v) >= 0.50 else { return nil }
          for j in sum.indices { sum[j] += v[j] }
        } else {
          reference = v
          sum = v
        }
      }
      let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
      return norm > 0 ? sum.map { $0 / norm } : nil
    }
    let mid = speech.count / 2
    guard let first = try vector(Array(speech[..<mid])),
      let last = try vector(Array(speech[mid...])),
      Self.similarity(first, last) >= 0.42
    else { return nil }
    return try vector(speech)
  }

  private func vector(_ samples: [Float]) throws -> [Float]? {
    if extractor == nil {
      // Packaged apps carry the model in Contents/Resources. SwiftPM tests use its resource bundle.
      let url =
        Bundle.main.url(forResource: "campplus", withExtension: "onnx")
        ?? Bundle.module.url(forResource: "campplus", withExtension: "onnx")
      guard let url else { throw WorkdayError.invalid("缺少本地声纹模型") }
      extractor = url.path.withCString { path in
        "cpu".withCString { cpu in
          var config = SherpaOnnxSpeakerEmbeddingExtractorConfig(
            model: path, num_threads: 2, debug: 0, provider: cpu)
          return SherpaOnnxCreateSpeakerEmbeddingExtractor(&config)
        }
      }
    }
    guard let extractor, let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor)
    else {
      throw WorkdayError.invalid("本地声纹模型无法启动")
    }
    defer { SherpaOnnxDestroyOnlineStream(stream) }
    samples.withUnsafeBufferPointer {
      SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, $0.baseAddress, Int32($0.count))
    }
    SherpaOnnxOnlineStreamInputFinished(stream)
    guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream) == 1,
      let p = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream)
    else { return nil }
    defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(p) }
    let vector = Array(
      UnsafeBufferPointer(start: p, count: Int(SherpaOnnxSpeakerEmbeddingExtractorDim(extractor))))
    let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
    guard norm.isFinite, norm > 0 else { return nil }
    return vector.map { $0 / norm }
  }

  public nonisolated static func similarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return -1 }
    return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
  }
}
