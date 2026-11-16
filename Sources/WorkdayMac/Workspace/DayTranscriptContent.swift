import SwiftUI
import WorkdayCore

/// Shared reading surface; selection tools only appear for an explicit organization action.
struct DayTranscriptContent: View {
  @ObservedObject var model: AppModel
  let entry: ActivityEntry
  var selecting = false
  @Binding var chosen: Set<String>

  private struct Item: Identifiable {
    let clip: Conversation
    let recording: Recording
    let line: TranscriptLine
    var id: String { recording.id + ":" + line.id }
  }

  private var items: [Item] {
    var seen = Set<String>()
    return entry.clips.flatMap { clip -> [Item] in
      guard let recording = model.recording(for: clip) else { return [] }
      let ids = Set(entry.activity.quotes?[clip.id]
        ?? (entry.activity.quotes?.isEmpty == false ? [] : Array(clip.lineIDs.prefix(2))))
      let lines = entry.isRaw || entry.isManualItem || entry.addedSentenceIDs.contains(clip.id)
        ? (clip.excerpt ?? [])
        : (model.documents[recording.id]?.transcript ?? []).filter {
          ids.contains($0.id) && clip.lineIDs.contains($0.id)
        }
      return lines.compactMap { line in
        let item = Item(clip: clip, recording: recording, line: line)
        return seen.insert(item.id).inserted ? item : nil
      }
    }
  }

  var body: some View {
    let rows = items
    LazyVStack(alignment: .leading, spacing: 12) {
      ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
        HStack(alignment: .top, spacing: 4) {
          if selecting {
            Toggle("选择原话", isOn: Binding(
              get: { chosen.contains(item.clip.id) },
              set: { if $0 { chosen.insert(item.clip.id) } else { chosen.remove(item.clip.id) } }
            )).toggleStyle(.checkbox).labelsHidden().padding(.top, 12)
              .accessibilityLabel("选择：" + item.line.text)
          }
          TranscriptRow(line: item.line, voices: model.voices,
            voiceID: VoiceRecognition.key(item.recording, item.line),
            active: model.excerptPlaying(item.clip, line: item.line), playing: model.player.playing,
            clockLabel: DaySentenceTime.label(item.clip, line: item.line),
            showsSpeaker: index == 0 || speaker(rows[index - 1]) != speaker(item)
          ) { model.playExcerpt(item.clip, line: item.line) }
        }
      }
    }
  }

  private func speaker(_ item: Item) -> String {
    let key = VoiceRecognition.key(item.recording, item.line)
    let label = model.voices.label(key)?.title ?? item.line.speaker ?? item.line.id
    return item.recording.id + ":" + label
  }
}
