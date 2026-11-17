import AVFoundation
import WiFiRecorderCore
import XCTest

@testable import WorkdayCore
@testable import WorkdayMac

final class WiFiArchiveTests: XCTestCase {
  private let fm = FileManager.default
  private func install(_ bytes: Data, device: String, store: ArchiveStore) throws -> URL {
    let entry = try RecordingEntry(
      [0] + Array("20000107000720".utf8) + Wire.beBytes(UInt64(bytes.count)))
    let sink = try DownloadStore(root: store.wifiInbox).begin(
      device: device, file: entry, resume: true)
    _ = try sink.accept(Array(bytes))
    _ = try sink.accept([2])
    return sink.destination
  }

  func testDownloadRejectsRedirectedDeviceDirectory() throws {
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let outside = root.appendingPathComponent("existing")
    let inbox = root.appendingPathComponent("inbox")
    for dir in [outside, inbox] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
    let store = DownloadStore(root: inbox)
    let item = try RecordingEntry([0] + Array("20000107000720".utf8) + Wire.beBytes(100))
    let device = store.url(device: "card", file: item, partial: true).deletingLastPathComponent()
    try fm.createSymbolicLink(at: device, withDestinationURL: outside)
    XCTAssertThrowsError(try store.begin(device: "card", file: item, resume: true))
    XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside.path), [])
  }

  @MainActor func testImportRetryAndRestartReachLibraryAndPlayer() async throws {
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let model = AppModel(libraryURL: root)
    let fixture = try Data(contentsOf: wifiFixture("silence.bin"))
    let raw = try install(fixture, device: "card-a", store: model.store)
    let a = try await model.store.archiveWiFiFile(raw)
    let again = try await model.store.archiveWiFiFile(raw)
    XCTAssertEqual(a.id, again.id)
    XCTAssertEqual(a.day, "日期未知")
    let folder = root.appendingPathComponent(a.folder)
    XCTAssertEqual(
      try Data(contentsOf: folder.appendingPathComponent(WiFiOriginal.filename)), fixture)
    // Also exercise repair after a local derivative is lost.
    try fm.removeItem(at: folder.appendingPathComponent(a.originalFile))
    let before = try await model.store.verifiedWiFiKeys()
    XCTAssertTrue(before.isEmpty)
    model.wifiSync.retryLocal()
    await model.wifiSync.shutdown()
    await model.reload()
    XCTAssertEqual(model.recordings.map(\.id), [a.id])
    XCTAssertFalse(fm.fileExists(atPath: raw.path))
    model.player.load(
      url: folder.appendingPathComponent(a.originalFile), id: a.id, recordingID: a.id,
      title: a.originalName)
    XCTAssertNil(model.player.error)
    XCTAssertEqual(model.player.duration, 0.32, accuracy: 0.001)
    let alternate = try install(fixture, device: "card-b", store: model.store)
    let b = try await model.store.archiveWiFiFile(alternate)
    XCTAssertNotEqual(a.id, b.id)
    let doc = try await ProcessingPipeline(store: model.store).process(
      a, service: WiFiTestInference())
    XCTAssertEqual(doc.phase, "complete")
    let reopened = try await ArchiveStore(root: root).load()
    XCTAssertEqual(reopened.count, 2)
    await model.shutdown()
  }

  @MainActor func testBadDecodeKeepsInboxAndExcludesPartial() async throws {
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let model = AppModel(libraryURL: root)
    var bytes = try Data(contentsOf: wifiFixture("silence.bin"))
    bytes[7] ^= 1
    let url = try install(bytes, device: "bad", store: model.store)
    try bytes.write(to: url.deletingPathExtension().appendingPathExtension("part"))
    model.wifiSync.retryLocal()
    await model.wifiSync.shutdown()
    XCTAssertEqual(model.wifiSync.failedImports, 1)
    let pending = try await model.store.pendingWiFiFiles()
    XCTAssertEqual(
      pending.map { $0.resolvingSymlinksInPath().path }, [url.resolvingSymlinksInPath().path])
    XCTAssertTrue(model.recordings.isEmpty)
    XCTAssertEqual(try Data(contentsOf: url), bytes)
  }

  func testCapturedFilesMatchReferencePCM() async throws {
    guard let path = ProcessInfo.processInfo.environment["WORKDAY_WIFI_SAMPLES"] else {
      throw XCTSkip("可指定 WORKDAY_WIFI_SAMPLES 与独立实机参考 WAV 对照")
    }
    let samples = URL(fileURLWithPath: path, isDirectory: true)
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let store = ArchiveStore(root: root)
    let devices = try fm.contentsOfDirectory(
      at: samples.appendingPathComponent("Recordings"), includingPropertiesForKeys: nil)
    var count = 0
    for device in devices where device.lastPathComponent.hasPrefix("device_") {
      for raw in try fm.contentsOfDirectory(at: device, includingPropertiesForKeys: nil)
      where raw.pathExtension == "bin" {
        let destination = store.wifiInbox.appendingPathComponent(device.lastPathComponent)
          .appendingPathComponent(raw.lastPathComponent)
        try fm.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: raw, to: destination)
        let row = try await store.archiveWiFiFile(destination)
        let rawHash = try Files.hash(raw)
        let reference = samples.appendingPathComponent(
          "Decoded/\(device.lastPathComponent)/\(rawHash).wav")
        XCTAssertEqual(row.wifiOriginal?.sha256, rawHash)
        XCTAssertEqual(row.sha256, try Files.hash(reference))
        count += 1
      }
    }
    XCTAssertGreaterThan(count, 0)
    print("Wi-Fi 实机原件与参考 WAV 一致：\(count) 份")
  }

  @MainActor func testLegacySettingsAndWiFiHardwarePresentation() throws {
    let preferences = try JSONDecoder().decode(
      Preferences.self, from: Data(#"{"boundID":"old","boundName":"旧卡"}"#.utf8))
    XCTAssertEqual(preferences.selectedRecorderID, "old")
    let model = AppModel(
      libraryURL: fm.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    var next = preferences
    next.recorderKind = .wifi
    next.wifiBoundID = "new"
    model.preferences = next
    model.card.state.connected = true
    model.card.state.updateWiFi(raw: 1, battery: 80)
    XCTAssertTrue(model.canChangeCard)
    XCTAssertEqual(model.preferences.boundID, "old")
    let status = model.statusPresentation(at: Date())
    XCTAssertEqual(status.hardware.kind, .recording)
    XCTAssertEqual(status.caption.title, "暂未收到实时音频")
    XCTAssertEqual(status.hardwareAction, .live)
    XCTAssertNil(model.pendingSyncBadge)
  }
}

private struct WiFiTestInference: InferenceServing {
  let transcriptionModel = "test"
  func transcribe(audio: Data, format: String, chunk: Int, offset: Double, duration: Double)
    async throws -> [TranscriptLine]
  {
    [TranscriptLine(id: "line", start: offset, end: offset + duration, text: "测试录音。")]
  }
  func organize(lines: [TranscriptLine]) async throws -> [ConversationProposal] {
    [ConversationProposal(title: "测试", summary: "模拟结果", firstID: "line", lastID: "line")]
  }
  func summarize(day: String, conversations: [Conversation], recordingIDs: [String]) async throws
    -> DaySummary
  {
    DaySummary(day: day, overview: "模拟结果", recordingIDs: recordingIDs)
  }
}

func wifiFixture(_ name: String) -> URL {
  #if SWIFT_PACKAGE
    return Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + name)
  #else
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
      "Fixtures/" + name)
  #endif
}
