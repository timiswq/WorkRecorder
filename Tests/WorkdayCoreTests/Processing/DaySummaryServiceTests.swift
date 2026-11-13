import Foundation
import XCTest

@testable import WorkdayCore

final class DaySummaryServiceTests: XCTestCase {
  func testSummaryResolvesOrdinalAndTranscriptReferencesBeforeSavingArchive() async throws {
    let clips = ["am1", "am2", "pm"].map { id in
      Conversation(
        id: id, recordingID: id + "-file", title: "确认日程", summary: "周五确认安排",
        start: 1, end: 4, lineIDs: ["0:1"],
        excerpt: [.init(id: "0:1", start: 1, end: 4, text: "安排在周五。")],
        audioFile: "clip.wav", sha256: id, decisions: [], tasks: [])
    }
    let service = AIService(key: "test-only")
    service.sessionConfiguration.protocolClasses = [DailyReportFixture.self]
    let result = try await service.summarize(
      day: "2026-11-10", conversations: clips,
      recordingIDs: clips.map(\.recordingID))
    let root = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
        ?? NSTemporaryDirectory()
    )
    .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ArchiveStore(root: root)
    try await store.save(result)
    let saved = try await store.summary(day: result.day)
    XCTAssertEqual(saved?.activities?.map(\.kind), [.event, .aside])
    XCTAssertEqual(saved?.activities?.first?.conversationIDs, ["am1", "am2"])
    XCTAssertEqual(saved?.activities?.first?.quotes, ["am2": ["0:1"]])
    XCTAssertEqual(saved?.activities?.first?.relatedIDs, ["pm"])
    XCTAssertEqual(saved?.tasks.first?.conversationIDs, ["am1"])
  }
}

private final class DailyReportFixture: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}
  override func startLoading() {
    // Reproduce the JSON-mode contract from the reported 400 at the transport boundary.
    let payload = (try? JSONSerialization.jsonObject(with: request.testBody)) as? [String: Any]
    let format = payload?["response_format"] as? [String: String]
    let messages = payload?["messages"] as? [[String: String]]
    XCTAssertEqual(format?["type"], "json_object")
    guard messages?.contains(where: { $0["content"]?.localizedCaseInsensitiveContains("json") == true }) == true else {
      let error = #"{"error":{"code":"invalid_parameter_error","message":"'messages' must contain the word 'json'"}}"#
      reply(status: 400, data: Data(error.utf8))
      return
    }
    let report = """
      {"overview":"确认周五的安排。","activities":[
      {"kind":"event","title":"讨论日程","summary":"确认周五的安排。","parts":[1,2],
       "related":[3],"quotes":[{"part":2,"line":"0:1"}]},
      {"kind":"aside","title":"后续交流","summary":"提到之前的讨论。","parts":[3]}],
      "tasks":[{"text":"周五确认安排","parts":[1]}],"decisions":[]}
      """
    let body = try! JSONSerialization.data(withJSONObject: [
      "choices": [["finish_reason": "stop", "message": ["content": report]]]
    ])
    reply(status: 200, data: body)
  }

  private func reply(status: Int, data: Data) {
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: status,
        httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
}
