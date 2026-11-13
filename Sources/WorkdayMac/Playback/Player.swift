import AVFoundation
import Combine
import Foundation
import WorkdayCore

@MainActor final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
  @Published private(set) var excerptRate: Float = 1

  func setExcerptRate(_ rate: Float) {
    excerptRate = rate
    if selectionID?.hasPrefix("excerpt:") == true { engine?.rate = rate }
  }

  @Published var title = ""
  @Published var position: Double = 0
  @Published var duration: Double = 0
  @Published var playing = false
  @Published var error: String?
  @Published var selectionID: String?
  private(set) var recordingID: String?
  private(set) var sourceOffset: Double = 0
  private(set) var url: URL?
  private(set) var route: DayAudioTimeline?
  private(set) var spanIndex = 0
  private var sources: [String: URL] = [:]
  private var engine: AVAudioPlayer?
  private var timer: Timer?
  private(set) var playbackRange: ClosedRange<Double>?
  private var captionLoad: Task<Void, Never>?
  private(set) var captionID: String?
  private(set) var captionFrames: CaptionReplay.Frames?
  private var captionExpiresAt: Date?
  var sourcePosition: Double { position + sourceOffset }
  func isAt(_ recordingID: String, from start: Double, to end: Double) -> Bool {
    // Wall-clock conversion can put a seek just below the original sample boundary.
    let position = sourcePosition + 0.000_001
    return self.recordingID == recordingID && start <= position && position < end
  }

  var heardDuration: Double {
    guard let route else { return 0 }
    let span = route.spans[spanIndex]
    return route.spans.prefix(spanIndex).reduce(0) { $0 + $1.duration }
      + max(0, min(span.duration, position - span.sourceStart))
  }
  var dayClock: Double {
    guard let span = route?.spans[spanIndex] else { return 0 }
    return span.clockStart + max(0, min(span.duration, position - span.sourceStart))
  }

  var dayEnded: Bool {
    guard !playing, error == nil, let last = route?.spans.last else { return false }
    return dayClock >= last.clockEnd - 0.001
  }

  func load(
    url: URL, id: String, recordingID: String, title: String, sourceOffset: Double = 0,
    position: Double = 0, autoplay: Bool = false, playbackRange: ClosedRange<Double>? = nil
  ) {
    route = nil
    sources.removeAll()
    open(
      url, id: id, recordingID: recordingID, title: title, base: sourceOffset,
      offset: position, range: playbackRange, autoplay: autoplay)
  }

  func startDay(
    _ timeline: DayAudioTimeline, recordings: [Recording], root: URL,
    clock: Double? = nil, autoplay: Bool = true
  ) {
    guard let location = timeline.locate(clock: clock ?? 0) else { return }
    route = timeline
    sources = Dictionary(
      uniqueKeysWithValues: recordings.map {
        ($0.id, root.appendingPathComponent($0.folder).appendingPathComponent($0.originalFile))
      })
    openSpan(location.index, at: location.offset, autoplay: autoplay)
  }

  func playCaption(_ record: CaptionRecord, title: String, audio: @escaping @MainActor () async throws -> Data) {
    let id = record.id
    let expiresAt = record.time.addingTimeInterval(CaptionWindow.duration)
    guard Date() <= expiresAt else { return }
    if captionID == id, captionFrames == record.replay, error == nil {
      if engine != nil { toggle(); return }
      if captionLoad != nil { return }
    }
    stop()
    error = nil
    captionID = id
    captionFrames = record.replay
    captionExpiresAt = expiresAt
    selectionID = "caption:" + id
    self.title = title
    captionLoad = Task { [weak self] in
      defer { if !Task.isCancelled { self?.captionLoad = nil } }
      do {
        let wav = try await audio()
        try Task.checkCancellation()
        guard let self, captionID == id else { return }
        guard Date() <= expiresAt else { stop(); return }
        try prepare(AVAudioPlayer(data: wav))
        beginPlaying()
      } catch {
        guard !Task.isCancelled, let self, captionID == id else { return }
        self.error = error.localizedDescription
      }
    }
  }

  func seekDay(_ clock: Double) {
    guard let location = route?.locate(clock: clock) else { return }
    openSpan(location.index, at: location.offset, autoplay: playing)
  }

  func step(_ direction: Int) {
    guard let route, route.spans.indices.contains(spanIndex + direction) else { return }
    openSpan(spanIndex + direction, autoplay: playing)
  }

  private func openSpan(_ index: Int, at offset: Double? = nil, autoplay: Bool) {
    guard let route else { return }
    let span = route.spans[index]
    guard let url = sources[span.recordingID] else { return }
    spanIndex = index
    open(
      url, id: span.id, recordingID: span.recordingID, title: "全天回听", base: 0,
      offset: offset ?? span.sourceStart, range: span.sourceStart...span.sourceEnd,
      autoplay: autoplay && (offset ?? span.sourceStart) < span.sourceEnd)
  }

  private func open(
    _ file: URL, id: String, recordingID: String, title: String, base: Double,
    offset: Double, range: ClosedRange<Double>?, autoplay: Bool
  ) {
    let reuse = engine != nil && url == file
    if !reuse { releaseEngine() }
    selectionID = id
    self.recordingID = recordingID
    self.title = title
    sourceOffset = base
    playbackRange = range
    error = nil
    do {
      if !reuse {
        try prepare(AVAudioPlayer(contentsOf: file))
        url = file
      }
      engine?.pause()
      let excerpt = id.hasPrefix("excerpt:")
      engine?.enableRate = excerpt
      if excerpt { engine?.rate = excerptRate }
      playing = false
      seek(offset)
      if autoplay { beginPlaying() }
    } catch {
      releaseEngine()
      self.error = "音频暂时无法播放：\(error.localizedDescription)"
    }
  }

  private func prepare(_ next: AVAudioPlayer) throws {
    guard next.prepareToPlay() else { throw WorkdayError.invalid("无法打开音频设备") }
    next.delegate = self
    engine = next
    duration = next.duration
    let clock = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    // Enforce the playback boundary while a slider or a menu tracks the pointer.
    RunLoop.main.add(clock, forMode: .common)
    timer = clock
  }

  private func beginPlaying() {
    playing = engine?.play() == true
    if !playing { error = "播放未能开始，请检查音频输出后重试。" }
  }

  private func tick() {
    if let captionExpiresAt, Date() > captionExpiresAt { stop(); return }
    guard playing, let engine else { return }
    if let range = playbackRange, engine.currentTime >= range.upperBound {
      if let route, spanIndex + 1 < route.spans.count, engine.isPlaying {
        let next = route.spans[spanIndex + 1]
        if next.recordingID == recordingID && abs(next.sourceStart - range.upperBound) < 0.0001 {
          spanIndex += 1
          selectionID = next.id
          playbackRange = next.sourceStart...next.sourceEnd
          position = engine.currentTime
          return
        }
      }
      finish()
    } else if engine.isPlaying {
      position = engine.currentTime
    }
  }

  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    Task { @MainActor [weak self] in
      guard let self, self.engine === player, self.playing, !player.isPlaying else { return }
      if flag {
        self.finish()
      } else {
        self.playing = false
        self.error = "音频播放中断，可重新播放。"
      }
    }
  }

  private func finish() {
    if let route, spanIndex + 1 < route.spans.count {
      openSpan(spanIndex + 1, autoplay: true)
    } else {
      engine?.pause()
      seek(playbackRange?.upperBound ?? duration)
      playing = false
    }
  }

  func toggle() {
    if playing {
      engine?.pause()
      playing = false
    } else if let route, engine == nil || dayClock >= (route.spans.last?.clockEnd ?? 0) - 0.001 {
      openSpan(engine == nil ? spanIndex : 0, autoplay: true)
    } else if engine != nil {
      if position >= (playbackRange?.upperBound ?? duration) - 0.001 {
        seek(playbackRange?.lowerBound ?? 0)
      }
      beginPlaying()
    }
  }

  func seek(_ value: Double) {
    guard value.isFinite else { return }
    let limit = min(duration, playbackRange?.upperBound ?? duration)
    let target = min(limit, max(playbackRange?.lowerBound ?? 0, value))
    engine?.currentTime = target
    position = target
  }

  private func releaseEngine() {
    captionLoad?.cancel()
    captionLoad = nil
    captionID = nil
    captionFrames = nil
    captionExpiresAt = nil
    engine?.delegate = nil
    engine?.stop()
    engine = nil
    timer?.invalidate()
    timer = nil
    playing = false
    url = nil
    position = 0
    duration = 0
  }

  func stop() {
    releaseEngine()
    route = nil
    sources.removeAll()
    spanIndex = 0
    playbackRange = nil
    sourceOffset = 0
    selectionID = nil
    recordingID = nil
    title = ""
  }
}
