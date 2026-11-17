import SwiftUI
import WorkdayCore

struct CurrentView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var history: CaptionHistory
  @State private var scrollAnchor: CaptionSelection?

  init(model: AppModel, history: CaptionHistory) {
    self.model = model
    self.history = history
    _scrollAnchor = State(initialValue: model.captionReadingAnchor)
  }

  private var selectedRange: ClosedRange<Date>? { model.captionPosition.selectedRange }
  private var following: Bool { model.captionPosition == .latest }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let window = CaptionWindow(now: max(context.date, Date()))
      let records = history.readingRecords
      let rows = window.visible(in: records)
      let matches = selectedRange == nil ? rows : window.visible(in: records, during: selectedRange)
      VStack(alignment: .leading, spacing: 0) {
        if let issue = history.issue {
          Text(issue).font(.caption).foregroundStyle(Palette.amber).padding(8)
        }
        controls(window, count: matches.count)
        CaptionTimeRuler(window: window, records: rows, selected: selectedRange) {
          model.selectCaptionRange($0, in: window)
        }
        .padding(.horizontal, 18).padding(.bottom, 10)
        Divider()
        if selectedRange == nil, rows.isEmpty {
          empty
        } else {
          transcript(window, rows: matches, allRows: rows)
        }
      }
      .onChange(of: window.minutes.lowerBound, initial: true) { _, start in
        if let selectedRange, selectedRange.upperBound < start { resume() }
      }
    }
    .background(Palette.surface)
  }

  private func controls(_ window: CaptionWindow, count matchCount: Int) -> some View {
    HStack(spacing: 12) {
      if following {
        Label(inputStatus(at: window.now), systemImage: "waveform")
          .lineLimit(1).truncationMode(.tail)
      } else {
        Label(
          selectedRange == nil ? "正在回看" : "所选时段 · \(matchCount) 句",
          systemImage: "clock.arrow.circlepath")
        let count = history.unreadCount(in: window)
        Button(count > 0 ? "\(count) 条新字幕 · 回到最新" : "回到最新") { resume() }
          .buttonStyle(.borderless).foregroundStyle(Palette.accent)
          .accessibilityIdentifier("live-return-latest")
      }
      recovery
      Spacer(minLength: 4)
    }
    .font(.callout).foregroundStyle(Palette.muted)
    .padding(.horizontal, 18).frame(minHeight: 42)
  }

  private func resume() {
    model.captionPosition = .latest
  }

  private func updateScrollPosition(atTop: Bool) {
    guard selectedRange == nil, following != atTop else { return }
    model.captionPosition = atTop ? .latest : .scrolling
    if !atTop, let scrollAnchor { model.captionReadingAnchor = scrollAnchor }
  }

  private func transcript(
    _ window: CaptionWindow, rows: ArraySlice<CaptionRecord>,
    allRows: ArraySlice<CaptionRecord>
  ) -> some View {
    let midnight = WorkdayTimeline.calendar.startOfDay(for: window.now)
    let lastYesterday = rows.firstIndex(atOrAfter: midnight) - 1
    let latestID = rows.last?.id
    let currentID = model.captionLeadID(at: window.now)
    let target = model.captionReadingAnchor
    return ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          Color.clear.frame(height: 1).id("live-top")
          if let selectedRange, rows.isEmpty {
            let neighbors = allRows.neighbors(of: selectedRange)
            VStack(spacing: 10) {
              Text("这段时间没有字幕").foregroundStyle(Palette.muted)
              HStack(spacing: 18) {
                if let before = neighbors.previous { jumpButton("查看上一句", to: before, in: window) }
                if let after = neighbors.next { jumpButton("查看下一句", to: after, in: window) }
              }
            }.font(.callout).frame(maxWidth: .infinity).padding(.vertical, 24)
          }
          ForEach(rows.reversed()) { line in
            VStack(alignment: .leading, spacing: 0) {
              if rows.indices.contains(lastYesterday), rows[lastYesterday].id == line.id {
                section("昨天")
              }
              row(
                line, current: selectedRange == nil && line.id == latestID && line.id == currentID)
            }.id(line.readingAnchor)
          }
        }
        .scrollTargetLayout()
        .padding(.horizontal, 8).padding(.bottom, 12)
        .background(ScrollGestureObserver(onPosition: updateScrollPosition(atTop:)))
      }
      .scrollPosition(id: $scrollAnchor, anchor: .top)
      .accessibilityIdentifier("live-transcript-scroll")
      .onChange(of: scrollAnchor) { _, anchor in
        if model.area == .live, !following, let anchor {
          model.captionReadingAnchor = anchor
        }
      }
      .onChange(of: model.captionPosition, initial: true) { previous, position in
        if position == .latest {
          proxy.scrollTo("live-top", anchor: .top)
        } else if let target, scrollAnchor != target || previous == position {
          proxy.scrollTo(target, anchor: .top)
        }
      }
      .onChange(of: rows.last?.id) { _, _ in
        if following { proxy.scrollTo("live-top", anchor: .top) }
      }
    }
  }

  private func jumpButton(_ label: String, to record: CaptionRecord, in window: CaptionWindow)
    -> some View
  {
    let day = CaptionTime.day(record.time, relativeTo: window.now)
    return Button("\(label) · \(day) \(CaptionTime.seconds.string(from: record.time))") {
      model.showNeighboringCaption(record, in: window)
    }.buttonStyle(.borderless).foregroundStyle(Palette.accent)
  }

  private func section(_ title: String) -> some View {
    Text(title).font(.callout.weight(.semibold)).foregroundStyle(Palette.muted)
      .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 2)
  }

  private func row(_ record: CaptionRecord, current: Bool = false) -> some View {
    let selected = model.selectedCaption?.id == record.id
    let speaker = model.captionSpeaker(for: record)
    let transcript = record.transcript
    let playing = model.player.captionID == record.id && model.player.playing
    let time = CaptionTime.seconds.string(from: record.time)
    let speakerColor = speaker.label.isMine ? Palette.accent : Palette.muted
    let canRetry =
      model.preferences.liveModel == .segment && model.preferences.cloudEnabled
      && model.preferences.realtime && model.hasKey && model.preferences.captions.enabled

    return VStack(alignment: .leading, spacing: 4) {
      Text(transcript.text)
        .font(.system(size: current ? 18 : 14, weight: current ? .medium : .regular))
        .lineSpacing(3).foregroundStyle(Palette.text)
        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        .simultaneousGesture(
          DragGesture(minimumDistance: 3).onChanged { _ in
            if following { model.captionPosition = .scrolling }
          })

      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Button(time) { model.selectCaption(record) }
          .buttonStyle(.plain).monospacedDigit().help("选中这句字幕")
        Menu {
          speakerAction(speaker, record: record)
        } label: {
          Text(speaker.title(using: model.preferences.captions)).lineLimit(1)
        }.menuStyle(.borderlessButton).controlSize(.small)
          .tint(speakerColor).fixedSize(horizontal: false, vertical: true)
          .contextMenu { speakerAction(speaker, record: record) }
          .accessibilityLabel(
            "发言人：" + speaker.title(using: model.preferences.captions))
        if !record.isFinal {
          Text(
            model.localCaptions.isWorking && model.localCaptions.lines.last?.id == record.id
              ? "识别中" : "初稿"
          )
          .foregroundStyle(Palette.accent)
        }
        Text(transcript.source?.title ?? "来源未记录").fixedSize()
        Button {
          model.replayCaption(record)
        } label: {
          Label(playing ? "暂停" : "回听", systemImage: playing ? "pause.fill" : "play.fill")
        }.buttonStyle(.borderless).fixedSize()
          .foregroundStyle(record.replay != nil ? Palette.accent : Palette.muted.opacity(0.55))
          .disabled(record.replay == nil)
          .help(
            record.replay != nil
              ? (playing ? "暂停这句字幕" : "回听这句字幕")
              : (record.isFinal ? "这句字幕没有缓存音频" : "字幕定稿并缓存音频后即可回听")
          )
          .accessibilityLabel((playing ? "暂停 " : "回听 ") + time + " 的字幕")
          .accessibilityIdentifier("caption-replay")
        if canRetry, case .failed = record.fileReview {
          Button("重试云端转写") { history.retryReview(record) }
            .buttonStyle(.borderless).foregroundStyle(Palette.accent)
        }
      }.font(.caption).foregroundStyle(Palette.muted)
    }
    .padding(.horizontal, 10).padding(.vertical, current ? 12 : 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(selected ? Palette.selected : .clear)
    .overlay(alignment: .leading) {
      if selected { Rectangle().fill(Palette.accent).frame(width: 2) }
    }
    .contentShape(Rectangle())
    .simultaneousGesture(TapGesture().onEnded { model.selectCaption(record) })
    .accessibilityElement(children: .contain)
    .accessibilityAction(named: Text("选中这句字幕")) { model.selectCaption(record) }
  }

  @ViewBuilder private func speakerAction(_ speaker: CaptionSpeaker, record: CaptionRecord) -> some View {
    if speaker.markedHere && !speaker.hasSavedSample { Text("仅标注本句") }
    if !speaker.label.isMine {
      Button("是我") { model.confirmCaption(record.id) }
    }
    if !speaker.label.excluded {
      Button("不是我") { model.correctCaption(record.id, expectedTurn: speaker.id) }
    }
  }

  private var empty: some View {
    VStack(spacing: 10) {
      Image(systemName: "text.bubble").font(.system(size: 30, weight: .light)).foregroundStyle(
        Palette.muted)
      Text("最近 24 小时还没有字幕").font(.headline)
      if model.localCaptions.canRetry {
        Text(model.localCaptions.status).font(.callout).foregroundStyle(Palette.muted)
      }
    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func inputStatus(at now: Date) -> String {
    model.statusPresentation(at: now).caption.title
  }

  @ViewBuilder private var recovery: some View {
    if let action = model.statusPresentation(at: Date()).caption.action,
      action == .captionSettings || action == .retryCaptions
    {
      Button(action.title) { model.performStatusAction(action) }
    }
  }
}
