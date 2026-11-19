import AppKit
import SwiftUI

struct CaptionBubble: View {
  let caption: DesktopCaption
  let username: String
  var preview = false
  var meter: LiveAudioMeter?
  var time = Date()
  var expansion: CGFloat = 1
  var waveOpacity: CGFloat = 0
  var reservesWave = false
  var inkOpacity: CGFloat = 1
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    CaptionBubbleContent(
      caption: caption, username: username, preview: preview, meter: meter, time: time, expansion: expansion,
      waveOpacity: waveOpacity, reservesWave: reservesWave, inkOpacity: inkOpacity,
      opaque: reduceTransparency, increasedContrast: contrast == .increased)
  }
}

struct CaptionBubbleContent: View {
  let caption: DesktopCaption
  let username: String
  var preview = false
  var meter: LiveAudioMeter?
  var time = Date()
  var expansion: CGFloat = 1
  var waveOpacity: CGFloat = 0
  var reservesWave = false
  var inkOpacity: CGFloat = 1
  var opaque = false
  var increasedContrast = false

  private var background: Color {
    if increasedContrast { return .black }
    return opaque ? Palette.captionSolidBackground : Palette.captionBackground
  }

  var body: some View {
    let cueWidth: CGFloat = caption.inputLabel == nil ? 14 : (caption.inputLabel == .microphone ? 84 : 58)
    CaptionReveal(progress: caption.isSoundFeedback ? 0 : CaptionReveal.envelope(expansion), collapsed: CGSize(width: cueWidth, height: 14)) {
      if caption.isSoundFeedback {
        HStack(spacing: 6) {
          if let label = caption.inputLabel { sourceLabel(label) }
          Color.clear.frame(width: 14, height: 14)
        }
        .frame(width: cueWidth, height: 14, alignment: .leading)
      } else {
        transcript.opacity(CaptionReveal.ink(expansion) * inkOpacity)
      }
    }
    .clipped()
    .padding(.horizontal, 12).padding(.vertical, 8)
    .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(.white.opacity(increasedContrast ? 0.45 : 0.10), lineWidth: 0.5)
    }
    .overlay(alignment: .topTrailing) {
      if caption.isSoundFeedback || waveOpacity > 0 {
        soundLevel.frame(width: 14, height: 14)
          .opacity(caption.isSoundFeedback ? 1 : waveOpacity)
          .padding(.top, 8).padding(.trailing, 12)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isStaticText)
    .accessibilityLabel(spokenLabel)
  }

  private var spokenLabel: String {
    var parts = [String]()
    if preview { parts.append("弹幕预览") }
    if let source = caption.inputLabel { parts.append(source.rawValue) }
    if caption.isSoundFeedback {
      parts.append("正在听取")
    } else {
      if caption.inputLabel != .microphone { parts.append(username) }
      parts.append(caption.text)
    }
    return parts.joined(separator: "，")
  }

  @ViewBuilder private var soundLevel: some View {
    if let meter { CaptionSoundLevel(meter: meter) }
    else { Image(systemName: "waveform").font(.system(size: 13)).foregroundStyle(.white) }
  }

  private func sourceLabel(_ label: CaptionInputLabel) -> some View {
    Text(label.rawValue).font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.white).lineLimit(1).fixedSize()
  }

  private var transcript: some View {
    CaptionBubbleLayout(keepsHeaderWidth: caption.inputLabel != nil || CaptionTypography.isNumberedSpeaker(username),
                        fixedWidth: caption.reservesReadingWidth) {
      HStack(spacing: 6) {
        if let label = caption.inputLabel { sourceLabel(label) }
        if caption.inputLabel != .microphone {
          Text(CaptionTypography.displayName(username))
            .font(.system(size: 11, weight: .semibold)).lineLimit(1)
            .foregroundStyle(increasedContrast ? .white : (caption.isMine ? Palette.captionName : .white.opacity(0.88)))
        }
      }
      HStack(spacing: 8) {
        if let time = caption.receivedAt {
          Text(CaptionTime.seconds.string(from: time))
            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.8))
            .help("本机收到这句字幕的时刻")
        }
        if caption.markedHere {
          Text(caption.hasSavedSample ? (caption.isMine ? "已存本人样本" : "已存非本人样本") : "仅标注本句")
            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.88))
        }
        if let controls = caption.identityControls, !preview {
          CaptionAnchor(id: caption.actionAnchor)
            .frame(width: CaptionVoiceActions.width(for: controls), height: CaptionVoiceActions.height)
            .accessibilityHidden(true)
        } else if reservesWave {
          Color.clear.frame(width: 14, height: 14)
        }
      }
      if caption.phrases.isEmpty {
        Text(verbatim: caption.text).font(.system(size: 14)).foregroundStyle(Palette.captionText).lineLimit(2)
      } else {
        CaptionPhraseBody(phrases: caption.phrases, time: time)
          .frame(width: caption.reservesReadingWidth ? CaptionPages.readingWidth : nil, alignment: .leading)
      }
    }
  }
}

