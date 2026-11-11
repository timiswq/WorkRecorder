import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: AppModel
  var embedded = false
  @State private var apiKey = ""
  @State private var cloudDetails = false
  var body: some View {
    VStack(spacing: 0) {
      if embedded {
        Text("设置").font(.title.bold()).padding(.horizontal, 24).padding(.top, 18)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      Picker("设置分类", selection: $model.settingsSection) {
        ForEach(SettingsSection.allCases) { section in
          Label(section.rawValue, systemImage: section.icon).tag(section)
        }
      }.pickerStyle(.segmented).padding(20)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          switch model.settingsSection {
          case .device: device
          case .recognition: recognition
          case .captions: DesktopCaptionSettings(model: model, desktop: model.desktop)
          case .archive: archive
          case .appearance: appearance
          }
          if let error = model.error {
            ErrorDetailsButton(message: error)
          }
          if let notice = model.notice {
            Text(notice).foregroundStyle(Palette.accent).font(.system(size: 12))
          }
          Text("录音由设备独立保存。关闭窗口后继续运行；退出应用不停止设备录音。")
            .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
      }
    }.frame(minWidth: embedded ? 0 : 680, idealWidth: 740, minHeight: embedded ? 0 : 560, idealHeight: 670)
      .background(Palette.background).foregroundStyle(Palette.text).tint(Palette.accent)
      .toggleStyle(.switch).controlSize(.small)
      .preferredColorScheme(
        model.preferences.theme == "system"
          ? nil : model.preferences.theme == "dark" ? .dark : .light)
  }
  private var device: some View {
    group("录音卡") {
      row {
        VStack(alignment: .leading, spacing: 5) {
          Text(model.preferences.boundName).font(.system(size: 13, weight: .medium))
          Text(model.card.status).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        Spacer()
        Button(model.card.scanning ? "寻找中…" : "寻找设备") { model.card.activate() }.disabled(
          model.card.scanning || model.isolated)
      }
      if !model.card.choices.isEmpty, !model.card.state.connected {
        ForEach(model.card.choices) { choice in
          Divider()
          row {
            Text(choice.name)
            Spacer()
            Text("\(choice.rssi) dBm").font(.caption).foregroundStyle(Palette.muted)
            Button("连接") { model.card.connect(choice.id) }.disabled(model.isolated)
          }
        }
      }
      Divider()
      row {
        Text("打开时自动连接")
        Spacer()
        Toggle("打开时自动连接", isOn: $model.preferences.autoConnect).labelsHidden().onChange(
          of: model.preferences.autoConnect
        ) { _, _ in model.configureChanged() }
      }
    }
  }
  private var recognition: some View {
    group("语音识别与整理") {
      row {
        VStack(alignment: .leading, spacing: 5) {
          Text("本人的声纹")
          Text(model.voices.confirmed
               ? "已保存 \(model.voices.sampleCount) 条本人声纹样本。在发言人的菜单中点「是我」可继续补充。"
               : "在发言人菜单或桌面气泡上点「是我」，用这句话的声纹识别后续发言。")
            .font(.system(size: 11)).foregroundStyle(Palette.muted)
          if let error = model.voices.error {
            Text(error).font(.caption).foregroundStyle(Palette.amber)
          }
        }
        Spacer()
        if model.voices.confirmed { Button("清除本人样本") { model.voices.undo() } }
      }
      if model.voices.negativeSampleCount > 0 {
        Divider()
        row {
          Text("非本人声纹样本 · \(model.voices.negativeSampleCount) 条")
          Spacer()
          Button("清除非本人样本") { model.voices.clearNegativeSamples() }
        }
      }
      Divider()
      row {
        Label(
          model.preferences.cloudEnabled && model.hasKey ? "云端服务已配置" : "云端服务尚未就绪",
          systemImage: model.preferences.cloudEnabled && model.hasKey
            ? "checkmark.circle" : "exclamationmark.circle"
        )
        .foregroundStyle(
          model.preferences.cloudEnabled && model.hasKey ? Palette.accent : Palette.amber)
        Spacer()
      }
      Divider()
      row {
        VStack(alignment: .leading, spacing: 5) {
          Text("使用阿里云百炼处理")
          Text("开启后，音频与文字会发送到北京地域的百炼服务，按服务用量计费。结果保存到此 Mac。 ").font(.system(size: 11))
            .foregroundStyle(Palette.muted).lineSpacing(4).fixedSize(
              horizontal: false, vertical: true)
        }
        Spacer(minLength: 22)
        Toggle("使用阿里云百炼处理", isOn: $model.preferences.cloudEnabled).labelsHidden().disabled(
          model.demo
        ).onChange(of: model.preferences.cloudEnabled) { _, _ in model.configureChanged() }
      }
      Divider()
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text(model.hasKey ? "API Key 已保存到钥匙串" : "尚未配置 API Key").font(.system(size: 11))
            .foregroundStyle(Palette.muted)
          Spacer()
        }
        HStack {
          SecureField("输入百炼 API Key", text: $apiKey).textFieldStyle(.roundedBorder)
          Button("保存密钥") {
            model.saveKey(apiKey)
            if model.hasKey { apiKey = "" }
          }.disabled(
            apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isolated)
        }
        DisclosureGroup("业务空间（可选）", isExpanded: $cloudDetails) {
          TextField("Workspace ID，留空使用默认北京地址", text: $model.preferences.workspaceID)
            .textFieldStyle(.roundedBorder).padding(.top, 8)
        }.font(.system(size: 11)).foregroundStyle(Palette.muted)
        Text("实时：Qwen Audio ASR Message · 文件：Qwen Audio ASR · 整理：Qwen Plus").font(
          .system(size: 11)
        ).foregroundStyle(
          Palette.muted)
      }.padding(16)
      Divider()
      row {
        VStack(alignment: .leading, spacing: 5) {
          Text("录音时自动显示实时文字")
          Text("打开 App 后保持连接；待机时等待，收到音频后逐句更新").font(.system(size: 11)).foregroundStyle(
            Palette.muted)
        }
        Spacer()
        Toggle("实时文字", isOn: $model.preferences.realtime).labelsHidden()
      }
    }
  }
  private var archive: some View {
    group("本地归档") {
      if let boundSource = model.boundSource, model.usb.volumes.count == 1,
        model.catalog.bindings[boundSource] != model.usb.volumes.first?.id
      {
        row {
          VStack(alignment: .leading, spacing: 5) {
            Text("确认录音卡来源")
            Text("若此 USB 录音卡就是已绑定设备，关联后可核对蓝牙下的待同步数量。")
              .font(.system(size: 11)).foregroundStyle(Palette.muted)
          }
          Spacer()
          Button("这是已绑定的录音卡") { model.bindCurrentUSB() }
        }
        Divider()
      }
      row {
        VStack(alignment: .leading, spacing: 5) {
          Text("保存位置")
          Text(model.libraryURL.path).font(.system(size: 11)).foregroundStyle(Palette.muted)
            .lineLimit(2).textSelection(.enabled)
        }
        Spacer()
        Button("打开") { model.reveal() }
        Button("选择…") { model.chooseLibrary() }.disabled(model.isBusy || model.isolated)
      }
      Divider()
      row {
        Text("接入 USB 后自动同步")
        Spacer()
        Toggle("接入 USB 后自动同步", isOn: $model.preferences.autoSync).labelsHidden().onChange(
          of: model.preferences.autoSync
        ) { _, _ in model.configureChanged() }
      }
      Divider()
      row {
        Text("同步后自动整理")
        Spacer()
        Toggle("同步后自动整理", isOn: $model.preferences.autoOrganize).labelsHidden().onChange(
          of: model.preferences.autoOrganize
        ) { _, _ in model.configureChanged() }
      }
      Divider()
      row {
        Image(systemName: "internaldrive").foregroundStyle(Palette.muted)
        Text("USB 录音校验后自动清理卡内副本。完整原件和剪辑保存在 Mac 上。").font(.system(size: 11)).foregroundStyle(Palette.muted)
        Spacer()
      }
    }
  }
  private var appearance: some View {
    group("外观") {
      row {
        Text("显示主题")
        Spacer()
        Picker("显示主题", selection: $model.preferences.theme) {
          Text("跟随系统").tag("system")
          Text("浅色").tag("light")
          Text("深色").tag("dark")
        }.labelsHidden().frame(width: 145)
      }
    }
  }
  private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 12) {
      SectionHeading(title: title)
      VStack(spacing: 0, content: content).background(
        Palette.surface, in: RoundedRectangle(cornerRadius: 9)
      ).overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
    }
  }
  private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: 12, content: content).font(.system(size: 12)).padding(16).frame(
      maxWidth: .infinity, alignment: .leading)
  }
}
