import AppKit
import Foundation
import SwiftUI
import WorkdayCore
import XCTest

@testable import WorkdayMac

final class CardFileCleanupTests: XCTestCase {
  var root: URL!
  var volume: USBVolume!
  var wav: URL!
  var opus: URL!
  var store: ArchiveStore!

  override func setUpWithError() throws {
    let base = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    root = URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString)
    let card = ProcessInfo.processInfo.environment["WORKDAY_TEST_CARD_BASE"].map {
      URL(fileURLWithPath: $0).appendingPathComponent(UUID().uuidString)
    } ?? root.appendingPathComponent("Card")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let directory = card.appendingPathComponent("record")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let uuid = try XCTUnwrap(card.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
    volume = USBVolume(id: "usb:" + uuid, url: card, name: "测试卡")
    wav = directory.appendingPathComponent("note20261111-081500.wav")
    opus = directory.appendingPathComponent("note20261111-081500.OPUS")
    try AudioFiles.wav(pcm: Data(repeating: 19, count: 64_000)).write(to: wav)
    try Data(repeating: 3, count: 800).write(to: opus)
    store = ArchiveStore(root: root.appendingPathComponent("Library"))
  }
  override func tearDownWithError() throws {
    if let volume { try FileManager.default.removeItem(at: volume.url) }
    try FileManager.default.removeItem(at: root)
  }

