import Combine
import Foundation
import WorkdayCore

struct USBRecordingRun {
  private(set) var positions: [String] = []
  private(set) var waiting = Set<String>()
  private(set) var complete = false
  var saved = 0
  var deleted = 0

  mutating func plan(_ ids: Set<String>, complete: Bool) {
    waiting = ids.subtracting(positions)
    self.complete = complete
  }

  mutating func begin(_ id: String, planned: Set<String>, complete: Bool) {
    if !positions.contains(id) {
      if waiting.isEmpty && !positions.isEmpty { self = USBRecordingRun() }
      positions.append(id)
    }
    plan(planned, complete: complete)
  }

  func transfer(file: SyncFile, progress: TransferProgress?) -> DeviceSyncTransfer? {
    guard let index = positions.firstIndex(of: file.id) else { return nil }
    return .init(name: file.name, position: index + 1,
                 count: complete ? positions.count + waiting.count : nil, progress: progress)
  }
}

/// One copy at a time; new discoveries remain queued while an import awaits disk I/O.
@MainActor final class SyncCoordinator: ObservableObject {
  @Published private(set) var ledger = SyncLedger()
  @Published private(set) var transfer: TransferProgress?
  @Published private(set) var cleaningFile: SyncFile?
  @Published private(set) var clearedBytesByVolume: [String: Int64] = [:]
  @Published private(set) var deviceRun = USBRecordingRun()
  private var mountGeneration = UUID()
  private var plannedUSB = Set<String>()
  private var completeUSBPlan = false
  private var mounted: [USBVolume] = []
  var deviceTransfer: DeviceSyncTransfer? {
    guard let file = activeFile, mounted.first?.id == file.sourceID else { return nil }
    return deviceRun.transfer(file: file, progress: transfer)
  }
  private var cleanable: [SyncFile] = []
  private var removed = Set<String>()
  private var retryCleanupAfter: [String: Date] = [:]
  var cleanupEnabled = true {
    didSet { if !cleanupEnabled && cleanupFailed { clearError() } }
  }
  var cleanupFailed: Bool {
    failedFile.map { retryCleanupAfter[$0.id] != nil } ?? false
  }
  @Published private(set) var activeFile: SyncFile?
  var label: String? {
    activeFile.map { ($0.sourceID.hasPrefix("usb:") ? "正在同步 " : "正在导入 ") + $0.name }
  }
  var usbLabel: String? { activeFile?.sourceID.hasPrefix("usb:") == true ? label : nil }
  @Published private(set) var error: String?
  private(set) var failedFile: SyncFile?
  @Published private(set) var completedThisRun = 0
  var onArchived: ((Recording) async -> Void)?
  private let store: ArchiveStore
  private var available = Set<String>()
  private var task: Task<Void, Never>?
  private var loaded = false
  private var stopping = false
  private var revision = 0
  private var savedRevision = -1
  var isBusy: Bool { task != nil || activeFile != nil }
  init(store: ArchiveStore) { self.store = store }

  /// Let the isolated native scene exercise the same status and action routing as a real copy.
  func setSceneTransfer(_ progress: TransferProgress?, files: [SyncFile] = []) {
    guard SceneWindowCapture.isRunning, task == nil else { return }
    deviceRun = USBRecordingRun()
    activeFile = nil
    transfer = nil
    guard let progress, files.count >= 2, files[1].sourceID == mounted.first?.id else { return }
    let planned = Set(files.map(\.id))
    for file in files.prefix(2) {
      deviceRun.begin(file.id, planned: planned, complete: true)
    }
    transfer = progress
    activeFile = files[1]
  }

  func load() async throws {
    ledger = try await store.loadSyncLedger()
    // Repair external deletion of local copies without treating a mere cached row as success.
    for i in ledger.entries.indices {
      if let id = ledger.entries[i].recordingID, try await !store.archivedFileExists(id) {
        ledger.entries[i].recordingID = nil
        ledger.entries[i].error = "本地原件缺失，等待重新同步"
      }
    }
    let manual = ledger.entries.filter {
      $0.recordingID == nil && !$0.file.sourceID.hasPrefix("usb:")
    }
    for entry in manual {
      if let stamp = try? FileStamp(URL(fileURLWithPath: entry.file.path)) {
        let file = SyncFile(
          sourceID: entry.file.sourceID, path: entry.file.path, size: stamp.size,
          modified: stamp.modified)
        ledger.discover([file])
        available.insert(file.id)
      }
    }
    loaded = true
  }
  func offer(_ files: [SyncFile]) {
    guard loaded, !stopping else { return }
    let previous = ledger.entries
    ledger.discover(files)
    available.formUnion(files.map(\.id))
    if ledger.entries != previous { revision += 1 }
    pump()
  }
  func updateUSB(_ files: [SyncFile], stableFiles: [SyncFile], volumes: [USBVolume],
                 planned: [SyncFile]? = nil, complete: Bool = false) {
    if mounted != volumes {
      mountGeneration = UUID()
      deviceRun = USBRecordingRun()
    }
    mounted = volumes
    cleanable = stableFiles.filter { $0.path.lowercased().hasSuffix(".wav") }
    let present = Set(cleanable.map(\.id))
    removed.formIntersection(present)
    retryCleanupAfter = retryCleanupAfter.filter { present.contains($0.key) }
    clearedBytesByVolume = clearedBytesByVolume.filter { key, _ in volumes.contains { $0.id == key }
    }
    let ids = Set(ledger.entries.filter { !$0.file.sourceID.hasPrefix("usb:") }.map(\.id))
    available.formIntersection(ids)
    let eligible = files.filter { !removed.contains($0.id) }
    let archived = Set(ledger.entries.compactMap { $0.recordingID == nil ? nil : $0.id })
    plannedUSB = Set((planned ?? eligible).filter(\.supported).map(\.id)).subtracting(archived)
    completeUSBPlan = complete
    if activeFile.map({ $0.sourceID == mounted.first?.id }) == true || !deviceRun.waiting.isEmpty {
      if deviceRun.waiting != plannedUSB.subtracting(deviceRun.positions) || deviceRun.complete != complete {
        deviceRun.plan(plannedUSB, complete: complete)
      }
    }
    if !eligible.isEmpty {
      offer(eligible)
    } else if !available.isEmpty || !cleanable.isEmpty {
      // A local import may still be pending after a restart or retry backoff.
      pump()
    }
  }
  func retry() {
    clearError()
    retryCleanupAfter.removeAll()
    ledger.retry()
    revision += 1
    pump()
  }
  func clearError() {
    failedFile = nil
    error = nil
  }
  private func nextCleanup() -> (SyncFile, USBVolume, String)? {
    guard cleanupEnabled else { return nil }
    let now = Date()
    for file in cleanable
    where !removed.contains(file.id) && (retryCleanupAfter[file.id] ?? .distantPast) <= now {
      guard let volume = mounted.first(where: { $0.id == file.sourceID }) else { continue }
      // A disconnect between unlinking the OPUS and WAV leaves a WAV-only scan on reconnect.
      let entry = ledger.entries.last { item in
        guard item.recordingID != nil else { return false }
        let known = item.file
        return known.sourceID == file.sourceID && known.name == file.name
          && known.size == file.size && known.modified == file.modified
          && (file.companionSize == nil
            || (known.companionSize == file.companionSize
              && known.companionModified == file.companionModified))
      }
      if let id = entry?.recordingID { return (file, volume, id) }
    }
    return nil
  }

