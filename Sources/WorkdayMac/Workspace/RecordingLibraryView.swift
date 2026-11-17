import SwiftUI
import WorkdayCore

struct OriginalRecordingRow: View {
  @ObservedObject var model: AppModel
  let recording: Recording
  let open: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        Button(action: open) {
          VStack(alignment: .leading, spacing: 7) {
            Text(recording.originalName).font(.system(size: 13, weight: .medium)).lineLimit(1)
              .help(recording.originalName)
            Text(
              humanDuration(recording.duration)
            )
            .font(.system(size: 12)).foregroundStyle(Palette.muted)
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("查看原录音，" + recording.originalName)
        Button {
          model.playOriginal(recording)
        } label: {
          Image(systemName: "play.circle.fill").font(.system(size: 25))
        }
        .buttonStyle(.plain).foregroundStyle(Palette.accent).accessibilityLabel(
          "播放完整录音，" + recording.originalName)
      }
      RecordingRetryButton(model: model, recording: recording)
      let state = model.recordingProcessingState(recording)
      if let error = model.documents[recording.id]?.error, state == .failed || state == .needsSetup {
        ErrorDetailsButton(message: error, context: "录音：\(recording.originalName)")
      }
    }.padding(13).background(
      model.area == .originals && model.libraryRecordingID == recording.id
        ? Palette.selected : Palette.surface,
      in: RoundedRectangle(cornerRadius: 8)
    )
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
  }
}

struct RecordingRetryButton: View {
  @ObservedObject var model: AppModel
  let recording: Recording
  var inMenu = false

  var body: some View {
    let state = model.recordingProcessingState(recording)
    if state != .complete {
      if inMenu {
        if let title = state.actionTitle { Button(title) { perform(state) } }
        else { Text(state.message) }
      } else {
        ProcessingStatusView(message: state.message, kind: state.kind, actionTitle: state.actionTitle) {
          perform(state)
        }
      }
    }
  }

  private func perform(_ state: RecordingProcessingState) {
    if state == .needsSetup { model.requestSettings(.recognition) }
    else { model.retryProcessing(scope: .recording(recording.id)) }
  }
}

struct RecordingLibraryView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    let recordings = model.visibleOriginals
    VStack(spacing: 0) {
      WorkspacePageHeader(
        title: "原始录音",
        subtitle: model.originalsDay.map {
          WorkspaceDate.heading($0, full: true) + " · \(recordings.count) 份"
        } ?? "Mac 资料库 · \(recordings.count) 份"
      ) {
        HStack(spacing: 12) {
          if let day = model.originalsDay {
            Button("全天事项") { model.selectDay(day) }
            Button("显示全部") { model.showOriginals() }
          }
          Button("导入音频…") { model.chooseFiles() }.disabled(model.importLabel != nil)
        }.buttonStyle(.bordered).controlSize(.small).font(.callout)
      }
      Divider()
      GeometryReader { geometry in
        let selected = model.libraryRecordingID
        let wide = geometry.size.width >= 810
        if wide, let selected {
          WorkspaceSplitView(minimumLeading: 280) {
            recordingList(recordings).frame(minWidth: 280, idealWidth: 380, maxWidth: .infinity)
          } trailing: {
            recordingDetail(selected, compact: false).frame(
              minWidth: 320, idealWidth: 450, maxWidth: .infinity)
          }
        } else if let selected {
          recordingDetail(selected, compact: true)
        } else {
          recordingList(recordings)
        }
      }
    }
  }

  private func recordingList(_ recordings: [Recording]) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 10) {
        if model.originalsDay == nil { PendingOriginalsView(model: model) }
        Text("已保存到 Mac · \(recordings.count) 份").font(.headline).padding(.bottom, 4)
        if recordings.isEmpty {
          Text(model.originalsDay == nil ? "Mac 上还没有录音" : "这一天没有本地原件")
            .foregroundStyle(Palette.muted)
        }
        ForEach(recordings) { recording in
          if model.originalsDay == nil {
            Text(recording.day).font(.caption).foregroundStyle(Palette.muted)
          }
          OriginalRecordingRow(model: model, recording: recording) {
            model.libraryRecordingID = recording.id
          }
        }
      }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func recordingDetail(_ id: String, compact: Bool) -> some View {
    RecordDetailView(
      model: model, compact: compact, originalID: id,
      onClose: { model.libraryRecordingID = nil }
    ).id(id)
  }

}

struct BluetoothSettingsButton: View {
  var beforeOpening: () -> Void = {}

  var body: some View {
    Button("打开系统设置…") {
      if let url = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.apple.systempreferences")
      {
        beforeOpening()
        NSWorkspace.shared.open(url)
      }
    }
  }
}
