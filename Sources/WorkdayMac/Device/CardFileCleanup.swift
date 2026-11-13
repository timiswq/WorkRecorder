import Darwin
import Foundation
import WorkdayCore

extension ArchiveStore {
  /// Only a fresh scan of the mounted card supplies deletion paths. The ledger identifies the Mac copy.
  func removeArchivedCardFiles(_ file: SyncFile, recordingID: String, volume: USBVolume) throws
    -> Int64
  {
    let source = URL(fileURLWithPath: file.path)
    let directory = volume.url.appendingPathComponent("record", isDirectory: true)
    let mount = volume.url.standardizedFileURL.resolvingSymlinksInPath()
    let library = root.standardizedFileURL.resolvingSymlinksInPath()
    guard file.sourceID == volume.id,
      source.deletingLastPathComponent().standardizedFileURL.path
        == directory.standardizedFileURL.path,
      file.name.range(
        of: #"^(note|call)[0-9]{8}-[0-9]{6}\.wav$"#,
        options: [.regularExpression, .caseInsensitive]) != nil,
      library.path != mount.path, !library.path.hasPrefix(mount.path + "/"),
      let recording = try load().first(where: { $0.id == recordingID }),
      recording.originalName == file.name, recording.originalFile == "original.wav",
      recording.bytes == file.size,
      ([recording.sourceID] + (recording.sourceAliases ?? [])).contains(volume.id)
    else { throw WorkdayError.invalid("无法确认录音卡或本地归档的位置，已保留卡内文件") }

    let folder = library.appendingPathComponent(recording.folder).resolvingSymlinksInPath()
    guard folder.path.hasPrefix(library.path + "/"), !folder.path.hasPrefix(mount.path + "/") else {
      throw WorkdayError.invalid("归档位置与录音卡不独立，已保留卡内文件")
    }
    // Keep the directory open through verification and unlink. A replacement mount cannot redirect unlinkat.
    let recordFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard recordFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(recordFD) }
    func checkMount() throws {
      // Discovery URLs can cache resource values. Read the current UUID at the mount path.
      let fresh = URL(fileURLWithPath: volume.url.path)
      let uuid = try fresh.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
      var opened = stat()
      var current = stat()
      var device = stat()
      guard let uuid, volume.id == "usb:" + uuid, fstat(recordFD, &opened) == 0,
        lstat(directory.path, &current) == 0, stat(fresh.path, &device) == 0,
        opened.st_dev == device.st_dev, opened.st_dev == current.st_dev,
        opened.st_ino == current.st_ino
      else { throw WorkdayError.invalid("录音卡已断开或挂载位置已变化，暂停清理") }
    }
    try checkMount()

    let expectedPair = source.deletingPathExtension().appendingPathExtension("opus")
      .lastPathComponent.lowercased()
    func pairNames() throws -> [String] {
      try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
        $0.lowercased() == expectedPair
      }
    }
    let names = try pairNames()
    var verified: [VerifiedCardFile] = []
    if let size = file.companionSize {
      guard names.count == 1, let name = names.first, recording.companionFile == "original.opus",
        recording.companionBytes == size, let modified = file.companionModified
      else { throw WorkdayError.invalid("配对 OPUS 与归档不匹配，已保留卡内文件") }
      verified.append(
        try VerifiedCardFile(
          directory: directory, directoryFD: recordFD, name: name,
          size: size, modified: modified,
          archive: folder.appendingPathComponent("original.opus"), expectedHash: nil))
    } else {
      guard names.isEmpty else { throw WorkdayError.invalid("录音卡出现新的配对文件，等待重新同步") }
      if recording.companionFile != nil {
        guard recording.companionFile == "original.opus",
          try FileStamp(folder.appendingPathComponent("original.opus")).size
            == recording.companionBytes
        else { throw WorkdayError.invalid("Mac 上的配对 OPUS 不完整，已保留卡内 WAV") }
      }
    }
    verified.append(
      try VerifiedCardFile(
        directory: directory, directoryFD: recordFD, name: file.name,
        size: file.size, modified: file.modified,
        archive: folder.appendingPathComponent(recording.originalFile),
        expectedHash: recording.sha256))
    try Task.checkCancellation()
    try checkMount()
    guard try pairNames() == names else { throw WorkdayError.invalid("配对文件已变化，等待重新同步") }
    for item in verified { try item.checkIdentity(in: recordFD) }
    // Remove the companion first so the WAV remains discoverable if removal is interrupted.
    for item in verified {
      try item.checkIdentity(in: recordFD)
      guard unlinkat(recordFD, item.name, 0) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
    return file.size + (file.companionSize ?? 0)
  }
}

private struct VerifiedCardFile {
  let name: String
  let archive: URL
  let sourceHandle: FileHandle
  let archiveHandle: FileHandle
  let sourceStat: stat
  let archiveStat: stat

  init(
    directory: URL, directoryFD: Int32, name: String, size: Int64, modified: Date,
    archive: URL, expectedHash: String?
  ) throws {
    self.name = name
    self.archive = archive
    let stamp = try FileStamp(directory.appendingPathComponent(name))
    guard stamp.size == size, stamp.modified == modified else {
      throw WorkdayError.invalid("卡内文件已发生变化，等待重新同步")
    }
    let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    let src = openat(directoryFD, name, flags)
    guard src >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    sourceHandle = FileHandle(fileDescriptor: src, closeOnDealloc: true)
    let dst = open(archive.path, flags)
    guard dst >= 0 else { throw WorkdayError.invalid("找不到本地归档文件，已保留卡内文件") }
    archiveHandle = FileHandle(fileDescriptor: dst, closeOnDealloc: true)
    var s = stat()
    var d = stat()
    guard fstat(src, &s) == 0, fstat(dst, &d) == 0, s.st_mode & S_IFMT == S_IFREG,
      d.st_mode & S_IFMT == S_IFREG, s.st_size == size, d.st_size == size,
      s.st_dev != d.st_dev || s.st_ino != d.st_ino
    else { throw WorkdayError.invalid("录音文件类型或长度与归档不符，已保留卡内文件") }
    sourceStat = s
    archiveStat = d
    let localHash = try Files.hash(archiveHandle)
    guard expectedHash.map({ $0 == localHash }) ?? true, try Files.hash(sourceHandle) == localHash
    else {
      throw WorkdayError.invalid("卡内录音与 Mac 副本校验不一致，已保留卡内文件")
    }
  }

  func checkIdentity(in directoryFD: Int32) throws {
    var currentSource = stat()
    var currentArchive = stat()
    func unchanged(_ old: stat, _ new: stat) -> Bool {
      old.st_dev == new.st_dev && old.st_ino == new.st_ino && old.st_size == new.st_size
        && old.st_mtimespec.tv_sec == new.st_mtimespec.tv_sec
        && old.st_mtimespec.tv_nsec == new.st_mtimespec.tv_nsec
        && old.st_ctimespec.tv_sec == new.st_ctimespec.tv_sec
        && old.st_ctimespec.tv_nsec == new.st_ctimespec.tv_nsec
    }
    guard fstatat(directoryFD, name, &currentSource, AT_SYMLINK_NOFOLLOW) == 0,
      lstat(archive.path, &currentArchive) == 0,
      unchanged(sourceStat, currentSource), unchanged(archiveStat, currentArchive)
    else { throw WorkdayError.invalid("校验期间文件已变化，暂停清理") }
  }
}
