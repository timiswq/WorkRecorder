import Combine
import Foundation
import Network
import WiFiRecorderCore
import WorkdayCore

@MainActor final class WiFiRecordingSync: ObservableObject {
  enum Phase {
    case idle, preparing, checking, hotspot, joining, permission, listing, downloading, restoring,
      archiving, cleaning
  }
  @Published private(set) var phase = Phase.idle
  @Published private(set) var message = "同步时 Mac 会临时连接录音卡热点。"
  @Published private(set) var result = ""
  @Published private(set) var pending: Int?
  @Published private(set) var failedImports = 0
  @Published private(set) var pendingCleanup = 0
  @Published private(set) var transferProgress: TransferProgress?
  @Published private(set) var deviceInventory: CardRecordingCount?
  @Published private(set) var outcome = DeviceSyncOutcome()
  private var sceneTransfer: DeviceSyncTransfer?
  var currentTransfer: DeviceSyncTransfer? {
    if let sceneTransfer { return sceneTransfer }
    guard phase == .downloading, let batch, let file = batch.current else { return nil }
    return .init(name: file.name, position: batch.completed + 1, count: batch.total,
                 progress: transferProgress)
  }
  var deviceID: String? { device.isEmpty ? nil : device }
  var cleanupEnabled = false {
    didSet {
      if !cleanupEnabled && phase == .cleaning { cancel() }
    }
  }
  var busy: Bool { phase != .idle }
  var connectedDeviceID: String? {
    guard phase == .listing || phase == .downloading, transfer.connected || sceneTransfer != nil else { return nil }
    return device
  }
  var usingNetwork: Bool {
    [.hotspot, .joining, .permission, .listing, .downloading, .restoring].contains(phase)
  }
  private var waitingForNetwork = false
  private var networkRetry: Task<Void, Never>?
  var blocksProcessing: Bool { waitingForNetwork || (busy && phase != .archiving) }
  var onArchiveChange: () async -> Void = {}

  private let store: ArchiveStore
  private let card: any WiFiSyncBluetooth
  private let wifi: any WiFiHotspotJoining
  private let connectTCP: (TransferClient, String, String) -> Void
  private let transfer: TransferClient
  private let cleanup: WiFiCardCleanup
  private var batch: SyncBatch?
  private var meter: TransferMeter?
  private var inventoryKeys = Set<String>()
  private var downloadedKeys = Set<String>()
  private var generation = UUID()
  private var device = ""
  private var timeout: Task<Void, Never>?
  private var verified = Set<String>()
  private var cleanupRequested = false
  private var unsupportedCleanupCount = 0
  // Only a full read in this sync can authorize deletion. A resumed file can still be archived.
  private var checkedDownloads: [String: RecordingEntry] = [:]
  private var receivedSocketReady = false
  private var requestedBluetoothRelease = false
  private var joinedOrAttempted = false
  private var archiveTask: Task<Void, Never>?

