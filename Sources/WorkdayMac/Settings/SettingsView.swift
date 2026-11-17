import SwiftUI
import WorkdayCore

struct SettingsView: View {
  @ObservedObject var model: AppModel
  @State private var apiKey = ""
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
    let name = model.card.state.connected ? model.card.name : (status.isUSB ? model.usb.volumes.first?.name : nil)
    return group("录音卡") {
      row {
        VStack(alignment: .leading, spacing: 5) {
          Text(name ?? "录音卡未连接").font(.system(size: 13, weight: .medium))
          Text(model.usesWiFiCard && model.wifiSync.usingNetwork ? model.wifiSync.message : status.isUSB ? status.title : status.bluetoothBlock?.instruction ?? model.card.status)
            .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        Spacer()
        if !model.usesWiFiCard, !status.isUSB, model.card.state.connected {
          Button("同步时间") { model.card.synchronizeClock() }
            .disabled(model.isolated || model.card.state.phase != .idle || !model.card.state.isFresh())
        }
        if status.bluetoothBlock?.usesSettings == true {
          BluetoothSettingsButton()
        } else if model.card.state.connected {
          Button("刷新状态") { model.card.activate() }
            .disabled(model.wifiSync.busy || model.isolated)
          Button("断开连接") { model.card.disconnect() }
            .disabled(!model.canChangeCard || model.isolated)
        } else if status.bluetoothBlock == nil {
          Button(model.card.scanning ? "寻找中…" : "寻找设备") { model.card.activate(.all) }
            .disabled(model.card.scanning || status.kind == .connecting || !model.canChangeCard || model.isolated)
        }
      }
      if !model.card.state.connected, !model.card.choices.isEmpty,
        status.canConnect || model.card.scanning || status.isUSB {
        ForEach(model.card.choices) { choice in
          Divider()
          row {
            Text(choice.name)
            if let kind = choice.kind { Text(kind.label).font(.caption).foregroundStyle(Palette.muted) }
            Spacer()
            Text("\(choice.rssi) dBm").font(.caption).foregroundStyle(Palette.muted)
            Button("连接") { model.chooseRecorder(choice) }.disabled(model.isolated || !model.canChangeCard)
          }
        }
      }
      ForEach(model.usb.detectedVolumes, id: \.url) { volume in
        if !model.usb.volumes.contains(volume), model.canAssociateUSB(volume) || !model.card.state.connected {
          Divider()
          row {
            VStack(alignment: .leading) {
              Text(volume.name)
              Text("USB · \(volume.url.path)").font(.caption).foregroundStyle(Palette.muted)
            }
            Spacer()
            if model.canAssociateUSB(volume) {
              Button("关联到「\(model.preferences.boundName)」") {
                model.selectUSB(volume, associateWithBoundCard: true)
              }
            }
            if !model.card.state.connected {
              Button("使用此 USB 设备") { model.selectUSB(volume, associateWithBoundCard: false) }
            }
          }.disabled(!model.canChangeCard || model.usb.detectedVolumes.filter { $0.id == volume.id }.count != 1)
        }
      }
      if let error = model.card.selectionError { Text(error).font(.callout).foregroundStyle(Palette.amber) }
      if model.usesWiFiCard { WiFiSyncControls(model: model) }
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
               : "点「是我」可标注这句发言。只有本句音频足够长且声纹可用时，才会保存为样本。")
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
          Text("使用 ESP 处理")
          Text("开启后，音频与文字会发送到 ESP 服务，按服务用量计费。结果保存到此 Mac。").font(.system(size: 11))
            .foregroundStyle(Palette.muted).lineSpacing(4).fixedSize(
              horizontal: false, vertical: true)
        }
        Spacer(minLength: 22)
        Toggle("使用 ESP 处理", isOn: $model.preferences.cloudEnabled).labelsHidden().disabled(
          model.demo
        ).onChange(of: model.preferences.cloudEnabled) { _, _ in model.configureChanged() }
      }
      Divider()
      row {
        VStack(alignment: .leading, spacing: 5) {
          Text("云端实时识别")
          Text(model.preferences.liveModel == .segment
               ? "桌面气泡按短语显示本机文字。云端复核结果保存在字幕历史的原行。"
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
          Text(model.preferences.liveModel == .segment
               ? "每句定稿后，将对应的音频片段发送到 ESP 复核。"
               : "下次连接云端字幕时生效。")
            .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        Spacer()
        Picker("实时字幕模型", selection: $model.preferences.liveModel) {
          ForEach(LiveASRModel.allCases, id: \.self) { Text($0 == .segment ? "3.1 Flash（逐句复核）" : $0.rawValue).tag($0) }
        }.labelsHidden().pickerStyle(.menu).frame(width: 245)
          .accessibilityIdentifier("live-asr-model")
      }
      Divider()
      row {
        VStack(alignment: .leading, spacing: 5) {
          Text("完整录音转写模型")
          Text("新录音转写时按发言人分段。")
            .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
        Spacer()
        Text(AIService.recordingModel).font(.caption)
      }
      Divider()
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text(model.hasKey ? "API Key 已保存到钥匙串" : "尚未配置 API Key").font(.system(size: 11))
            .foregroundStyle(Palette.muted)
          Spacer()
        }
        HStack {
          SecureField("输入 ESP API Key", text: $apiKey).textFieldStyle(.roundedBorder)
          Button("保存密钥") {
            model.saveKey(apiKey)
            if model.hasKey { apiKey = "" }
          }.disabled(
            apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isolated)
        }
        Text("录音整理使用 \(AIService.organizationModel)").font(.system(size: 11)).foregroundStyle(Palette.muted)
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
