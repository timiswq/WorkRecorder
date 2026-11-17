import Combine
import DiskArbitration
import Foundation
import IOKit
import WorkdayCore

struct USBVolume: Equatable, Sendable {
  let id: String
  let url: URL
  let name: String
  var uuid: String { String(id.dropFirst("usb:".count)) }
  var isMounted: Bool { (try? Files.checkVolume(uuid, at: url)) != nil }
  struct Space: Equatable, Sendable {
    let free: Int64
    let total: Int64
  }
  var diskSpace: Space? {
    let root = URL(fileURLWithPath: url.path, isDirectory: true)
    guard let values = try? root.resourceValues(forKeys: [
      .volumeURLKey, .volumeUUIDStringKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey,
    ]), values.volumeUUIDString == uuid, values.volume?.standardizedFileURL.path == root.standardizedFileURL.path,
      let free = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity,
      total > 0, (0...total).contains(free)
    else { return nil }
    return Space(free: Int64(free), total: Int64(total))
  }
}
struct USBScan {
  let files: [SyncFile]
  let ready: [SyncFile]
  let inventories: [DeviceInventory]
}

@MainActor final class USBMonitor: ObservableObject {
  @Published private(set) var detectedVolumes: [USBVolume] = []
  // Only the selected volume reaches connection, inventory and sync consumers.
  @Published var volumes: [USBVolume] = []
  @Published private(set) var diskSpace: USBVolume.Space?
  @Published var issue: String?
  var onScan: ((USBScan) -> Void)?
  var onConnection: ((Bool) -> Void)?
  @Published var excludedStems = Set<String>()
  @Published var activeFilenameUnknown = false
  var needsSaveConfirmation: Bool { activeFilenameUnknown || !excludedStems.isEmpty }
  private var selectedID: String?
  private var generation = 0
  private var scanning = false
  private var timer: Timer?
  private var candidates: [String: Date] = [:]

  func start() {
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.scan() }
    }
    scan()
  }
  func stop() {
    timer?.invalidate()
    timer = nil
    generation += 1
  }
  func refresh() { scan() }
  private func scan() {
    guard !scanning else { return }
    scanning = true
    let version = generation
    Task {
      defer { scanning = false }
      let mounted = await Task.detached(priority: .utility) { Self.discover() }.value
      guard version == generation else { return }
      await scanMountedVolumes(mounted)
    }
  }

  func select(_ id: String?) {
    guard selectedID != id else { return }
    selectedID = id
    updateActiveVolume()
  }

  // A cloned disk can advertise the same UUID. Only a unique, still-mounted match may sync.
  func mountedVolume(withID id: String?) -> USBVolume? {
    guard let id else { return nil }
    let matches = detectedVolumes.filter { $0.id == id }
    guard matches.count == 1, let volume = matches.first, volume.isMounted else { return nil }
    return volume
  }

  private func updateActiveVolume() {
    let active = mountedVolume(withID: selectedID).map { [$0] } ?? []
    guard volumes != active else { return }
    generation += 1
    candidates.removeAll()
    issue = nil
    diskSpace = nil
    volumes = active
    onScan?(USBScan(files: [], ready: [], inventories: []))
    onConnection?(!active.isEmpty)
  }

  func scanMountedVolumes(_ mounted: [USBVolume], at now: Date = Date()) async {
    if detectedVolumes != mounted { detectedVolumes = mounted }
    updateActiveVolume()
    guard let volume = volumes.first else { return }
    let version = generation
    let (read, space) = await Task.detached(priority: .utility) { (Self.files(volume), volume.diskSpace) }.value
    guard generation == version else { return }
    if diskSpace != space { diskSpace = space }
    issue = read.errors.isEmpty ? nil : read.errors.joined(separator: "\n")
    let keys = Set(read.files.map(\.id))
    candidates = candidates.filter { keys.contains($0.key) }
    let ready = read.files.filter { file in
      guard !excludedStems.contains(file.stem) else { return false }
      if let first = candidates[file.id] {
        return now.timeIntervalSince(first) >= 5 && now.timeIntervalSince(file.modified) >= 5
          && file.companionModified.map { now.timeIntervalSince($0) >= 5 } != false
      }
      candidates[file.id] = now
      return false
    }
    let inventory = DeviceInventory(sourceID: volume.id, entries: read.files.map {
      InventoryEntry(name: $0.name, duration: nil, bytes: $0.size, isOpusOnly: !$0.supported)
    }, observedAt: now, complete: read.errors.isEmpty)
    onScan?(USBScan(files: read.files, ready: ready, inventories: [inventory]))
  }
  nonisolated private static func discover() -> [USBVolume] {
    guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
    let urls =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: [.volumeUUIDStringKey, .volumeNameKey],
        options: [.skipHiddenVolumes]) ?? []
    return urls.compactMap { url in
      guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else {
        return nil
      }
      var entry = DADiskCopyIOMedia(disk)
      var matched = false
      while entry != 0 {
        let vendor =
          IORegistryEntryCreateCFProperty(entry, "idVendor" as CFString, kCFAllocatorDefault, 0)?
          .takeRetainedValue() as? NSNumber
        let product =
          IORegistryEntryCreateCFProperty(entry, "idProduct" as CFString, kCFAllocatorDefault, 0)?
          .takeRetainedValue() as? NSNumber
        if vendor?.intValue == 0x301a, product?.intValue == 0x2800 { matched = true }
        var parent: io_registry_entry_t = 0
        let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
        IOObjectRelease(entry)
        entry = result == KERN_SUCCESS ? parent : 0
      }
      guard matched,
        let v = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey]),
        let uuid = v.volumeUUIDString
      else { return nil }
      return USBVolume(id: "usb:\(uuid)", url: url, name: v.volumeName ?? "AI 录音卡")
    }
  }
  nonisolated static func files(_ volume: USBVolume) -> (files: [SyncFile], errors: [String]) {
    let directory = volume.url.appendingPathComponent("record")
    var files: [SyncFile] = []
    var errors: [String] = []
    do {
      try Files.checkVolume(volume.uuid, at: volume.url)
      guard FileManager.default.fileExists(atPath: directory.path) else { return ([], []) }
      let urls = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
      let names = Set(urls.map { $0.lastPathComponent.lowercased() })
      for url in urls
      where url.lastPathComponent.range(
        of: #"^(note|call)\d{8}-\d{6}\.(wav|opus)$"#,
        options: [.regularExpression, .caseInsensitive]) != nil
      {
        if url.pathExtension.lowercased() == "opus",
          names.contains(url.deletingPathExtension().lastPathComponent.lowercased() + ".wav")
        {
          continue
        }
        do {
          let stamp = try FileStamp(url)
          let companion = urls.first {
            $0.lastPathComponent.lowercased() == url.deletingPathExtension().lastPathComponent
              .lowercased() + ".opus"
          }
          let paired =
            url.pathExtension.lowercased() == "wav" ? try companion.map(FileStamp.init) : nil
          files.append(
            SyncFile(
              sourceID: volume.id, path: url.path, size: stamp.size, modified: stamp.modified,
              companionName: paired == nil ? nil : companion?.lastPathComponent, companionSize: paired?.size, companionModified: paired?.modified))
        } catch { errors.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
      }
      try Files.checkVolume(volume.uuid, at: volume.url)
    } catch { return ([], ["无法读取录音卡文件：\(error.localizedDescription)"]) }
    return (files.sorted { $0.name < $1.name }, errors)
  }
}
