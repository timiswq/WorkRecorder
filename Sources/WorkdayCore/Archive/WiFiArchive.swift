import Foundation
import WiFiRecorderCore

/// File identity on the card, independent of the decoded audio and the Mac's import date.
public struct WiFiOriginal: Codable, Equatable, Sendable {
  public var device: String
  public var wireName: String
  public var bytes: Int64
  public var sha256: String
  public static let filename = "device.bin"
  public var key: String { "\(device)/\(wireName)_\(bytes).bin" }
}

extension ArchiveStore {
  public nonisolated var wifiInbox: URL {
    root.appendingPathComponent("Sync/WiFiTransfers", isDirectory: true)
  }

  public func pendingWiFiFiles() throws -> [URL] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: wifiInbox.path) else { return [] }
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    var pending: [URL] = []
    for directory in try fm.contentsOfDirectory(
      at: wifiInbox, includingPropertiesForKeys: Array(keys))
    {
      let info = try directory.resourceValues(forKeys: keys)
      guard
        directory.lastPathComponent.range(
          of: #"^device_[a-f0-9]{24}$"#, options: .regularExpression) != nil,
        info.isDirectory == true, info.isSymbolicLink != true
      else { continue }
      for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
      where url.pathExtension == "bin" {
        let info = try url.resourceValues(forKeys: keys)
        if info.isRegularFile == true && info.isSymbolicLink != true { pending.append(url) }
      }
    }
    return pending.sorted { $0.path < $1.path }
  }

  public func verifiedWiFiKeys() throws -> Set<String> {
    var keys = Set<String>()
    for row in try load() {
      guard let original = row.wifiOriginal else { continue }
      let directory = root.appendingPathComponent(row.folder)
      if (try? Files.hash(directory.appendingPathComponent(WiFiOriginal.filename)))
        == original.sha256,
        (try? Files.hash(directory.appendingPathComponent(row.originalFile))) == row.sha256
      {
        keys.insert(original.key)
      }
    }
    return keys
  }

  /// Only consume an END-committed download. The incoming bin remains available after any failure.
  public func archiveWiFiFile(_ url: URL) throws -> Recording {
    let fm = FileManager.default
    let directory = url.deletingLastPathComponent()
    let name = url.deletingPathExtension().lastPathComponent.split(separator: "_")
    guard
      directory.deletingLastPathComponent().standardizedFileURL.path
        == wifiInbox.standardizedFileURL.path,
      directory.lastPathComponent.range(of: #"^device_[a-f0-9]{24}$"#, options: .regularExpression)
        != nil,
      try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
      url.pathExtension == "bin", name.count == 2, name[0].utf8.count == 28,
      name[0].allSatisfy(\.isHexDigit), let expected = Int64(name[1]), expected > 0,
      try FileStamp(url).size == expected
    else { throw WorkdayError.invalid("录音卡原件名称或长度无效") }
    let wire = String(name[0]).uppercased()
    let rawName = stride(from: 0, to: 28, by: 2).compactMap { start -> UInt8? in
      UInt8(wire.dropFirst(start).prefix(2), radix: 16)
    }
    let display = String(decoding: rawName.prefix { $0 != 0 }, as: UTF8.self)
    let stage = root.appendingPathComponent(".incoming/\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(
      at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: stage) }
    let bin = stage.appendingPathComponent(WiFiOriginal.filename)
    let rawHash = try Files.copyAndHash(from: url, to: bin, bytesWritten: { _ in })
    guard try FileStamp(bin).size == expected, try Files.hash(bin) == rawHash else {
      throw WorkdayError.invalid("设备原件复制校验失败")
    }
    let original = WiFiOriginal(
      device: directory.lastPathComponent, wireName: wire, bytes: expected, sha256: rawHash)
    let id = Files.digest(Data("wifi|\(original.key)|\(rawHash)".utf8))
    let folder = "Records/日期未知/\(id)"
    let destination = root.appendingPathComponent(folder)
    let wav = stage.appendingPathComponent("original.wav")
    let decoded = try RecordingDecoder.decode(source: bin, destination: wav)
    let wavHash = try Files.hash(wav)
    let item = Recording(
      id: id, startedAt: nil, importedAt: Date(), originalName: display,
      folder: folder, originalFile: "original.wav", sha256: wavHash, bytes: try FileStamp(wav).size,
      duration: decoded.duration, sourceID: "wifi:\(original.device)", wifiOriginal: original)
    if fm.fileExists(atPath: destination.path) {
      let existing = try JSONDecoder().decode(
        Recording.self, from: Data(contentsOf: destination.appendingPathComponent("recording.json"))
      )
      guard existing.id == id, existing.wifiOriginal == original, existing.sha256 == wavHash,
        existing.originalFile == "original.wav"
      else { throw WorkdayError.invalid("已有归档与录音原件不一致") }
      for (source, hash) in [(bin, rawHash), (wav, wavHash)] {
        let target = destination.appendingPathComponent(source.lastPathComponent)
        if (try? Files.hash(target)) != hash {
          if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(
              target, withItemAt: source, backupItemName: "replaced-\(UUID().uuidString)")
          } else {
            try fm.moveItem(at: source, to: target)
          }
        }
      }
      return existing
    }
    try Files.writeJSON(item, to: stage.appendingPathComponent("recording.json"))
    try fm.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try fm.moveItem(at: stage, to: destination)
    return item
  }
}