private struct CaptionSoundLevel: View {
  @ObservedObject var meter: LiveAudioMeter
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.5)) { clock in
      let sample = meter.sample
      let level = sample.flatMap { clock.date.timeIntervalSince($0.at) < 1.5 ? $0.segments : nil } ?? 0
      HStack(spacing: 2) {
        ForEach(0..<4) { index in
          let height = CGFloat(4 + min(index, 3 - index) * 5)
          Capsule().frame(width: 2, height: height)
            .scaleEffect(y: index < level ? 1 : 2 / height)
        }
      }
      .animation(reduceMotion ? nil : .timingCurve(0.23, 1, 0.32, 1, duration: 0.09), value: level)
      .frame(height: 13).foregroundStyle(Palette.captionName)
    }.accessibilityHidden(true)
  }
}

private struct CaptionPhraseBody: View {
  let phrases: [CaptionPhrase]
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let time: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      line(0, at: time)
      if let first = phrases.first(where: { $0.line == 1 }) {
        let progress = reduceMotion ? 1 : CaptionTransition.progress(time.timeIntervalSince(first.appearedAt),
                                                                      duration: CaptionPhrase.duration)
        CaptionReveal(progress: CaptionReveal.envelope(progress)) {
          line(1, at: time).padding(.top, 2).opacity(CaptionReveal.ink(progress))
        }.clipped()
      }
    }
    .font(.system(size: 14))
  }

  private func line(_ number: Int, at now: Date) -> some View {
    phrases.filter { $0.line == number }.reduce(Text("")) { body, phrase in
      let opacity = reduceMotion ? 1 : CaptionTransition.progress(now.timeIntervalSince(phrase.appearedAt), duration: CaptionPhrase.duration)
      return body + Text(verbatim: phrase.text).foregroundColor(Palette.captionText.opacity(opacity))
    }.lineLimit(1).fixedSize()
  }
}

/// Measure the text at its reading width on every frame. Only the visible envelope changes size.
struct CaptionReveal: Layout {
  let progress: CGFloat
  var collapsed: CGSize? = nil

  // Open the reading area first, then expose whole glyphs at their final position.
  private static let inkStart: CGFloat = 0.84
  static func envelope(_ progress: CGFloat) -> CGFloat { min(1, progress / inkStart) }
  static func ink(_ progress: CGFloat) -> CGFloat { max(0, (progress - inkStart) / (1 - inkStart)) }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let view = subviews.first else { return .zero }
    let size = view.sizeThatFits(proposal)
    let start = collapsed ?? CGSize(width: size.width, height: 0)
    return CGSize(width: start.width + (size.width - start.width) * progress,
                  height: start.height + (size.height - start.height) * progress)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing, proposal: proposal)
  }
}

/// A short caption needs only a compact header. When the body is wider, the name can use
/// the spare width while the timestamp and the native action keep their intrinsic sizes.
private struct CaptionBubbleLayout: Layout {
  let keepsHeaderWidth: Bool
  let fixedWidth: Bool

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let name = subviews[0].sizeThatFits(.unspecified)
    let metadata = subviews[1].sizeThatFits(.unspecified)
    let body = subviews[2].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
    let compactName = keepsHeaderWidth ? name.width : min(name.width, 72)
    let headerWidth = compactName + (metadata.width > 0 ? 8 : 0) + metadata.width
    return CGSize(width: min(proposal.width ?? .infinity, max(headerWidth, body.width)),
                  height: max(name.height, metadata.height) + 4 + body.height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let metadata = subviews[1].sizeThatFits(.unspecified)
    let gap: CGFloat = metadata.width > 0 ? 8 : 0
    let idealName = subviews[0].sizeThatFits(.unspecified)
    let nameWidth = min(idealName.width, max(0, bounds.width - gap - metadata.width))
    let headerHeight = max(idealName.height, metadata.height)
    let midY = bounds.minY + headerHeight / 2
    subviews[0].place(at: CGPoint(x: bounds.minX, y: midY), anchor: .leading,
                      proposal: ProposedViewSize(width: nameWidth, height: idealName.height))
    let metadataX = fixedWidth ? bounds.maxX - metadata.width : bounds.minX + nameWidth + gap
    subviews[1].place(at: CGPoint(x: metadataX, y: midY), anchor: .leading,
                      proposal: ProposedViewSize(metadata))
    subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.minY + headerHeight + 4),
                      anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
  }
}

enum CaptionTypography {
  static func displayName(_ name: String) -> String {
    let candidate = name.prefix(64)
    return candidate.endIndex == name.endIndex ? name : String(candidate) + "…"
  }

  static func isNumberedSpeaker(_ name: String) -> Bool {
    let unknownPrefix = VoiceLabel.unknown + " "
    return name.hasPrefix(unknownPrefix) && Int64(name.dropFirst(unknownPrefix.count)) != nil
  }
}