  private func clean(_ file: SyncFile, on volume: USBVolume, recordingID: String) async {
    let mount = mountGeneration
    cleaningFile = file
    defer { cleaningFile = nil }
    do {
      let bytes = try await store.removeArchivedCardFiles(
        file, recordingID: recordingID, volume: volume)
      removed.insert(file.id)
      available.remove(file.id)
      if ledger.entries.contains(where: { $0.id == file.id && $0.recordingID == nil }) {
        ledger.complete(file.id, recordingID: recordingID)
        revision += 1
      }
      clearedBytesByVolume[volume.id, default: 0] += bytes
      if mount == mountGeneration && mounted.first?.id == file.sourceID { deviceRun.deleted += 1 }
      if failedFile?.id == file.id { clearError() }
    } catch {
      guard !Task.isCancelled else { return }
      retryCleanupAfter[file.id] = Date().addingTimeInterval(60)
      failedFile = file
      self.error = "\(file.name) 的卡内副本暂未清理：\(error.localizedDescription)"
    }
  }

  private func pump() {
    guard loaded, !stopping, task == nil else { return }
    task = Task {
      defer {
        task = nil
        activeFile = nil
      }
      do {
        while !Task.isCancelled {
          if savedRevision != revision {
            let saving = revision
            try await store.saveSyncLedger(ledger)
            savedRevision = saving
          }
          if let (file, volume, recordingID) = nextCleanup() {
            await clean(file, on: volume, recordingID: recordingID)
            continue
          }
          guard let entry = ledger.next(available: available, at: Date()) else {
            if savedRevision != revision { continue }
            break
          }
          activeFile = entry.file
          transfer = nil
          let mount = mountGeneration
          if mounted.first?.id == entry.file.sourceID {
            deviceRun.begin(entry.id, planned: plannedUSB, complete: completeUSBPlan)
          }
          let (updates, sink) = AsyncStream<TransferProgress>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
          let observer = Task {
            for await value in updates {
              guard !Task.isCancelled else { break }
              transfer = value
            }
          }
          defer {
            sink.finish()
            observer.cancel()
            activeFile = nil
            transfer = nil
          }
          do {
            let file = entry.file
            let source = URL(fileURLWithPath: file.path)
            let before = try FileStamp(source)
            guard before.size == file.size, before.modified == file.modified else {
              throw WorkdayError.invalid("文件仍在保存，等待稳定后重新同步")
            }
            let receipt = try await store.importAudioWithOutcome(
              source, sourceID: file.sourceID, companionName: file.companionName,
              volumeUUID: mounted.first { $0.id == file.sourceID }?.uuid,
              transfer: { sink.yield($0) })
            let recording = receipt.recording
            if failedFile?.sourceID == file.sourceID && failedFile?.name == file.name {
              clearError()
            }
            ledger.complete(entry.id, recordingID: recording.id)
            if receipt.saved && mount == mountGeneration && mounted.first?.id == entry.file.sourceID {
              deviceRun.saved += 1
            }
            completedThisRun += 1
            revision += 1
            try await store.saveSyncLedger(ledger)
            await onArchived?(recording)
          } catch {
            ledger.fail(entry.id, message: error.localizedDescription, at: Date())
            revision += 1
            failedFile = entry.file
            self.error = "\(entry.file.name)：\(error.localizedDescription)；会自动重试"
            try await store.saveSyncLedger(ledger)
            if error is CancellationError { break }
          }
        }
      } catch {
        failedFile = nil
        self.error = "同步台账保存失败：\(error.localizedDescription)。原件已保留，请重试。"
      }
    }
  }
  func shutdown() async {
    stopping = true
    task?.cancel()
    await task?.value
  }
}
