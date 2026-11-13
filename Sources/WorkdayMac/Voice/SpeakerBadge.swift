import SwiftUI

struct SpeakerBadge: View {
  @ObservedObject var voices: VoiceRecognition
  let id: String?
  var fallback: String? = nil
  @State private var editing = false
  @State private var name = ""
  var body: some View {
    if let id, let label = voices.label(id) {
      HStack(spacing: 8) {
        Text(label.title).foregroundStyle(label.isMine ? Palette.accent : Palette.muted)
          .help(label.inferredName ? "根据已命名录音的声纹匹配，可在发言人操作中更正。" : label.title)
        Menu {
          if label.canConfirm { Button("是我") { voices.confirm(id) } }
          if label.canAddSample { Button("加入本人样本") { voices.confirm(id) } }
          if label.canConfirm || label.canAddSample { Button("不是我") { voices.setExcluded(true, for: id) } }
          if label.isMine && !label.canAddSample {
            Button(label.sampleID == nil ? "撤销标注" : "移除这条样本") { voices.undoConfirmation(for: id) }
          } else if !label.isMine, label.archiveSpeaker || (label.group != nil && !id.hasPrefix("file:")) {
            if label.inferredName {
              Button("确认是" + label.title) { setName(label.title, for: id, label: label) }
            }
            Button(label.inferredName ? "更正名字…" : label.savedName == nil ? "填写名字…" : "编辑名字…") {
              name = label.savedName ?? (label.inferredName ? label.title : "")
              editing = true
            }
            if label.savedName != nil || label.inferredName {
              Button(label.inferredName ? "忽略此次识别" : "移除名字") { setName("", for: id, label: label) }
            }
          }
          if label.excluded { Button("撤销「不是我」") { voices.setExcluded(false, for: id) } }
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("发言人操作")
        .popover(isPresented: $editing) {
          VStack(alignment: .leading) {
            Text("发言人名字")
            TextField("名字", text: $name).onSubmit { save(id, label: label) }
            if label.archiveSpeaker {
              Text(label.hasArchiveVoice
                   ? "名字用于本组发言，也可通过声纹在其他录音中识别此人。"
                   : "本组缺少清晰的声纹样本，名字仅用于本组发言。")
                .font(.caption).foregroundStyle(.secondary)
            }
            Button("保存") { save(id, label: label) }.disabled(!validName)
          }.frame(width: label.archiveSpeaker ? 220 : 170).padding()
        }
      }.font(.system(size: 11))
    } else if let fallback {
      Text(fallback).font(.system(size: 11)).foregroundStyle(Palette.muted)
    }
  }
  private var validName: Bool {
    VoiceLabel.acceptsName(name)
  }
  private func setName(_ value: String, for id: String, label: VoiceLabel) {
    if label.archiveSpeaker { voices.nameArchiveSpeaker(id, value) }
    else if let group = label.group { voices.name(group, value) }
  }
  private func save(_ id: String, label: VoiceLabel) {
    guard validName else { return }
    setName(name, for: id, label: label)
    editing = false
  }
}
