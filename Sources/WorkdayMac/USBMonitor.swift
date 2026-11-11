import Combine
import DiskArbitration
import Foundation
import IOKit
import WorkdayCore

struct USBVolume: Equatable, Sendable {
  let id: String
  let url: URL
  let name: String
}
struct USBScan {
  let files: [SyncFile]
  let ready: [SyncFile]
  let inventories: [DeviceInventory]
}

@MainActor final class USBMonitor: ObservableObject {
  @Published var volumes: [USBVolume] = []
  @Published var issue: String?
  var onScan: ((USBScan) -> Void)?
  var onConnection: ((Bool) -> Void)?
  var excludedStems = Set<String>()
  var activeFilenameUnknown = false
  var needsSaveConfirmation: Bool { activeFilenameUnknown || !excludedStems.isEmpty }
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
  }
  func refresh() { scan() }
  private func scan() {
    guard !scanning else { return }
    scanning = true
    Task {
      let result = await Task.detached(priority: .utility) {
        let volumes = Self.discover()
        var files: [SyncFile] = []
        var inventories: [DeviceInventory] = []
        var errors: [String] = []
        for volume in volumes {
          let read = Self.files(volume)
          files += read.files
          errors += read.errors
          inventories.append(
            DeviceInventory(
              sourceID: volume.id,
              entries: read.files.map {
                InventoryEntry(
                  name: $0.name, duration: nil, bytes: $0.size, isOpusOnly: !$0.supported)
              }, observedAt: Date(), complete: read.errors.isEmpty))
        }
        return (volumes, files, inventories, errors)
      }.value
      scanning = false
      if volumes != result.0 {
        volumes = result.0
        onConnection?(!volumes.isEmpty)
      }
      issue = result.3.isEmpty ? nil : result.3.joined(separator: "\n")
      let now = Date()
      let keys = Set(result.1.map(\.id))
      candidates = candidates.filter { keys.contains($0.key) }
      let ready = result.1.filter { file in
        guard !excludedStems.contains(file.stem) else { return false }
        if let first = candidates[file.id] {
          return now.timeIntervalSince(first) >= 5 && now.timeIntervalSince(file.modified) >= 5
            && file.companionModified.map { now.timeIntervalSince($0) >= 5 } != false
        }
        candidates[file.id] = now
        return false
      }
      onScan?(USBScan(files: result.1, ready: ready, inventories: result.2))
    }
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
    } catch { errors.append("无法读取录音卡文件：\(error.localizedDescription)") }
    return (files.sorted { $0.name < $1.name }, errors)
  }
}
