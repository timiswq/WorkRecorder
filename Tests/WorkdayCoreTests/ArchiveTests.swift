import AVFoundation
import Darwin
import Foundation
import XCTest

@testable import WorkdayCore

final class ArchiveTests: XCTestCase {
  var area: URL!
  override func setUpWithError() throws {
    let base = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    area = URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: area, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: area) }

  func testTransferMeterUsesElapsedTimeAndCumulativePairBytes() throws {
    var meter = TransferMeter(total: 13_000_000, at: 10)
    XCTAssertNil(meter.update(1000, at: 10.1))
    let wav = try XCTUnwrap(meter.update(10_000_000, at: 12))
    XCTAssertEqual(wav.bytesPerSecond, 5_000_000)
    let opus = try XCTUnwrap(meter.update(13_000_000, at: 13))
    XCTAssertEqual(opus.bytesPerSecond, 3_000_000)
    XCTAssertEqual(opus.fraction, 1)
  }

  func testPairTransferReportsActualBytesBeforeVerification() async throws {
    let wav = try fixture()
    let opus = wav.deletingPathExtension().appendingPathExtension("opus")
    try Data(repeating: 5, count: 1234).write(to: opus)
    let total = try FileStamp(wav).size + FileStamp(opus).size
    let store = ArchiveStore(root: area.appendingPathComponent("Library"))
    let (stream, events) = AsyncStream<TransferProgress>.makeStream()
    _ = try await store.importAudio(wav, sourceID: "fixture", transfer: { events.yield($0) })
    events.finish()
    var samples: [TransferProgress] = []
    for await sample in stream { samples.append(sample) }
    XCTAssertEqual(samples.first?.copied, 0)
    XCTAssertTrue(samples.contains { $0.phase == .copying && $0.copied == total && ($0.bytesPerSecond ?? 0) > 0 })
    XCTAssertEqual(samples.last?.total, total)
    XCTAssertEqual(samples.last?.phase, .verifying)
    XCTAssertNil(samples.last?.bytesPerSecond)
  }

  func fixture(
    _ name: String = "note20261109-083000.wav", samples: Int = 32000, value: Int16 = 1200
  ) throws -> URL {
    var data = Data()
    func text(_ s: String) { data.append(Data(s.utf8)) }
    func integer(_ n: UInt32, _ bytes: Int) {
      for index in 0..<bytes { data.append(UInt8(truncatingIfNeeded: n >> (index * 8))) }
    }
    text("RIFF")
    integer(UInt32(36 + samples * 2), 4)
    text("WAVEfmt ")
    integer(16, 4)
    integer(1, 2)
    integer(1, 2)
    integer(16000, 4)
    integer(32000, 4)
    integer(2, 2)
    integer(16, 2)
    text("data")
    integer(UInt32(samples * 2), 4)
    for _ in 0..<samples { integer(UInt32(UInt16(bitPattern: value)), 2) }
    let url = area.appendingPathComponent(name)
    try data.write(to: url)
    return url
  }

  func testVerifiedImportPreservesSourceAndDeduplicates() async throws {
    let file = try fixture()
    let before = try Data(contentsOf: file)
    let store = ArchiveStore(root: area.appendingPathComponent("Library"))
    let first = try await store.importAudio(file, sourceID: "test-card")
    let again = try await store.importAudio(file, sourceID: "test-card")
    XCTAssertEqual(first.id, again.id)
    XCTAssertEqual(first.day, "2026-11-09")
    XCTAssertEqual(first.duration, 2, accuracy: 0.001)
    XCTAssertEqual(try Data(contentsOf: file), before)
    let records = try await store.load()
    XCTAssertEqual(records.count, 1)
    let archived = area.appendingPathComponent("Library").appendingPathComponent(first.folder)
      .appendingPathComponent(first.originalFile)
    XCTAssertEqual(try Data(contentsOf: archived), before)
  }

  func testManualAndUSBImportOfSameRecordingShareOneArchive() async throws {
    let file = try fixture()
    let store = ArchiveStore(root: area.appendingPathComponent("Library"))
    let manual = try await store.importAudio(file, sourceID: "manual")
    let usb = try await store.importAudio(file, sourceID: "usb:test-card")
    XCTAssertEqual(manual.id, usb.id)
    let loaded = try await store.load()
    XCTAssertEqual(loaded.count, 1)
  }

  func testSameNameWithDifferentAudioIsNotOverwritten() async throws {
    let store = ArchiveStore(root: area.appendingPathComponent("Library"))
    let first = try await store.importAudio(fixture(), sourceID: "test-card")
    let second = try await store.importAudio(fixture(value: 3000), sourceID: "test-card")
    XCTAssertNotEqual(first.id, second.id)
    let items = try await store.load()
    XCTAssertEqual(items.count, 2)
  }

  func testTruncatedWAVRejectedWithoutRemovingSource() async throws {
    let file = try fixture()
    var data = try Data(contentsOf: file)
    data.removeLast(50)
    try data.write(to: file)
    let store = ArchiveStore(root: area.appendingPathComponent("Library"))
    do {
      _ = try await store.importAudio(file, sourceID: "test")
      XCTFail("必须拒绝未完整保存的 WAV")
    } catch { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
    let items = try await store.load()
    XCTAssertTrue(items.isEmpty)
  }
  func testClipIsAnIndependentAudioFileAndChunksRetainTime() throws {
    let file = try fixture(samples: 64000)
    let clip = area.appendingPathComponent("clip.wav")
    try AudioFiles.slice(file, start: 1, end: 2.5, destination: clip)
    XCTAssertEqual(try AudioFiles.duration(clip), 1.5, accuracy: 0.001)
    XCTAssertNotEqual(try Data(contentsOf: clip), try Data(contentsOf: file))
    let chunk = try AudioFiles.wavChunk(file, start: 2, duration: 1)
    let chunkFile = area.appendingPathComponent("chunk.wav")
    try chunk.write(to: chunkFile)
    XCTAssertEqual(try AudioFiles.duration(chunkFile), 1, accuracy: 0.01)
    XCTAssertThrowsError(try AudioFiles.slice(file, start: -1, end: 3, destination: clip))
  }
  func testProcessingResumesWithoutUploadingCompletedChunkAndCreatesRealClip() async throws {
    let pcm = Data(repeating: 0, count: 16000 * 2 * 121)
    let file = area.appendingPathComponent("note20261109-083000.wav")
    try AudioFiles.wav(pcm: pcm).write(to: file)
    let root = area.appendingPathComponent("Library")
    let store = ArchiveStore(root: root)
    let recording = try await store.importAudio(file, sourceID: "fixture")
    let service = FixtureInference()
    let pipeline = ProcessingPipeline(store: store)
    do {
      _ = try await pipeline.process(recording, service: service)
      XCTFail("第二段应模拟网络失败")
    } catch {}
    let failed = try await store.document(for: recording)
    XCTAssertEqual(failed?.completedChunks, 1)
    XCTAssertEqual(failed?.phase, "failed")
    let result = try await pipeline.process(recording, service: service)
    XCTAssertEqual(result.phase, "complete")
    XCTAssertEqual(result.conversations.count, 1)
    let calls = await service.calls
    XCTAssertEqual(calls, [0, 1, 1])
    let conversation = try XCTUnwrap(result.conversations.first)
    let clip = root.appendingPathComponent(recording.folder).appendingPathComponent(
      conversation.audioFile)
    XCTAssertEqual(
      try AudioFiles.duration(clip), conversation.end - conversation.start, accuracy: 0.05)
    XCTAssertEqual(try Files.hash(clip), conversation.sha256)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent(recording.folder).appendingPathComponent(
          recording.originalFile
        ).path))
    let restarted = ArchiveStore(root: root)
    let persisted = try await restarted.document(for: recording)
    XCTAssertEqual(persisted?.conversations, result.conversations)
  }
  func testUnavailableDestinationNeverRemovesSource() async throws {
    let source = try fixture()
    let destination = area.appendingPathComponent("not-a-directory")
    try Data("occupied".utf8).write(to: destination)
    let store = ArchiveStore(root: destination)
    do {
      _ = try await store.importAudio(source, sourceID: "test")
      XCTFail("目标不可写应失败")
    } catch {
      XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
      XCTAssertEqual(try AudioFiles.duration(source), 2, accuracy: 0.001)
    }
  }
  func testSkippedChunkResumesWithoutEnteringClipsOrConversationEvidence() async throws {
    let source = area.appendingPathComponent("note20261110-172849.wav")
    try AudioFiles.wav(pcm: Data(repeating: 0, count: 241 * 32000)).write(to: source)
    let store = ArchiveStore(root: area.appendingPathComponent("Library"))
    let recording = try await store.importAudio(source, sourceID: "fixture")
    let service = SkippedChunkInference()
    var old = ProcessingDocument(recording: recording, model: service.transcriptionModel)
    old.phase = "failed"
    old.error = "ASR_RESPONSE_HAVE_NO_WORDS"
    old.completedChunks = 1
    old.transcript = [TranscriptLine(id: "first", start: 119, end: 120, text: "确定了验收日期。")]
    try await store.save(old, recording: recording)
    do {
      _ = try await ProcessingPipeline(store: store).process(recording, service: service)
      XCTFail("Expected the third chunk to encounter a temporary failure")
    } catch { XCTAssertEqual(error.localizedDescription, "模拟网络中断") }
    let failed = try await store.document(for: recording)
    XCTAssertEqual(failed?.completedChunks, 2)
    XCTAssertEqual(failed?.unrecognizedChunkDescription, "第 2 段未识别到文字")
    XCTAssertEqual(failed?.transcript, old.transcript)

    let result = try await ProcessingPipeline(store: store).process(recording, service: service)
    let calls = await service.calls
    XCTAssertEqual(calls, [1, 2, 2])
    XCTAssertEqual(result.phase, "complete")
    XCTAssertNil(result.error)
    XCTAssertEqual(result.completedChunks, 3)
    XCTAssertEqual(result.transcript.map(\.id), ["first", "last", "chatter"])
    XCTAssertEqual(result.conversations.map(\.lineIDs), [["first"], ["last"]])
    XCTAssertEqual(result.conversations.first?.end, 120)
    XCTAssertEqual(result.conversations.last?.start, 240)
    XCTAssertEqual(result.conversations.last?.end, 240.4)
    let saved = try await store.document(for: recording)
    XCTAssertEqual(saved?.unrecognizedChunkDescription, "第 2 段未识别到文字")
    let day = WorkdayTimeline.conversations(day: recording.day, recordings: [recording],
      documents: [recording.id: result])
    XCTAssertEqual(day.map(\.lineIDs), [["first"], ["last"]])
  }
  func testAllDayWAVArchiveAndLastMinute() async throws {
    guard ProcessInfo.processInfo.environment["WORKDAY_LONG_AUDIO"] == "1" else {
      throw XCTSkip("按需执行 1.09 GB 合成长录音验证")
    }
    let bytes = 34200 * 32000
    let source = area.appendingPathComponent("note20261110-083000.wav")
    var header = AudioFiles.wav(pcm: Data(repeating: 0, count: 2))
    header = header.prefix(44)
    func le(_ number: UInt32) -> [UInt8] {
      (0..<4).map { UInt8(truncatingIfNeeded: number >> ($0 * 8)) }
    }
    header.replaceSubrange(4..<8, with: le(UInt32(36 + bytes)))
    header.replaceSubrange(40..<44, with: le(UInt32(bytes)))
    try header.write(to: source)
    let handle = try FileHandle(forWritingTo: source)
    try handle.truncate(atOffset: UInt64(44 + bytes))
    try handle.close()
    var before = rusage()
    getrusage(RUSAGE_SELF, &before)
    let store = ArchiveStore(root: area.appendingPathComponent("Library"))
    let item = try await store.importAudio(source, sourceID: "synthetic-long")
    XCTAssertEqual(item.duration, 34200, accuracy: 0.001)
    let tail = try AudioFiles.wavChunk(source, start: 34140, duration: 60)
    XCTAssertLessThan(tail.count, 2_000_000)
    let tailURL = area.appendingPathComponent("last-minute.wav")
    try tail.write(to: tailURL)
    XCTAssertEqual(try AudioFiles.duration(tailURL), 60, accuracy: 0.01)
    let clip = area.appendingPathComponent("last-dialogue.wav")
    try AudioFiles.slice(source, start: 34190, end: 34200, destination: clip)
    XCTAssertEqual(try AudioFiles.duration(clip), 10, accuracy: 0.001)
    let player = try AVAudioPlayer(contentsOf: source)
    XCTAssertTrue(player.prepareToPlay())
    XCTAssertEqual(player.duration, 34200, accuracy: 0.001)
    player.currentTime = 34190
    XCTAssertEqual(player.currentTime, 34190, accuracy: 0.01)
    player.stop()
    var after = rusage()
    getrusage(RUSAGE_SELF, &after)
    print("Long WAV additional peak RSS: \(after.ru_maxrss - before.ru_maxrss) bytes")
    XCTAssertLessThan(after.ru_maxrss - before.ru_maxrss, 256 * 1024 * 1024, "长录音处理的额外内存必须保持有界")
  }

  func testResumingOlderProposalAcrossAnEmptyChunkSplitsItsAudio() async throws {
    let source = area.appendingPathComponent("note20261110-172849.wav")
    try AudioFiles.wav(pcm: Data(repeating: 0, count: 241 * 32000)).write(to: source)
    let store = ArchiveStore(root: area.appendingPathComponent("Library"))
    let recording = try await store.importAudio(source, sourceID: "fixture")
    let service = SkippedChunkInference()
    var saved = ProcessingDocument(recording: recording, model: service.transcriptionModel)
    saved.phase = "clipping"
    saved.completedChunks = 3
    saved.analyzedBatches = 1
    saved.transcript = [
      TranscriptLine(id: "a", start: 119, end: 120, text: "确认排期。"),
      TranscriptLine(id: "b", start: 240, end: 241, text: "明天交付。"),
    ]
    saved.proposals = [ConversationProposal(title: "排期", summary: "确认交付", firstID: "a", lastID: "b")]
    try await store.save(saved, recording: recording)
    let result = try await ProcessingPipeline(store: store).process(recording, service: service)
    XCTAssertEqual(result.conversations.map(\.lineIDs), [["a"], ["b"]])
    XCTAssertEqual(result.conversations.first?.end, 120)
    XCTAssertEqual(result.conversations.last?.start, 240)
    let calls = await service.calls
    XCTAssertTrue(calls.isEmpty)
  }
}

