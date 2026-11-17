import SwiftUI

struct DesktopCaptionSettings: View {
  @ObservedObject var model: AppModel
  @ObservedObject var desktop: DesktopCompanion
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeading(title: "菜单栏与桌面语音气泡")
      VStack(spacing: 0) {
        HStack {
          VStack(alignment: .leading, spacing: 5) {
            Text("启用本机字幕与桌面气泡")
            Text("开口时先显示声波，短语稳定后淡入文字。未识别出发言人时显示「未知发言人」。")
              .font(.system(size: 10)).foregroundStyle(Palette.muted)
          }
          Spacer()
          Toggle("启用本机字幕与桌面气泡", isOn: $model.preferences.captions.enabled).labelsHidden()
        }.padding(16)
        Divider()
        HStack {
          VStack(alignment: .leading, spacing: 5) {
            Text("我的用户名")
            Text("显示在我的发言和气泡预览中，留空使用 Mac 账户名称")
              .font(.system(size: 10)).foregroundStyle(Palette.muted)
          }
          Spacer(minLength: 16)
          TextField(
            CaptionPreferences().resolvedUsername(),
            text: Binding(
              get: { model.preferences.captions.username ?? "" },
              set: { model.preferences.captions.username = $0.isEmpty ? nil : $0 }
            )
          )
          .textFieldStyle(.roundedBorder).frame(width: 200)
          .accessibilityLabel("我的用户名")
          .accessibilityIdentifier("desktop-caption-username")
        }.padding(16)
        Divider()
        HStack {
          Text("气泡所在显示屏")
          Spacer()
          Picker(
            "气泡所在显示屏",
            selection: Binding(
              get: { model.preferences.captions.displayID ?? "" },
              set: { model.preferences.captions.displayID = $0.isEmpty ? nil : $0 }
            )
          ) {
            Text("主显示屏").tag("")
            ForEach(desktop.displays) { display in Text(display.name).tag(display.id) }
            if let id = model.preferences.captions.displayID,
              !desktop.displays.contains(where: { $0.id == id })
            {
              Text("所选屏幕未连接 · 暂用主屏幕").tag(id)
            }
          }.labelsHidden().frame(maxWidth: 240)
        }.padding(16)
        Divider()
        HStack {
          Text("全屏时也显示气泡")
          Spacer()
          Toggle("全屏时也显示气泡", isOn: $model.preferences.captions.showInFullScreen).labelsHidden()
        }.padding(16)
        Divider()
        HStack {
          Text(desktop.isSnoozed ? "桌面语音气泡已暂时隐藏" : "点击气泡可收起；移入后点「是我 / 不是我」可校正身份。右键点标注按钮可选择另一项或撤销。")
            .font(.system(size: 11)).foregroundStyle(Palette.muted)
          Spacer()
          if desktop.isSnoozed {
            Button("恢复气泡") { desktop.resume() }
          } else {
            Button("隐藏 15 分钟") { desktop.snooze() }.disabled(!model.preferences.captions.enabled)
          }
          Button("预览气泡") { desktop.preview() }.accessibilityIdentifier("preview-desktop-caption")
        }.padding(16)
        if model.localCaptions.canRetry {
          Divider()
          HStack {
            Text(model.localCaptions.status).font(.system(size: 11)).foregroundStyle(Palette.amber)
            Spacer()
            Button("重试本地识别") { model.localCaptions.retry() }
          }.padding(16)
        } else if model.localCaptions.phase == .connecting {
          Divider()
          Text("正在准备本地中文识别，首次使用可能需要下载苹果语言模型。")
            .font(.system(size: 11)).foregroundStyle(Palette.muted).padding(16)
        } else {
          Divider()
          Text("可在主窗口的实时字幕中回看最近 24 小时的发言，并用「是我」标记自己的声音。")
            .font(.system(size: 11)).foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
      }
      .font(.system(size: 12)).background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
      .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
    }
  }
}
