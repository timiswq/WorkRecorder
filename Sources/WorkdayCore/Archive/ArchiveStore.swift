import CryptoKit
import Foundation
import QS668Core

public actor ArchiveStore {
  public nonisolated let root: URL
  public init(root: URL) { self.root = root }
  public func load() throws -> [Recording] {
    let records = root.appendingPathComponent("Records", isDirectory: true)
    guard FileManager.default.fileExists(atPath: records.path) else { return [] }
    guard
      let walker = FileManager.default.enumerator(
        at: records, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])
    else {
      throw WorkdayError.invalid("无法读取本地录音目录")
    }
    var result: [Recording] = []
    for case let file as URL in walker {
      if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
        walker.skipDescendants()
        continue
      }
      if file.lastPathComponent == "recording.json" {
        let item = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: file))
        guard item.folder == "Records/\(item.day)/\(item.id)",
          item.id.allSatisfy({ $0.isHexDigit }), item.id.count == 64,
          !item.originalFile.contains("/"), !item.originalFile.contains("..")
        else {
          throw WorkdayError.invalid("录音索引路径无效：\(file.lastPathComponent)")
        }
        result.append(item)
      }
    }
    return result.sorted { ($0.startedAt ?? $0.importedAt) > ($1.startedAt ?? $1.importedAt) }
  }
  public func importAudio(
    _ url: URL, sourceID: String, companionName: String? = nil, volumeUUID: String? = nil,
    transfer: @Sendable (TransferProgress) -> Void = { _ in },
    progress: @Sendable (Double) -> Void = { _ in }
  ) throws -> Recording {
    try importAudioWithOutcome(
      url, sourceID: sourceID, companionName: companionName, volumeUUID: volumeUUID,
      transfer: transfer, progress: progress).recording
  }

  /// `saved` also includes an OPUS companion newly added to an existing WAV archive.
  public func importAudioWithOutcome(
    _ url: URL, sourceID: String, companionName: String? = nil, volumeUUID: String? = nil,
    transfer: @Sendable (TransferProgress) -> Void = { _ in },
    progress: @Sendable (Double) -> Void = { _ in }
  ) throws -> (recording: Recording, saved: Bool) {
    let fm = FileManager.default
    guard ["wav", "m4a", "mp3", "aiff", "aif"].contains(url.pathExtension.lowercased()) else {
      throw WorkdayError.invalid("请选择 WAV、M4A、MP3 或 AIFF 文件。设备原始 OPUS 会随同名 WAV 一起保存。")
    }
    if let volumeUUID { try Files.checkVolume(volumeUUID, at: url) }
    let source = try FileStamp(url)
    let staging = root.appendingPathComponent(".incoming/\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(
      at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: staging) }
    let originalFile = "original.\(url.pathExtension.lowercased())"
    let copy = staging.appendingPathComponent(originalFile)
    let defaultCompanion = url.deletingPathExtension().appendingPathExtension("opus")
    let pairedName = companionName ?? defaultCompanion.lastPathComponent
    guard pairedName.lowercased() == defaultCompanion.lastPathComponent.lowercased() else {
      throw WorkdayError.invalid("配对文件名与录音不一致")
    }
    let companion = url.deletingLastPathComponent().appendingPathComponent(pairedName)
    let companionStamp =
      url.pathExtension.lowercased() == "wav" && fm.fileExists(atPath: companion.path)
      ? try FileStamp(companion) : nil
    let total = source.size + (companionStamp?.size ?? 0)
    let start = ProcessInfo.processInfo.systemUptime
    var meter = TransferMeter(total: total, at: start)
    transfer(
      TransferProgress(phase: .copying, copied: 0, total: total, bytesPerSecond: nil, uptime: start)
    )
    func wrote(_ bytes: Int64) {
      if let sample = meter.update(bytes, at: ProcessInfo.processInfo.systemUptime) {
        transfer(sample)
        progress(sample.fraction * 0.9)
      }
    }
    let hash = try Files.copyAndHash(from: url, to: copy, bytesWritten: wrote)
    let pairedCopy = staging.appendingPathComponent("original.opus")
    var pairedHash: String?
    if companionStamp != nil {
      pairedHash = try Files.copyAndHash(
        from: companion, to: pairedCopy, bytesWritten: { wrote(source.size + $0) })
    }
    transfer(
      TransferProgress(
        phase: .verifying, copied: total, total: total, bytesPerSecond: nil,
        uptime: ProcessInfo.processInfo.systemUptime))
    guard try FileStamp(url) == source, try Files.hash(url) == hash else {
      throw WorkdayError.invalid("录音文件仍在变化或传输中断，原件已保留，请稍后同步")
    }
    let duration = try AudioFiles.duration(copy)
    guard try Files.hash(copy) == hash else { throw WorkdayError.invalid("本地副本校验失败，请重试") }
    let started = DeviceRecording(duration: 0, size: 0, name: url.lastPathComponent).recordingDate
    let id = Files.digest(Data("\(sourceID)|\(url.lastPathComponent)|\(hash)".utf8))
    let day = started.map(WorkdayDate.day) ?? "日期未知"
    let folder = "Records/\(day)/\(id)"
    let destination = root.appendingPathComponent(folder, isDirectory: true)
    let companionFile = companionStamp == nil ? nil : "original.opus"
    let companionBytes = companionStamp?.size
    if let pairedHash {
      guard try FileStamp(companion) == companionStamp, try Files.hash(companion) == pairedHash,
        try Files.hash(pairedCopy) == pairedHash
      else { throw WorkdayError.invalid("配对 OPUS 尚未保存完整，请稍后同步") }
    }
    guard try FileStamp(url) == source else { throw WorkdayError.invalid("录音文件仍在保存，请稍后同步") }
    if let volumeUUID { try Files.checkVolume(volumeUUID, at: url) }
    // Cross-transport imports share an immutable archive only after content verification.
    if var existing = try load().first(where: {
      $0.originalName == url.lastPathComponent && $0.sha256 == hash
    }),
      try Files.hash(
        root.appendingPathComponent(existing.folder).appendingPathComponent(existing.originalFile))
        == hash
    {
      existing.sourceAliases = Array(Set((existing.sourceAliases ?? []) + [sourceID])).sorted()
      var addedCompanion = false
      if let pairedHash {
        let pairedDestination = root.appendingPathComponent(existing.folder).appendingPathComponent(
          "original.opus")
        if !fm.fileExists(atPath: pairedDestination.path) {
          try fm.moveItem(at: pairedCopy, to: pairedDestination)
          addedCompanion = true
        }
        guard try Files.hash(pairedDestination) == pairedHash else {
          throw WorkdayError.invalid("配对 OPUS 与已有归档不一致，已保留两侧原件，请核对")
        }
        existing.companionFile = "original.opus"
        existing.companionBytes = companionBytes
      }
      try Files.writeJSON(
        existing,
        to: root.appendingPathComponent(existing.folder).appendingPathComponent("recording.json"))
      progress(1)
      return (existing, addedCompanion)
    }
    let item = Recording(
      id: id, startedAt: started, importedAt: Date(), originalName: url.lastPathComponent,
      folder: folder, originalFile: originalFile, companionFile: companionFile, sha256: hash,
      bytes: source.size, duration: duration, companionBytes: companionBytes, sourceID: sourceID)
    try Files.writeJSON(item, to: staging.appendingPathComponent("recording.json"))
    try fm.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try fm.moveItem(at: staging, to: destination)
    progress(1)
    return (item, true)
  }
}

