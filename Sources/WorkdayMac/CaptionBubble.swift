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
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(CaptionTypography.displayName(username)).font(.system(size: 11, weight: .semibold))
          .foregroundStyle(increasedContrast ? .white : (caption.isMine ? Palette.captionName : .white.opacity(0.88)))
        if let time = caption.receivedAt {
          Text(time, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.8))
            .help("本机收到这句字幕的时刻")
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
    .padding(.horizontal, 12).padding(.vertical, 8)
    .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(.white.opacity(increasedContrast ? 0.45 : 0.10), lineWidth: 0.5)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isStaticText)
    .accessibilityLabel(
      preview ? "弹幕预览，\(username)，\(caption.text)" : "\(username)，\(caption.text)")
  }
}

enum CaptionTypography {
  static let nameWidth: CGFloat = 72
  static let nameFont = NSFont.systemFont(ofSize: 13, weight: .medium)

  static func visibleText(_ caption: DesktopCaption, username: String) -> String {
    let availableWidth: CGFloat = 314
    var text = String(caption.text.suffix(70))
    if text != caption.text { text = "…" + text }
    // Keep the latest words visible through finalization and speaker enrichment.
    while text.count > 1, wrappedHeight(text: text, width: availableWidth) > 38 {
      if text.first == "…" { text.removeFirst() }
      text.removeFirst()
      text = "…" + text
    }
    return text
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
    // Bound measurement work even for a pasted paragraph, preserving grapheme clusters.
    let candidate = String(name.prefix(64))
    let unknownPrefix = VoiceLabel.unknown + " "
    if candidate == name, candidate.hasPrefix(unknownPrefix),
      Int64(candidate.dropFirst(unknownPrefix.count)) != nil { return candidate }
    if candidate == name, width(of: candidate) <= nameWidth { return candidate }
    var prefix = ""
    for character in candidate {
      let next = prefix + String(character)
      if width(of: next + "…") > nameWidth { break }
      prefix = next
    }
    return prefix + "…"
  }

  static func width(of text: String) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: nameFont]).width
  }
}
