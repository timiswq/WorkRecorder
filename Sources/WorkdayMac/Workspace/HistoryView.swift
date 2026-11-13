import SwiftUI
import WorkdayCore

struct HistoryView: View {
  @ObservedObject var model: AppModel
  @State private var collapsedPeriods = Set<String>()
  @State private var rawOnly = false
  @State private var draft: OrganizationDraft?
  @State private var sourceReturn: RecordDetailSelection?
  @State private var sourceLineID: String?

  var body: some View {
    let all = model.workspace.activities
    let raw = all.filter(\.isRaw)
    let items = rawOnly ? raw : all
    VStack(spacing: 0) {
      GeometryReader { geometry in
        let wide = geometry.size.width >= 800
        let selected =
          selectedActivity(items)
          ?? (wide && model.selectedDetail == nil ? items.first : nil)
        if wide && (selected != nil || model.selectedDetail != nil) {
          WorkspaceSplitView {
            dayList(all: all, raw: raw, items: items, selected: selected, wide: true)
              .frame(minWidth: 320, idealWidth: 410, maxWidth: .infinity)
          } trailing: {
            detail(selected, compact: false)
              .frame(minWidth: 320, idealWidth: 450, maxWidth: .infinity)
          }.accessibilityIdentifier("day-workspace-split")
        } else if selected != nil || model.selectedDetail != nil {
          VStack(spacing: 0) {
            DayWorkspaceHeader(model: model)
            Divider()
            detail(selected, compact: true)
          }
        } else {
          dayList(all: all, raw: raw, items: items, selected: nil, wide: false)
        }
      }
    }.sheet(item: $draft) { item in
      OrganizationSheet(model: model, draft: item) { id in
        draft = nil
        guard model.selectedDay == item.day else { return }
        rawOnly = false
        if let target = model.workspace.activities.first(where: { $0.manualIDs.contains(id) }) {
          collapsedPeriods.remove(target.period)
        }
        model.selectedDetail = .conversation(id)
      }
    }.onChange(of: rawOnly) { _, filter in
      if filter { model.selectedDetail = nil }
    }.onChange(of: model.selectedDay) { _, _ in
      draft = nil
      collapsedPeriods.removeAll()
      rawOnly = false
      sourceReturn = nil
      sourceLineID = nil
    }
  }

  private func dayList(
    all: [ActivityEntry], raw: [ActivityEntry], items: [ActivityEntry],
    selected: ActivityEntry?, wide: Bool
  ) -> some View {
    VStack(spacing: 0) {
      DayWorkspaceHeader(model: model)
      Divider()
      timeline(all: all, raw: raw, items: items, selected: selected, wide: wide)
    }
  }

