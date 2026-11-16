import Foundation

public struct DecodedRecording: Codable, Equatable {
  public let packets: Int
  public let samples: UInt64
  public var duration: Double { Double(samples) / 16000 }
}
public enum RecordingDecoder {
  public static func decode(source: URL, destination: URL) throws -> DecodedRecording {
    let fm = FileManager.default
    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw AudioError.invalid("原始录音不是普通文件")
    }
    guard !fm.fileExists(atPath: destination.path) else { throw AudioError.invalid("WAV已存在，不覆盖") }
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    try fm.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let part = destination.deletingLastPathComponent().appendingPathComponent(
      ".decode-\(UUID().uuidString).part")
    guard fm.createFile(atPath: part.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else { throw AudioError.invalid("无法创建解码文件") }
    defer { try? fm.removeItem(at: part) }
    let output = try FileHandle(forWritingTo: part)
    defer { try? output.close() }
    try output.write(contentsOf: wavHeader(bytes: 0))
    guard let decoder = RecorderOpusDecoder() else { throw AudioError.invalid("无法创建Opus解码器") }
    var packets = 0
    var samples: UInt64 = 0
    while true {
      let header = try read(input, count: RecordingPacketHeader.byteCount)
      if header.isEmpty { break }
      guard header.count == RecordingPacketHeader.byteCount else { throw AudioError.invalid("录音头不完整（第\(packets + 1)包）") }
      guard let packet = RecordingPacketHeader(header) else { throw AudioError.invalid("无法识别的录音封装或包长度") }
      let payload = try read(input, count: packet.payloadLength)
      guard payload.count == packet.payloadLength else { throw AudioError.invalid("录音数据被截断（第\(packets + 1)包）") }
      guard let decoded = decoder.decode(payload) else { throw AudioError.invalid("不支持此录音编码或声道参数") }
      guard decoded.finalRange == packet.finalRange else {
        throw AudioError.invalid("录音内容校验失败（第\(packets + 1)包），请重新下载后核对")
      }
      packets += 1
      samples += UInt64(decoded.samples.count)
      guard samples * 2 <= UInt64(UInt32.max) - 36 else {
        throw AudioError.invalid("录音超过当前WAV长度上限")
      }
      try decoded.samples.withUnsafeBytes { try output.write(contentsOf: Data($0)) }
    }
    guard packets > 0 else { throw AudioError.invalid("录音文件为空") }
    try output.seek(toOffset: 0)
    try output.write(contentsOf: wavHeader(bytes: UInt32(samples * 2)))
    try output.synchronize()
    try output.close()
    try fm.moveItem(at: part, to: destination)
    return DecodedRecording(packets: packets, samples: samples)
  }
  private static func read(_ handle: FileHandle, count: Int) throws -> Data {
    var data = Data()
    while data.count < count {
      guard let next = try handle.read(upToCount: count - data.count), !next.isEmpty else { break }
      data.append(next)
    }
    return data
  }
  private static func wavHeader(bytes: UInt32) -> Data {
    var data = Data("RIFF".utf8)
    func u16(_ x: UInt16) {
      data.append(UInt8(x & 255))
      data.append(UInt8(x >> 8))
    }
    func u32(_ x: UInt32) {
      u16(UInt16(x & 65535))
      u16(UInt16(x >> 16))
    }
    u32(bytes + 36)
    data.append(Data("WAVEfmt ".utf8))
    u32(16)
    u16(1)
    u16(1)
    u32(16000)
    u32(32000)
    u16(2)
    u16(16)
    data.append(Data("data".utf8))
    u32(bytes)
    return data
  }
}
public enum AudioError: LocalizedError {
  case invalid(String)
  public var errorDescription: String? {
    if case .invalid(let text) = self { return text }
    return nil
  }
}