  init(
    store: ArchiveStore, card: any WiFiSyncBluetooth, wifi: any WiFiHotspotJoining = WifiJoiner(),
    connectTCP: @escaping (TransferClient, String, String) -> Void = {
      $0.connect(deviceID: $1, interfaceName: $2)
    }
  ) {
    self.store = store
    self.card = card
    self.wifi = wifi
    self.connectTCP = connectTCP
    cleanup = WiFiCardCleanup(card: card, store: store)
    transfer = TransferClient(root: store.wifiInbox)
    transfer.onConnected = { [weak self] in
      self?.objectWillChange.send()
      self?.releaseBluetoothIfReady()
    }
    transfer.onFiles = { [weak self] in self?.filesListed($0) }
    transfer.onPartialList = { [weak self] count in
      guard let self, self.phase == .listing else { return }
      let inventory = CardRecordingCount(discovered: count)
      if self.deviceInventory != inventory { self.deviceInventory = inventory }
    }
    transfer.onDownloadStart = { [weak self] offset, total in
      guard let self, self.phase == .downloading else { return }
      let now = ProcessInfo.processInfo.systemUptime
      let copied = Int64(offset)
      let size = Int64(total)
      self.meter = TransferMeter(total: size, initialBytes: copied, at: now)
      self.transferProgress = .init(phase: .copying, copied: copied, total: size,
                                    bytesPerSecond: nil, uptime: now)
    }
    transfer.onDownloaded = { [weak self] in self?.downloaded($0) }
    transfer.onFailure = { [weak self] in self?.finish($0) }
    transfer.onProgress = { [weak self] received, total in
      guard let self, self.phase == .downloading, let batch = self.batch else { return }
      let percent = total > 0 ? Int(100 * received / total) : 0
      let message = "正在下载 \(batch.completed + 1)/\(batch.total) · \(percent)%"
      if self.message != message { self.message = message }
      if let sample = self.meter?.update(Int64(received), at: ProcessInfo.processInfo.systemUptime) {
        self.transferProgress = sample
      }
    }
    wifi.permissionChanged = { [weak self] allowed in
      guard let self, self.phase == .permission else { return }
      if allowed { self.checkState() } else { self.finish("未获热点识别权限，可在系统设置中允许工作留声访问定位后重试。") }
    }
  }
  func bluetoothRecordingCount(for id: String, onListed: (Int) -> Void = { _ in }) async throws -> CardRecordingCount {
    guard !busy, card.preferredKind == .wifi, card.boundID == id else { throw CancellationError() }
    let files = try await card.readWiFiFileList(for: id, duringSync: false)
    try Task.checkCancellation()
    guard !busy, card.boundID == id else { throw CancellationError() }
    let keys = Set(files.map { DownloadStore.key(device: id, file: $0) })
    onListed(keys.count)
    let verified = try await store.verifiedWiFiKeys(matching: keys)
    try Task.checkCancellation()
    guard !busy, card.boundID == id else { throw CancellationError() }
    return CardRecordingCount(discovered: keys.count, complete: true, pending: keys.subtracting(verified).count)
  }

  func attach() {
    card.onWiFiState = { [weak self] in self?.receivedState($0) }
    card.onHotspot = { [weak self] in self?.join($0) }
    card.onWiFiFilePacket = { [weak self] packet in self?.cleanup.accept(packet) }
    card.onSocket = { [weak self] in
      guard let self, self.usingNetwork else { return }
      self.receivedSocketReady = true
      self.releaseBluetoothIfReady()
    }
    card.onWiFiLost = { [weak self] in
      guard let self else { return }
      switch self.phase {
      case .listing, .downloading:
        // FW925 可能在蓝牙交接通知到达前断开蓝牙。发起 TCP 连接后，由传输层处理超时和断线。
        // 等网络恢复流程结束再允许蓝牙重连，避免干扰当前传输。
        self.card.holdReconnect = true
      case .checking, .hotspot, .joining, .permission:
        self.finish("录音卡蓝牙连接中断，请重新同步。")
      case .cleaning:
        self.cleanup.interrupt(WorkdayError.invalid("清理时蓝牙断开，请重新同步"))
      default: break
      }
    }
  }

