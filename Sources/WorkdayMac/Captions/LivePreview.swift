import Combine
import Foundation
import QS668Core
import WorkdayCore

enum LiveAudioBoundary { case started, resumed, paused, saving, ended, disconnected, corrupted }

enum CaptionTextSource: String, Codable {
  case local, cloud, mixed

  var title: String {
    switch self {
    case .local: "本机转写"
    case .cloud: "云端转写"
    case .mixed: "云端＋本机转写"
    }
  }
}

struct LiveLine: Identifiable, Equatable {
  static let maximumRetained = 100
  let id: String
  let segment: Int
  let sentence: Int
  var text: String
  var isFinal: Bool
  var textSource: CaptionTextSource = .local
  var voiceID: String? = nil
  var voiceRange: Range<Int>? = nil
  struct DraftVoice: Equatable {
    let id: String
    let range: Range<Int>
    let packets: Data
  }
  var voicePackets: Data?
  var draftVoice: DraftVoice?
  var bubbleVoiceID: String? { isFinal ? voiceID : draftVoice?.id }
  var bubblePackets: Data? { isFinal ? voicePackets : draftVoice?.packets }
  var recordingRange: Range<Int>? = nil
  // Recording-relative times align recognizers. Voice windows contain complete Opus packets.
  var recognitionRange: Range<Int>? = nil
  var stableCloudText: String? = nil
  var receivedAt: Date? = nil
  var replay: CaptionReplay? = nil
  var fileReviewEligible = false
  var hasUnpublishedWords = false
  var bubblePhrase: AppleBubblePhrase?

  var captionText: String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
  static func containsSpeech(_ text: String) -> Bool {
    text.contains { !$0.isWhitespace && !$0.isPunctuation }
  }
}

struct PendingCaption: Equatable {
  let id = UUID().uuidString
  let offset: Int
  let startedAt: Date
  var delayed = false
  var text: String { delayed ? "已收到声音，字幕稍后显示" : "已收到声音" }
}

@MainActor final class LivePreview: ObservableObject {
  enum Phase { case disabled, waiting, connecting, recognizing, finishing, failed }
  @Published private(set) var lines: [LiveLine] = []
  @Published private(set) var phase: Phase = .disabled
  @Published private(set) var status = "实时文字尚未开启。"
  // Audio offsets and the last-packet clock advance independently of the visible transcript.
  private(set) var receivedBytes = 0
  private(set) var lastAudioAt: Date?
  @Published private(set) var lastTextAt: Date?
  @Published private(set) var hasGap = false
  @Published private(set) var pendingSpeech: PendingCaption?
  private var pendingIDAssigned = false
  private var activity: CardSpeechActivity?
  private var activityDrain: Task<Void, Never>?
  private var activityGeneration = 0
  private var feedbackPaused = false
  private var speechEndedAt: Date?
  private var textThroughOffset = -1
  private struct Session {
    let stream: LiveASRStreaming
    let index: Int
    let recordingOffset: Int
    var bytes = 0
    var finishAfterPacket = false
    var sourceName: String?
    var packets = Data()
    var fileReviewFrom: Int?
    var firstByte = 0
    var retiredSentence = -1
    var cloudDrafts: [Int: AppleCaptionPhrases.BubbleDraft] = [:]
  }
  var onLineChanged: ((LiveLine) -> Void)?
  var cacheCaptionAudio = false
  var collectForFileReview = false {
    didSet {
      guard oldValue != collectForFileReview else { return }
      for id in Array(sessions.keys) {
        let first = collectForFileReview ? sessions[id]?.bytes : nil
        sessions[id]?.fileReviewFrom = first
      }
      if !collectForFileReview {
        for id in Array(closing.keys) { closing[id]?.fileReviewFrom = nil }
      }
    }
  }
  var onPreviousRecordingFinal: ((LiveLine) -> Void)?
  var voiceSource: (() -> String?)?
  var onVoice: ((String, String, Data, Double) -> Void)?
  var draftVoiceIsUsable: ((String) -> Bool)?
  var onDraftVoice: ((String, String, Data, Double) -> Void)?
  private var sessions: [UUID: Session] = [:]
  private struct ClosingRecording {
    let stream: LiveASRStreaming
    let segment: Int
    let end: Date
    let retiredSentence: Int
    let replayAudio: Data
    var fileReviewFrom: Int?
    var lines: [Int: LiveLine]
    let timeout: Task<Void, Never>
  }
  private var closing: [UUID: ClosingRecording] = [:]
  private var active: UUID?
  private var sequence = 0
  private var configuration: LiveASRConfiguration?
  private var enabled = false
  private var failures = 0
  private var recoverable = true
  private var retryAfter = Date.distantPast
  private var unsentAudio = Data()
  private var unsentEnd: Int?
  private var timer: Timer?
  private var waitingMessage = "等待设备音频，收到后即开始识别。"
  private let input: CaptionAudioInput
  private var packetBytes: Int { input.packetBytes }
  private var bytesPerMs: Double { Double(input.bytesPerSecond) / 1000 }
  private let clock: () -> Date
  private let makeStream: @MainActor (LiveASRConfiguration) throws -> LiveASRStreaming
  private let makeLocalStream: (@MainActor () throws -> LiveASRStreaming)?
  var isWorking: Bool { phase == .connecting || phase == .recognizing || phase == .finishing }
  var canRetry: Bool { phase == .failed }
  var receivedSeconds: Double { Double(receivedBytes) / Double(input.bytesPerSecond) }

