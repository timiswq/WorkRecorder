import Foundation
import WiFiRecorderCore
import WorkdayCore

/// Uses the selected card's Bluetooth control channel after the hotspot has closed.
@MainActor final class WiFiCardCleanup {
  typealias Candidate = (file: RecordingEntry, archive: Recording)

  private let card: any WiFiSyncBluetooth
  private let store: ArchiveStore
  private var receive: ((Packet) -> Void)?
  private var reject: ((Error) -> Void)?
  private var timeout: Task<Void, Never>?
  private(set) var removed = 0

  init(card: any WiFiSyncBluetooth, store: ArchiveStore) {
    self.card = card
    self.store = store
  }

  func accept(_ packet: Packet) { receive?(packet) }

  func interrupt(_ error: Error) { reject?(error) }

  func remove(_ candidates: [Candidate], from device: String, progress: (Int) -> Void) async throws {
    removed = 0
    try await requireIdle(device)
    var files = try await card.readWiFiFileList(for: device, duringSync: true)
    var confirmed = 0
    for candidate in candidates {
      let file = candidate.file
      guard let current = files.first(where: { $0.id == file.id }) else {
        confirmed += 1
        progress(confirmed)
        continue
      }
      guard current == file, file.supportsCardCleanup,
        candidate.archive.wifiOriginal?.key == DownloadStore.key(device: device, file: file)
      else {
        throw WorkdayError.invalid("卡内文件标识或长度已变化，请重新同步")
      }
      try await requireIdle(device)
      try await store.verifyWiFiArchive(candidate.archive)
      try await wait(seconds: 12, send: { card.deleteWiFiFile(file, from: device) }) {
        $0.key == 13 ? () : nil
      }
      // A complete fresh inventory confirms removal even on firmware that omits an echoed filename.
      files = try await card.readWiFiFileList(for: device, duringSync: true)
      guard !files.contains(where: { $0.id == file.id }) else {
        throw WorkdayError.invalid("录音卡仍有这段录音，请重新同步后重试清理")
      }
      removed += 1
      confirmed += 1
      progress(confirmed)
    }
  }

  private func requireIdle(_ device: String) async throws {
    try await wait(seconds: 28, send: {
      guard card.boundID == device else { return false }
      card.queryWiFiState()
      return true
    }) { packet -> Void? in
      guard packet.key == 5 else { return nil }
      guard packet.payload == [0] else {
        throw WorkdayError.invalid("请先在卡上结束并保存录音，再清理卡内副本")
      }
      return ()
    }
  }

  private func wait<T>(
    seconds: Int, send: () -> Bool, decode: @escaping (Packet) throws -> T?
  ) async throws -> T {
    try Task.checkCancellation()
    return try await withCheckedThrowingContinuation { continuation in
      let finish: (Result<T, Error>) -> Void = { [weak self] result in
        self?.timeout?.cancel()
        self?.timeout = nil
        self?.receive = nil
        self?.reject = nil
        continuation.resume(with: result)
      }
      receive = { packet in
        do {
          if let value = try decode(packet) { finish(.success(value)) }
        } catch { finish(.failure(error)) }
      }
      reject = { finish(.failure($0)) }
      timeout = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
        self?.interrupt(WorkdayError.invalid("等待录音卡清理应答超时，请重新同步"))
      }
      if !send() {
        interrupt(WorkdayError.invalid("所选录音卡的蓝牙会话不可用，请重新同步"))
      }
    }
  }
}
