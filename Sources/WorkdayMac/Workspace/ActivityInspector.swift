import SwiftUI
import WorkdayCore

struct ActivityInspector: View {
  @ObservedObject var model: AppModel
  let entry: ActivityEntry
  let compact: Bool
  let openSource: (String, String?) -> Void
  @State private var showsSources = false
  @State private var showsNotes = false
  @State private var unusedSelection = Set<String>()
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        if compact { Button("‹ 返回全天事项") { model.selectedDetail = nil }.buttonStyle(.link) }
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 7) {
            Text(entry.activity.title).font(.system(size: 23, weight: .semibold))
            Text(entry.timeLabel).font(.callout.monospacedDigit()).foregroundStyle(Palette.muted)
          }
          Spacer(minLength: 12)
          Button { model.playDay(from: entry.clips.first) } label: {
            Label("连续回听", systemImage: "play.circle.fill")
          }.buttonStyle(.plain).foregroundStyle(Palette.accent).font(.callout)
        }
        if !entry.activity.summary.isEmpty {
          Text("讨论内容").font(.headline).padding(.top, 10)
          Text(entry.activity.summary).textSelection(.enabled).lineSpacing(5)
        }
        Divider()
        Text("原话").font(.headline)
        DayTranscriptContent(model: model, entry: entry, chosen: $unusedSelection)
        DisclosureGroup("更多信息", isExpanded: $showsNotes) {
          VStack(alignment: .leading, spacing: 12) {
            let decisions = unique(entry.clips.flatMap(\.decisions))
            let tasks = unique(entry.clips.flatMap(\.tasks))
            if !decisions.isEmpty { notes("决定", decisions) }
            if !tasks.isEmpty { notes("待办", tasks) }
            if let topics = entry.activity.topics, !topics.isEmpty { notes("会议议题", unique(topics)) }
            if let when = entry.activity.appointment, !when.isEmpty {
              Text("约定时间").font(.headline)
              Label(when, systemImage: "calendar")
            }
            let related = Set(entry.activity.relatedIDs ?? [])
            if !related.isEmpty {
              Text("相关事项").font(.headline)
              ForEach(
                model.workspace.activities.filter {
                  !related.isDisjoint(with: $0.activity.conversationIDs)
                }
              ) { item in
                Button(item.timeLabel + "  " + item.activity.title) {
                  model.selectedDetail = .conversation(item.id)
                }
                .buttonStyle(.link)
              }
            }
          }.padding(.top, 8)
        }.font(.caption).foregroundStyle(Palette.muted)
        let ids = unique(entry.clips.map(\.recordingID))
        DisclosureGroup("录音来源 · \(ids.count)", isExpanded: $showsSources) {
          ForEach(ids, id: \.self) { id in
            if let source = model.recordings.first(where: { $0.id == id }) {
              Button(source.originalName + "  ·  查看原文") {
                openSource(id, entry.clips.first { $0.recordingID == id }?.lineIDs.first)
              }
              .buttonStyle(.link).padding(.vertical, 4)
            }
          }
        }
      }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }.background(Palette.surface).accessibilityIdentifier("activity-detail")
  }

  private func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }
  private func notes(_ title: String, _ values: [String]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.headline)
      ForEach(values, id: \.self) { Text($0).textSelection(.enabled) }
    }
  }
}
