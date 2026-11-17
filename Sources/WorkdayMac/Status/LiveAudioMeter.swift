import Combine
import Foundation
import WorkdayCore

/// The sidebar and active caption meter observe samples without refreshing the workspace.
@MainActor final class LiveAudioMeter: ObservableObject {
  struct Sample: Equatable {
    let segments: Int
    let at: Date
  }
  @Published private(set) var sample: Sample?
  private var reader: CardAudioMeter?
  private var generation = 0

  func append(_ data: Data, offset: Int) {
    if reader == nil {
      let token = generation
      reader = CardAudioMeter { [weak self] segments, at in
        guard let self, token == self.generation else { return }
        self.sample = Sample(segments: segments, at: at)
      }
    }
    reader?.append(data, offset: offset)
  }
  func reset() {
    generation += 1
    reader?.cancel()
    reader = nil
    sample = nil
  }
}

enum LiveSidebarState: Equatable {
  case level(Int)
  case noAudio, idle, paused, saving, connecting, unknown
  static func resolve(status: DesktopStatus, sample: LiveAudioMeter.Sample?, now: Date) -> Self {
    switch status.kind {
    case .recording:
      guard let sample, (0..<1.5).contains(now.timeIntervalSince(sample.at)) else {
        return .noAudio
      }
      return .level(min(4, max(0, sample.segments)))
    case .idle: return .idle
    case .paused: return .paused
    case .saving: return .saving
    case .connecting: return .connecting
    case .unknown, .usb, .disconnected: return .unknown
    }
  }
  var description: String {
    switch self {
    case .level(let count): return count == 0 ? "正在录音 · 当前环境安静" : "正在录音 · 输入音量 \(count) 格，共 4 格"
    case .noAudio: return "正在录音 · 暂未收到音频"
    case .idle: return "未录音"
    case .paused: return "录音已暂停"
    case .saving: return "正在保存到录音卡"
    case .connecting: return "正在连接录音卡"
    case .unknown: return "录音状态待确认"
    }
  }
}
