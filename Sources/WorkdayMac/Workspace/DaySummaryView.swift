import SwiftUI
import WorkdayCore

struct DaySummaryView: View {
  @ObservedObject var model: AppModel
  @State private var expanded = false
  @State private var recentlyUpdated = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if recentlyUpdated || model.selectedDay.map({ model.dayUpdates.isUnseen($0) }) == true {
        Label("事项与全天总结已更新", systemImage: "circle.fill")
          .font(.system(size: 11)).foregroundStyle(Palette.accent)
      }
      HStack {
        Text("全天总结").font(.system(size: 14, weight: .semibold))
        Spacer()
        if let day = model.selectedDay, model.summaryErrors[day] == nil,
          model.processingSummaryDay != day, !model.queuedSummaryRetries.contains(day),
          !model.summaryIsCurrent(day) || !model.dayComplete
        {
          let canUpdateSummary =
            !model.summaryIsCurrent(day)
            && model.dayRecordings.contains { model.documents[$0.id]?.phase == "complete" }
          Button(model.service == nil ? "配置整理" : "整理这一天") {
            model.retryProcessing(scope: canUpdateSummary ? .summary(day) : .day(day))
          }.buttonStyle(.link).font(.system(size: 12))
            .disabled(!canUpdateSummary && model.processingID != nil)
        }
      }
      if let day = model.selectedDay, let value = model.summaries[day], !value.overview.isEmpty {
        Text(value.overview).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
          .lineLimit(expanded ? nil : 2)
          .padding(.leading, 12).overlay(alignment: .leading) {
            Rectangle().fill(Palette.line).frame(width: 2)
          }
        Button(expanded ? "收起详情" : "展开摘要与待办") { expanded.toggle() }
          .buttonStyle(.link).font(.system(size: 12))
        if !model.summaryIsCurrent(day) || !model.dayComplete {
          Text("基于已整理的 \(value.recordingIDs.count) 段录音 · 等待更新")
            .font(.system(size: 11)).foregroundStyle(Palette.amber)
        }
        if expanded && (!value.decisions.isEmpty || !value.tasks.isEmpty) {
          VStack(alignment: .leading, spacing: 12) {
            Text("决定与待办").fontWeight(.medium)
            ForEach(value.decisions) { note in noteRow(note, icon: "checkmark.circle") }
            ForEach(value.tasks) { note in noteRow(note, icon: "square") }
          }.padding(.top, 6).font(.system(size: 12))
        }
      } else if let day = model.selectedDay, model.processingSummaryDay != day,
        !model.queuedSummaryRetries.contains(day), model.summaryErrors[day] == nil
      {
        Text(placeholder).font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(5)
      }
      if let day = model.selectedDay {
        if model.processingSummaryDay == day {
          HStack {
            ProgressView().controlSize(.small)
            Text("正在整理全天事项…")
          }.font(.callout)
        } else if model.queuedSummaryRetries.contains(day) {
          Label("已排队，当前任务结束后重试", systemImage: "clock").font(.callout)
        } else if let error = model.summaryErrors[day] {
          ErrorDetailsButton(message: error, context: "当天摘要：\(day)")
          Button("重试这一天") { model.retryProcessing(scope: .summary(day)) }
            .buttonStyle(.link).controlSize(.small)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Palette.selected, in: RoundedRectangle(cornerRadius: 5))
            .accessibilityIdentifier("retry-day-summary")
            .help("用这一天已整理的录音重新生成摘要")
        }
      }
    }.background {
      if let day = model.selectedDay, model.dayUpdates.isUnseen(day),
        let signature = model.dayUpdates.signature(for: day) {
        DayResultReadMarker(signature: day + ":" + signature) {
          model.markDayViewed(day, signature: signature)
          recentlyUpdated = true
          Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            recentlyUpdated = false
          }
        }
      }
    }.padding(.bottom, 16)
      .overlay(alignment: .bottom) { Divider().allowsHitTesting(false) }
      .onChange(of: model.selectedDay) { _, _ in
        expanded = false
        recentlyUpdated = false
      }
  }

  private var placeholder: String {
    if model.dayRecordings.contains(where: { $0.id == model.processingID }) {
      return model.processingLabel ?? "正在整理…"
    }
    if model.dayRecordings.contains(where: { model.documents[$0.id]?.error != nil }) {
      return "部分录音整理失败，已保存的原件和可用文字仍可查看。请在原始录音中重试对应条目。"
    }
    if !model.workspace.activities.isEmpty && model.dayConversations.isEmpty {
      return "当天原话已显示在时间线上，可逐句回听和补整理。"
    }
    if model.dayComplete && model.dayConversations.isEmpty { return "已整理当天录音，未发现可确认的工作事项。" }
    return model.service == nil ? "原件已保存在 Mac。配置语音识别后，可生成全天事项与总结。" : "原件已保存，等待整理。"
  }
  private func noteRow(_ note: SummaryNote, icon: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon).foregroundStyle(Palette.muted)
      Text(note.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
      if let id = note.conversationIDs.first,
        let clip = model.dayConversations.first(where: { $0.id == id })
      {
        Button("回听") {
          model.selectConversation(clip)
          model.playDay(from: clip)
        }.buttonStyle(.link)
      }
    }
  }
}
