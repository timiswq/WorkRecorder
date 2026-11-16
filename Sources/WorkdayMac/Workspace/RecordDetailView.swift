import SwiftUI
import WorkdayCore

struct RecordDetailView: View {
  @ObservedObject var model: AppModel
  var compact: Bool
  var originalID: String? = nil
  var initialLineID: String? = nil
  var onClose: (() -> Void)? = nil
  @State private var showsOriginal = false
  @State private var scrollID: String?
  @State private var clipScrollID: String?
  @State private var originalScrollID: String?

  private var clip: Conversation? {
    guard originalID == nil, case .conversation(let id) = model.selectedDetail else { return nil }
    return model.dayConversations.first { $0.id == id }
  }
  private var recording: Recording? {
    if let originalID { return model.recordings.first { $0.id == originalID } }
    if let clip { return model.recording(for: clip) }
    guard case .original(let id) = model.selectedDetail else { return nil }
    return model.recordings.first { $0.id == id }
  }
  private var lines: [TranscriptLine] {
    guard let recording else { return [] }
    let all = model.documents[recording.id]?.transcript ?? []
    guard let clip, !showsOriginal else { return all }
    return all.filter { clip.lineIDs.contains($0.id) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Button {
          if let onClose { onClose() } else { model.selectedDetail = nil }
        } label: {
          Label(compact ? "返回列表" : "关闭详情", systemImage: compact ? "chevron.left" : "xmark")
        }
        .buttonStyle(.plain).font(.system(size: 12)).accessibilityIdentifier("close-record-detail")
        Spacer()
        if clip != nil {
          Button(showsOriginal ? "返回这段对话" : "查看完整文字") {
            if showsOriginal { originalScrollID = scrollID } else { clipScrollID = scrollID }
            showsOriginal.toggle()
          }.buttonStyle(.link).font(.system(size: 12))
        }
        if let recording {
          Menu {
            Button("打开原件所在目录") { model.reveal(recording) }
            RecordingRetryButton(model: model, recording: recording, inMenu: true)
          } label: {
            Image(systemName: "ellipsis")
          }.menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("这段录音的操作")
        }
      }.padding(20)
      Divider()
      if let recording {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
              Text(showsOriginal ? "完整录音" : clip?.title ?? "完整录音").font(
                .system(size: 19, weight: .semibold)
              ).id(
                "detail-top")
              Text(recording.originalName).font(.system(size: 11)).foregroundStyle(Palette.muted)
                .textSelection(.enabled)
              if clip == nil || showsOriginal,
                let skipped = model.documents[recording.id]?.unrecognizedChunkDescription
              {
                Text(skipped).font(.system(size: 12)).foregroundStyle(Palette.muted)
              }
              HStack {
                Button {
                  if let clip, !showsOriginal {
                    model.play(clip)
                  } else {
                    model.playOriginal(recording, at: clip?.start ?? 0)
                  }
                } label: {
                  Label("播放", systemImage: "play.fill")
                }.controlSize(.small)
                Text(
                  humanDuration(
                    showsOriginal
                      ? recording.duration : clip.map { $0.end - $0.start } ?? recording.duration)
                )
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
                Spacer()
              }
              if let clip, !showsOriginal {
                Text(clip.summary).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
              }
              RecordingRetryButton(model: model, recording: recording)
              let state = model.recordingProcessingState(recording)
              if let error = model.documents[recording.id]?.error, state == .failed || state == .needsSetup {
                ErrorDetailsButton(message: error, context: "录音：\(recording.originalName)")
              }
              if originalID != nil {
                ForEach(WorkdayTimeline.days(recording), id: \.self) { day in
                  let entries = model.workspace(for: day).activities.filter { $0.clips.contains { $0.recordingID == recording.id } }
                  if !entries.isEmpty {
                    Text("关联事项 · " + WorkspaceDate.title(day)).font(.headline)
                    ForEach(entries) { entry in
                      Button(entry.timeLabel + "  " + entry.activity.title) {
                        model.selectDay(day); model.selectedDetail = .conversation(entry.id)
                      }.buttonStyle(.link)
                    }
                  }
                }
              }
              Divider()
              Text(showsOriginal || clip == nil ? "完整文字" : "对话原文").font(
                .system(size: 13, weight: .semibold))
              if lines.isEmpty {
                Text(model.recordingProcessingState(recording) == .complete
                  ? "这段录音未识别到文字，仍可回听原录音。" : "转写完成后，文字会自动显示在这里；现在仍可回听原录音。").font(.system(size: 13)).foregroundStyle(Palette.muted)
              }
              ForEach(lines) { line in
                TranscriptRow(
                  line: line, voices: model.voices, voiceID: VoiceRecognition.key(recording, line),
                  active: model.player.isAt(recording.id, from: line.start, to: line.end)
                ) {
                  if let clip, !showsOriginal {
                    model.play(clip, at: line.start)
                  } else {
                    model.playOriginal(recording, at: line.start)
                  }
                }.id(line.id)
              }
            }.scrollTargetLayout().padding(20)
          }.scrollPosition(id: $scrollID)
            .task(id: showsOriginal) {
              await Task.yield()
              guard !Task.isCancelled else { return }
              let target =
                showsOriginal
                ? originalScrollID ?? clip?.lineIDs.first ?? "detail-top"
                : clipScrollID ?? initialLineID ?? "detail-top"
              scrollID = target
              proxy.scrollTo(target, anchor: .top)
            }
            .onChange(of: model.selectedDetail) { _, _ in
              clipScrollID = nil
              originalScrollID = nil
              showsOriginal = false
              scrollID = "detail-top"
              proxy.scrollTo("detail-top", anchor: .top)
            }
        }
      } else {
        EmptyMessage(icon: "text.bubble", title: "这条记录暂不可用", detail: "返回工作记录后重新选择。")
      }
    }.background(Palette.surface).accessibilityIdentifier("record-detail")
  }
}

struct TranscriptRow: View {
  let line: TranscriptLine
  let voices: VoiceRecognition
  let voiceID: String
  let active: Bool
  var playing = false
  var clockLabel: String? = nil
  var showsSpeaker = true
  let play: () -> Void
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Button(action: play) {
        Text(clockLabel ?? WorkdayDate.clock(line.start)).font(.system(size: 11).monospacedDigit())
          .padding(.horizontal, 6).padding(.vertical, 7).contentShape(Rectangle())
      }.buttonStyle(.plain).foregroundStyle(Palette.accent)
        .accessibilityLabel("从 \(clockLabel ?? WorkdayDate.clock(line.start)) 开始播放").help("从这句话开始播放")
      VStack(alignment: .leading, spacing: 5) {
        if showsSpeaker { SpeakerBadge(voices: voices, id: voiceID, fallback: line.speaker) }
        Text(line.text).font(.system(size: 14)).lineSpacing(6).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let clockLabel {
        Button(action: play) {
          Image(systemName: active && playing ? "pause.circle.fill" : "play.circle.fill")
            .font(.system(size: 18))
        }.buttonStyle(.plain).foregroundStyle(Palette.accent)
          .accessibilityLabel((active && playing ? "暂停" : "回听") + clockLabel + "的原话")
      }
    }.padding(8).background(
      active ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
  }
}
