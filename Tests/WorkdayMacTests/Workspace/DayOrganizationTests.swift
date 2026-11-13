import AppKit
import SwiftUI
import XCTest

@testable import WorkdayCore
@testable import WorkdayMac

final class DayOrganizationTests: XCTestCase {
  private let day = "2026-11-10"

  @MainActor private func library() async throws -> (URL, AppModel, Recording, ProcessingDocument) {
    let base = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"] ?? NSTemporaryDirectory()
    let root = URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(libraryURL: root.appendingPathComponent("Library"))
    let url = root.appendingPathComponent("note20261110-093000.wav")
    try AudioFiles.wav(pcm: Data(repeating: 0, count: 16_000 * 2 * 15)).write(to: url)
    let record = try await model.store.importAudio(url, sourceID: "fixture")
    var doc = ProcessingDocument(recording: record, model: "fixture")
    doc.phase = "complete"
    doc.editorialVersion = 2
    doc.deferredLineIDs = ["3"]
    let texts = ["确定周五验收。", "表格记得加上设备编号。", "好，我去拿杯水。", "导出也要保留编号。", "下午见。"]
    doc.transcript = texts.enumerated().map { i, text in
      TranscriptLine(
        id: String(i), start: Double(i * 2), end: Double(i * 2) + 0.35,
        text: text, speaker: i.isMultiple(of: 2) ? nil : "发言人 2")
    }
    var meeting = WorkdayTimeline.sentenceSlices(day: day, recording: record, document: doc)[0][0]
    meeting.id = "meeting"
    meeting.title = "周五验收"
    doc.conversations = [meeting]
    try await model.store.save(doc, recording: record)
    var summary = DaySummary(day: day, overview: "确认了周五的验收安排。", recordingIDs: [record.id])
    summary.activities = [
      DayActivity(
        kind: .event, title: meeting.title, summary: meeting.summary, conversationIDs: ["meeting"])
    ]
    try await model.store.save(summary)
    await model.reload()
    model.loading = false
    model.selectDay(day)
    return (root, model, record, doc)
  }

  @MainActor func testNonAdjacentSelectionAppendAndReopenAfterSummaryRegeneration() async throws {
    let (root, model, record, doc) = try await library()
    defer { try? FileManager.default.removeItem(at: root) }
    let raw = try XCTUnwrap(model.workspace.activities.first(where: \.isRaw))
    let original = try XCTUnwrap(model.workspace.activities.first(where: { !$0.isRaw }))
    XCTAssertEqual(raw.clips.flatMap(\.lineIDs), ["1", "2", "3", "4"])
    let lines = raw.clips
    let created = try await model.organize(
      day: day, sentenceIDs: [lines[0].id, lines[2].id], title: "设备编号")
    let remaining = model.workspace.activities.filter(\.isRaw)
    XCTAssertEqual(remaining.map { $0.clips.map(\.id) }, [[lines[1].id], [lines[3].id]])
    XCTAssertEqual(remaining.map(\.start), [lines[1].wallStart, lines[3].wallStart])
    XCTAssertEqual(remaining.flatMap(\.clips), [lines[1], lines[3]])
    let saved = try XCTUnwrap(model.workspace.activities.first { $0.id == created })
    XCTAssertEqual(saved.clips.flatMap(\.lineIDs), ["1", "3"])
    let supplemented = try await model.organize(
      day: day, sentenceIDs: [lines[3].id], into: original.id)
    let merged = try XCTUnwrap(model.workspace.activities.first { $0.id == supplemented })
    XCTAssertEqual(merged.end, original.end)
    XCTAssertEqual(merged.clips.flatMap(\.lineIDs), ["0", "4"])
    let before = try await model.store.organization(day: day)
    do {
      _ = try await model.organize(day: day, sentenceIDs: [lines[3].id], into: created)
      XCTFail("同一句不能重复整理")
    } catch { XCTAssertTrue(error.localizedDescription.contains("归属")) }
    // Simulate a regenerated meeting with a new clip ID referencing a manually claimed line as well.
    var regenerated = doc
    regenerated.conversations[0].id = "regenerated"
    regenerated.conversations[0].lineIDs = ["0", "1"]
    regenerated.conversations[0].end = lines[0].end
    try await model.store.save(regenerated, recording: record)
    let reopened = AppModel(libraryURL: model.libraryURL)
    await reopened.reload()
    reopened.selectDay(day)
    let events = reopened.workspace.activities
    let target = try XCTUnwrap(events.first { $0.id == supplemented })
    XCTAssertEqual(target.clips.flatMap(\.lineIDs), ["0", "4"])
    XCTAssertEqual(target.addedSentenceIDs, [lines[3].id])
    XCTAssertEqual(events.first { $0.id == created }?.clips.flatMap(\.lineIDs), ["1", "3"])
    XCTAssertEqual(events.filter(\.isRaw).flatMap(\.clips), [lines[1]])
    _ = try await reopened.organize(day: day, sentenceIDs: [lines[1].id], into: created)
    let expanded = try XCTUnwrap(reopened.workspace.activities.first { $0.id == created })
    XCTAssertEqual(expanded.start, saved.start)
    XCTAssertEqual(expanded.end, saved.end)
    XCTAssertEqual(expanded.addedSentenceIDs, [lines[1].id])
    do {
      _ = try await reopened.store.saveOrganization(before, day: day)
      XCTFail("旧版本不能覆盖更新后的归属")
    } catch { XCTAssertTrue(error.localizedDescription.contains("更新")) }
    // Losing the automatic target entirely still preserves its original evidence and manual supplement.
    regenerated.conversations = []
    try await reopened.store.save(regenerated, recording: record)
    let last = AppModel(libraryURL: model.libraryURL)
    await last.reload()
    last.selectDay(day)
    XCTAssertEqual(
      last.workspace.activities.first { $0.id == supplemented }?.clips.flatMap(\.lineIDs),
      ["0", "4"])
    XCTAssertEqual(
      last.workspace.activities.flatMap(\.clips).flatMap(\.lineIDs).sorted(),
      ["0", "1", "2", "3", "4"])
  }

