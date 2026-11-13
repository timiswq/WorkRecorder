import XCTest

@testable import WorkdayCore

final class CloudErrorTests: XCTestCase {
  private func service(_ fixture: String) -> AIService {
    let service = AIService(key: "fixture-secret", host: "\(fixture).cn-beijing.maas.aliyuncs.com")
    service.sessionConfiguration.protocolClasses = [CloudErrorResponse.self]
    return service
  }

  func testTranscriptionFailurePreservesServiceDetailsInArchive() async throws {
    let root = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
        ?? NSTemporaryDirectory()
    ).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("note20261111-090000.wav")
    try AudioFiles.wav(pcm: Data(repeating: 0, count: 32000)).write(to: source)
    let store = ArchiveStore(root: root.appendingPathComponent("Library"))
    let recording = try await store.importAudio(source, sourceID: "fixture")
    do {
      _ = try await ProcessingPipeline(store: store).process(recording, service: service("asr"))
      XCTFail("Expected HTTP 400")
    } catch {
      let saved = try await ArchiveStore(root: store.root).document(for: recording)
      let message = try XCTUnwrap(saved?.error)
      XCTAssertEqual(message, error.localizedDescription)
      for field in [
        "转写第 1 段音频", "HTTP 400", "qwen-audio-3.1-asr-flash", "InvalidParameter",
        "Unsupported audio format", "asr-request",
      ] {
        XCTAssertTrue(message.contains(field), field)
      }
      for sensitive in ["fixture-secret", "Bearer", "data:audio", "ignored-input"] {
        XCTAssertFalse(message.contains(sensitive), sensitive)
      }
    }
  }

  func testChatFailureSupportsNestedErrorAndRequestHeader() async {
    do {
      _ = try await service("chat").organize(lines: [
        TranscriptLine(id: "line", start: 0, end: 1, text: "合成文字")
      ])
      XCTFail("Expected HTTP 400")
    } catch {
      for field in [
        "整理对话", "HTTP 400", "模型：qwen-plus", "InvalidModel", "Unknown model", "chat-request",
      ] {
        XCTAssertTrue(error.localizedDescription.contains(field), field)
      }
    }
  }

  func testNoWordsOnlySkipsExplicitTranscriptionResponses() async throws {
    for fixture in ["no-words", "no-words-code"] {
      let lines = try await service(fixture).transcribe(
        audio: Data([0]), format: "wav", chunk: 13, offset: 1560, duration: 120)
      XCTAssertTrue(lines.isEmpty)
    }
    for fixture in ["other-client-error", "no-words-503", "mentions-no-words"] {
      do {
        _ = try await service(fixture).transcribe(
          audio: Data([0]), format: "wav", chunk: 13, offset: 1560, duration: 120)
        XCTFail("Unexpected empty transcript for \(fixture)")
      } catch { XCTAssertTrue(error.localizedDescription.contains("转写第 14 段音频失败")) }
    }
    do {
      _ = try await service("no-words").organize(lines: [
        TranscriptLine(id: "0", start: 0, end: 1, text: "确认交付")
      ])
      XCTFail("Only transcription can accept this error")
    } catch { XCTAssertTrue(error.localizedDescription.contains("整理对话失败")) }
  }

  func testChangingFileModelPinsCompletedChunksButCanRetryAnUnstartedTranscription() async throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("meeting.wav")
    try AudioFiles.wav(pcm: Data(repeating: 0, count: 121 * 32000)).write(to: file)
    let store = ArchiveStore(root: root.appendingPathComponent("Library"))
    let recording = try await store.importAudio(file, sourceID: "fixture")
    let client = AIService(key: "fixture-secret", host: "asr.cn-beijing.maas.aliyuncs.com", recordingModel: .flash30)
    client.sessionConfiguration.protocolClasses = [CloudErrorResponse.self]
    for completed in [0, 1] {
      var prior = ProcessingDocument(recording: recording, model: RecordingASRModel.flash31.rawValue)
      prior.completedChunks = completed
      try await store.save(prior, recording: recording)
      let expected = completed == 0 ? RecordingASRModel.flash30 : .flash31
      do {
        _ = try await ProcessingPipeline(store: store).process(recording, service: client)
        XCTFail("Expected the fixture HTTP error")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains("模型：\(expected.rawValue)"))
      }
      let checkpoint = try await store.document(for: recording)
      XCTAssertEqual(checkpoint?.model, expected.rawValue)
      XCTAssertEqual(checkpoint?.completedChunks, completed)
    }
  }

  func testEntirelyUnrecognizedRecordingKeepsOnlyOriginalAudio() async throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
      ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("note20261111-090000.wav")
    try AudioFiles.wav(pcm: Data(repeating: 0, count: 121 * 32000)).write(to: source)
    let store = ArchiveStore(root: root.appendingPathComponent("Library"))
    let recording = try await store.importAudio(source, sourceID: "fixture")
    let service = service("no-words")
    let result = try await ProcessingPipeline(store: store).process(recording, service: service)
    XCTAssertEqual(result.phase, "complete")
    XCTAssertNil(result.error)
    XCTAssertEqual(result.completedChunks, 2)
    XCTAssertEqual(result.unrecognizedChunkDescription, "第 1–2 段未识别到文字")
    XCTAssertTrue(result.transcript.isEmpty)
    XCTAssertTrue(result.proposals.isEmpty)
    XCTAssertTrue(result.conversations.isEmpty)
    let folder = store.root.appendingPathComponent(recording.folder)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("clips").path))
    XCTAssertEqual(try Files.hash(folder.appendingPathComponent(recording.originalFile)), recording.sha256)
    let summary = try await service.summarize(
      day: recording.day, conversations: result.conversations, recordingIDs: [recording.id])
    XCTAssertTrue(summary.overview.isEmpty)
    XCTAssertTrue(summary.decisions.isEmpty)
    XCTAssertTrue(summary.tasks.isEmpty)
  }

  func testNonJSONFailureShowsPlainTextOrFallback() async {
    for (fixture, expected) in [("plain", "Server busy"), ("html", "没有可显示的服务端说明")] {
      do {
        _ = try await service(fixture).transcribe(
          audio: Data([0]), format: "wav", chunk: 1,
          offset: 120, duration: 1)
        XCTFail("Expected HTTP 503")
      } catch {
        let message = error.localizedDescription
        XCTAssertTrue(message.contains("第 2 段"))
        XCTAssertTrue(message.contains("HTTP 503"))
        XCTAssertTrue(message.contains(expected))
        XCTAssertFalse(message.contains("<html>"))
      }
    }
  }
}

