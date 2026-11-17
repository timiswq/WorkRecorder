import Foundation
import XCTest

@testable import WorkdayCore

final class ConversationSelectionTests: XCTestCase {
  private let lines = ["41:28", "42:0", "42:4", "42:7", "43:0"].enumerated().map { index, id in
    TranscriptLine(id: id, start: Double(index * 2), end: Double(index * 2 + 1), text: "测试句\(index)")
  }
  private func service(_ fixture: String) -> AIService {
    let service = AIService(key: "test-\(fixture)")
    service.sessionConfiguration.protocolClasses = [SelectionResponse.self]
    return service
  }
  func testUnorderedStartsMapToDisjointOriginalSentencesAndOmitChatter() async throws {
    let result = try await service("starts").organize(lines: lines)
    XCTAssertEqual(result.map(\.firstID), ["42:0", "43:0"])
    XCTAssertEqual(result.map(\.lastID), ["42:4", "43:0"])
    XCTAssertEqual(result.first?.tasks, ["周五验收"])
  }
  func testConflictingOrUnknownStartsRecoverUsingSentenceLabels() async throws {
    for fixture in ["collision", "unknown", "legacy-overlap"] {
      let result = try await service(fixture).organize(lines: lines)
      XCTAssertEqual(result.map(\.firstID), ["42:0", "43:0"])
      XCTAssertEqual(result.map(\.lastID), ["42:4", "43:0"])
    }
  }

  func testFallbackWindowsKeepTheirOriginalSentenceIDs() async throws {
    let many = (0..<49).map { i in
      TranscriptLine(id: "chunk:\(i)", start: Double(i), end: Double(i + 1), text: "原句")
    }
    let selected = try await service("windows").organize(lines: many)
    XCTAssertEqual(selected.map(\.firstID), ["chunk:0", "chunk:24", "chunk:48"])
    XCTAssertEqual(selected.map(\.lastID), ["chunk:23", "chunk:47", "chunk:48"])
    let split = try await service("split").organize(lines: many)
    XCTAssertEqual(split.map(\.firstID), ["chunk:0", "chunk:12", "chunk:24", "chunk:36", "chunk:48"])
    XCTAssertEqual(split.map(\.lastID), ["chunk:11", "chunk:23", "chunk:35", "chunk:47", "chunk:48"])
  }

