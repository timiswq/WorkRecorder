import Foundation
import WorkdayCore

struct PendingOriginal: Identifiable {
  let sourceID: String
  let entry: InventoryEntry
  var id: String { sourceID + "|" + entry.stem }
}

extension AppModel {
  var pendingOriginals: [PendingOriginal] {
    currentInventories.flatMap { inventory in
      let linked = catalog.bindings[inventory.sourceID].map { Set([$0]) } ?? []
      return inventory.pendingEntries(recordings: recordings, linkedSources: linked,
        activeName: activeInventoryName(inventory.sourceID)).map { PendingOriginal(sourceID: inventory.sourceID, entry: $0) }
    }
  }
  var pendingSyncBadge: Int? {
    // A cached discovery still needs USB import. Freshness changes the explanation,
    // not whether an already-known pending original deserves a reminder.
    if usesWiFiCard { return wifiSync.pending.flatMap { $0 > 0 ? $0 : nil } }
    guard !usb.needsSaveConfirmation else { return nil }
    let count = pendingCount.total
    return count > 0 ? count : nil
  }
  private var pendingSyncCountIsComplete: Bool {
    currentInventories.allSatisfy(\.complete)
      && (usb.volumes.isEmpty || currentInventories.count == usb.volumes.count)
  }
  var pendingSyncBadgeText: String? {
    guard let count = pendingSyncBadge else { return nil }
    if count > 99 { return "99+" }
    if usesWiFiCard { return "\(count)" }
    return pendingSyncCountIsComplete ? "\(count)" : "≥\(count)"
  }
  var pendingSyncBadgeHint: String? {
    guard let count = pendingSyncBadge else { return nil }
    if usesWiFiCard { return "本轮 Wi-Fi 清单还有 \(count) 段待下载" }
    let fresh = inventoryIsFresh
    let prefix = (fresh ? "" : "上次发现 ") + (pendingSyncCountIsComplete ? "" : "至少 ")
    return "\(prefix)\(count) 段录音尚未保存到 Mac"
      + (fresh ? "" : "，连接录音卡后更新")
  }
  var boundSource: String? { (usesWiFiCard ? nil : preferences.boundID).map { "ble:\($0)" } }
  var currentInventories: [DeviceInventory] {
    if usesWiFiCard { return [] }
    if !usb.volumes.isEmpty { return usb.volumes.compactMap { catalog.snapshots[$0.id] } }
    if let boundSource {
      let sources = [boundSource, catalog.bindings[boundSource]].compactMap { $0 }
      if let value = sources.compactMap({ catalog.snapshots[$0] }).max(by: {
        $0.observedAt < $1.observedAt
      }) {
        return [value]
      }
    }
    // USB-only users still see the last confirmed directory after unplugging.
    return catalog.snapshots.values.filter { $0.sourceID.hasPrefix("usb:") }
      .sorted { $0.observedAt > $1.observedAt }.prefix(1).map { $0 }
  }
  var inventoryIsFresh: Bool {
    guard !currentInventories.isEmpty else { return false }
    if !usb.volumes.isEmpty {
      return currentInventories.allSatisfy { Date().timeIntervalSince($0.observedAt) < 12 }
    }
    return currentInventories.allSatisfy { $0.sourceID == boundSource } && card.state.isFresh()
      && card.state.phase == .idle
      && currentInventories.allSatisfy { Date().timeIntervalSince($0.observedAt) < 65 }
  }
  var pendingCount: InventoryCount {
    var total = InventoryCount()
    for inventory in currentInventories {
      let linked = catalog.bindings[inventory.sourceID].map { Set([$0]) } ?? []
      let count = inventory.count(
        recordings: recordings, linkedSources: linked,
        activeName: activeInventoryName(inventory.sourceID), today: WorkdayDate.day(Date()))
      total.today += count.today
      total.earlier += count.earlier
      total.unknownDate += count.unknownDate
      total.unverified += count.unverified
      total.unsupported += count.unsupported
    }
    return total
  }
  private func activeInventoryName(_ source: String) -> String? {
    guard let name = card.state.filename else { return nil }
    if usb.volumes.contains(where: { $0.id == source }) {
      // USB suspends BLE. An explicit saved confirmation supersedes that stale state.
      let sameCard =
        usb.volumes.count == 1 || boundSource.flatMap { catalog.bindings[$0] } == source
      return sameCard && usb.excludedStems.contains(InventoryEntry.stem(name)) ? name : nil
    }
    guard let boundSource, source == boundSource || catalog.bindings[boundSource] == source,
      [.recording, .paused, .saving].contains(card.state.phase)
    else { return nil }
    return name
  }
  var syncStatus: String {
    guard !currentInventories.isEmpty else { return "待同步数量尚未确认，连接录音卡后更新" }
    let count = pendingCount
    let complete = currentInventories.allSatisfy(\.complete)
    let prefix = inventoryIsFresh ? (complete ? "" : "已发现至少 ") : "上次发现 "
    if count.total == 0 {
      if !complete { return "录音清单尚未完整返回，待同步数量待确认" }
      if currentInventories.allSatisfy({ $0.entries.isEmpty }) { return inventoryIsFresh ? "卡内暂无录音" : "上次读取时卡内暂无录音" }
      return inventoryIsFresh ? "已发现的录音均已同步" : "上次发现的录音均已同步，重连后更新"
    }
    var parts = ["\(prefix)今天 \(count.today) 段待同步"]
    if count.earlier > 0 { parts.append("其他日期 \(count.earlier) 段") }
    if count.unknownDate > 0 { parts.append("日期待确认 \(count.unknownDate) 段") }
    return parts.joined(separator: " · ")
  }
  var syncDetail: String {
    var parts: [String] = []
    if let date = currentInventories.map(\.observedAt).min() {
      parts.append("清单确认于 \(date.formatted(date: .abbreviated, time: .shortened))")
    }
    if pendingCount.unverified > 0 { parts.append("其中 \(pendingCount.unverified) 段与本地同名，来源或内容待核对") }
    if pendingCount.unsupported > 0 {
      parts.append("其中 \(pendingCount.unsupported) 段只有 OPUS，暂不支持同步")
    }
    if usb.needsSaveConfirmation { parts.append("当前文件等待在卡上结束并保存") }
    return parts.joined(separator: " · ")
  }
  func receiveInventory(_ inventory: DeviceInventory) {
    catalog.snapshots[inventory.sourceID] = inventory
    persistCatalog()
  }
  func associateUSB(_ files: [SyncFile]) {
    guard let boundSource, catalog.bindings[boundSource] == nil,
      usb.volumes.count == 1, let volume = usb.volumes.first,
      let snapshot = catalog.snapshots[boundSource], snapshot.complete,
      Date().timeIntervalSince(snapshot.observedAt) < 300, !snapshot.entries.isEmpty
    else { return }
    // A unique, complete directory with matching paired OPUS lengths is evidence;
    // a model name, volume label, or a lone timestamp is not.
    let grouped = Dictionary(grouping: snapshot.entries, by: \.stem)
    guard
      grouped.allSatisfy({ stem, entries in
        let matches = files.filter { $0.sourceID == volume.id && $0.stem == stem }
        return matches.count == 1 && entries.contains { $0.bytes == matches[0].companionSize }
      })
    else { return }
    catalog.bindings[boundSource] = volume.id
    persistCatalog()
  }
  func receivePause(name: String, pause: RecordingPause) {
    guard let boundSource else { return }
    let key = boundSource + "|" + InventoryEntry.stem(name)
    var timings = catalog.timings ?? [:]
    var timing = timings[key] ?? ObservedTiming()
    timing.pauses.append(pause)
    timing.updatedAt = Date()
    timings[key] = timing
    catalog.timings = timings
    persistCatalog()
  }
  func applyObservedTiming(_ recording: Recording) async {
    guard let boundSource, let source = catalog.bindings[boundSource],
      ([recording.sourceID] + (recording.sourceAliases ?? [])).contains(source),
      let timing = catalog.timings?[
        boundSource + "|" + InventoryEntry.stem(recording.originalName)],
      Date().timeIntervalSince(timing.updatedAt) < 86400, recording.pauses == nil
    else { return }
    do { _ = try await store.applyPauses(timing.pauses, to: recording) } catch {
      self.error = error.localizedDescription
    }
  }
  func receiveUSBInventories(_ inventories: [DeviceInventory]) {
    // Refresh counts immediately, persist only changed contents (avoid disk writes every poll).
    var changed = false
    for value in inventories {
      if catalog.snapshots[value.sourceID]?.entries != value.entries
        || catalog.snapshots[value.sourceID]?.complete != value.complete
      {
        changed = true
      }
      catalog.snapshots[value.sourceID] = value
    }
    if changed { persistCatalog() }
  }
  func bindCurrentUSB() {
    guard let boundSource, usb.volumes.count == 1, let volume = usb.volumes.first else { return }
    catalog.bindings[boundSource] = volume.id
    persistCatalog()
    notice = "已将此 USB 录音卡与已绑定蓝牙设备关联"
  }
  func confirmSavedOnCard() {
    usb.activeFilenameUnknown = false
    usb.excludedStems = []
    retrySync()
  }
  func persistCatalog() {
    catalogRevision += 1
    guard catalogSaveTask == nil else { return }
    let targetStore = store
    catalogSaveTask = Task {
      defer { catalogSaveTask = nil }
      var saved = -1
      do {
        while saved != catalogRevision, targetStore === store {
          let revision = catalogRevision
          try await targetStore.saveDeviceCatalog(catalog)
          saved = revision
        }
      } catch { self.error = "设备清单保存失败：\(error.localizedDescription)" }
    }
  }
}