  init(
    input: CaptionAudioInput = .cardOpus,
    clock: @escaping () -> Date = Date.init,
    makeLocalStream: (@MainActor () throws -> LiveASRStreaming)? = nil,
    makeStream: @escaping @MainActor (LiveASRConfiguration) throws -> LiveASRStreaming = {
      try QwenLiveConnection(configuration: $0)
    }
  ) {
    self.input = input
    self.makeLocalStream = makeLocalStream
    self.clock = clock
    self.makeStream = makeStream
  }
  static func local(input: CaptionAudioInput) -> LivePreview {
    LivePreview(input: input, makeLocalStream: {
      if #available(macOS 26, *) { return AppleCaptionConnection(input: input) }
      return try DictationCaptionConnection(input: input)
    })
  }

  func configure(enabled: Bool, service: AIService?, model: LiveASRModel = .streaming) {
    let config = service.map { LiveASRConfiguration(key: $0.key, model: model) }
    guard self.enabled != enabled || configuration != config else { return }
    // An open socket owns its model until it has delivered the tail of its sentence.
    if self.enabled == enabled, let config, let current = configuration,
       config.key == current.key {
      configuration = config
      if phase == .failed { retry() }
      return
    }
    for id in Array(closing.keys) { releaseClosing(id) }
    stopStreams()
    clearUnsentAudio()
    self.enabled = enabled
    configuration = config
    failures = 0
    recoverable = true
    retryAfter = .distantPast
    phase = enabled && (makeLocalStream != nil || config != nil) ? .waiting : .disabled
    if !enabled { status = makeLocalStream == nil ? "云端实时识别已关闭。" : "本机字幕已关闭。" }
    else { status = config == nil && makeLocalStream == nil ? "请在设置中保存 ESP API Key。" : waitingMessage }
  }
  private var streamByteLimit: Int {
    if makeLocalStream != nil {
      if #unavailable(macOS 26) { return 50 * input.bytesPerSecond }
    }
    return 600 * input.bytesPerSecond
  }
  func append(_ data: Data, recordingOffset: Int? = nil) {
    guard enabled, makeLocalStream != nil || configuration != nil, !data.isEmpty else { return }
    let now = clock()
    if !feedbackPaused, let previous = lastAudioAt, now.timeIntervalSince(previous) >= 1.5 {
      resetActivity()
    }
    lastAudioAt = now
    receivedBytes += data.count
    let offset = recordingOffset ?? receivedBytes - data.count
    if makeLocalStream != nil, !feedbackPaused {
      if activity == nil {
        let generation = activityGeneration
        activity = CardSpeechActivity(input: self.input, onEvent: { [weak self] event in
          guard let self, self.activityGeneration == generation else { return }
          self.receiveActivity(event)
        }, onConfirmedPause: { [weak self] quiet in
          guard let self, self.activityGeneration == generation else { return true }
          return self.finishAtPause(quiet)
        })
      }
      activity?.append(data, offset: offset)
    }
    if timer == nil {
      timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.tick() }
      }
    }
    // BLE chunks can end inside a 40-byte Opus packet. Finish that packet on
    // its original decoder before handing the remaining bytes to the next one.
    var input = data
    var inputOffset = offset
    if let active, let session = sessions[active], session.finishAfterPacket || session.bytes >= streamByteLimit {
      let needed = (packetBytes - session.bytes % packetBytes) % packetBytes
      let tail = min(needed, input.count)
      if tail > 0 {
        appendToActive(input.prefix(tail))
        input = input.dropFirst(tail)
        inputOffset += tail
      }
      if tail == needed { finishActive() }
      if input.isEmpty { return }
    }
    if active == nil {
      guard recoverable, clock() >= retryAfter else {
        if !hasGap { hasGap = true }
        if recoverable { retainUnsent(input, at: inputOffset) }
        return
      }
      while sessions.count >= 2 {
        guard let oldest = sessions.min(by: { $0.value.index < $1.value.index })?.key else { break }
        sessions.removeValue(forKey: oldest)?.stream.cancel()
        hasGap = true
      }
      do {
        if unsentEnd == inputOffset {
          inputOffset -= unsentAudio.count
          input = unsentAudio + input
          let skip = min(input.count, (packetBytes - inputOffset % packetBytes) % packetBytes)
          input = input.dropFirst(skip)
          inputOffset += skip
          if input.isEmpty {
            unsentAudio = Data()
            unsentEnd = inputOffset
            return
          }
        }
        clearUnsentAudio()
        let id = UUID()
        let stream: LiveASRStreaming
        if let makeLocalStream { stream = try makeLocalStream() }
        else if let configuration { stream = try makeStream(configuration) }
        else { return }
        let index = sequence
        sequence += 1
        sessions[id] = Session(stream: stream, index: index, recordingOffset: inputOffset, sourceName: voiceSource?(),
                               fileReviewFrom: collectForFileReview ? 0 : nil)
        active = id
        phase = .connecting
        status = makeLocalStream == nil ? "已收到音频，正在连接实时识别…" : "正在准备苹果本地中文识别…"
        stream.onEvent = { [weak self] event in self?.receive(event, id: id) }
        stream.start()
        if active != id, recoverable { retainUnsent(input, at: inputOffset) }
      } catch {
        retainUnsent(input, at: inputOffset)
        fail(error.localizedDescription)
        return
      }
    }
    appendToActive(input)
  }
  // During a local recognizer restart retain only audio never submitted to it.
  // Overlapping an already submitted range could duplicate a short answer.
  private func retainUnsent(_ data: Data, at offset: Int) {
    guard makeLocalStream != nil else { return }
    if unsentEnd != offset { clearUnsentAudio() }
    unsentAudio.append(data)
    let end = offset + data.count
    unsentEnd = end
    let start = end - unsentAudio.count
    let earliest = max(start, end - 6 * input.bytesPerSecond)
    let aligned = ((earliest + packetBytes - 1) / packetBytes) * packetBytes
    unsentAudio.removeFirst(min(unsentAudio.count, aligned - start))
  }
  private func clearUnsentAudio() {
    unsentAudio = Data()
    unsentEnd = nil
  }
  private func appendToActive(_ data: Data) {
    guard let id = active, let stream = sessions[id]?.stream else { return }
    if onVoice != nil || onDraftVoice != nil || cacheCaptionAudio {
      if sessions[id]?.sourceName == nil { sessions[id]?.sourceName = voiceSource?() }
      sessions[id]?.packets.append(data)
      // Prune whole packets in batches, keeping at least two minutes of trailing audio.
      // For replay, keep the entire bounded recognizer session until its last final.
      if !cacheCaptionAudio, let size = sessions[id]?.packets.count, size > 260_000 {
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
      if makeLocalStream != nil { drainPreviousRecording() }
      clearCurrentRecording(message: "设备已开始录音，等待音频后即开始识别。")
    case .resumed:
      clearUnsentAudio()
      feedbackPaused = false
      waitingMessage = "设备已继续录音，等待新的音频。"
      if active == nil, sessions.isEmpty, phase != .failed { showWaiting() }
    case .paused, .saving, .ended:
      resetActivity()
      feedbackPaused = true
      switch boundary {
      case .paused: waitingMessage = "设备已暂停，已识别的文字保留。"
      case .saving: waitingMessage = "设备正在保存，已识别的文字保留。"
      default: waitingMessage = "本次录音已结束，已识别的文字保留。"
      }
      // Keep accepting the hardware tail until actual audio stops arriving.
      if active == nil, sessions.isEmpty, phase != .failed { showWaiting() }
    case .disconnected:
      clearUnsentAudio()
      resetActivity()
      waitingMessage = "设备已断开，已识别的文字保留；重连收到音频后继续。"
      finishActive()
      if sessions.isEmpty, phase != .failed { showWaiting() }
    case .corrupted:
      clearUnsentAudio()
      resetActivity()
      hasGap = true
      waitingMessage = "音频接收出现缺口，等待后续音频；完整内容请在同步录音后查看。"
      finishActive()
      if sessions.isEmpty, phase != .failed { showWaiting() }
    }
  }
  func tick() {
    let now = clock()
    if let pending = pendingSpeech {
      let lastSound = speechEndedAt ?? lastAudioAt
      if let lastSound, now.timeIntervalSince(lastSound) >= 5 {
        pendingSpeech = nil
      } else if !pending.delayed, now.timeIntervalSince(pending.startedAt) >= 2 {
        pendingSpeech?.delayed = true
      }
    }
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
    for id in Array(closing.keys) { releaseClosing(id) }
    clearCurrentRecording(message: message)
  }
  private func clearCurrentRecording(message: String) {
    stopStreams()
    clearUnsentAudio()
    textThroughOffset = -1
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
    resetActivity()
    active = nil
    let old = sessions
    sessions = [:]
    for value in old.values { value.stream.cancel() }
    timer?.invalidate()
    timer = nil
  }
  private func resetActivity() {
    activityGeneration += 1
    if let activity {
      let previous = activityDrain
      let worker = activity.cancel()
      activityDrain = Task { await previous?.value; await worker.value }
      self.activity = nil
    }
    feedbackPaused = false
    speechEndedAt = nil
    if pendingSpeech != nil { pendingSpeech = nil }
  }
  func waitForSpeechActivityToStop() async { await activityDrain?.value }
  private func finishAtPause(_ quiet: Range<Int>) -> Bool {
    guard let active, let session = sessions[active],
          quiet.lowerBound >= session.recordingOffset else { return true }
    // A queued VAD result must not close a stream that already contains new
    // speech. Wait until every complete packet currently held has been checked.
    let completeEnd = session.recordingOffset + session.bytes / packetBytes * packetBytes
    guard quiet.upperBound >= completeEnd, sessions.count == 1 else { return false }
    if session.bytes.isMultiple(of: packetBytes) { finishActive() }
    else { sessions[active]?.finishAfterPacket = true }
    return true
  }

  func isAwaitingFinal(_ lineID: String) -> Bool {
    if let line = lines.first(where: { $0.id == lineID }),
       sessions.values.contains(where: { $0.index == line.segment }) { return !line.isFinal }
    return closing.values.contains { recording in
      recording.lines.values.contains { $0.id == lineID && !$0.isFinal }
    }
  }
  private func receiveActivity(_ event: CardSpeechActivity.Event) {
    switch event {
    case .began(let offset):
      speechEndedAt = nil
      guard offset > textThroughOffset else { return }
      pendingIDAssigned = false
      pendingSpeech = PendingCaption(offset: offset, startedAt: clock())
    case .ended:
      speechEndedAt = clock()
    }
  }

  // Keep local recognizers alive just long enough to commit their final revisions
  // to the previous recording. They no longer publish into the active feed.
  private func drainPreviousRecording() {
    for (id, session) in sessions.sorted(by: { $0.value.index < $1.value.index }) {
      if closing.count >= 2, let oldest = closing.min(by: { $0.value.segment < $1.value.segment }) {
        releaseClosing(oldest.key)
      }
      let oldLines = lines.filter { $0.segment == session.index }
      let timeout = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(20)) } catch { return }
        self?.releaseClosing(id)
      }
      closing[id] = ClosingRecording(stream: session.stream, segment: session.index, end: lastAudioAt ?? clock(),
        retiredSentence: session.retiredSentence,
        replayAudio: cacheCaptionAudio ? session.packets : Data(),
        fileReviewFrom: session.fileReviewFrom,
        lines: Dictionary(uniqueKeysWithValues: oldLines.map { ($0.sentence, $0) }), timeout: timeout)
      sessions.removeValue(forKey: id)
      if active == id { active = nil; session.stream.finish() }
    }
  }
  private func releaseClosing(_ id: UUID) {
    guard let old = closing.removeValue(forKey: id) else { return }
    old.timeout.cancel()
    old.stream.cancel()
  }
  private func receiveClosing(_ event: ASREvent, id: UUID) {
    guard let old = closing[id] else { return }
    switch event {
    case .sentence(let number, let text, true, let start, let end, let words):
      guard number >= 0, number > old.retiredSentence, text.count <= 16_000 else { return }
      let previous = old.lines[number]
      let replay = CaptionReplay(audio: old.replayAudio, startMs: start ?? words?.first?.startMs,
                                 endMs: end ?? words?.last?.endMs)
      if previous?.isFinal == true && previous?.text == text && previous?.replay == replay { return }
      var line = LiveLine(id: previous?.id ?? "\(id.uuidString):\(number)", segment: old.segment,
        sentence: number, text: text, isFinal: true, textSource: makeLocalStream == nil ? .cloud : .local,
        receivedAt: previous?.receivedAt ?? old.end, replay: replay)
      if let replay, let first = old.fileReviewFrom { line.fileReviewEligible = replay.frames.sessionStart >= first * 8 }
      closing[id]?.lines[number] = line
      onPreviousRecordingFinal?(line)
    case .finished, .failed: releaseClosing(id)
    default: break
    }
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
    status = phase == .waiting ? waitingMessage
      : (makeLocalStream == nil ? "云端实时识别尚未开启或未配置。" : "本机字幕已关闭。")
  }
  private func receive(_ event: ASREvent, id: UUID) {
    guard let session = sessions[id] else { receiveClosing(event, id: id); return }
    switch event {
    case .started:
      if active == id {
        phase = .recognizing
        status = "正在实时识别，文字随讲话更新。"
      }
    case .sentence(let number, let text, let isFinal, let start, let end, let words):
      guard number >= 0, number > session.retiredSentence, text.count <= 16_000 else { return }
      let index = lines.firstIndex { $0.segment == session.index && $0.sentence == number }
      let previous = index.map { lines[$0] }
      guard previous?.isFinal != true || isFinal else { return }
      let endTime = end ?? words?.last?.endMs
      let textEnd: Int? = endTime.flatMap { ms in
        guard ms.isFinite, ms >= 0, ms <= Double(session.bytes) / bytesPerMs + 1 else { return nil }
        return session.recordingOffset + Int(ms * bytesPerMs)
      }
      let spoken = LiveLine.containsSpeech(text)
      let coversPending = pendingSpeech.map { pending in
        spoken && session.recordingOffset + session.bytes >= pending.offset
          && (textEnd.map { $0 >= pending.offset } ?? (active == id && previous == nil))
      } ?? false
      let lineID: String
      if let previous {
        lineID = previous.id
      } else if coversPending, let pending = pendingSpeech, !pendingIDAssigned {
        // The feedback stays visible until words are ready, but only one sentence can inherit its ID.
        lineID = pending.id
        pendingIDAssigned = true
      } else {
        lineID = "\(id.uuidString):\(number)"
      }
      var line = LiveLine(
        id: lineID, segment: session.index, sentence: number, text: text, isFinal: isFinal,
        textSource: makeLocalStream == nil ? .cloud : .local)
      line.bubblePhrase = (session.stream as? AppleBubbleStreaming)?.bubblePhrase(for: number)
      if let start = start ?? words?.first?.startMs, start.isFinite, start >= 0,
         let end = textEnd, start < Double(session.bytes) / bytesPerMs + 1 {
        let begin = session.recordingOffset + Int(start * bytesPerMs)
        if begin < end { line.recognitionRange = begin..<end }
      }
      if makeLocalStream == nil, spoken || previous != nil {
        var draft = session.cloudDrafts[number] ?? .init()
        draft.update(text: text, final: isFinal)
        line.stableCloudText = draft.text
        sessions[id]?.cloudDrafts[number] = isFinal ? nil : draft
      }
      line.receivedAt = previous?.receivedAt ?? clock()
      if spoken {
        let through = textEnd ?? session.recordingOffset + session.bytes
        textThroughOffset = max(textThroughOffset, through)
      }
      let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      let acceptsLine = previous != nil || isFinal || hasText
      if isFinal, let start = start ?? words?.first?.startMs, let end = end ?? words?.last?.endMs,
        start >= 0, end > start, end <= Double(session.bytes) / bytesPerMs + 1 {
        let lower = session.recordingOffset + Int(start * bytesPerMs)
        let upper = session.recordingOffset + Int(end * bytesPerMs)
        line.recordingRange = lower..<upper
        if cacheCaptionAudio && spoken {
          line.replay = CaptionReplay(audio: session.packets, startMs: start, endMs: end)
          if let replay = line.replay, let first = session.fileReviewFrom {
            line.fileReviewEligible = replay.frames.sessionStart >= first * 8
          }
        }
      }
      var evidence: (Data, Double)?
      var draftPackets: Data?
      if onVoice != nil || onDraftVoice != nil, spoken, let start = start ?? words?.first?.startMs, let end = endTime,
         start.isFinite, end.isFinite, start >= 0, end > start, end <= Double(session.bytes) / bytesPerMs + 1 {
        let lower = Int(ceil(start / 20)) * 40
        let upper = Int(floor(end / 20)) * 40
        if SpeakerEncoder.acceptsLivePacketCount(upper - lower), lower >= session.firstByte,
           upper - session.firstByte <= session.packets.count {
          let range = lower..<upper
          let base = session.packets.startIndex - session.firstByte
          let old = previous?.draftVoice
          let text = line.bubblePhrase?.text ?? line.text
          if isFinal, onVoice != nil {
            line.voiceRange = range
            if let old, old.range == range, draftVoiceIsUsable?(old.id) == true {
              line.voiceID = old.id
              line.draftVoice = old
              line.voicePackets = old.packets
            } else {
              line.voiceID = "live:" + lineID
              line.voicePackets = session.packets.subdata(in: base + lower..<base + upper)
            }
            if let packets = line.voicePackets { evidence = (packets, Double(range.count) / 2000) }
          } else if !isFinal, onDraftVoice != nil, LiveLine.containsSpeech(text) {
            // Keep the verified packet window immutable while the same utterance grows.
            if let old, old.range.lowerBound == lower, old.range.upperBound <= upper,
               upper - old.range.upperBound < 2000 || draftVoiceIsUsable?(old.id) == true {
              line.draftVoice = old
            } else {
              let packets = session.packets.subdata(in: base + lower..<base + upper)
              line.draftVoice = .init(id: "draft:\(lineID):\(lower)-\(upper)", range: range, packets: packets)
              draftPackets = packets
            }
          }
        }
      }
      if let old = previous, old.isFinal, isFinal {
        // A revised text for the same time span can reuse its evidence. If
        // a final moves the boundaries, never attach the previous person's voice.
        if let range = old.voiceRange, range != line.voiceRange {
          line.voiceID = nil
          line.voicePackets = nil
          line.draftVoice = nil
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
          if let owner = sessions.first(where: { $0.value.index == retired.segment })?.key {
            let floor = max(sessions[owner]?.retiredSentence ?? -1, retired.sentence)
            sessions[owner]?.retiredSentence = floor
            sessions[owner]?.cloudDrafts.removeValue(forKey: retired.sentence)
          }
        }
        lines = updated
        changed = true
      }
      if coversPending && (line.bubblePhrase?.text.isEmpty != true || isFinal) { pendingSpeech = nil }
      lastTextAt = clock()
      failures = 0
      if active == id {
        phase = .recognizing
        status = "正在实时识别 · 浅色文字仍可能修订"
      }
      if changed, let draft = line.draftVoice, let draftPackets {
        onDraftVoice?(draft.id, VoiceRecognition.source(session.sourceName, fallback: id.uuidString),
                      draftPackets, Double(draft.range.count) / 2000)
      }
      if changed, let voiceID = line.voiceID, let (packets, seconds) = evidence {
        let source = VoiceRecognition.source(session.sourceName, fallback: id.uuidString)
        onVoice?(voiceID, source, packets, seconds)
      }
      if changed { onLineChanged?(line) }
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
