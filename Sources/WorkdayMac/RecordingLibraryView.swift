import SwiftUI
import WorkdayCore

struct OriginalRecordingRow: View {
  @ObservedObject var model: AppModel
  let recording: Recording
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        Button {
          model.libraryRecordingID = recording.id
        } label: {
          VStack(alignment: .leading, spacing: 7) {
            Text(recording.originalName).font(.system(size: 13, weight: .medium)).lineLimit(1)
              .help(recording.originalName)
            Text(
              "\(humanDuration(recording.duration)) · \(model.documents[recording.id]?.label ?? "已保存")"
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
      if let error = model.documents[recording.id]?.error {
        ErrorDetailsButton(message: error, context: "录音：\(recording.originalName)")
        RecordingRetryButton(model: model, recording: recording).buttonStyle(.link)
      }
    }.padding(13).background(
      model.libraryRecordingID == recording.id ? Palette.selected : Palette.surface,
      in: RoundedRectangle(cornerRadius: 8)
    )
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
  }
}

struct RecordingRetryButton: View {
  @ObservedObject var model: AppModel
  let recording: Recording

  var body: some View {
    let queued = model.queuedRecordingRetries.contains(recording.id)
    let active = model.processingID == recording.id
    Button(queued ? "已排队，等待重试" : active ? "正在整理" : "重试这段录音") {
      model.retryProcessing(scope: .recording(recording.id))
    }
    .disabled(queued || active || model.documents[recording.id]?.phase == "complete")
    .help(queued ? "当前任务结束后自动重试这段录音" : "从已保存的进度继续整理这段录音")
  }
}

struct RecordingLibraryView: View {
  @ObservedObject var model: AppModel
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 18) {
        Text("设备与资料库").font(.title2.bold())
        Picker("资料库分类", selection: $model.libraryTab) {
          ForEach(LibraryTab.allCases, id: \.self) { tab in Text(tab.rawValue).tag(tab) }
        }.pickerStyle(.segmented).frame(width: 175)
        Spacer()
        if model.libraryTab == .originals {
          Button("导入音频…") { model.chooseFiles() }.disabled(model.importLabel != nil)
        }
      }.padding(.horizontal, 20).padding(.vertical, 16)
      Divider()
      if model.libraryTab == .device {
        DeviceStatusBar(model: model)
        HStack {
          Text(model.preferences.boundName).font(.headline)
          Spacer()
          Button("设备设置") { model.requestSettings(.device) }
        }.padding(20)
        Spacer()
      } else {
        GeometryReader { geometry in
          let selected = model.libraryRecordingID
          let wide = geometry.size.width >= 810
          HStack(spacing: 0) {
            if wide || selected == nil {
              ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                  HStack {
                    Text("原始录音").font(.title2.bold())
                    Spacer()
                    Text("\(model.recordings.count) 份").font(.caption).foregroundStyle(
                      Palette.muted)
                  }.padding(.bottom, 5)
                  if model.recordings.isEmpty { Text("尚无本地录音").foregroundStyle(Palette.muted) }
                  ForEach(model.recordings) { recording in
                    Text(recording.day).font(.caption).foregroundStyle(Palette.muted)
                    OriginalRecordingRow(model: model, recording: recording)
                  }
                }.padding(20)
              }.frame(maxWidth: .infinity)
            }
            if let selected {
              if wide { Divider() }
              RecordDetailView(
                model: model, compact: !wide, originalID: selected,
                onClose: { model.libraryRecordingID = nil }
              )
              .id(selected).frame(maxWidth: .infinity)
            }
          }
        }
      }
    }
  }
}
