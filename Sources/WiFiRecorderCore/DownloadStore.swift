import CryptoKit
import Foundation

public final class DownloadStore {
  public let root: URL
  public init(root: URL) { self.root = root }
  public static func directoryName(for device: String) -> String {
    let identity = SHA256.hash(data: Data(device.utf8)).prefix(12).map {
      String(format: "%02x", $0)
    }.joined()
    return "device_\(identity)"
  }
  public static func key(device: String, file: RecordingEntry) -> String {
    "\(directoryName(for: device))/\(file.id)_\(file.size).bin"
  }
  public func url(device: String, file: RecordingEntry, partial: Bool) -> URL {
    let completed = root.appendingPathComponent(Self.key(device: device, file: file))
    return partial ? completed.deletingPathExtension().appendingPathExtension("part") : completed
  }
  public func completed(device: String, file: RecordingEntry) -> URL? {
    let p = url(device: device, file: file, partial: false)
    guard (try? validateDirectory(for: p)) != nil,
      let values = try? p.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
      values.isRegularFile == true, values.isSymbolicLink != true,
      (try? FileManager.default.attributesOfItem(atPath: p.path)[.size] as? NSNumber)?.uint64Value
        == file.size
    else { return nil }
    return p
  }
  private func validateDirectory(for file: URL) throws {
    for directory in [root, file.deletingLastPathComponent()] {
      if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
        throw WiFiRecorderError.invalid("下载目录不能是符号链接")
      }
    }
  }
  public func begin(device: String, file: RecordingEntry, resume: Bool) throws -> DownloadSink {
    let part = url(device: device, file: file, partial: true)
    let done = url(device: device, file: file, partial: false)
    try validateDirectory(for: part)
    try FileManager.default.createDirectory(
      at: part.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard !FileManager.default.fileExists(atPath: done.path) else {
      throw WiFiRecorderError.invalid("已存在完成文件，请先核对，不覆盖原件")
    }
    let attrs = try? FileManager.default.attributesOfItem(atPath: part.path)
    guard (attrs?[.type] as? FileAttributeType) != .typeSymbolicLink else {
      throw WiFiRecorderError.invalid("断点路径不能是符号链接")
    }
    let offset: UInt64 = resume ? (attrs?[.size] as? NSNumber)?.uint64Value ?? 0 : 0
    guard offset <= file.size else { throw WiFiRecorderError.invalid("断点大于文件，请选择重新下载") }
    if let free =
      (try? FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize])
      as? NSNumber, free.uint64Value < file.size - offset + 1_048_576
    {
      throw WiFiRecorderError.invalid("磁盘剩余空间不足")
    }
    if !FileManager.default.fileExists(atPath: part.path) {
      guard FileManager.default.createFile(atPath: part.path, contents: nil) else {
        throw WiFiRecorderError.invalid("不能创建断点文件")
      }
    }
    let handle = try FileHandle(forWritingTo: part)
    do {
      if offset == 0 { try handle.truncate(atOffset: 0) }
      try handle.seek(toOffset: offset)
    } catch {
      try? handle.close()
      throw error
    }
    return DownloadSink(
      handle: handle, partial: part, destination: done, expected: file.size, offset: offset)
  }
}
public final class DownloadSink {
  private var handle: FileHandle?
  public let partial: URL, destination: URL, expected: UInt64, offset: UInt64
  public private(set) var received: UInt64
  public private(set) var ended = false
  init(handle: FileHandle, partial: URL, destination: URL, expected: UInt64, offset: UInt64) {
    self.handle = handle
    self.partial = partial
    self.destination = destination
    self.expected = expected
    self.offset = offset
    received = offset
  }
  /// Returns true only for a validated END, synchronized/closed and atomically committed.
  public func accept(_ b: [UInt8]) throws -> Bool {
    guard let handle, !ended else { throw WiFiRecorderError.invalid("下载已结束") }
    if b.count == 5, b[0] == 0 {
      guard Wire.be32(b, 1) == expected else { throw WiFiRecorderError.invalid("大小通告与列表不符") }
      return false
    }
    if b == [1] { throw WiFiRecorderError.invalid("设备拒绝下载，状态1") }
    if b == [2] {
      guard received == expected else {
        throw WiFiRecorderError.invalid("提前结束：\(received)/\(expected)字节")
      }
      try handle.synchronize()
      try handle.close()
      self.handle = nil
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw WiFiRecorderError.invalid("完成文件已存在，不覆盖")
      }
      try FileManager.default.moveItem(at: partial, to: destination)
      ended = true
      return true
    }
    guard !b.isEmpty, UInt64(b.count) <= expected - received else {
      throw WiFiRecorderError.invalid("文件数据为空或超过声明长度")
    }
    try handle.write(contentsOf: Data(b))
    received += UInt64(b.count)
    return false
  }
  public func close() {
    if let handle {
      try? handle.synchronize()
      try? handle.close()
    }
    handle = nil
  }
  deinit { close() }
}
