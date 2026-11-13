import AVFoundation
import SwiftUI
import WorkdayCore

struct ConversationAudioPreview: View {
  @ObservedObject var model: AppModel
  let first: Conversation
  let last: Conversation
  @State private var peaks: [Float] = []
  @State private var scrub: Double?
  @State private var dragging = false
  @State private var expanded = false

  var body: some View {
    let range = first.start...last.end
    let id = model.excerptID(first, through: last)
    let same = model.player.selectionID == id
    let sourcePosition = model.player.sourcePosition
    let onSentence =
      model.player.recordingID == first.recordingID
      && model.player.selectionID?.hasPrefix("excerpt:") == true && range.contains(sourcePosition)
    let position = scrub ?? (same || onSentence ? sourcePosition : range.lowerBound)
    let playing = same && model.player.playing
    let showsWaveform = range.upperBound - range.lowerBound > 30 || expanded
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 10) {
        Button {
          model.playExcerpt(first, through: last)
        } label: {
          Image(systemName: playing ? "pause.fill" : "play.fill")
            .frame(width: 30, height: 30).background(Palette.accent, in: Circle()).foregroundStyle(
              Palette.surface)
        }.buttonStyle(.plain).accessibilityLabel(playing ? "暂停这段对话" : "回听这段对话")
        if showsWaveform {
          waveform(position: position, range: range)
        } else {
          Text("回听这段对话").font(.callout).frame(maxWidth: .infinity, alignment: .leading)
        }
        Menu {
          ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
            Button {
              model.player.setExcerptRate(Float(speed))
            } label: {
              if Float(speed) == model.player.excerptRate {
                Label(speed.formatted() + "×", systemImage: "checkmark")
              } else {
                Text(speed.formatted() + "×")
              }
            }
          }
        } label: {
          Text(model.player.excerptRate.formatted() + "×").monospacedDigit()
        }
        .fixedSize().menuStyle(.borderlessButton).accessibilityLabel("回听速度")
        if range.upperBound - range.lowerBound <= 30 {
          Button {
            expanded.toggle()
          } label: {
            Image(systemName: expanded ? "waveform.slash" : "waveform")
          }.buttonStyle(.plain).foregroundStyle(Palette.muted)
            .accessibilityLabel(expanded ? "收起波形" : "展开波形")
        }
      }
      HStack {
        Text("本段对话").font(.caption)
        Spacer()
        Text(
          elapsed(position - range.lowerBound) + " / "
            + elapsed(range.upperBound - range.lowerBound)
        )
        .font(.caption.monospacedDigit())
      }.foregroundStyle(.secondary)
    }.padding(12).background(Palette.background, in: RoundedRectangle(cornerRadius: 8))
      .task(id: (id ?? "") + String(showsWaveform)) {
        guard showsWaveform else {
          peaks = []
          return
        }
        peaks = []
        guard let source = model.recording(for: first) else { return }
        let url = model.libraryURL.appendingPathComponent(source.folder).appendingPathComponent(
          source.originalFile)
        let task = Task.detached(priority: .utility) { try Self.waveform(url, range: range) }
        let values = await withTaskCancellationHandler {
          try? await task.value
        } onCancel: {
          task.cancel()
        }
        if !Task.isCancelled { peaks = values ?? [] }
      }
  }

  private func waveform(position: Double, range: ClosedRange<Double>) -> some View {
    ZStack {
      Canvas { context, size in
        let fraction = (position - range.lowerBound) / (range.upperBound - range.lowerBound)
        let step = size.width / CGFloat(max(1, peaks.count))
        if peaks.isEmpty {
          context.fill(
            Path(CGRect(x: 0, y: size.height / 2, width: size.width, height: 2)),
            with: .color(Palette.line))
        }
        for (i, level) in peaks.enumerated() {
          let h = max(2, CGFloat(level) * size.height)
          let x = CGFloat(i) * step
          let rect = CGRect(
            x: x, y: (size.height - h) / 2, width: max(1, step * 0.65), height: h)
          context.fill(
            Path(roundedRect: rect, cornerRadius: 1),
            with: .color(
              x <= fraction * size.width ? Palette.accent : Palette.muted.opacity(0.6)))
        }
        let cursor = min(size.width - 1, max(0, size.width * fraction))
        context.fill(
          Path(CGRect(x: cursor, y: 0, width: 1.5, height: size.height)),
          with: .color(Palette.accent))
      }.accessibilityHidden(true)
      Slider(
        value: Binding(
          get: { position },
          set: { value in
            if dragging { scrub = value } else { seek(value) }
          }), in: range,
        onEditingChanged: { editing in
          dragging = editing
          if !editing, let scrub {
            seek(scrub)
            self.scrub = nil
          }
        }
      ).opacity(0.02).accessibilityLabel("片段回听位置")
    }.frame(height: 27)
  }

  private func elapsed(_ value: Double) -> String {
    let seconds = max(0, Int(value))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  private func seek(_ value: Double) {
    model.seekExcerpt(first, through: last, to: value)
  }

  /// Stream short clips completely; sample long recordings in bounded windows.
  nonisolated static func waveform(_ url: URL, range: ClosedRange<Double>) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let rate = file.processingFormat.sampleRate
    let start = AVAudioFramePosition((range.lowerBound * rate).rounded(.down))
    let end = min(file.length, AVAudioFramePosition((range.upperBound * rate).rounded(.up)))
    guard end > start, start >= 0,
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048)
    else { return [] }
    let count = min(Int(end - start), 100)
    var peaks = [Float]()
    for i in 0..<count {
      try Task.checkCancellation()
      let lo = start + (end - start) * Int64(i) / Int64(count)
      let hi = start + (end - start) * Int64(i + 1) / Int64(count)
      let frames = min(hi - lo, 2048)
      let target = lo + (hi - lo - frames) / 2
      if file.framePosition != target { file.framePosition = target }
      try file.read(into: buffer, frameCount: AVAudioFrameCount(frames))
      var peak: Float = 0
      if let channels = buffer.floatChannelData {
        for channel in 0..<Int(buffer.format.channelCount) {
          let samples = UnsafeBufferPointer(
            start: channels[channel], count: Int(buffer.frameLength))
          for sample in samples { peak = max(peak, abs(sample)) }
        }
      }
      peaks.append(peak)
    }
    let maximum = max(peaks.max() ?? 0, 0.01)
    return peaks.map { sqrt($0 / maximum) }
  }
}