public struct FileStamp: Equatable, Sendable {
  public let size: Int64
  public let modified: Date
  public init(_ url: URL) throws {
    var fresh = url
    fresh.removeAllCachedResourceValues()
    let v = try fresh.resourceValues(forKeys: [
      .fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
    ])
    guard v.isRegularFile == true, v.isSymbolicLink != true, let size = v.fileSize, size > 0,
      let date = v.contentModificationDate
    else {
      throw WorkdayError.invalid("文件为空、不可读取或不是普通音频文件")
    }
    self.size = Int64(size)
    modified = date
  }
}

public enum Files {
  public static func checkVolume(_ uuid: String, at url: URL) throws {
    // Recreate the URL so a cached resource value cannot hide a remount at the same path.
    let fresh = URL(fileURLWithPath: url.path)
    guard try fresh.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString == uuid else {
      throw WorkdayError.invalid("挂载位置的设备已变化，请重新连接所选录音卡")
    }
  }

  public static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  public static func hash(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    return try hash(file)
  }
  public static func hash(_ file: FileHandle) throws -> String {
    var hash = SHA256()
    while try autoreleasepool(invoking: { () throws -> Bool in
      guard let data = try file.read(upToCount: 1_048_576), !data.isEmpty else { return false }
      try Task.checkCancellation()
      hash.update(data: data)
      return true
    }) {}
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  public static func copyAndHash(
    from source: URL, to destination: URL, bytesWritten: (Int64) -> Void = { _ in },
    progress: (Double) -> Void = { _ in }
  ) throws -> String {
    let expected = try FileStamp(source).size
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    guard
      FileManager.default.createFile(
        atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else { throw WorkdayError.invalid("无法创建归档文件") }
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    var hash = SHA256()
    var copied: Int64 = 0
    while try autoreleasepool(invoking: { () throws -> Bool in
      guard let data = try input.read(upToCount: 1_048_576), !data.isEmpty else { return false }
      try Task.checkCancellation()
      try output.write(contentsOf: data)
      hash.update(data: data)
      copied += Int64(data.count)
      bytesWritten(copied)
      progress(min(1, Double(copied) / Double(expected)))
      return true
    }) {}
    guard copied == expected else { throw WorkdayError.invalid("复制长度发生变化，请重新同步") }
    try output.synchronize()
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  public static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.synchronize()
  }
}
