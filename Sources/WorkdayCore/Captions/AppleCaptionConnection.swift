import AVFoundation
import Foundation
import QS668Core
import Speech

@available(macOS 26.0, *)
@MainActor public final class AppleCaptionConnection: AppleBubbleStreaming {
  public var onEvent: ((ASREvent) -> Void)?
  private let input = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(2048))
  private var run: Task<Void, Never>?
  private var analyzer: SpeechAnalyzer?
  private var bufferedBytes = 0
  private var closed = false
  private var phrases = AppleCaptionPhrases()
  public func bubblePhrase(for sentence: Int) -> AppleBubblePhrase? { phrases.bubblePhrases[sentence] }
  private let audioInput: CaptionAudioInput
  public init(input: CaptionAudioInput = .cardOpus) { audioInput = input }

  public func start() {
    guard run == nil, !closed else { return }
    run = Task { [weak self] in
      guard let self else { return }
      do {
        guard SpeechTranscriber.isAvailable,
          let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN"))
        else { throw WorkdayError.invalid("此 Mac 的苹果语音模型不支持本地中文转写") }
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [],
          reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
          try await install.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
          throw WorkdayError.invalid("无法取得苹果本地识别的音频格式")
        }
        let decoder = try InputDecoder(input: audioInput, format: format)
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        onEvent?(.started)
        // The analyzer consumes card audio and returns timed, replaceable word ranges independently.
        async let read: Void = receive(module, decoder: decoder)
        let buffers = input.stream.compactMap { data -> AnalyzerInput? in
          await self.consumed(data.count)
          return try await decoder.input(for: data)
        }
        if let end = try await analyzer.analyzeSequence(buffers) {
          try await analyzer.finalizeAndFinish(through: end)
        } else {
          await analyzer.cancelAndFinishNow()
        }
        try await read
        if !closed { closed = true; onEvent?(.finished) }
      } catch {
        if !closed && !Task.isCancelled {
          closed = true
          onEvent?(.failed(code: "local-speech", message: error.localizedDescription))
        }
      }
      if let analyzer { await analyzer.cancelAndFinishNow() }
      analyzer = nil
      input.continuation.finish()
      run = nil
    }
  }

  private actor InputDecoder {
    private let decoder: CaptionAudioDecoder
    private let packetBytes: Int
    private var remainder = Data()
    private var pauses = CaptionAudioPauses()
    var boundaries: [Double] { pauses.boundaries }
    init(input: CaptionAudioInput, format: AVAudioFormat) throws {
      packetBytes = input.packetBytes
      decoder = try CaptionAudioDecoder(input: input, outputFormat: format)
    }

    func input(for data: Data) throws -> AnalyzerInput? {
      remainder.append(data)
      let bytes = remainder.count / packetBytes * packetBytes
      guard bytes > 0 else { return nil }
      let buffer = try decoder.decode(remainder.prefix(bytes))
      remainder.removeFirst(bytes)
      pauses.append(buffer)
      return buffer.frameLength > 0 ? AnalyzerInput(buffer: buffer) : nil
    }
  }

  private func receive(_ module: SpeechTranscriber, decoder: InputDecoder) async throws {
    for try await result in module.results {
      try Task.checkCancellation()
      let text = result.text
      var words: [ASRWord] = []
      for (range, characters) in text.runs[\.audioTimeRange] {
        let value = String(text[characters].characters)
        if let range {
          words.append(ASRWord(text: value, startMs: range.start.seconds * 1000,
                               endMs: range.end.seconds * 1000))
        } else if let last = words.popLast() {
          words.append(ASRWord(text: last.text + value, startMs: last.startMs, endMs: last.endMs))
        } else {
          let start = result.range.start.seconds * 1000
          words.append(ASRWord(text: value, startMs: start, endMs: start))
        }
      }
      if !text.characters.isEmpty, !text.runs.contains(where: { $0.audioTimeRange != nil }) {
        words = [ASRWord(text: String(text.characters), startMs: result.range.start.seconds * 1000,
                         endMs: result.range.end.seconds * 1000)]
      }
      let range = result.range.start.seconds * 1000..<result.range.end.seconds * 1000
      let events = phrases.update(words, final: result.isFinal, pauses: await decoder.boundaries,
                                  replacing: range, finalizedThrough: result.resultsFinalizationTime.seconds * 1000)
      for event in events where !closed { onEvent?(event) }
    }
    for event in phrases.finish() where !closed { onEvent?(event) }
  }

  private func consumed(_ count: Int) { bufferedBytes -= count }

  public func append(_ data: Data) {
    guard !closed, !data.isEmpty else { return }
    bufferedBytes += data.count
    // Bound the backlog while a model loads. Mark overload explicitly so the next
    // session starts with a clean decoder and an accurate audio timeline.
    if bufferedBytes <= 120 * audioInput.bytesPerSecond, case .enqueued = input.continuation.yield(data) { return }
    cancel()
    onEvent?(.failed(code: "local-speech", message: "苹果字幕处理积压，正在重新连接本地识别"))
  }

  public func finish() { input.continuation.finish() }

  public func cancel() {
    closed = true
    run?.cancel()
    input.continuation.finish()
    if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
  }
}