private actor SkippedChunkInference: InferenceServing {
  nonisolated let transcriptionModel = "fixture"
  var calls: [Int] = []
  func transcribe(audio: Data, format: String, chunk: Int, offset: Double, duration: Double)
    async throws -> [TranscriptLine]
  {
    calls.append(chunk)
    if chunk == 1 { return [] }
    if calls == [1, 2] { throw WorkdayError.invalid("模拟网络中断") }
    return [
      TranscriptLine(id: "last", start: offset, end: offset + 0.3, text: "明天交付。"),
      TranscriptLine(id: "chatter", start: offset + 0.4, end: offset + 1, text: "嗯。"),
    ]
  }
  func organize(lines: [TranscriptLine]) async throws -> [ConversationProposal] {
    let evidence = lines.filter { $0.id != "chatter" }
    guard let first = evidence.first, let last = evidence.last else { return [] }
    return [ConversationProposal(title: "进度", summary: "确认时间", firstID: first.id, lastID: last.id)]
  }
  func summarize(day: String, conversations: [Conversation], recordingIDs: [String]) async throws
    -> DaySummary
  { DaySummary(day: day, overview: "", recordingIDs: recordingIDs) }
}

actor FixtureInference: InferenceServing {
  nonisolated let transcriptionModel = "fixture"
  var calls: [Int] = []
  func transcribe(audio: Data, format: String, chunk: Int, offset: Double, duration: Double)
    async throws -> [TranscriptLine]
  {
    calls.append(chunk)
    if calls == [0, 1] { throw WorkdayError.invalid("模拟网络中断") }
    return [
      TranscriptLine(
        id: "\(chunk):1", start: offset + 0.1, end: offset + min(0.9, duration),
        text: chunk == 0 ? "讨论交付时间。" : "明天检查进度。")
    ]
  }
  func organize(lines: [TranscriptLine]) async throws -> [ConversationProposal] {
    [
      ConversationProposal(
        title: "交付进度", summary: "讨论交付并约定检查进度。", firstID: lines.first!.id, lastID: lines.last!.id)
    ]
  }
  func summarize(day: String, conversations: [Conversation], recordingIDs: [String]) async throws
    -> DaySummary
  {
    DaySummary(day: day, overview: "合成测试内容。", recordingIDs: recordingIDs)
  }
}
