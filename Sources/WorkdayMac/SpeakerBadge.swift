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
        Menu {
          if label.canConfirm { Button("是我") { voices.confirm(id) } }
          if label.canAddSample { Button("加入本人样本") { voices.confirm(id) } }
          if label.canConfirm || label.canAddSample { Button("不是我") { voices.setExcluded(true, for: id) } }
          if label.isMine && !label.canAddSample {
            Button(label.sampleID == nil ? "撤销标注" : "移除这条样本") { voices.undoConfirmation(for: id) }
          } else if !label.isMine, let group = label.group {
            Button(label.savedName == nil ? "填写名字…" : "编辑名字…") {
              name = label.savedName ?? ""
              editing = true
            }
            if label.savedName != nil { Button("移除名字") { voices.name(group, "") } }
          }
          if label.excluded { Button("撤销「不是我」") { voices.setExcluded(false, for: id) } }
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("发言人操作")
        .popover(isPresented: $editing) {
          VStack(alignment: .leading) {
            Text("发言人名字")
            TextField("名字", text: $name).onSubmit { save(label.group) }
            Button("保存") { save(label.group) }.disabled(!validName)
          }.frame(width: 170).padding()
        }
      }.font(.system(size: 11))
    } else if let fallback {
      Text(fallback).font(.system(size: 11)).foregroundStyle(Palette.muted)
    }
  }
  private var validName: Bool {
    VoiceLabel.acceptsName(name)
  }
  private func save(_ group: Int64?) {
    guard let group, validName else { return }
    voices.name(group, name)
    editing = false
  }
}
