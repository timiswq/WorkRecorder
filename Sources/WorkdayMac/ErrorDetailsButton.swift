import AppKit
import SwiftUI

private struct ErrorDetails: Identifiable {
  let id = UUID()
  let message: String
  let context: String?

  var summary: String { String(message.prefix { !$0.isNewline }) }

  var text: String {
    var parts = [context, message].compactMap { $0 }
    if summary.hasPrefix("云端请求失败（"), summary.hasSuffix("已完成部分已保留") {
      parts.append("旧版只保存了 HTTP 状态码。重试后，如果请求再次失败，这里会显示新请求的错误详情。")
    }
    return parts.joined(separator: "\n\n")
  }
}

struct ErrorDetailsButton: View {
  let message: String
  var context: String? = nil
  @State private var selected: ErrorDetails?

  var body: some View {
    let details = ErrorDetails(message: message, context: context)
    Button {
      selected = details
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "exclamationmark.circle")
        Text(verbatim: details.summary).lineLimit(2).multilineTextAlignment(.leading)
        Spacer(minLength: 4)
        Text("查看详情").fixedSize()
      }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
    .font(.system(size: 12)).buttonStyle(.plain).foregroundStyle(Palette.amber)
    .accessibilityLabel(
      "查看错误详情，" + ([context, details.summary].compactMap { $0 }.joined(separator: "，"))
    )
    .sheet(item: $selected) { details in
      VStack(alignment: .leading, spacing: 16) {
        Text("错误详情").font(.headline)
        ScrollView {
          Text(verbatim: details.text).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).lineSpacing(4)
        }
        HStack {
          Button("复制详情") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(details.text, forType: .string)
          }
          Spacer()
          Button("关闭") { selected = nil }.keyboardShortcut(.defaultAction)
        }
      }.padding(20).frame(width: 480, height: 280)
    }
  }
}