  @MainActor func testConcurrentLibraryWritersCannotOverwriteEachOther() async throws {
    let (root, model, _, _) = try await library()
    defer { try? FileManager.default.removeItem(at: root) }
    let stores = [model.store, ArchiveStore(root: model.libraryURL)]
    let day = self.day
    let winners = await withTaskGroup(of: Bool.self) { group in
      for (index, store) in stores.enumerated() {
        group.addTask {
          var initial = DayOrganization()
          initial.items = [
            .init(
              title: "事项", summary: "", anchors: [], anchorSentences: [],
              sentences: ["line-\(index)"])
          ]
          return (try? await store.saveOrganization(initial, day: day)) != nil
        }
      }
      var wins = 0
      for await success in group where success { wins += 1 }
      return wins
    }
    XCTAssertEqual(winners, 1)
    let saved = try await model.store.organization(day: day)
    XCTAssertEqual(saved.revision, 1)
    XCTAssertEqual(saved.items.count, 1)
  }

  @MainActor func testNativeSheetPrefillsFromOnlyReviewedSentences() async throws {
    _ = NSApplication.shared
    let (root, model, _, _) = try await library()
    defer { try? FileManager.default.removeItem(at: root) }
    let raw = try XCTUnwrap(model.workspace.activities.first(where: \.isRaw))
    let draft = OrganizationDraft(day: day, clips: [raw.clips[0], raw.clips[2]])
    let frame = NSRect(x: 0, y: 0, width: 440, height: 370)
    let window = NSWindow(
      contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingController(
      rootView: OrganizationSheet(model: model, draft: draft) { _ in }
        .background(Palette.surface))
    window.appearance = NSAppearance(named: .aqua)
    window.contentViewController = host
    window.setContentSize(frame.size)
    host.view.frame = frame
    host.view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    host.view.layoutSubtreeIfNeeded()
    let sheet = host.view
    let bitmap = try XCTUnwrap(sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds))
    sheet.cacheDisplay(in: sheet.bounds, to: bitmap)
    if ProcessInfo.processInfo.environment["WORKDAY_WORKSPACE_SNAPSHOTS"] == "1",
      let output = ProcessInfo.processInfo.environment["WORKDAY_TEST_ROOT"]
    {
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        .write(
          to: URL(fileURLWithPath: output).appendingPathComponent("workspace-organize-selected.png")
        )
    }
    func inputs(_ view: NSView) -> [String] {
      var values: [String] = []
      if let field = view as? NSTextField { values.append(field.stringValue) }
      if let editor = view as? NSTextView { values.append(editor.string) }
      return values + view.subviews.flatMap(inputs)
    }
    let displayed = inputs(sheet).joined(separator: " ")
    XCTAssertTrue(displayed.contains(raw.clips[0].summary))
    XCTAssertTrue(displayed.contains(raw.clips[2].summary))
    XCTAssertFalse(displayed.contains(raw.clips[1].summary))
    XCTAssertFalse(displayed.contains(raw.clips[3].summary))
  }

