import SwiftUI
import WorkdayCore

enum DaySentenceTime {
  static func label(_ clip: Conversation, line: TranscriptLine) -> String {
    let start = max(line.start, clip.start)
    guard let wall = clip.wallStart else { return WorkdayDate.clock(start) }
    let at = wall.addingTimeInterval(start - clip.start)
    return WorkdayDate.clock(
      at.timeIntervalSince(WorkdayTimeline.calendar.startOfDay(for: at)).rounded(.down))
  }
}

private enum OrganizationAction: String {
  case create = "新建事项"
  case append = "加入已有事项"
}

struct RawConversationInspector: View {
  @ObservedObject var model: AppModel
  let entry: ActivityEntry
  let compact: Bool
  let openSource: (String, String?) -> Void
  let edit: ([Conversation]) -> Void
  @State private var selecting = false
  @State private var chosen = Set<String>()

  var body: some View {
    let selected = entry.clips.filter { chosen.contains($0.id) }
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if compact { Button("‹ 返回全天事项") { model.selectedDetail = nil }.buttonStyle(.link) }
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
              Text("对话片段").font(.system(size: 23, weight: .semibold))
              Text(entry.timeLabel).font(.callout.monospacedDigit()).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 12)
            if let first = entry.clips.first, let last = entry.clips.last {
              let playing = model.player.playing && model.player.selectionID == model.excerptID(first, through: last)
              Button { model.playExcerpt(first, through: last) } label: {
                Label(playing ? "暂停这段" : "播放这段", systemImage: playing ? "pause.circle.fill" : "play.circle.fill")
              }.buttonStyle(.plain).foregroundStyle(Palette.accent)
            }
            Menu {
              Button("选择原话…") { selecting = true; chosen = Set(entry.clips.map(\.id)) }
              if let first = entry.clips.first {
                Button("查看完整原文") { openSource(first.recordingID, first.lineIDs.first) }
              }
            } label: { Image(systemName: "ellipsis") }
              .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("对话操作")
          }
          Divider()
          HStack {
            Text("原话").font(.headline)
            Spacer()
            if selecting {
              Button(selected.count == entry.clips.count ? "取消全选" : "全选") {
                chosen = selected.count == entry.clips.count ? [] : Set(entry.clips.map(\.id))
              }.buttonStyle(.link)
            }
          }
          DayTranscriptContent(model: model, entry: entry, selecting: selecting, chosen: $chosen)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
      }
      if selecting {
        Divider()
        HStack {
          Button("取消") { selecting = false; chosen.removeAll() }.buttonStyle(.plain)
          Text("已选 \(selected.count) 句").font(.callout).foregroundStyle(Palette.muted)
          Spacer()
          Button("加入事项…") { edit(selected) }.buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty)
        }.padding(.horizontal, 20).padding(.vertical, 12)
      }
    }.background(Palette.surface).accessibilityIdentifier("raw-conversation-detail")
  }
}

struct OrganizationDraft: Identifiable {
  let id = UUID()
  let day: String
  let clips: [Conversation]
}

struct OrganizationSheet: View {
  @ObservedObject var model: AppModel
  let draft: OrganizationDraft
  let didSave: (String) -> Void
  @State private var action: OrganizationAction = .create
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var summary = ""
  @State private var target: String?
  @State private var saving = false
  @State private var error: String?

  var body: some View {
    let targets = model.workspace(for: draft.day).activities.filter { !$0.isRaw }
    VStack(alignment: .leading, spacing: 15) {
      Text("加入事项").font(.title2.bold())
      Picker("保存方式", selection: $action) {
        Text("新建事项").tag(OrganizationAction.create)
        Text("加入已有事项").tag(OrganizationAction.append)
      }.pickerStyle(.segmented).labelsHidden()

      if action == .create {
        VStack(alignment: .leading, spacing: 5) {
          Text("事项名称").font(.caption).foregroundStyle(.secondary)
          TextField("事项名称", text: $title)
        }
        VStack(alignment: .leading, spacing: 5) {
          Text("摘要（选填）").font(.caption).foregroundStyle(.secondary)
          TextField("摘要", text: $summary, axis: .vertical).lineLimit(2...4)
        }
      } else {
        if targets.isEmpty { Text("当天还没有可加入的事项。").font(.callout).foregroundStyle(.secondary) }
        Picker("补进事项", selection: $target) {
          Text("选择当天事项").tag(nil as String?)
          ForEach(targets) { item in
            Text(item.timeLabel + "  " + item.activity.title).tag(Optional(item.id))
          }
        }
      }
      Text("已选原话 · \(draft.clips.count) 句").font(.headline)
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(draft.clips) { clip in
            if let line = clip.excerpt?.first {
              HStack(alignment: .firstTextBaseline) {
                Text(DaySentenceTime.label(clip, line: line)).font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
                Text(line.text).lineLimit(3)
              }
            }
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.frame(maxHeight: 165)
      if let error { Text(error).foregroundStyle(.red).font(.callout) }
      HStack {
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
        Button(saving ? "正在保存…" : action.rawValue) {
          saving = true
          Task {
            do {
              let id = try await model.organize(
                day: draft.day, sentenceIDs: Set(draft.clips.map(\.id)),
                title: title, summary: summary, into: action == .append ? target : nil)
              didSave(id)
            } catch { self.error = error.localizedDescription }
            saving = false
          }
        }.keyboardShortcut(.defaultAction)
          .disabled(
            saving || draft.clips.isEmpty
              || (action == .create
                ? title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                : !targets.contains { $0.id == target })
          )
      }
    }.padding(24).frame(width: 440)
      .onAppear {
        title = String((draft.clips.first?.summary ?? "").prefix(32))
        summary = draft.clips.map(\.summary).joined(separator: " ")
      }
      .interactiveDismissDisabled(saving)
  }
}
