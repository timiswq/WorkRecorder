import Combine
import Foundation
import Network
import WiFiRecorderCore
import WorkdayCore

@MainActor final class WiFiRecordingSync: ObservableObject {
  enum Phase {
    case idle, preparing, checking, hotspot, joining, permission, listing, downloading, restoring,
      archiving
  }
  @Published private(set) var phase = Phase.idle
  @Published private(set) var message = "同步时 Mac 会临时连接录音卡热点。"
  @Published private(set) var result = ""
  @Published private(set) var pending: Int?
  @Published private(set) var failedImports = 0
  var busy: Bool { phase != .idle }
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
  private var batch: SyncBatch?
  private var generation = UUID()
  private var device = ""
  private var timeout: Task<Void, Never>?
  private var verified = Set<String>()
  private var sawSocket = false
  private var handedOff = false
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
    transfer = TransferClient(root: store.wifiInbox)
    transfer.onConnected = { [weak self] in self?.tryHandoff() }
    transfer.onFiles = { [weak self] in self?.filesListed($0) }
    transfer.onDownloaded = { [weak self] in self?.downloaded($0) }
    transfer.onFailure = { [weak self] in self?.finish($0) }
    transfer.onProgress = { [weak self] received, total in
      guard let self, self.phase == .downloading, let batch = self.batch else { return }
      let percent = total > 0 ? Int(100 * received / total) : 0
      self.message = "正在下载 \(batch.completed + 1)/\(batch.total) · \(percent)%"
    }
    wifi.permissionChanged = { [weak self] allowed in
      guard let self, self.phase == .permission else { return }
      if allowed { self.checkState() } else { self.finish("未获热点识别权限，可在系统设置中允许工作留声访问定位后重试。") }
    }
  }
  func attach() {
    card.onWiFiState = { [weak self] in self?.receivedState($0) }
    card.onHotspot = { [weak self] in self?.join($0) }
    card.onSocket = { [weak self] in
      guard let self, self.usingNetwork else { return }
      self.sawSocket = true
      self.tryHandoff()
    }
    card.onWiFiLost = { [weak self] in
      guard let self, !self.handedOff,
        [.checking, .hotspot, .joining, .permission, .listing, .downloading].contains(self.phase)
      else { return }
      self.finish("录音卡蓝牙连接中断，请重新同步。")
    }
  }
  func clearDeviceResult() {
    guard !busy else { return }
    pending = nil
    result = ""
    message = "同步时 Mac 会临时连接录音卡热点。"
  }
  func start(id: String, after processing: Task<Void, Never>? = nil) {
    guard !busy, card.preferredKind == .wifi, card.boundID == id else { return }
    device = id
    generation = UUID()
    sawSocket = false
    handedOff = false
    joinedOrAttempted = false
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
  private func tryHandoff() {
    guard sawSocket, transfer.connected, !handedOff else { return }
    handedOff = true
    card.releaseForWiFi()
  }
  private func filesListed(_ files: [RecordingEntry]) {
    guard phase == .listing else { return }
    let inbox = DownloadStore(root: store.wifiInbox)
    let existing = files.filter { item in
      let url = inbox.url(device: device, file: item, partial: false)
      let key = url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
      return verified.contains(key) || inbox.completed(device: device, file: item) != nil
    }
    batch = SyncBatch(files: files, existing: existing)
    pending = batch?.total
    next()
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
        set(.downloading, "正在下载 \(batch.completed + 1)/\(batch.total)")
        transfer.download(item)
      } else {
        finish("新增 \(batch.completed) 段，已有 \(batch.skipped) 段。")
      }
    } catch { finish(error.localizedDescription) }
  }
  private func downloaded(_ url: URL) {
    guard phase == .downloading, var batch, let item = batch.current else { return }
    let expected = DownloadStore(root: store.wifiInbox).url(
      device: device, file: item, partial: false)
    guard url == expected else {
      finish("收到的录音与本次下载不符")
      return
    }
    do {
      try batch.finish(item)
      self.batch = batch
      pending = batch.total - batch.completed
      next()
    } catch { finish(error.localizedDescription) }
  }
  private func set(_ phase: Phase, _ message: String, timeout seconds: UInt64? = nil) {
    timeout?.cancel()
    timeout = nil
    self.phase = phase
    self.message = message
    guard let seconds else { return }
    timeout = Task {
      do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
      finish(transfer.state == .waitingPermission ? transfer.error : "等待录音卡超时，可重新同步。")
    }
  }
  func cancel() {
    guard busy, phase != .restoring, phase != .archiving else { return }
    finish("已取消同步，已下载原件和断点保留。")
  }
  private func finish(_ outcome: String) {
    guard busy, phase != .restoring, phase != .archiving else { return }
    let shouldRestore = joinedOrAttempted
    generation = UUID()
    wifi.cancel()
    set(.restoring, "正在结束连接并恢复网络…")
    result = outcome
    let complete: (String) -> Void = { [weak self] note in
      guard let self, self.phase == .restoring else { return }
      self.result += note.isEmpty ? "" : " " + note
      if shouldRestore { self.checkNetworkRestoration() }
      self.card.holdReconnect = false
      self.beginArchive()
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
  func retryLocal() {
    guard !busy else { return }
    result = ""
    beginArchive()
  }
  private func beginArchive() {
    set(.archiving, "正在检查已下载的录音…")
    archiveTask = Task {
      var count = 0
      var failures = 0
      var lastError: String?
      do {
        for url in try await store.pendingWiFiFiles() {
          if Task.isCancelled { break }
          do {
            _ = try await store.archiveWiFiFile(url)
            count += 1
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
      if count > 0 { result += " \(count) 段已加入录音库。" }
      if let lastError { result += " \(failures) 项待重试：\(lastError)" }
      card.wifiBusy = false
      set(.idle, "同步时 Mac 会临时连接录音卡热点。")
      if count > 0 || !device.isEmpty { await onArchiveChange() }
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
    if busy { cancel() }
    while phase == .restoring { try? await Task.sleep(nanoseconds: 50_000_000) }
    await archiveTask?.value
    networkRetry?.cancel()
  }
}