  @MainActor func testPreviouslyArchivedPairIsCleanedAfterRestartWithoutReimport() async throws {
    let file = try XCTUnwrap(USBMonitor.files(volume).files.first)
    let first = SyncCoordinator(store: store)
    try await first.load()
    first.offer([file])
    try await settle(first)
    XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
    await first.shutdown()
    let prior = try await store.load()
    let recording = try XCTUnwrap(prior.first)
    let original = store.root.appendingPathComponent(recording.folder).appendingPathComponent(
      recording.originalFile)
    let copiedOpus = original.deletingLastPathComponent().appendingPathComponent("original.opus")
    let unrelated = wav.deletingLastPathComponent().appendingPathComponent("notes.txt")
    try Data("保留".utf8).write(to: unrelated)
    let restarted = SyncCoordinator(store: store)
    try await restarted.load()
    restarted.cleanupEnabled = false
    restarted.updateUSB([], stableFiles: [file], volumes: [volume])
    try await settle(restarted)
    XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: opus.path))
    restarted.cleanupEnabled = true
    restarted.updateUSB([], stableFiles: [file], volumes: [volume])
    try await settle(restarted)
    XCTAssertNil(restarted.error)
    XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: opus.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    XCTAssertEqual(try Files.hash(original), recording.sha256)
    XCTAssertEqual(try Data(contentsOf: copiedOpus), Data(repeating: 3, count: 800))
    XCTAssertEqual(restarted.clearedBytesByVolume[volume.id], file.size + 800)
    XCTAssertEqual(restarted.completedThisRun, 0)
  }

  @MainActor func testChangedLocalPairRetainsBothCardFilesAndCanRetryWithoutCopying() async throws {
    let file = try XCTUnwrap(USBMonitor.files(volume).files.first)
    let sync = SyncCoordinator(store: store)
    try await sync.load()
    sync.offer([file])
    try await settle(sync)
    let prior = try await store.load()
    let recording = try XCTUnwrap(prior.first)
    let local = store.root.appendingPathComponent(recording.folder).appendingPathComponent(
      "original.opus")
    let good = try Data(contentsOf: local)
    try Data(repeating: 12, count: good.count).write(to: local)
    sync.updateUSB([], stableFiles: [file], volumes: [volume])
    try await settle(sync)
    XCTAssertNotNil(sync.error)
    XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: opus.path))
    try good.write(to: local)
    sync.retry()
    try await settle(sync)
    XCTAssertNil(sync.error)
    XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: opus.path))
    XCTAssertEqual(sync.completedThisRun, 1)
  }

  @MainActor func testDisconnectBetweenPairRemovalsResumesUsingWAVIdentity() async throws {
    let file = try XCTUnwrap(USBMonitor.files(volume).files.first)
    let sync = SyncCoordinator(store: store)
    try await sync.load()
    sync.offer([file])
    try await settle(sync)
    try FileManager.default.removeItem(at: opus)
    let remaining = try XCTUnwrap(USBMonitor.files(volume).files.first)
    XCTAssertNotEqual(remaining.id, file.id)
    sync.updateUSB([], stableFiles: [remaining], volumes: [volume])
    try await settle(sync)
    XCTAssertNil(sync.error)
    XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
    XCTAssertEqual(sync.completedThisRun, 1)
  }

  func testWrongVolumeAndChangedSourceRetainCardFiles() async throws {
    let file = try XCTUnwrap(USBMonitor.files(volume).files.first)
    let recording = try await store.importAudio(
      wav, sourceID: volume.id, companionName: file.companionName)
    let wrong = USBVolume(id: "usb:another-card", url: volume.url, name: "同名测试卡")
    do {
      _ = try await store.removeArchivedCardFiles(file, recordingID: recording.id, volume: wrong)
      XCTFail("必须核对挂载卷身份")
    } catch {}
    let bytes = try Data(contentsOf: wav)
    var changed = bytes
    changed[changed.count - 1] ^= 0x01
    try changed.write(to: wav)
    let replacement = try XCTUnwrap(USBMonitor.files(volume).files.first)
    do {
      _ = try await store.removeArchivedCardFiles(
        replacement, recordingID: recording.id, volume: volume)
      XCTFail("同长度的替换文件也必须重新核验内容")
    } catch {}
    XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: opus.path))
  }

  @MainActor private func settle(_ sync: SyncCoordinator) async throws {
    for _ in 0..<500 where sync.isBusy { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(sync.isBusy)
  }

  @MainActor func testNativeTransferRowSnapshot() throws {
    guard ProcessInfo.processInfo.environment["WORKDAY_WORKSPACE_SNAPSHOTS"] == "1",
      let output = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
    else { return }
    let sample = TransferProgress(
      phase: .copying, copied: 45_000_000, total: 100_000_000,
      bytesPerSecond: 6_500_000, uptime: ProcessInfo.processInfo.systemUptime)
    let view = FileTransferRow(transfer: sample)
      .frame(width: 380, height: 40).padding(.horizontal, 16)
      .tint(Palette.accent).background(Palette.surface).environment(\.colorScheme, .light)
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 412, height: 40)
    host.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      .write(to: URL(fileURLWithPath: output).appendingPathComponent("USB传输速度样张.png"))
  }

  func testRateLabelClearsWhenVerificationOrAStallBegins() {
    let copying = TransferProgress(
      phase: .copying, copied: 6_000_000, total: 12_000_000,
      bytesPerSecond: 3_000_000, uptime: 10)
    XCTAssertEqual(FileTransferRow.label(for: copying, at: 10.2), "3 MB/s")
    XCTAssertEqual(FileTransferRow.label(for: copying, at: 12.5), "0 B/s")
    let check = TransferProgress(
      phase: .verifying, copied: 12_000_000, total: 12_000_000,
      bytesPerSecond: nil, uptime: 13)
    XCTAssertEqual(FileTransferRow.label(for: check, at: 14), "正在校验")
  }

  func testDeviceSpeedUsesTheRecentRateAndExpiresWithoutNewBytes() {
    let measuring = TransferProgress(phase: .copying, copied: 4_000_000, total: 12_000_000,
                                     bytesPerSecond: 3_000_000, uptime: 10)
    XCTAssertEqual(DeviceTransferDetails.speedLabel(measuring, at: 10.4), "测速中…")
    let copying = TransferProgress(phase: .copying, copied: 7_000_000, total: 12_000_000,
                                   bytesPerSecond: 3_000_000, uptime: 11,
                                   recentBytesPerSecond: 1_000_000)
    XCTAssertEqual(DeviceTransferDetails.speedLabel(copying, at: 11.2), deviceBytes(1_000_000) + "/s")
    XCTAssertEqual(DeviceTransferDetails.speedLabel(copying, at: 12.5), "0 B/s")
  }

  @MainActor func testDeviceResultCountsSavedPairEvenIfCopyCleanupFails() async throws {
    let file = try XCTUnwrap(USBMonitor.files(volume).files.first)
    let sync = SyncCoordinator(store: store)
    try await sync.load()
    sync.onArchived = { recording in
      let local = self.store.root.appendingPathComponent(recording.folder)
        .appendingPathComponent("original.opus")
      try? Data(repeating: 12, count: 800).write(to: local)
    }
    sync.updateUSB([file], stableFiles: [file], volumes: [volume], complete: true)
    try await settle(sync)
    XCTAssertTrue(sync.cleanupFailed)
    XCTAssertEqual(sync.deviceRun.saved, 1)
    XCTAssertEqual(sync.deviceRun.deleted, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
    sync.updateUSB([], stableFiles: [], volumes: [])
    XCTAssertEqual(sync.deviceRun.saved, 0)
  }
}