  private func timeline(
    all: [ActivityEntry], raw: [ActivityEntry], items: [ActivityEntry],
    selected: ActivityEntry?, wide: Bool
  ) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 16) {
          if model.loading {
            ProgressView("正在读取本地资料…")
          } else if model.dayRecordings.isEmpty {
            if model.selectedDay == WorkdayDate.day(Date()) {
              TodayRecordingStatus(model: model)
            } else {
              Text("这一天没有本地录音").font(.title3.weight(.semibold))
              if let recent = model.days.first(where: { WorkspaceDate.date($0) != nil }) {
                Button("查看最近的记录 · " + WorkspaceDate.title(recent)) { model.selectDay(recent) }
              } else if !model.recordings.isEmpty {
                Button("查看原始录音") { model.showOriginals() }
              } else {
                Button("导入本地音频…") { model.chooseFiles() }.disabled(model.importLabel != nil)
              }
            }
          } else {
            DaySummaryView(model: model)
            if all.isEmpty {
              ForEach(model.dayRecordings.prefix(3)) { recording in
                OriginalRecordingRow(model: model, recording: recording) {
                  openSource(recording.id, nil)
                }
              }
            }
            if !model.workspace.audio.spans.isEmpty {
              DayActivityOverview(model: model, entries: all, selected: selected?.id)
            }
            if !all.isEmpty {
              HStack {
                Text("时间线").font(.headline)
                Spacer(minLength: 8)
                Picker("时间线范围", selection: $rawOnly) {
                  Text("全部 · \(all.count)").tag(false)
                  Text("未整理 · \(raw.count)").tag(true)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
              }
              if rawOnly && raw.isEmpty {
                Text("当天的原话都已归入事项。").font(.callout).foregroundStyle(Palette.muted)
              }
            }
            ForEach(["上午", "下午", "晚上", "时间未知"], id: \.self) { period in
              let entries = items.filter { $0.period == period }
              if !entries.isEmpty { section(period, entries: entries, selected: selected?.id) }
            }
          }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
      }.id(model.selectedDay)
        .onChange(of: model.selectedDetail) { _, detail in
          guard wide, case .conversation(let id) = detail,
            let entry = items.first(where: { $0.id == id || $0.manualIDs.contains(id) })
          else { return }
          collapsedPeriods.remove(entry.period)
          withAnimation { proxy.scrollTo(entry.id, anchor: .center) }
        }
    }.accessibilityIdentifier("day-records-scroll")
  }

  @ViewBuilder private func detail(_ selected: ActivityEntry?, compact: Bool) -> some View {
    if let selected {
      if selected.isRaw {
        RawConversationInspector(
          model: model, entry: selected, compact: compact, openSource: openSource
        ) { clips in
          if let day = model.selectedDay { draft = OrganizationDraft(day: day, clips: clips) }
        }.id(selected.id)
      } else {
        ActivityInspector(model: model, entry: selected, compact: compact, openSource: openSource)
          .id(selected.id)
      }
    } else if case .original(let id) = model.selectedDetail {
      RecordDetailView(model: model, compact: compact, initialLineID: sourceLineID) {
        model.selectedDetail = sourceReturn
        sourceLineID = nil
        sourceReturn = nil
      }.id(id)
    } else {
      Button("返回全天事项") { model.selectedDetail = nil }.padding()
    }
  }

  private func openSource(_ id: String, _ lineID: String?) {
    sourceReturn = model.selectedDetail
    sourceLineID = lineID
    model.selectedDetail = .original(id)
  }

  private func selectedActivity(_ entries: [ActivityEntry]) -> ActivityEntry? {
    guard case .conversation(let id) = model.selectedDetail else { return nil }
    return entries.first {
      $0.id == id || $0.manualIDs.contains(id) || $0.activity.conversationIDs.contains(id)
    }
      ?? model.dayConversations.first(where: { $0.id == id }).flatMap { clip in
        entries.first { entry in
          entry.clips.contains {
            $0.recordingID == clip.recordingID && $0.end > clip.start
              && $0.start < clip.end && !Set(clip.lineIDs).isDisjoint(with: $0.lineIDs)
          }
        }
      }
  }

  private func section(_ period: String, entries: [ActivityEntry], selected: String?) -> some View {
    let collapsed = collapsedPeriods.contains(period)
    return VStack(alignment: .leading, spacing: 5) {
      Button {
        if collapsed { collapsedPeriods.remove(period) } else { collapsedPeriods.insert(period) }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: collapsed ? "chevron.right" : "chevron.down")
            .font(.caption.weight(.semibold)).foregroundStyle(Palette.muted).frame(width: 12)
          Text(period).font(.system(size: 16, weight: .semibold))
          Rectangle().fill(Palette.line).frame(height: 1)
        }.padding(.vertical, 6).contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .foregroundStyle(Palette.text)
      .help((collapsed ? "展开" : "收起") + period)
      .accessibilityLabel(period)
      .accessibilityValue(collapsed ? "已收起" : "已展开")
      .accessibilityIdentifier("day-period-" + period)
      if !collapsed {
        VStack(spacing: 0) {
          ForEach(entries) { entry in
            row(
              entry, selected: selected, first: entry.id == entries.first?.id,
              last: entry.id == entries.last?.id
            )
            .id(entry.id)
          }
        }
      }
    }
  }

  private func row(_ entry: ActivityEntry, selected: String?, first: Bool, last: Bool) -> some View
  {
    Button {
      model.selectedDetail = .conversation(entry.id)
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Circle().strokeBorder(entry.isRaw ? Palette.amber : Palette.accent, lineWidth: 1.6)
          .background(Circle().fill(entry.isRaw ? Palette.surface : Palette.accent))
          .frame(width: 7, height: 7).padding(.top, 5)
        Text(entry.timeLabel).font(.system(size: 11).monospacedDigit()).foregroundStyle(
          Palette.muted
        )
        .frame(width: 77, alignment: .leading).padding(.top, 2)
        HStack(spacing: 5) {
          VStack(alignment: .leading, spacing: 4) {
            if entry.isRaw {
              Text("未整理 · \(entry.clips.count) 句").font(.caption.weight(.medium)).foregroundStyle(
                Palette.amber)
            }
            Text(entry.activity.title).font(
              .system(size: entry.isRaw ? 13 : 15, weight: entry.isRaw ? .regular : .semibold)
            )
            .lineLimit(2).foregroundStyle(Palette.text)
          }
          if model.player.playing && entry.containsPlayback(model.player) {
            Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(Palette.accent)
              .accessibilityLabel("正在回听")
          }
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
    }.buttonStyle(.plain).accessibilityLabel(
      entry.timeLabel + (entry.isRaw ? "，未整理，" : "，") + entry.activity.title
    )
    .accessibilityAddTraits(entry.id == selected ? .isSelected : [])
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
          if compact {
            Label(entry.timeLabel, systemImage: "clock").font(.callout.monospacedDigit())
              .foregroundStyle(Palette.muted)
          }
          Button {
            model.playDay(from: entry.clips.first)
          } label: {
            Label(entry.start == nil ? "回听这段录音" : "从这里连续播放", systemImage: "play.circle.fill")
          }.buttonStyle(.plain).foregroundStyle(Palette.accent).font(.callout)
        }
        Divider()
        if !entry.activity.summary.isEmpty {
          Text("结果与进展").font(.headline)
          Text(entry.activity.summary).textSelection(.enabled).lineSpacing(4)
        }
        let decisions = unique(entry.clips.flatMap(\.decisions))
        let tasks = unique(entry.clips.flatMap(\.tasks))
        if !decisions.isEmpty { notes("决定", decisions) }
        if !tasks.isEmpty { notes("待办", tasks) }
        Divider()
        Text("原话").font(.headline)
        ForEach(entry.clips) { clip in
          if let recording = model.recording(for: clip) {
            if entry.addedSentenceIDs.contains(clip.id),
              entry.clips.first(where: { entry.addedSentenceIDs.contains($0.id) })?.id == clip.id
            {
              Label("补入原话", systemImage: "text.badge.plus").font(.callout.weight(.semibold))
            }
            let ids = Set(
              entry.activity.quotes?[clip.id]
                ?? (entry.activity.quotes?.isEmpty == false ? [] : Array(clip.lineIDs.prefix(2))))
            let lines =
              entry.isManualItem || entry.addedSentenceIDs.contains(clip.id)
              ? (clip.excerpt ?? [])
              : (model.documents[recording.id]?.transcript ?? []).filter {
                ids.contains($0.id) && clip.lineIDs.contains($0.id)
              }
            ForEach(lines) { line in
              let active = model.excerptPlaying(clip, line: line)
              TranscriptRow(
                line: line, voices: model.voices, voiceID: VoiceRecognition.key(recording, line),
                active: active,
                playing: model.player.playing,
                clockLabel: DaySentenceTime.label(clip, line: line)
              ) { model.playExcerpt(clip, line: line) }
            }
          }
        }
        Divider()
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
