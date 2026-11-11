import SwiftUI
import WorkdayCore

struct CurrentView: View {
  @ObservedObject var model: AppModel
  var transcriptHeight: CGFloat
  @State private var reading = LiveReadingPosition()
  @State private var isUserScrolling = false
  @State private var bottom: CGFloat = 0

  private var feed: LivePreview { model.displayedLiveFeed }
  private var showingLocal: Bool { feed === model.localCaptions }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("实时文字", systemImage: "text.bubble").font(.system(size: 14, weight: .semibold))
        if feed.isWorking { ProgressView().controlSize(.mini) }
        Spacer()
        if !feed.lines.isEmpty {
          Button(model.showsLiveText ? "收起" : "展开") { model.showsLiveText.toggle() }
            .buttonStyle(.link).font(.system(size: 12))
        }
      }
      if model.showsLiveText {
        if !feed.lines.isEmpty {
          liveText.frame(height: transcriptHeight)
          HStack(alignment: .firstTextBaseline) {
            Text(showingLocal ? "本机实时字幕 · 保留最近 100 句" : "蓝牙实时文字 · 保留最近 100 句")
              .font(.system(size: 11)).foregroundStyle(Palette.muted)
            Spacer()
            if feed.hasGap {
              Label("连接期间可能有缺口", systemImage: "exclamationmark.circle")
                .font(.system(size: 11)).foregroundStyle(Palette.amber)
            }
          }
        }
        if feed.lines.isEmpty || needsAction || model.live.canRetry
          || !model.card.state.connected || !model.usb.volumes.isEmpty
        {
          HStack(alignment: .center, spacing: 16) {
            Text(message).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(
              horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if model.usb.volumes.isEmpty, needsAction {
              Button("配置语音识别") { model.requestSettings(.recognition) }.controlSize(.small)
            } else if model.usb.volumes.isEmpty, model.live.canRetry {
              Button("重试转写") { model.live.retry() }.controlSize(.small)
            }
          }
        }
      }
    }.padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
  }

  private var liveText: some View {
    ScrollViewReader { proxy in
      VStack(alignment: .trailing, spacing: 8) {
        GeometryReader { geometry in
          ScrollView {
            VStack(alignment: .leading, spacing: 14) {
              ForEach(feed.lines.filter { !$0.text.isEmpty }) { line in
                VStack(alignment: .leading, spacing: 3) {
                  if showingLocal {
                    let speaker = model.captionSpeaker(for: line.id)
                    Text(speaker.label.captionTitle(using: model.preferences.captions))
                      .font(.caption).foregroundStyle(speaker.label.isMine ? Palette.accent : Palette.muted)
                      .contextMenu {
                        Button(speaker.controls.rawValue) {
                          if speaker.controls == .confirm { model.confirmCaption(line.id) }
                          else { model.correctCaption(line.id, expectedTurn: speaker.id) }
                        }
                      }
                  } else {
                    SpeakerBadge(voices: model.voices, id: line.voiceID)
                  }
                  Text(line.text).font(.system(size: 14)).lineSpacing(6)
                    .foregroundStyle(line.isFinal ? Palette.text : Palette.muted)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.id(line.id)
              }
              Color.clear.frame(height: 1).id("live-end")
                .background(
                  GeometryReader { item in
                    Color.clear.preference(
                      key: LiveBottomPreference.self,
                      value: item.frame(in: .named("live-scroll")).maxY)
                  })
            }.padding(.trailing, 12)
              .background(
                ScrollGestureObserver(
                  onBegin: {
                    isUserScrolling = true
                  },
                  onEnd: {
                    isUserScrolling = false
                    reading.update(bottom: bottom, viewport: geometry.size.height)
                  }))
          }.coordinateSpace(name: "live-scroll")
            .accessibilityIdentifier("live-transcript-scroll")
            .onPreferenceChange(LiveBottomPreference.self) { value in
              bottom = value
              if isUserScrolling { reading.update(bottom: value, viewport: geometry.size.height) }
            }
            .onAppear { proxy.scrollTo("live-end", anchor: .bottom) }
            .onChange(of: feed.lines.last) { _, _ in
              guard reading.followsLatest, !isUserScrolling else { return }
              proxy.scrollTo("live-end", anchor: .bottom)
            }
        }
        if !reading.followsLatest {
          Button {
            reading.resume()
            proxy.scrollTo("live-end", anchor: .bottom)
          } label: {
            Label("回到最新", systemImage: "arrow.down")
          }
          .buttonStyle(.borderedProminent).controlSize(.small)
          .accessibilityIdentifier("live-return-latest")
        }
      }
    }
  }

  private var needsAction: Bool {
    !showingLocal && (!model.preferences.realtime || !model.preferences.cloudEnabled || !model.hasKey)
  }
  private var message: String {
    if !model.usb.volumes.isEmpty { return "USB 连接期间暂停蓝牙实时文字。" }
    if showingLocal { return model.live.canRetry ? model.live.status : feed.status }
    if !model.preferences.realtime { return "实时文字已关闭；设备仍独立保存录音。" }
    if !model.preferences.cloudEnabled || !model.hasKey { return "语音识别尚未就绪。配置云端服务后，收到录音卡音频即显示文字。" }
    if model.live.canRetry { return model.live.status }
    if !model.card.state.connected { return "等待连接录音卡，已接收的文字仍可回看。" }
    if model.card.state.isFresh(), model.card.state.phase == .idle {
      return "设备待机。在录音卡上开始录音，收到音频后自动显示文字。"
    }
    if model.live.lastAudioAt == nil { return "尚未收到设备音频。设备原件独立保存，可在 USB 同步后查看。" }
    return model.live.status
  }
}

private struct LiveBottomPreference: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
