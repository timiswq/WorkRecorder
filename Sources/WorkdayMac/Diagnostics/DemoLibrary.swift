import Foundation
import WorkdayCore

/// Explicit isolated validation only; normal launch never creates example records.
enum DemoLibrary {
  static func seed(store: ArchiveStore) async throws {
    guard ProcessInfo.processInfo.environment["WORKDAY_LIBRARY"] != nil,
      ProcessInfo.processInfo.environment["WORKDAY_DEMO"] == "1", try await store.load().isEmpty,
      let directory = ProcessInfo.processInfo.environment["WORKDAY_DEMO_FIXTURE"]
    else { return }
    let fixture = URL(fileURLWithPath: directory)
    let lines = try JSONDecoder().decode(
      [TranscriptLine].self,
      from: Data(contentsOf: fixture.appendingPathComponent("transcript.json")))
    let service = DemoInference(lines: lines)
    let pipeline = ProcessingPipeline(store: store)
    let sources = try FileManager.default.contentsOfDirectory(
      at: fixture, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "wav" && $0.lastPathComponent.hasPrefix("note") }.sorted {
      $0.path < $1.path
    }
    var recordings: [Recording] = []
    var documents: [String: ProcessingDocument] = [:]
    for source in sources {
      let item = try await store.importAudio(source, sourceID: "synthetic-demo")
      documents[item.id] = try await pipeline.process(item, service: service)
      recordings.append(item)
    }
    for day in Set(recordings.flatMap(WorkdayTimeline.days)) {
      let items = recordings.filter { WorkdayTimeline.days($0).contains(day) }
      var summary = service.summarize(
        day: day,
        conversations: WorkdayTimeline.conversations(
          day: day, recordings: items, documents: documents), recordingIDs: items.map(\.id))
      summary.inputFingerprint = WorkdayTimeline.fingerprint(
        day: day, recordings: recordings, documents: documents)
      try await store.save(summary)
    }
  }
}

private struct DemoInference: InferenceServing {
  let lines: [TranscriptLine]
  let transcriptionModel = "合成示例（未调用 AI）"
  func transcribe(audio: Data, format: String, chunk: Int, offset: Double, duration: Double)
    async throws -> [TranscriptLine]
  { lines.filter { $0.start >= offset && $0.end <= offset + duration } }
  func organize(lines: [TranscriptLine]) async throws -> [ConversationProposal] {
    let titles = ["确认首版界面的三个入口", "确定本地归档与断点续传", "安排设备连接与全天录音验证"]
    let summaries = [
      "首页精简为当前、历史和设置；历史记录中支持音文对照。", "设备结束后再接线，先保存完整原件；转写中断后从断点继续。", "先验证断联对设备录音的影响，再安排全天录音验证。",
    ]
    return stride(from: 0, to: lines.count, by: 2).enumerated().map { index, first in
      ConversationProposal(
        title: titles[index % 3], summary: summaries[index % 3], firstID: lines[first].id,
        lastID: lines[min(first + 1, lines.count - 1)].id,
        decisions: index == 0 ? ["首版保留当前、历史和设置三个入口。"] : [], tasks: index == 2 ? ["明天先验证断联场景。"] : [])
    }
  }
  func summarize(day: String, conversations: [Conversation], recordingIDs: [String]) -> DaySummary {
    DaySummary(
      day: day, overview: "今天围绕工作录音应用确认了首版界面与同步流程。明确原件先在本地归档，转写支持断点继续，并安排下一步设备验证。",
      decisions: conversations.first.map {
        [SummaryNote(text: "首版保留当前、历史和设置三个入口。", conversationIDs: [$0.id])]
      } ?? [],
      tasks: conversations.last.map {
        [SummaryNote(text: "先验证断联场景，再安排全天录音测试。", conversationIDs: [$0.id])]
      } ?? [], recordingIDs: recordingIDs)
  }
}
