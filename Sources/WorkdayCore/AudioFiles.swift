import AVFoundation
import Foundation

public enum AudioFiles {
  public static func slice(_ url: URL, start: Double, end: Double, destination: URL) throws {
    let input = try AVAudioFile(forReading: url)
    let rate = input.processingFormat.sampleRate
    let total = Double(input.length) / rate
    guard start.isFinite, end.isFinite, start >= 0, end > start, end <= total + 0.001,
      !FileManager.default.fileExists(atPath: destination.path)
    else { throw WorkdayError.invalid("剪辑范围无效或目标文件已经存在") }
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let first = AVAudioFramePosition((start * rate).rounded(.down))
    let last = min(input.length, AVAudioFramePosition((end * rate).rounded(.up)))
    var output: AVAudioFile? = try AVAudioFile(
      forWriting: destination,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: rate, AVNumberOfChannelsKey: input.processingFormat.channelCount,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
      ],
      commonFormat: input.processingFormat.commonFormat,
      interleaved: input.processingFormat.isInterleaved)
    input.framePosition = first
    guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192)
    else { throw WorkdayError.invalid("无法创建音频缓冲") }
    while input.framePosition < last {
      try Task.checkCancellation()
      try input.read(
        into: buffer, frameCount: AVAudioFrameCount(min(8192, last - input.framePosition)))
      guard buffer.frameLength > 0 else { throw WorkdayError.invalid("音频读取中断") }
      try output?.write(from: buffer)
    }
    output = nil  // finalize RIFF lengths before verification
    let actual = try duration(destination)
    guard abs(actual - (end - start)) < 0.05 else { throw WorkdayError.invalid("剪辑时长核验失败") }
    let handle = try FileHandle(forWritingTo: destination)
    defer { try? handle.close() }
    try handle.synchronize()
  }
  public static func wavChunk(_ url: URL, start: Double, duration: Double) throws -> Data {
    let file = try AVAudioFile(forReading: url)
    let rate = file.processingFormat.sampleRate
    guard start.isFinite, start >= 0, duration.isFinite, duration > 0, duration <= 120,
      rate > 0, rate <= 384000, file.processingFormat.channelCount <= 8
    else { throw WorkdayError.invalid("转写分段范围或格式无效") }
    file.framePosition = AVAudioFramePosition((start * rate).rounded())
    guard file.framePosition < file.length else { throw WorkdayError.invalid("转写分段超出原件范围") }
    let frames = AVAudioFrameCount(
      min(AVAudioFramePosition((duration * rate).rounded()), file.length - file.framePosition))
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
      let converter = AVAudioConverter(from: file.processingFormat, to: format),
      let output = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(ceil(Double(frames) * 16000 / rate)) + 64)
    else { throw WorkdayError.invalid("无法准备转写音频") }
    var remaining = frames
    var readError: Error?
    var convertError: NSError?
    let status = converter.convert(to: output, error: &convertError) { requested, state in
      if remaining == 0 {
        state.pointee = .endOfStream
        return nil
      }
      do {
        try Task.checkCancellation()
        let count = min(remaining, requested, 8192)
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)
        else { throw WorkdayError.invalid("无法准备读取缓冲") }
        try file.read(into: input, frameCount: count)
        guard input.frameLength > 0 else { throw WorkdayError.invalid("原件在读取时被截断") }
        remaining -= input.frameLength
        state.pointee = .haveData
        return input
      } catch {
        readError = error
        state.pointee = .noDataNow
        return nil
      }
    }
    if let readError { throw readError }
    guard status != .error, convertError == nil, output.frameLength > 0,
      let samples = output.int16ChannelData?[0]
    else { throw WorkdayError.invalid("音频转换失败") }
    return wav(pcm: Data(bytes: samples, count: Int(output.frameLength) * 2))
  }
  public static func wav(pcm: Data) -> Data {
    var data = Data("RIFF".utf8)
    func append<T: FixedWidthInteger>(_ value: T) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    append(UInt32(36 + pcm.count))
    data.append(Data("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(1))
    append(UInt32(16000))
    append(UInt32(32000))
    append(UInt16(2))
    append(UInt16(16))
    data.append(Data("data".utf8))
    append(UInt32(pcm.count))
    data.append(pcm)
    return data
  }
  public static func duration(_ url: URL) throws -> Double {
    if url.pathExtension.lowercased() == "wav" { try validateWAV(url) }
    let input = try AVAudioFile(forReading: url)
    let value = Double(input.length) / input.processingFormat.sampleRate
    guard value.isFinite, value > 0 else { throw WorkdayError.invalid("音频没有可解码的声音数据") }
    return value
  }

  /// Read chunk headers only, never materialize an all-day WAV in memory.
  private static func validateWAV(_ url: URL) throws {
    let size = UInt64(try FileStamp(url).size)
    let input = try FileHandle(forReadingFrom: url)
    defer { try? input.close() }
    let head = try input.read(upToCount: 12) ?? Data()
    func uint(_ bytes: Data) -> UInt64 {
      bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) }
    }
    guard head.count == 12, String(decoding: head.prefix(4), as: UTF8.self) == "RIFF",
      String(decoding: head.suffix(4), as: UTF8.self) == "WAVE",
      uint(head.subdata(in: 4..<8)) + 8 == size
    else {
      throw WorkdayError.invalid("WAV 长度不完整，等待设备保存后再同步")
    }
    var offset: UInt64 = 12
    var hasData = false
    var hasFormat = false
    while offset + 8 <= size {
      try input.seek(toOffset: offset)
      let header = try input.read(upToCount: 8) ?? Data()
      guard header.count == 8 else { throw WorkdayError.invalid("WAV 数据块不完整") }
      let length = uint(header.suffix(4))
      let kind = String(decoding: header.prefix(4), as: UTF8.self)
      guard length <= size - offset - 8 else { throw WorkdayError.invalid("WAV 数据块超出文件长度") }
      if kind == "fmt " { hasFormat = length >= 16 }
      if kind == "data" { hasData = length > 0 }
      offset += 8 + length + length % 2
    }
    guard offset == size, hasData, hasFormat else { throw WorkdayError.invalid("WAV 缺少完整格式或音频块") }
  }
}
