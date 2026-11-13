import SwiftUI

struct PendingOriginalsView: View {
  @ObservedObject var model: AppModel
  @State private var expanded = true
  var body: some View {
    if !model.currentInventories.isEmpty || !model.usb.volumes.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        SyncStatusView(model: model, showsOriginalsAction: false)
        let pending = model.pendingOriginals
        if !pending.isEmpty {
          DisclosureGroup("待同步原件 · \(pending.count) 段", isExpanded: $expanded) {
            LazyVStack(alignment: .leading, spacing: 10) {
              if !model.inventoryIsFresh {
                Text("以下为上次发现的录音，连接录音卡后更新。").foregroundStyle(Palette.muted)
              } else if !model.currentInventories.allSatisfy(\.complete) {
                Text("清单尚未完整返回，以下为已发现的录音。").foregroundStyle(Palette.muted)
              }
              ForEach(pending) { item in
                HStack(alignment: .firstTextBaseline) {
                  Text(item.entry.name).lineLimit(1).truncationMode(.middle).help(item.entry.name)
                  Spacer(minLength: 4)
                  Text(item.entry.isOpusOnly ? "缺少配对 WAV" : "尚未保存到 Mac")
                    .foregroundStyle(item.entry.isOpusOnly ? Palette.amber : Palette.muted)
                }.accessibilityElement(children: .combine)
              }
            }.font(.caption).padding(.top, 8)
          }.font(.callout)
        }
      }.padding(.bottom, 12)
    } else {
      Text("录音卡上的原件可通过 USB 同步到 Mac。").font(.callout).foregroundStyle(Palette.muted)
        .padding(.bottom, 8)
    }
  }
}
