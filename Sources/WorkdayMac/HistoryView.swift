import SwiftUI
import WorkdayCore

struct HistoryView: View {
  @ObservedObject var model: AppModel
  @State private var openAsides = Set<String>()
  @State private var sourceReturn: RecordDetailSelection?
  @State private var sourceLineID: String?

  var body: some View {
    let items = model.workspace.activities
    GeometryReader { geometry in
      let wide = geometry.size.width >= 850
      let selected =
        selectedActivity(items)
        ?? (wide && model.selectedDetail == nil
          ? items.first(where: { $0.activity.kind != .aside }) : nil)
      HStack(spacing: 0) {
        if wide || model.selectedDetail == nil {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
              Text(WorkspaceDate.heading(model.selectedDay)).font(.system(size: 28, weight: .bold))
              if model.loading {
                ProgressView("正在读取本地资料…")
              } else if model.dayRecordings.isEmpty {
                EmptyMessage(icon: "calendar", title: "这一天暂无录音", detail: "打开日历，带圆点的日期可以回看。")
                Button("查看资料库") { model.libraryTab = .originals; model.area = .library }
                  .buttonStyle(.link).frame(maxWidth: .infinity)
              } else {
                DaySummaryView(model: model)
                if items.isEmpty {
                  Text(model.dayComplete ? "当天没有提取到工作事项" : "事项整理后会显示在这里。")
                    .foregroundStyle(Palette.muted)
                  Button("查看原始录音") { model.area = .library }.buttonStyle(.link)
                }
                ForEach(["上午", "下午", "晚上", "时间未知"], id: \.self) { period in
                  let entries = items.filter { $0.period == period }
                  if !entries.isEmpty { section(period, entries: entries, selected: selected?.id) }
                }
              }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
          }.id(model.selectedDay).accessibilityIdentifier("day-records-scroll")
            .frame(width: wide && (selected != nil || model.selectedDetail != nil) ? geometry.size.width * 0.49 : nil)
        }
        if let selected {
          if wide { Divider() }
          ActivityInspector(model: model, entry: selected, compact: !wide, openSource: openSource).id(selected.id)
        } else if case .original(let id) = model.selectedDetail {
          if wide { Divider() }
          RecordDetailView(model: model, compact: !wide, initialLineID: sourceLineID) {
            model.selectedDetail = sourceReturn
            sourceLineID = nil
            sourceReturn = nil
          }.id(id)
        } else if model.selectedDetail != nil {
          Button("返回全天事项") { model.selectedDetail = nil }.padding()
        }
      }
    }.onChange(of: model.selectedDay) { _, _ in
      openAsides.removeAll()
      sourceReturn = nil
      sourceLineID = nil
    }
  }

  private func openSource(_ id: String, _ lineID: String?) {
    sourceReturn = model.selectedDetail
    sourceLineID = lineID
    model.selectedDetail = .original(id)
  }

  private func selectedActivity(_ entries: [ActivityEntry]) -> ActivityEntry? {
    guard case .conversation(let id) = model.selectedDetail else { return nil }
    return entries.first { $0.activity.conversationIDs.contains(id) }
  }

  private func section(_ period: String, entries: [ActivityEntry], selected: String?) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Text(period).font(.system(size: 16, weight: .semibold))
        Rectangle().fill(Palette.line).frame(height: 1)
      }.padding(.vertical, 6)
      let events = entries.filter { $0.activity.kind != .aside }
      VStack(spacing: 0) {
        ForEach(events) { entry in
          row(entry, selected: selected, first: entry.id == events.first?.id, last: entry.id == events.last?.id)
        }
      }
      let asides = entries.filter { $0.activity.kind == .aside }
      if !asides.isEmpty {
        DisclosureGroup(
          "零散交流 · \(asides.count)",
          isExpanded: Binding(
            get: { openAsides.contains(period) },
            set: { if $0 { openAsides.insert(period) } else { openAsides.remove(period) } }
          )
        ) {
          ForEach(asides) { entry in
            ForEach(entry.clips) { clip in
              let line = clip.excerpt?.first ?? model.documents[clip.recordingID]?.transcript.first { clip.lineIDs.contains($0.id) }
              let offset = max(line?.start ?? clip.start, clip.start)
              let playing = model.player.playing && model.player.recordingID == clip.recordingID
                && model.player.sourcePosition >= offset && model.player.sourcePosition < (line?.end ?? clip.end)
              HStack(alignment: .top, spacing: 10) {
                Text(clip.wallStart.map(WorkdayTimeline.time) ?? "时间未知").font(.caption.monospacedDigit())
                VStack(alignment: .leading, spacing: 5) {
                  Text(line?.text ?? clip.summary).foregroundStyle(Palette.text).textSelection(.enabled)
                  Button("查看完整原文") { openSource(clip.recordingID, line?.id) }.buttonStyle(.link)
                }
                Spacer(minLength: 4)
                Button {
                  if playing { model.player.toggle() } else { model.playDay(from: clip, offset: offset) }
                } label: { Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill") }
                  .buttonStyle(.plain).foregroundStyle(Palette.accent)
                  .accessibilityLabel(playing ? "暂停这段零散交流" : "回听这段零散交流")
              }.padding(.vertical, 6)
            }
          }
        }
        .font(.callout).foregroundStyle(Palette.muted).padding(.top, 5)
      }
    }
  }

  private func row(_ entry: ActivityEntry, selected: String?, first: Bool, last: Bool) -> some View {
    Button {
      model.selectedDetail = .conversation(entry.id)
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Circle().fill(Palette.accent)
          .frame(width: 7, height: 7).padding(.top, 5)
        Text(entry.timeLabel).font(.system(size: 11).monospacedDigit()).foregroundStyle(
          Palette.muted
        )
        .frame(width: 77, alignment: .leading).padding(.top, 2)
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 5) {
            Text(entry.activity.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.text)
            if model.player.playing && entry.containsPlayback(model.player) {
              Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(Palette.accent)
                .accessibilityLabel("正在回听")
            }
          }
          Text(entry.activity.summary).lineLimit(2).font(.callout).foregroundStyle(Palette.muted)
        }
        Spacer(minLength: 0)
      }.padding(12)
      .background(alignment: .topLeading) {
        GeometryReader { geometry in
          let dotY: CGFloat = 20.5
          Path { path in
            path.move(to: CGPoint(x: 15.5, y: first ? dotY : 0))
            path.addLine(to: CGPoint(x: 15.5, y: last ? dotY : geometry.size.height))
          }.stroke(Palette.accent.opacity(0.35), lineWidth: 1)
        }.allowsHitTesting(false)
      }.background(
        entry.id == selected ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: 8)
      )
      .contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityLabel(entry.timeLabel + "，" + entry.activity.title)
  }
}