  /// Stage a consistent coordinator state for the isolated native window capture.
  func setSceneState(id: String, transfer: DeviceSyncTransfer? = nil,
                     inventory: CardRecordingCount? = nil, outcome: DeviceSyncOutcome = .init(),
                     pendingCleanup: Int = 0) {
    guard SceneWindowCapture.isRunning, card.boundID == id else { return }
    device = id
    sceneTransfer = transfer
    deviceInventory = inventory
    self.outcome = outcome
    self.pendingCleanup = pendingCleanup
    set(transfer == nil ? .idle : .downloading,
        transfer == nil ? "同步时 Mac 会临时连接录音卡热点。" : "正在同步录音")
  }
  func clearDeviceResult() {
    guard !busy else { return }
    pending = nil
    pendingCleanup = 0
    unsupportedCleanupCount = 0
    outcome = DeviceSyncOutcome()
    clearInventory()
    device = ""
    result = ""
    message = "同步时 Mac 会临时连接录音卡热点。"
  }
  func start(id: String, after processing: Task<Void, Never>? = nil) {
    guard !busy, card.preferredKind == .wifi, card.boundID == id else { return }
    device = id
    generation = UUID()
    receivedSocketReady = false
    requestedBluetoothRelease = false
    joinedOrAttempted = false
    cleanupRequested = cleanupEnabled
    checkedDownloads.removeAll()
    downloadedKeys.removeAll()
    clearInventory()
    outcome = DeviceSyncOutcome()
    pendingCleanup = 0
    unsupportedCleanupCount = 0
    result = ""
    batch = nil
    card.wifiBusy = true
    let token = generation
    set(.preparing, processing == nil ? "正在核对本地原件…" : "等待当前整理结束后同步…")
    Task {
      do {
        await processing?.value
        guard generation == token, phase == .preparing else { return }
        let keys = try await store.verifiedWiFiKeys()
        guard generation == token, phase == .preparing else { return }
        verified = keys
        checkState()
      } catch { if generation == token { finish(error.localizedDescription) } }
    }
  }
  private func checkState() {
    set(.checking, "正在确认录音卡空闲…", timeout: 28)
    card.queryWiFiState()
  }
  func receivedState(_ raw: UInt8) {
    if phase == .cleaning, card.boundID == device {
      cleanup.accept(Packet(5, [raw]))
      return
    }
    guard phase == .checking, card.boundID == device else { return }
    guard raw == 0 else {
      finish("请先在卡上结束并保存录音，再同步。")
      return
    }
    set(.hotspot, "正在开启录音卡热点…", timeout: 30)
    card.openWiFiHotspot(for: device)
  }
  private func join(_ credentials: HotspotCredentials) {
    guard phase == .hotspot else { return }
    set(.joining, "正在连接录音卡热点…", timeout: 85)
    joinedOrAttempted = true
    let token = generation
    wifi.join(credentials) { [weak self] outcome in
      guard let self, self.generation == token, self.phase == .joining else { return }
      switch outcome {
      case .success(let interface):
        self.set(.listing, "正在读取卡内录音…", timeout: 30)
        self.connectTCP(self.transfer, self.device, interface)
      case .failure(WifiJoinError.locationRequired):
        self.set(.permission, "允许工作留声识别 Wi-Fi 后将继续同步。")
        self.wifi.requestLocationPermission()
      case .failure(let error): self.finish(error.localizedDescription)
      }
    }
  }
  private func releaseBluetoothIfReady() {
    // 收到卡的 Socket 就绪通知且 TCP 已连通时，才主动请求释放蓝牙。
    guard receivedSocketReady, transfer.connected, !requestedBluetoothRelease else { return }
    requestedBluetoothRelease = true
    card.releaseForWiFi()
  }
  private func filesListed(_ files: [RecordingEntry]) {
    guard phase == .listing else { return }
    let inbox = DownloadStore(root: store.wifiInbox)
    inventoryKeys = Set(files.map { DownloadStore.key(device: device, file: $0) })
    updateInventory()
    let existing = files.filter { item in
      let verifyForCleanup = cleanupRequested && item.supportsCardCleanup
      return inbox.completed(device: device, file: item) != nil
        || (!verifyForCleanup && verified.contains(DownloadStore.key(device: device, file: item)))
    }
    if cleanupRequested {
      pendingCleanup = files.filter(\.supportsCardCleanup).count
      unsupportedCleanupCount = files.count - pendingCleanup
    }
    batch = SyncBatch(files: files, existing: existing)
    pending = batch?.total
    next()
  }
  private func updateInventory() {
    let inventory = CardRecordingCount(discovered: inventoryKeys.count, complete: true,
                                      pending: inventoryKeys.subtracting(verified).count)
    if deviceInventory != inventory { deviceInventory = inventory }
  }