  func testUnselectedSentencesProduceNoConversationAndFullDayCanExceed100Clips() throws {
    let empty = Data(#"{"sections":[]}"#.utf8)
    XCTAssertEqual(try ConversationSelection.fromSections(empty, lines: lines), [])
    let many = (0..<101).map { i in
      TranscriptLine(id: "x\(i)", start: Double(i), end: Double(i + 1), text: "原句")
    }
    let valid = many.map { ConversationProposal(title: "工作对话", summary: "", firstID: $0.id, lastID: $0.id) }
    XCTAssertNoThrow(try AIService.validate(valid, lines: many))
  }
  func testInvalidFallbackDoesNotSilentlyDropEvidence() async throws {
    do {
      _ = try await service("bad-count").organize(lines: lines)
      XCTFail("Expected incomplete sentence classification to fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("逐句标注"))
      XCTAssertTrue(error.localizedDescription.contains("5"))
    }
  }

  func testOmittedEmptyNotesStillKeepAnExplicitSelection() throws {
    let data = Data(#"{"labels":[0,1,1,0,0],"topics":[{"title":"验收","summary":"确认验收安排"}]}"#.utf8)
    let selected = try ConversationSelection.fromLabels(data, lines: lines)
    XCTAssertEqual(selected, [ConversationProposal(title: "验收", summary: "确认验收安排",
      firstID: "42:0", lastID: "42:4")])
    let malformed = Data(#"{"labels":[0,1,1,0,0],"topics":[{"title":"验收","summary":"确认验收安排","tasks":42}]}"#.utf8)
    XCTAssertThrowsError(try ConversationSelection.fromLabels(malformed, lines: lines))
  }

  func testSevenUndecodableLabelsResumeAsDailyEvidenceAndNextBatchFinishes() async throws {
    let base = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    let root = URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("note20261112-084946.wav")
    try AudioFiles.wav(pcm: Data(repeating: 0, count: 690 * 32000)).write(to: source)
    let store = ArchiveStore(root: root.appendingPathComponent("Library"))
    let recording = try await store.importAudio(source, sourceID: "fixture")
    let cloud = service("seven")
    var saved = ProcessingDocument(recording: recording, model: cloud.transcriptionModel)
    saved.phase = "failed"
    saved.completedChunks = 6
    saved.analyzedBatches = 1
    saved.editorialVersion = 2
    let seven = (0..<7).map { i in
      TranscriptLine(id: "4:\(i)", start: 505 + Double(i), end: 506 + Double(i), text: "原句\(i)")
    }
    saved.transcript = [TranscriptLine(id: "0:0", start: 0, end: 1, text: "已排除")]
      + seven + [TranscriptLine(id: "5:0", start: 680, end: 681, text: "随后确认验收")]
    try await store.save(saved, recording: recording)
    let result = try await ProcessingPipeline(store: store).process(recording, service: cloud)
    XCTAssertEqual(result.phase, "complete")
    XCTAssertEqual(result.label, "已生成文字与事项 · 7 句保留为原话")
    XCTAssertEqual(result.analyzedBatches, 3)
    XCTAssertEqual(result.conversations.map(\.lineIDs), [["5:0"]])
    let reopened = try await ArchiveStore(root: store.root).document(for: recording)
    let evidence = WorkdayTimeline.evidence(day: recording.day, recordings: [recording],
      documents: [recording.id: try XCTUnwrap(reopened)])
    let pending = evidence.filter { $0.needsClassification == true }
    XCTAssertEqual(pending.flatMap(\.lineIDs), seven.map(\.id))
    XCTAssertEqual(pending.compactMap { $0.excerpt?.first }, seven)
    XCTAssertTrue(pending.allSatisfy { $0.audioFile == recording.originalFile })
    XCTAssertEqual(DayActivity.timeline(evidence, saved: nil).count, 1)
  }
}

private final class SelectionResponse: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}
  override func startLoading() {
    let url = request.url!
    let body = request.testBody
    let topic = #"{"title":"验收","summary":"确认验收安排","decisions":[],"tasks":["周五验收"]}"#
    XCTAssertEqual(url.absoluteString, "https://esp.xkw.cn/ai/v1/chat/completions")
    let fixture = String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst("Bearer test-".count))
    let selection: String
    let isLabeling = String(decoding: body, as: UTF8.self).contains("逐句标注")
    if fixture == "seven" {
      let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
      let messages = payload?["messages"] as? [[String: String]]
      if messages?.last?["content"]?.contains("随后确认验收") == true {
        selection = #"{"sections":[{"start":1,"keep":true,"topic":\#(topic)}]}"#
      } else {
        selection = isLabeling ? #"{"topics":[]}"# : #"{}"#
      }
    } else if isLabeling && (fixture == "windows" || fixture == "split") {
      guard let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
        let messages = request["messages"] as? [[String: String]], let input = messages.last?["content"],
        let sentences = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [[String: Any]]
      else {
        client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse))
        return
      }
      let count = fixture == "split" && sentences.count > 12 ? 0 : sentences.count
      let labels = Array(repeating: "1", count: count).joined(separator: ",")
      selection = #"{"labels":[\#(labels)],"topics":[\#(topic)]}"#
    } else if isLabeling {
      selection = fixture == "bad-count" ? #"{"labels":[1],"topics":[]}"#
        : #"{"labels":[0,1,1,0,2],"topics":[\#(topic),\#(topic)]}"#
    } else {
      switch fixture {
      case "starts":
        selection = #"{"sections":[{"start":5,"keep":true,"topic":\#(topic)},{"start":4,"keep":false},{"start":2,"keep":true,"topic":\#(topic)}]}"#
      case "collision":
        selection = #"{"sections":[{"start":2,"keep":true,"topic":\#(topic)},{"start":2,"keep":false}]}"#
      case "legacy-overlap":
        selection = #"{"conversations":[{"firstID":"42:0","lastID":"42:7","title":"甲","summary":"甲","decisions":[],"tasks":[]},{"firstID":"42:4","lastID":"43:0","title":"乙","summary":"乙","decisions":[],"tasks":[]}]}"#
      default: selection = #"{"sections":[{"start":90,"keep":true,"topic":\#(topic)}]}"#
      }
    }
    let envelope = ["choices": [["finish_reason": "stop", "message": ["content": selection]]]]
    client?.urlProtocol(self, didReceive: HTTPURLResponse(
      url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: envelope))
    client?.urlProtocolDidFinishLoading(self)
  }
}
