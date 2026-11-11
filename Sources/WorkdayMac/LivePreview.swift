import Combine
import Foundation
import QS668Core
import WorkdayCore

enum LiveAudioBoundary { case started, resumed, paused, saving, ended, disconnected, corrupted }

struct LiveLine: Identifiable, Equatable {
  static let maximumRetained = 100
  let id: String
  let segment: Int
  let sentence: Int
  var text: String
  var isFinal: Bool
  var voiceID: String? = nil
  var voiceRange: Range<Int>? = nil
  var recordingRange: Range<Int>? = nil
  var receivedAt: Date? = nil
}

@MainActor final class LivePreview: ObservableObject {
  enum Phase { case disabled, waiting, connecting, recognizing, finishing, failed }
  @Published private(set) var lines: [LiveLine] = []
  @Published private(set) var phase: Phase = .disabled
  @Published private(set) var status = "实时文字尚未开启。"
  @Published private(set) var receivedBytes = 0
  @Published private(set) var lastAudioAt: Date?
  @Published private(set) var lastTextAt: Date?
  @Published private(set) var hasGap = false
  private struct Session {
    let stream: LiveASRStreaming
    let index: Int
    let recordingOffset: Int
    var bytes = 0
    var sourceName: String?
    var packets = Data()
    var firstByte = 0
    var retiredSentence = -1
  }
  var voiceSource: (() -> String?)?
  var onVoice: ((String, String, Data, Double) -> Void)?
  struct ConfirmationAudio {
    let source: String
    let packets: Data
    let seconds: Double
  }
  // With cloud ASR, keep the local phrase's own audio for explicit corrections.
  // The cache follows the bounded transcript and does not run a second encoder by default.
  var retainConfirmationAudio = false {
    didSet { if !retainConfirmationAudio { confirmationAudio.removeAll() } }
  }
  private(set) var confirmationAudio: [String: ConfirmationAudio] = [:]
  private var sessions: [UUID: Session] = [:]
  private var active: UUID?
  private var sequence = 0
  private var configuration: LiveASRConfiguration?
  private var enabled = false
  private var failures = 0
  private var recoverable = true
  private var retryAfter = Date.distantPast
  private var timer: Timer?
  private var waitingMessage = "等待设备音频，收到后即开始识别。"
  private let clock: () -> Date
  private let makeStream: @MainActor (LiveASRConfiguration) throws -> LiveASRStreaming
  private let makeLocalStream: (@MainActor () throws -> LiveASRStreaming)?
  var isWorking: Bool { phase == .connecting || phase == .recognizing || phase == .finishing }
  var canRetry: Bool { phase == .failed }
  var receivedSeconds: Double { Double(receivedBytes) / 2000 }

