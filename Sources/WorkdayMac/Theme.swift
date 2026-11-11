import AppKit
import SwiftUI

enum Palette {
  static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(
          srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
          blue: Double(value & 255) / 255, alpha: 1)
      })
  }
  static let background = adaptive(0xFAFBFD, 0x171B24)
  static let sidebar = adaptive(0xF2F5FA, 0x161B26)
  static let surface = adaptive(0xFFFFFF, 0x202633)
  static let text = adaptive(0x172033, 0xE6EDF8)
  static let muted = adaptive(0x606D81, 0xABB8CA)
  static let line = adaptive(0xDDE3EC, 0x364051)
  static let accent = adaptive(0x225DD7, 0x95B7FF)
  static let selected = adaptive(0xEAF1FF, 0x293D60)
  static let red = adaptive(0xCD4153, 0xF38F99)
  static let amber = adaptive(0x9B742E, 0xCEB478)
  // Keep a dark, readable text surface over both white windows and dark desktops.
  static let captionSolidBackground = Color(red: 0.10, green: 0.135, blue: 0.195)
  static let captionBackground = captionSolidBackground.opacity(0.94)
  static let captionText = Color.white
  static let captionName = Color(red: 0.69, green: 0.80, blue: 1)
}

struct SectionHeading: View {
  let title: String
  var body: some View {
    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
  }
}

struct EmptyMessage: View {
  let icon: String
  let title: String
  let detail: String
  var body: some View {
    VStack(spacing: 15) {
      Image(systemName: icon).font(.system(size: 35, weight: .ultraLight)).foregroundStyle(
        Palette.accent)
      Text(title).font(.title3.weight(.semibold))
      Text(detail).foregroundStyle(Palette.muted).multilineTextAlignment(.center).lineSpacing(5)
        .frame(maxWidth: 380)
    }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

func humanDuration(_ seconds: Double) -> String {
  let minutes = max(0, Int(seconds / 60))
  if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟" }
  return seconds < 60 ? "\(max(0, Int(seconds))) 秒" : "\(minutes) 分钟"
}
