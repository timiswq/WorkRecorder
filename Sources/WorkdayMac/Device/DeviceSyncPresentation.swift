import Foundation
import WorkdayCore

struct CardRecordingCount: Equatable {
  let discovered: Int
  var complete = false
  var pending: Int? = nil

  var label: String {
    guard complete else { return "已发现 \(discovered) 段" }
    return "共 \(discovered) 段" + (pending.map { " · \($0) 段待同步" } ?? "")
  }
}

struct DeviceSyncTransfer {
  let name: String
  let position: Int
  let count: Int?
  let progress: TransferProgress?

  var stageIsVerifying: Bool {
    guard let progress else { return false }
    return progress.phase == .verifying || progress.fraction == 1
  }

  var positionLabel: String {
    "第 \(position) 段" + (count.map { "，共 \($0) 段" } ?? "")
  }
}

struct DeviceSyncOutcome {
  var saved: Int?
  var copies: String?
  var notice: String?
  var network: String?

  mutating func addCopies(_ text: String) {
    copies = [copies, text].compactMap { $0 }.joined(separator: " ")
  }

  mutating func addNotice(_ text: String) {
    notice = [notice, text].compactMap { $0 }.joined(separator: " ")
  }
}