  init(
    clock: @escaping () -> Date = Date.init,
    makeLocalStream: (@MainActor () throws -> LiveASRStreaming)? = nil,
    makeStream: @escaping @MainActor (LiveASRConfiguration) throws -> LiveASRStreaming = {
      try QwenLiveConnection(configuration: $0)
    }
  ) {
    self.makeLocalStream = makeLocalStream
    self.clock = clock
    self.makeStream = makeStream
  }
  func configure(enabled: Bool, service: AIService?) {
    let config = service.map { LiveASRConfiguration(key: $0.key, host: $0.host) }
    guard self.enabled != enabled || configuration != config else { return }
    stopStreams()
    self.enabled = enabled
    configuration = config
    failures = 0
    recoverable = true
    retryAfter = .distantPast
    phase = enabled && (makeLocalStream != nil || config != nil) ? .waiting : .disabled
    status = enabled ? (config == nil && makeLocalStream == nil ? "请在设置中保存百炼 API Key。" : waitingMessage) : "实时文字尚未开启。"
  }
  private var streamByteLimit: Int {
    if makeLocalStream != nil {
      if #unavailable(macOS 26) { return 100_000 }
    }
    return 1_200_000
  }
  func append(_ data: Data, recordingOffset: Int? = nil) {
    guard enabled, makeLocalStream != nil || configuration != nil, !data.isEmpty else { return }
    lastAudioAt = clock()
    receivedBytes += data.count
    if timer == nil {
      timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.tick() }
      }
    }
    // Rotate cloud tasks while the device keeps the same recording.
    if let active, let session = sessions[active], session.bytes >= streamByteLimit { finishActive() }
    if active == nil {
      guard recoverable, clock() >= retryAfter else {
        hasGap = true
        return
      }
      while sessions.count >= 2 {
        guard let oldest = sessions.min(by: { $0.value.index < $1.value.index })?.key else { break }
        sessions.removeValue(forKey: oldest)?.stream.cancel()
        hasGap = true
      }
      do {
        let id = UUID()
        let stream: LiveASRStreaming
        if let makeLocalStream { stream = try makeLocalStream() }
        else if let configuration { stream = try makeStream(configuration) }
        else { return }
        let index = sequence
        sequence += 1
        sessions[id] = Session(stream: stream, index: index, recordingOffset: recordingOffset ?? receivedBytes - data.count, sourceName: voiceSource?())
        active = id
        phase = .connecting
        status = makeLocalStream == nil ? "已收到音频，正在连接实时识别…" : "正在准备苹果本地中文识别…"
        stream.onEvent = { [weak self] event in self?.receive(event, id: id) }
        stream.start()
      } catch {
        fail(error.localizedDescription)
        return
      }
    }
    guard let id = active, let stream = sessions[id]?.stream else { return }
    if onVoice != nil || retainConfirmationAudio {
      if sessions[id]?.sourceName == nil { sessions[id]?.sourceName = voiceSource?() }
      sessions[id]?.packets.append(data)
      // Prune whole packets in batches, keeping at least two minutes of trailing audio.
      if let size = sessions[id]?.packets.count, size > 260_000 {
        let removed = ((size - 240_000) / 40) * 40
        sessions[id]?.packets.removeFirst(removed)
        sessions[id]?.firstByte += removed
      }
    }
    sessions[id]?.bytes += data.count
    stream.append(data)
  }
  func boundary(_ boundary: LiveAudioBoundary) {
    switch boundary {
    case .started:
      reset(message: "设备已开始录音，等待音频后即开始识别。")
    case .resumed:
      waitingMessage = "设备已继续录音，等待新的音频。"
      if active == nil, sessions.isEmpty, phase != .failed { showWaiting() }
    case .paused, .saving, .ended:
      switch boundary {
      case .paused: waitingMessage = "设备已暂停，已识别的文字保留。"
      case .saving: waitingMessage = "设备正在保存，已识别的文字保留。"
      default: waitingMessage = "本次录音已结束，已识别的文字保留。"
      }
      // Keep accepting the hardware tail until actual audio stops arriving.
      if active == nil, sessions.isEmpty, phase != .failed { showWaiting() }
    case .disconnected:
      waitingMessage = "设备已断开，已识别的文字保留；重连收到音频后继续。"
      finishActive()
      if sessions.isEmpty, phase != .failed { showWaiting() }
    case .corrupted:
      hasGap = true
      waitingMessage = "音频接收出现缺口，等待后续音频；完整内容请在 USB 同步后查看。"
      finishActive()
      if sessions.isEmpty, phase != .failed { showWaiting() }
    }
  }
  func tick() {
    if let lastAudioAt, clock().timeIntervalSince(lastAudioAt) >= 1.5, active != nil {
      finishActive()
    }
  }
  func retryIfRecoverable() { if phase == .failed, recoverable { retry() } }
  func retry() {
    stopStreams()
    failures = 0
    recoverable = true
    retryAfter = .distantPast
    waitingMessage = "等待新的设备音频，收到后重新连接识别服务。"
    showWaiting()
  }
  func reset(message: String = "等待设备音频，收到后即开始识别。") {
    stopStreams()
    confirmationAudio.removeAll()
    lines = []
    receivedBytes = 0
    lastAudioAt = nil
    lastTextAt = nil
    hasGap = false
    failures = 0
    recoverable = true
    retryAfter = .distantPast
    waitingMessage = message
    showWaiting()
  }
  private func stopStreams() {
    active = nil
    let old = sessions
    sessions = [:]
    for value in old.values { value.stream.cancel() }
    timer?.invalidate()
    timer = nil
  }
  private func finishActive() {
    guard let id = active, let stream = sessions[id]?.stream else { return }
    active = nil
    phase = .finishing
    status = "正在识别末尾文字…"
    stream.finish()
  }
  private func showWaiting() {
    phase = enabled && (configuration != nil || makeLocalStream != nil) ? .waiting : .disabled
    status = phase == .waiting ? waitingMessage : "实时文字尚未开启或未配置云端服务。"
  }
  private func receive(_ event: ASREvent, id: UUID) {
    guard let session = sessions[id] else { return }
    switch event {
    case .started:
      if active == id {
        phase = .recognizing
        status = "正在实时识别，文字随讲话更新。"
      }
    case .sentence(let number, let text, let isFinal, let start, let end, let words):
      guard number >= 0, number > session.retiredSentence, text.count <= 16_000 else { return }
      let lineID = "\(id.uuidString):\(number)"
      var line = LiveLine(
        id: lineID, segment: session.index, sentence: number, text: text, isFinal: isFinal)
      let index = lines.firstIndex { $0.id == lineID }
      let previous = index.map { lines[$0] }
      line.receivedAt = previous?.receivedAt ?? clock()
      guard previous?.isFinal != true || isFinal else { return }
      let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      let acceptsLine = previous != nil || isFinal || hasText
      if isFinal, let start = start ?? words?.first?.startMs, let end = end ?? words?.last?.endMs,
        start >= 0, end > start, end <= Double(session.bytes) / 2 + 1 {
        let lower = session.recordingOffset + Int(start * 2)
        let upper = session.recordingOffset + Int(end * 2)
        line.recordingRange = lower..<upper
      }
      var evidence: (Data, Double)?
      if isFinal, onVoice != nil || retainConfirmationAudio, hasText,
        let start = start ?? words?.first?.startMs, let end = end ?? words?.last?.endMs,
        start.isFinite, end.isFinite, start >= 0, (2000...120000).contains(end - start),
        end <= Double(session.bytes) / 2 + 1
      {
        let lo = Int(ceil(start / 20)) * 40 - session.firstByte
        let hi = Int(floor(end / 20)) * 40 - session.firstByte
        if lo >= 0, hi <= session.packets.count, hi > lo {
          let base = session.packets.startIndex
          line.voiceRange = (lo + session.firstByte)..<(hi + session.firstByte)
          line.voiceID = "live:" + lineID
          evidence = (session.packets.subdata(in: base + lo..<base + hi), (end - start) / 1000)
        }
      }
      if let old = previous, old.isFinal, isFinal {
        // A revised text for the same time span can reuse its evidence. If
        // a final moves the boundaries, never attach the previous person's voice.
        if let range = old.voiceRange, range != line.voiceRange {
          line.voiceID = nil
          line.voiceRange = range
          evidence = nil
        }
      }
      var changed = false
      if let index {
        if lines[index] != line {
          lines[index] = line
          changed = true
        }
      } else if acceptsLine {
        var updated = lines
        let insertion = updated.firstIndex {
          ($0.segment, $0.sentence) > (line.segment, line.sentence)
        } ?? updated.endIndex
        updated.insert(line, at: insertion)
        if updated.count > LiveLine.maximumRetained {
          let retired = updated.removeFirst()
          confirmationAudio.removeValue(forKey: retired.id)
          if let owner = sessions.first(where: { $0.value.index == retired.segment })?.key {
            let floor = max(sessions[owner]?.retiredSentence ?? -1, retired.sentence)
            sessions[owner]?.retiredSentence = floor
          }
        }
        lines = updated
        changed = true
      }
      lastTextAt = clock()
      failures = 0
      if active == id {
        phase = .recognizing
        status = "正在实时识别 · 浅色文字仍可能修订"
      }
      if changed, let voiceID = line.voiceID, let (packets, seconds) = evidence {
        let source = VoiceRecognition.source(session.sourceName, fallback: id.uuidString)
        if retainConfirmationAudio {
          confirmationAudio[lineID] = ConfirmationAudio(source: source, packets: packets, seconds: seconds)
        }
        onVoice?(voiceID, source, packets, seconds)
      } else if changed, line.voiceID == nil {
        confirmationAudio.removeValue(forKey: lineID)
      }
    case .finished:
      sessions.removeValue(forKey: id)
      if active == id { active = nil }
      if active == nil, sessions.isEmpty, phase != .failed { showWaiting() }
    case .failed(let code, let message):
      sessions.removeValue(forKey: id)?.stream.cancel()
      if active == id {
        active = nil
        fail(message, recoverable: code != "configuration")
      } else if active == nil {
        fail(message, recoverable: code != "configuration")
      } else {
        hasGap = true
      }
    case .ignored: break
    }
  }
  private func fail(_ message: String, recoverable: Bool = true) {
    self.recoverable = recoverable
    failures += 1
    retryAfter = clock().addingTimeInterval(failures >= 3 ? 60 : Double(failures * 3))
    hasGap = true
    phase = .failed
    if !recoverable {
      status = message + " 请修复配置后重试转写。"
    } else if failures < 3 {
      status = message + " 收到后续音频后将自动重连。"
    } else {
      status = message + " 将在一分钟后自动重试，也可手动重试。"
    }
  }
}