struct ActivityInspector: View {
  @ObservedObject var model: AppModel
  let entry: ActivityEntry
  let compact: Bool
  let openSource: (String, String?) -> Void
  @State private var showsSources = false
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        if compact { Button("‹ 返回全天事项") { model.selectedDetail = nil }.buttonStyle(.link) }
        Text(entry.activity.title).font(.system(size: 23, weight: .semibold))
        HStack(spacing: 12) {
          Label(entry.timeLabel, systemImage: "clock").font(.callout.monospacedDigit()).foregroundStyle(Palette.muted)
          Button { model.playDay(from: entry.clips.first) } label: {
            Label(entry.start == nil ? "回听这段录音" : "从这里连续播放", systemImage: "play.circle.fill")
          }.buttonStyle(.plain).foregroundStyle(Palette.accent).font(.callout)
        }
        Divider()
        Text("结果与进展").font(.headline)
        Text(entry.activity.summary).textSelection(.enabled).lineSpacing(4)
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
        let decisions = unique(entry.clips.flatMap(\.decisions))
        let tasks = unique(entry.clips.flatMap(\.tasks))
        if !decisions.isEmpty { notes("决定", decisions) }
        if !tasks.isEmpty { notes("待办", tasks) }
        Divider()
        Text("原话").font(.headline)
        ForEach(entry.clips) { clip in
          if let recording = model.recording(for: clip) {
            let lines = model.documents[recording.id]?.transcript ?? []
            let ids = Set(
              entry.activity.quotes?[clip.id]
                ?? (entry.activity.quotes?.isEmpty == false
                  ? [] : Array(clip.lineIDs.prefix(2))))
            ForEach(lines.filter { ids.contains($0.id) }) { line in
              TranscriptRow(
                line: line, voices: model.voices, voiceID: VoiceRecognition.key(recording, line),
                active: model.player.recordingID == recording.id
                  && model.player.sourcePosition >= line.start
                  && model.player.sourcePosition < line.end,
                playing: model.player.playing,
                clockLabel: WorkdayTimeline.date(recording, offset: max(line.start, clip.start)).map
                {
                  WorkdayDate.clock(
                    $0.timeIntervalSince(WorkdayTimeline.calendar.startOfDay(for: $0)))
                }
              ) {
                if model.player.playing, model.player.recordingID == recording.id,
                  model.player.sourcePosition >= line.start, model.player.sourcePosition < line.end
                {
                  model.player.toggle()
                } else {
                  model.playDay(from: clip, offset: line.start)
                }
              }
            }
          }
        }
        Divider()
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