  @MainActor func testBoundedOriginalReplayAndSplitDays() async throws {
    let (root, model, record, doc) = try await library()
    defer {
      model.player.stop()
      try? FileManager.default.removeItem(at: root)
    }
    let raw = try XCTUnwrap(model.workspace.activities.first(where: \.isRaw))
    model.selectedDetail = .conversation(raw.id)
    let first = try XCTUnwrap(raw.clips.first)
    let last = try XCTUnwrap(raw.clips.last)
    let original = model.libraryURL.appendingPathComponent(record.folder).appendingPathComponent(
      record.originalFile)
    let silent = try ConversationAudioPreview.waveform(original, range: first.start...last.end)
    XCTAssertEqual(silent, Array(repeating: Float.zero, count: 100))
    model.player.setExcerptRate(1.5)
    model.seekExcerpt(first, through: last, to: 5)
    XCTAssertFalse(model.player.playing)
    XCTAssertEqual(model.player.sourcePosition, 5, accuracy: 0.01)
    model.playExcerpt(first, through: last)
    XCTAssertTrue(model.player.playing)
    model.playExcerpt(first, through: last)
    XCTAssertFalse(model.player.playing)
    let clip = raw.clips[1]
    let line = try XCTUnwrap(clip.excerpt?.first)
    model.playExcerpt(clip, line: line)
    XCTAssertTrue(model.player.playing)
    XCTAssertEqual(model.player.recordingID, record.id)
    XCTAssertNil(model.player.route)
    XCTAssertEqual(model.player.sourcePosition, line.start, accuracy: 0.01)
    for _ in 0..<65 where model.player.playing { try await Task.sleep(for: .milliseconds(30)) }
    XCTAssertNil(model.player.error)
    XCTAssertFalse(model.player.playing)
    XCTAssertEqual(model.player.sourcePosition, line.end, accuracy: 0.01)
    XCTAssertEqual(model.selectedDetail, .conversation(raw.id))
    model.playExcerpt(clip, line: line)
    XCTAssertTrue(model.player.playing)
    model.playExcerpt(clip, line: line)
    XCTAssertFalse(model.player.playing)
    var night = record
    let midnight = WorkdayTimeline.calendar.startOfDay(for: try XCTUnwrap(record.startedAt))
    night.startedAt = midnight.addingTimeInterval(-3)
    night.pauses = [RecordingPause(offset: 5.5, duration: 20)]
    var continuous = doc
    continuous.transcript = [.init(id: "one", start: 1, end: 7, text: "跨过午夜和暂停的一句")]
    continuous.conversations = []
    let prior = WorkdayDate.day(midnight.addingTimeInterval(-1))
    let yesterday = DayWorkspace(
      day: prior, recordings: [night], documents: [record.id: continuous], summary: nil)
    let today = DayWorkspace(
      day: day, recordings: [night], documents: [record.id: continuous], summary: nil)
    XCTAssertEqual(yesterday.activities.flatMap(\.clips).map(\.end), [3])
    XCTAssertEqual(today.activities.map { $0.clips[0].start }, [3, 5.5])
    XCTAssertEqual(today.activities.map { $0.clips[0].end }, [5.5, 7])
    XCTAssertEqual(today.activities[1].start, midnight.addingTimeInterval(22.5))
    XCTAssertEqual(Set((yesterday.activities + today.activities).map(\.id)).count, 3)
  }
}