  private func clearInventory() {
    inventoryKeys.removeAll()
    deviceInventory = nil
  }
  private func next() {
    guard var batch else { return }
    do {
      let item = try batch.next()
      self.batch = batch
      if let item {
        guard transfer.state == .ready else {
          finish("下载通道已断开，可重新同步。")
          return
        }
        transferProgress = nil
        meter = nil
        set(.downloading, "正在下载 \(batch.completed + 1)/\(batch.total)")
        let recheckingArchive = cleanupRequested
          && verified.contains(DownloadStore.key(device: device, file: item))
        transfer.download(item, resume: !recheckingArchive)
      } else {
        let summary = cleanupRequested
          ? "已完整读取 \(batch.completed) 段，跳过 \(batch.skipped) 段。"
          : "新增 \(batch.completed) 段，已有 \(batch.skipped) 段。"
        finish(summary, completedBatch: true)
      }
    } catch { finish(error.localizedDescription) }
  }
  private func downloaded(_ url: URL) {
    guard phase == .downloading, var batch, let item = batch.current else { return }
    let inbox = DownloadStore(root: store.wifiInbox)
    let expected = inbox.url(device: device, file: item, partial: false)
    guard url == expected else {
      finish("收到的录音与本次下载不符")
      return
    }
    do {
      try batch.finish(item)
      if meter != nil { downloadedKeys.insert(DownloadStore.key(device: device, file: item)) }
      if cleanupRequested, item.supportsCardCleanup, transfer.downloadedFromStart {
        checkedDownloads[DownloadStore.key(device: device, file: item)] = item
      }
      self.batch = batch
      pending = batch.total - batch.completed
      next()
    } catch { finish(error.localizedDescription) }
  }
  private func set(_ phase: Phase, _ message: String, timeout seconds: UInt64? = nil) {
    timeout?.cancel()
    timeout = nil
    self.phase = phase
    if phase != .downloading {
      transferProgress = nil
      meter = nil
    }
    self.message = message
    guard let seconds else { return }
    timeout = Task {
      do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
      finish(transfer.state == .waitingPermission ? transfer.error : "等待录音卡超时，可重新同步。")
    }
  }
  func cancel() {
    guard busy, phase != .restoring, phase != .archiving else { return }
    if phase == .cleaning {
      archiveTask?.cancel()
      cleanup.interrupt(CancellationError())
      return
    }
    finish("已取消同步，已下载原件和断点保留。")
  }
  private func finish(_ detail: String, completedBatch: Bool = false) {
    guard busy, phase != .restoring, phase != .archiving, phase != .cleaning else { return }
    let shouldRestore = joinedOrAttempted
    if !completedBatch {
      pendingCleanup = 0
      outcome.notice = detail
    }
    generation = UUID()
    wifi.cancel()
    set(.restoring, shouldRestore ? "正在恢复 Wi-Fi…" : "正在结束同步…")
    result = detail
    let complete: (String) -> Void = { [weak self] note in
      guard let self, self.phase == .restoring else { return }
      self.result += note.isEmpty ? "" : " " + note
      if !note.isEmpty { self.outcome.network = note }
      if shouldRestore { self.checkNetworkRestoration() }
      self.card.holdReconnect = false
      self.beginArchive(completedBatch: completedBatch, cleanAfter: completedBatch && self.cleanupRequested)
    }
    let restore = { [weak self] in
      guard let self else { return }
      if shouldRestore { self.wifi.restore(completion: complete) } else { complete("") }
    }
    if transfer.state == .ready {
      transfer.closeHotspot(whenClosed: restore)
    } else if transfer.state == .downloading || transfer.state == .recovering {
      transfer.cancelDownload(whenClosed: restore)
    } else {
      transfer.disconnect()
      restore()
    }
  }
  /// Also runs on library open so a crash after END or a codec failure needs no card to retry.
  func retryLocal(for deviceID: String? = nil) {
    guard !busy else { return }
    result = ""
    if let deviceID, deviceID != self.deviceID {
      clearDeviceResult()
      device = deviceID
    } else {
      outcome.notice = nil
    }
    checkedDownloads.removeAll()
    downloadedKeys.removeAll()
    beginArchive(localRetry: true)
  }
  private func beginArchive(completedBatch: Bool = false, cleanAfter: Bool = false,
                            localRetry: Bool = false) {
    set(.archiving, "正在检查已下载的录音…")
    archiveTask = Task {
      let retryDirectory = localRetry ? deviceID.map(DownloadStore.directoryName(for:)) : nil
      var count = 0
      var saved = 0
      var failures = 0
      var lastError: String?
      var candidates: [WiFiCardCleanup.Candidate] = []
      do {
        for url in try await store.pendingWiFiFiles() {
          if Task.isCancelled { break }
          do {
            let receipt = try await store.archiveWiFiFileWithOutcome(url)
            let archive = receipt.recording
            count += 1
            if let key = archive.wifiOriginal?.key {
              verified.insert(key)
              if inventoryKeys.contains(key) { updateInventory() }
              if receipt.saved && (downloadedKeys.contains(key)
                || archive.wifiOriginal?.device == retryDirectory) {
                saved += 1
              }
              if cleanAfter, let item = checkedDownloads[key] {
                candidates.append((item, archive))
              }
            }
            try FileManager.default.removeItem(at: url)
          } catch {
            failures += 1
            lastError = error.localizedDescription
          }
        }
      } catch {
        failures += 1
        lastError = error.localizedDescription
      }
      failedImports = failures
      if saved > 0 || completedBatch { outcome.saved = (outcome.saved ?? 0) + saved }
      if !localRetry && !cleanupRequested && (saved > 0 || !inventoryKeys.isEmpty) {
        outcome.copies = "卡内副本已保留。"
      }
      if count > 0 { result += " 已确认 \(count) 段本地归档。" }
      if let lastError {
        result += " \(failures) 项待重试：\(lastError)"
        outcome.addNotice("\(failures) 项本地归档或下载暂存文件清理待重试。")
      }
      checkedDownloads.removeAll()
      downloadedKeys.removeAll()
      if cleanAfter && cleanupRequested && cleanupEnabled && !candidates.isEmpty {
        await cleanCard(candidates)
      } else if cleanAfter && pendingCleanup > 0 && cleanupEnabled {
        result += " \(pendingCleanup) 段卡内副本待完整核对，可重新同步。"
        outcome.addCopies("\(pendingCleanup) 段卡内副本待核对，可重新同步。")
      } else if !localRetry && cleanupRequested && saved > 0 {
        outcome.addCopies("卡内副本已保留。")
      }
      if cleanAfter && cleanupEnabled && unsupportedCleanupCount > 0 {
        result += " \(unsupportedCleanupCount) 段录音的卡内文件名不适用于自动清理，已保留。"
        outcome.addCopies("\(unsupportedCleanupCount) 段卡内副本不支持自动清理，已保留。")
      }
      card.wifiBusy = false
      clearInventory()
      set(.idle, "同步时 Mac 会临时连接录音卡热点。")
      if count > 0 || !device.isEmpty { await onArchiveChange() }
    }
  }
  private func cleanCard(_ candidates: [WiFiCardCleanup.Candidate]) async {
    let initialPending = pendingCleanup
    set(.cleaning, "原件已保存，正在核对卡内副本…")
    clearInventory()
    do {
      try await cleanup.remove(candidates, from: device) { confirmed in
        pendingCleanup = max(0, initialPending - confirmed)
        message = "正在清理卡内副本 · 已确认 \(confirmed)/\(candidates.count)"
      }
    } catch is CancellationError {
      result += " 已停止清理。"
      outcome.addCopies("已停止清理。")
    } catch {
      result += " 清理暂停：\(error.localizedDescription)。"
      if pendingCleanup == 0 || !cleanupEnabled { outcome.addCopies("卡内副本待清理。") }
    }
    if cleanup.removed > 0 {
      result += " 已删除 \(cleanup.removed) 段卡内副本。"
      outcome.addCopies("已删除 \(cleanup.removed) 段卡内副本。")
    }
    if cleanupEnabled && pendingCleanup > 0 {
      result += " \(pendingCleanup) 段卡内副本待清理，可重新同步。"
      outcome.addCopies("\(pendingCleanup) 段副本待清理，可重新同步。")
    }
  }
  private func checkNetworkRestoration() {
    networkRetry?.cancel()
    waitingForNetwork = true
    let monitor = NWPathMonitor()
    monitor.start(queue: .main)
    networkRetry = Task { [weak self] in
      defer { monitor.cancel() }
      while !Task.isCancelled {
        do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
        guard let self else { return }
        if monitor.currentPath.status == .satisfied, WifiNetworkInspector.read().recorderLink == nil
        {
          waitingForNetwork = false
          await onArchiveChange()
          return
        }
      }
    }
  }
  func shutdown() async {
    cleanupRequested = false
    if busy { cancel() }
    while phase == .restoring { try? await Task.sleep(nanoseconds: 50_000_000) }
    await archiveTask?.value
    networkRetry?.cancel()
  }
}
