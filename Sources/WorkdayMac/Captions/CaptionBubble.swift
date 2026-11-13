import AppKit
import SwiftUI

struct CaptionBubble: View {
  let caption: DesktopCaption
  let username: String
  var preview = false
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    CaptionBubbleContent(
      caption: caption, username: username, preview: preview,
      opaque: reduceTransparency, increasedContrast: contrast == .increased)
  }
}

struct CaptionBubbleContent: View {
  let caption: DesktopCaption
  let username: String
  var preview = false
  var opaque = false
  var increasedContrast = false

  private var background: Color {
    if increasedContrast { return .black }
    return opaque ? Palette.captionSolidBackground : Palette.captionBackground
  }

  var body: some View {
    Group {
      if caption.isSoundFeedback {
        Label(caption.text, systemImage: "waveform")
          .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
      } else {
        transcript
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
    .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(.white.opacity(increasedContrast ? 0.45 : 0.10), lineWidth: 0.5)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isStaticText)
    .accessibilityLabel(caption.isSoundFeedback ? caption.text :
      (preview ? "弹幕预览，\(username)，\(caption.text)" : "\(username)，\(caption.text)"))
  }

  private var transcript: some View {
    CaptionBubbleLayout(keepsNumber: CaptionTypography.isNumberedSpeaker(username)) {
      Text(CaptionTypography.displayName(username))
        .font(.system(size: 11, weight: .semibold)).lineLimit(1)
        .foregroundStyle(increasedContrast ? .white : (caption.isMine ? Palette.captionName : .white.opacity(0.88)))
      HStack(spacing: 8) {
        if let time = caption.receivedAt {
          Text(CaptionTime.seconds.string(from: time))
            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.8))
            .help("本机收到这句字幕的时刻")
        }
        if caption.markedHere {
          Text(caption.isMine ? "已存本人样本" : "已存非本人样本")
            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.88))
        }
        if let controls = caption.identityControls, !preview {
          CaptionAnchor(id: caption.actionAnchor)
            .frame(width: CaptionVoiceActions.width(for: controls), height: CaptionVoiceActions.height)
            .accessibilityHidden(true)
        }
      }
      (Text(CaptionTypography.visibleText(caption, username: username)).foregroundColor(Palette.captionText)
       + Text(caption.isFinal ? "" : " ▏").foregroundColor(Palette.captionName))
        .font(.system(size: 14)).lineSpacing(2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// A short caption needs only a compact header. When the body is wider, the name can use
/// the spare width while the timestamp and the native action keep their intrinsic sizes.
private struct CaptionBubbleLayout: Layout {
  let keepsNumber: Bool

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let name = subviews[0].sizeThatFits(.unspecified)
    let metadata = subviews[1].sizeThatFits(.unspecified)
    let body = subviews[2].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
    let compactName = keepsNumber ? name.width : min(name.width, 72)
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
    subviews[1].place(at: CGPoint(x: bounds.minX + nameWidth + gap, y: midY), anchor: .leading,
                      proposal: ProposedViewSize(metadata))
    subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.minY + headerHeight + 4),
                      anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
  }
}

enum CaptionTypography {
  static func visibleText(_ caption: DesktopCaption, username: String) -> String {
    let availableWidth: CGFloat = 314
    let source = caption.text
    var start = source.suffix(70).startIndex
    while start < source.endIndex {
      let text = (start == source.startIndex ? "" : "…") + source[start...]
      if wrappedHeight(text: text, width: availableWidth) <= 38 { break }
      source.formIndex(after: &start)
    }
    guard start > source.startIndex else { return source }
    guard start < source.endIndex else { return "…" }

    // Look only near the cut so a distant comma cannot discard most of the two lines.
    if !isPhraseBreak(source[source.index(before: start)]),
       let boundary = source[start...].prefix(8).firstIndex(where: isPhraseBreak),
       let nextWord = source[boundary...].firstIndex(where: { !isPhraseBreak($0) }) {
      start = nextWord
    }
    let words = source[start...].drop(while: isPhraseBreak)
    return "…" + (words.isEmpty ? source[start...] : words)
  }

  private static func isPhraseBreak(_ character: Character) -> Bool {
    character.isWhitespace || "，、。；：！？,;:!?".contains(character)
  }

  private static func wrappedHeight(text: String, width: CGFloat) -> CGFloat {
    let value = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 3
    value.addAttribute(
      .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: value.length))
    return value.boundingRect(
      with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    ).height
  }

  static func displayName(_ name: String) -> String {
    let candidate = name.prefix(64)
    return candidate.endIndex == name.endIndex ? name : String(candidate) + "…"
  }

  static func isNumberedSpeaker(_ name: String) -> Bool {
    let unknownPrefix = VoiceLabel.unknown + " "
    return name.hasPrefix(unknownPrefix) && Int64(name.dropFirst(unknownPrefix.count)) != nil
  }
}
