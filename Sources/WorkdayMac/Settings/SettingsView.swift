import SwiftUI
import WorkdayCore

struct SettingsView: View {
  @ObservedObject var model: AppModel
  @State private var apiKey = ""
  @State private var cloudDetails = false
  @State private var showingClearSamples = false
  var body: some View {
    VStack(spacing: 0) {
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
    }.frame(minWidth: 680, idealWidth: 740, minHeight: 560, idealHeight: 670)
      .background(Palette.background).foregroundStyle(Palette.text).tint(Palette.accent)
      .toggleStyle(.switch).controlSize(.small)
      .preferredColorScheme(
        model.preferences.theme == "system"
          ? nil : model.preferences.theme == "dark" ? .dark : .light)
  }
  private var device: some View {
    let status = model.deviceStatus(at: Date())
    return group("录音卡") {
      row {
        VStack(alignment: .leading, spacing: 5) {
          Text(model.preferences.boundName).font(.system(size: 13, weight: .medium))
          Text(status.isUSB ? status.title : status.bluetoothBlock?.instruction ?? model.card.status)
            .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        Spacer()
        if !status.isUSB, model.card.state.connected {
          Button("同步时间") { model.card.synchronizeClock() }
            .disabled(model.isolated || model.card.state.phase != .idle || !model.card.state.isFresh())
        }
        if status.bluetoothBlock?.usesSettings == true {
          BluetoothSettingsButton()
        } else if status.bluetoothBlock == nil, !status.isUSB {
          Button(model.card.state.connected ? "刷新状态" : (model.card.scanning ? "寻找中…" : "寻找设备")) { model.card.activate() }
            .disabled(status.kind == .connecting || model.isolated)
        }
      }
      if status.canConnect {
        row {
          Button("扫描全部设备") { model.card.activate(.all) }
            .disabled(model.isolated || model.card.connectionPhase == .usb)
        }
      }
      if !model.card.choices.isEmpty, status.canConnect || model.card.scanning && status.kind == .connecting {
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
          if model.voices.inconsistentSampleCount > 0 {
            Text("有 \(model.voices.inconsistentSampleCount) 条样本与其他本人样本差异较大，建议在正常佩戴录音卡时补充清晰发言。原样本已保留。")
              .font(.system(size: 11)).foregroundStyle(Palette.muted)
          }
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
        VStack(alignment: .leading, spacing: 5) {
          Text("本人识别样本库")
          Text("本人 \(model.voices.sampleCount) 条 · 非本人 \(model.voices.negativeSampleCount) 条")
            .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        Spacer()
        Button("清空样本库…", role: .destructive) { showingClearSamples = true }
          .disabled(!model.voices.canClearSamples)
          .accessibilityIdentifier("clear-voice-samples")
          .confirmationDialog("清空本人识别样本库？", isPresented: $showingClearSamples,
                              titleVisibility: .visible) {
            Button("清空样本库", role: .destructive) { model.voices.clearSamples() }
            Button("取消", role: .cancel) {}
          } message: {
            Text("将清除全部本人和非本人声纹样本。录音、字幕、历史身份标注及其他发言人姓名会保留。此操作不可撤销，清空后可重新标记本人发言。")
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
      row {
        VStack(alignment: .leading, spacing: 5) {
          Text("云端实时识别")
          Text(model.preferences.liveModel == .fileTrans
               ? "先显示本机初稿。云端转写完成后，同一行字幕和仍在显示的气泡会更新为云端文字。"
               : "与本机同时识别。字幕就绪后最多等云端 150 毫秒，已显示的气泡文字只追加。")
            .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        Spacer()
        Toggle("云端实时识别", isOn: $model.preferences.realtime).labelsHidden()
      }
      Divider()
      row {
        VStack(alignment: .leading, spacing: 5) {
          Text("实时字幕模型")
          Text(model.preferences.liveModel == .fileTrans
               ? "新语音段使用百炼临时文件转写，上传的音频保留 48 小时。"
               : "下次连接云端字幕时生效。")
            .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        Spacer()
        Picker("实时字幕模型", selection: $model.preferences.liveModel) {
          ForEach(LiveASRModel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.labelsHidden().pickerStyle(.menu).frame(width: 245)
          .accessibilityIdentifier("live-asr-model")
      }
      Divider()
      row {
        VStack(alignment: .leading, spacing: 5) {
          Text("完整录音转写模型")
          Text(model.preferences.recordingModel == .flash31
               ? "新录音转写时按发言人分段。" : "新录音转写为文字和时间戳。")
            .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        Spacer()
        Picker("完整录音转写模型", selection: $model.preferences.recordingModel) {
          ForEach(RecordingASRModel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.labelsHidden().pickerStyle(.menu).frame(width: 245)
          .accessibilityIdentifier("recording-asr-model")
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
        Text("录音整理使用 Qwen Plus").font(.system(size: 11)).foregroundStyle(Palette.muted)
      }.padding(16)
      if model.live.canRetry {
        Divider()
        row {
          Text(model.live.status).font(.caption).foregroundStyle(Palette.amber)
          Spacer()
          Button("重试云端识别") { model.live.retry() }
        }
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
