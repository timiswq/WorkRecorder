import AVFoundation
import Foundation
import QS668Core
import Speech

/// On macOS 14–15 the dictation API supports on-device recognition on compatible Macs.
@MainActor public final class DictationCaptionConnection: AppleBubbleStreaming {
  public var onEvent: ((ASREvent) -> Void)?
  private let recognizer: SFSpeechRecognizer
  private let decoder: CaptionAudioDecoder
  private let audioInput: CaptionAudioInput
  private let request = SFSpeechAudioBufferRecognitionRequest()
  private var task: SFSpeechRecognitionTask?
  private var phrases = AppleCaptionPhrases()
  public func bubblePhrase(for sentence: Int) -> AppleBubblePhrase? { phrases.bubblePhrases[sentence] }
  private var remainder = Data()
  private var pauses = CaptionAudioPauses()
  private var waitingBytes = 0
  private var closed = false

  public init(input: CaptionAudioInput = .cardOpus) throws {
    audioInput = input
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
      recognizer.supportsOnDeviceRecognition, recognizer.isAvailable,
      let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)
    else { throw WorkdayError.invalid("此 Mac 的本地中文听写不可用，请检查系统听写语言") }
    self.recognizer = recognizer
    decoder = try CaptionAudioDecoder(input: input, outputFormat: format)
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    request.addsPunctuation = true
  }

  public func start() {
    SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
      Task { @MainActor in
        guard let self, !self.closed else { return }
        guard authorization == .authorized else {
          self.fail("请在系统设置的「隐私与安全性 → 语音识别」允许工作留声使用本地听写")
          return
        }
        self.onEvent?(.started)
        self.task = self.recognizer.recognitionTask(with: self.request) { [weak self] result, error in
          Task { @MainActor in
            guard let self, !self.closed else { return }
            if let result {
              let transcription = result.bestTranscription
              let string = transcription.formattedString as NSString
              let segments = transcription.segments
              let words = segments.enumerated().map { index, segment in
                let start = index == 0 ? 0 : segment.substringRange.location
                let end = index + 1 < segments.count ? segments[index + 1].substringRange.location : string.length
                let text = string.substring(with: NSRange(location: start, length: end - start))
                return ASRWord(text: text, startMs: segment.timestamp * 1000,
                               endMs: (segment.timestamp + segment.duration) * 1000)
              }
              for event in self.phrases.update(words, final: result.isFinal, pauses: self.pauses.boundaries) { self.onEvent?(event) }
              if result.isFinal {
                for event in self.phrases.finish() { self.onEvent?(event) }
                self.closed = true
                self.onEvent?(.finished)
                return
              }
            }
            if let error { self.fail(error.localizedDescription) }
          }
        }
      }
    }
  }

  public func append(_ data: Data) {
    guard !closed else { return }
    if task == nil {
      waitingBytes += data.count
      guard waitingBytes <= 60 * audioInput.bytesPerSecond else { fail("本地听写授权等待超时"); return }
    }
    remainder.append(data)
    let count = remainder.count / audioInput.packetBytes * audioInput.packetBytes
    guard count > 0 else { return }
    do {
      let pcm = try decoder.decode(remainder.prefix(count))
      remainder.removeFirst(count)
      if pcm.frameLength > 0 {
        pauses.append(pcm)
        request.append(pcm)
      }
    } catch { fail(error.localizedDescription) }
  }
  public func finish() { request.endAudio() }
  public func cancel() {
    closed = true
    task?.cancel()
    task = nil
    request.endAudio()
  }
  private func fail(_ message: String) {
    cancel()
    onEvent?(.failed(code: "local-speech", message: message))
  }
}