private final class CloudErrorResponse: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}
  override func startLoading() {
    let url = request.url!
    var headers = ["Content-Type": "application/json"]
    var status = 400
    let body: String
    switch url.host?.components(separatedBy: ".").first {
    case "no-words":
      body = #"{"code":"CLIENT_ERROR","message":"ASR_RESPONSE_HAVE_NO_WORDS","request_id":"fixture-request"}"#
    case "no-words-code":
      body = #"{"error":{"code":"ASR_RESPONSE_HAVE_NO_WORDS"}}"#
    case "other-client-error":
      body = #"{"code":"CLIENT_ERROR","message":"INVALID_AUDIO"}"#
    case "mentions-no-words":
      body = #"{"code":"CLIENT_ERROR","message":"Unexpected field ASR_RESPONSE_HAVE_NO_WORDS"}"#
    case "no-words-503":
      status = 503
      body = #"{"message":"ASR_RESPONSE_HAVE_NO_WORDS"}"#
    case "asr":
      body =
        #"{"code":"InvalidParameter","message":"Unsupported audio format: data:audio/wav;base64,AAAA (Bearer example-token) fixture-secret","request_id":"asr-request","input":"ignored-input"}"#
    case "chat":
      body = #"{"error":{"code":"InvalidModel","message":"Unknown model"}}"#
      headers["X-Request-Id"] = "chat-request"
    case "plain":
      body = "Server busy"
      headers["Content-Type"] = "text/plain"
      status = 503
    default:
      body = "<html>Proxy unavailable</html>"
      headers["Content-Type"] = "text/html"
      status = 503
    }
    let response = HTTPURLResponse(
      url: url, statusCode: status, httpVersion: "HTTP/1.1",
      headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
}
