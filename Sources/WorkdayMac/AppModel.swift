import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WorkdayCore

enum Destination: String, CaseIterable {
  case current = "当前"
  case history = "历史"
  case settings = "设置"
  var icon: String {
    switch self {
    case .current: return "waveform"
    case .history: return "clock.arrow.circlepath"
    case .settings: return "slider.horizontal.3"
    }
  }
}

@MainActor final class AppModel: ObservableObject {
  @Published var destination: Destination = .current
  @Published var preferences: Preferences {
    didSet {
      if !isolated { preferences.save() }
      applyPreferences()
    }
  }
  @Published var recordings: [Recording] = [] { didSet { cachedDays.removeAll(); fingerprints.removeAll() } }
  @Published var documents: [String: ProcessingDocument] = [:] { didSet { cachedDays.removeAll(); fingerprints.removeAll() } }
  @Published var summaries: [String: DaySummary] = [:] { didSet { cachedDays.removeAll() } }
  @Published var selectedDay: String? = WorkdayDate.day(Date())
  @Published var libraryTab: LibraryTab = .originals
  @Published var libraryRecordingID: String?
  @Published var area: WorkspaceArea = .day
  private var cachedDays: [String: DayWorkspace] = [:]
  private var fingerprints: [String: String] = [:]
  @Published var selectedDetail: RecordDetailSelection?
  @Published var settingsSection: SettingsSection = .device
  @Published var settingsRequest = UUID()
  @Published var summaryErrors: [String: String] = [:]
  @Published var showsLiveText = true
  private var daySelections: [String: RecordDetailSelection] = [:]
  var importLabel: String? { sync.label }
  private(set) var sync: SyncCoordinator
  @Published private(set) var manualSyncVolumes = Set<String>()
  @Published var processingID: String?
  @Published var processingLabel: String?
  @Published private(set) var queuedRecordingRetries: [String] = []
  @Published private(set) var queuedSummaryRetries: [String] = []
  @Published private(set) var processingSummaryDay: String?
  @Published var error: String?
  @Published var notice: String?
  @Published var hasKey = false
  @Published var loading = true
  @Published var catalog = DeviceCatalog()
  var catalogRevision = 0
  var catalogSaveTask: Task<Void, Never>?
  let card = CardObserver()
  let usb = USBMonitor()
  let player = Player()
  let localCaptions: LivePreview
  private var recordingOffset = 0
  let live: LivePreview
  private(set) var voices: VoiceRecognition
  private var voiceSubscription: AnyCancellable?
  private var pendingCaptionSubscription: AnyCancellable?
  let desktop = DesktopCompanion()
  let isolated: Bool
  let demo: Bool
  private(set) var store: ArchiveStore
  private var pipeline: ProcessingPipeline
  private var key: String?
  private let inference: (any InferenceServing)?
  private var subscriptions = Set<AnyCancellable>()
  private var processingTask: Task<Void, Never>?
  private var attempted = Set<String>()
  private var started = false
  private var quitting = false
  private var processingPaused = false
  var isBusy: Bool { sync.isBusy || processingTask != nil || catalogSaveTask != nil }
  var libraryURL: URL { store.root }
  var days: [String] { Array(Set(recordings.flatMap(WorkdayTimeline.days))).sorted(by: >) }
  var workspace: DayWorkspace {
    workspace(for: selectedDay ?? "")
  }
  func workspace(for day: String) -> DayWorkspace {
    if let cached = cachedDays[day] { return cached }
    let value = DayWorkspace(day: day, recordings: recordings, documents: documents, summary: summaries[day])
    cachedDays[day] = value
    return value
  }
  var dayRecordings: [Recording] { workspace.recordings }
  var dayConversations: [Conversation] { workspace.conversations }
  func summaryIsCurrent(_ day: String) -> Bool {
    guard let saved = summaries[day]?.inputFingerprint else { return false }
    if let known = fingerprints[day] { return saved == known }
    let version = WorkdayTimeline.fingerprint(day: day, recordings: recordings, documents: documents)
    fingerprints[day] = version
    return saved == version
  }
  var dayComplete: Bool {
    !dayRecordings.isEmpty && dayRecordings.allSatisfy { documents[$0.id]?.phase == "complete" }
  }
  var service: AIService? {
    guard preferences.cloudEnabled, let key, !key.isEmpty else { return nil }
    return AIService(key: key, host: preferences.host)
  }

  init(libraryURL: URL? = nil, inference: (any InferenceServing)? = nil, live: LivePreview? = nil,
       localCaptions: LivePreview? = nil) {
    self.inference = inference
    self.live = live ?? LivePreview()
    self.localCaptions = localCaptions ?? LivePreview(makeLocalStream: {
      if #available(macOS 26, *) { return AppleCaptionConnection() }
      return try DictationCaptionConnection()
    })
    let environment = ProcessInfo.processInfo.environment
    isolated = libraryURL != nil || environment["WORKDAY_LIBRARY"] != nil
    demo = isolated && environment["WORKDAY_DEMO"] == "1"
    var prefs = isolated ? Preferences() : Preferences.load()
    if let path = libraryURL?.path ?? environment["WORKDAY_LIBRARY"] {
      prefs.libraryPath = path
      prefs.autoConnect = false
    }
    preferences = prefs
    let store = ArchiveStore(root: URL(fileURLWithPath: prefs.libraryPath, isDirectory: true))
    voices = VoiceRecognition(root: store.root)
    self.store = store
    sync = SyncCoordinator(store: store)
    pipeline = ProcessingPipeline(store: store)
    for publisher in [
      card.objectWillChange.eraseToAnyPublisher(), usb.objectWillChange.eraseToAnyPublisher(),
      player.objectWillChange.eraseToAnyPublisher(),
      self.live.objectWillChange.eraseToAnyPublisher(),
      self.localCaptions.$status.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      self.localCaptions.$lines.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      sync.objectWillChange.eraseToAnyPublisher(),
    ] {
      publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }
    card.onBound = { [weak self] id, name in
      self?.preferences.boundID = id
      self?.preferences.boundName = name
    }
    card.onPause = { [weak self] name, gap in self?.receivePause(name: name, pause: gap) }
    card.onInventory = { [weak self] value in self?.receiveInventory(value) }
    card.onAudio = { [weak self] data in
      guard let self else { return }
      self.live.append(data, recordingOffset: recordingOffset)
      self.localCaptions.append(data, recordingOffset: recordingOffset)
      recordingOffset += data.count
    }
    card.onStreamReset = { [weak self] reason in
      guard let self else { return }
      if case .started = reason { recordingOffset = 0 }
      self.live.boundary(reason)
      self.localCaptions.boundary(reason)
    }
    usb.onConnection = { [weak self] connected in
      guard let self else { return }
      let needsSave = connected && [.recording, .paused, .saving].contains(self.card.state.phase)
      let name = self.card.state.filename
      self.usb.excludedStems = needsSave ? Set(name.map { [InventoryEntry.stem($0)] } ?? []) : []
      self.usb.activeFilenameUnknown = needsSave && name == nil
      self.card.suspendForUSB(connected)
      self.sync.retry()
    }
    usb.onScan = { [weak self] scan in self?.receiveUSBScan(scan) }
    attachVoices()
    attachSync()
    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
      .receive(on: RunLoop.main).sink { [weak self] _ in
        guard let self, !self.isolated else { return }
        if self.preferences.autoConnect { self.card.resumeAfterWake() }
        self.usb.refresh()
        self.sync.retry()
        self.live.retryIfRecoverable()
        self.localCaptions.retryIfRecoverable()
      }.store(in: &subscriptions)
  }
  func start() {
    guard !started else { return }
    started = true
    desktop.start(model: self)
    if !isolated {
      key = Credentials.load()
      hasKey = key != nil
    }
    applyPreferences()
    Task {
      if demo {
        do { try await DemoLibrary.seed(store: store) } catch {
          self.error = error.localizedDescription
        }
      }
      do {
        try await sync.load()
        catalog = try await store.loadDeviceCatalog()
      } catch { self.error = error.localizedDescription }
      await reload()
      loading = false
      if !isolated {
        usb.start()
        if preferences.autoConnect { card.activate() }
      }
      scheduleProcessing()
    }
  }
  private func applyPreferences() {
    card.boundID = preferences.boundID
    card.autoConnect = preferences.autoConnect
    if preferences.autoSync, !manualSyncVolumes.isEmpty { manualSyncVolumes = [] }
    live.configure(enabled: preferences.realtime && preferences.cloudEnabled, service: service)
    localCaptions.configure(enabled: preferences.captions.enabled, service: nil)
    localCaptions.onVoice = preferences.realtime && service != nil ? nil : live.onVoice
    localCaptions.retainConfirmationAudio = preferences.captions.enabled && localCaptions.onVoice == nil
    if !preferences.cloudEnabled {
      queuedRecordingRetries.removeAll()
      queuedSummaryRetries.removeAll()
      processingTask?.cancel()
    }
  }
  func reload() async {
    let loadingStore = store
    do {
      let loaded = try await loadingStore.load()
      var documents: [String: ProcessingDocument] = [:]
      var summaries: [String: DaySummary] = [:]
      for recording in loaded {
        documents[recording.id] = try await loadingStore.document(for: recording)
      }
      let loadedDays = Set(loaded.flatMap(WorkdayTimeline.days))
      for day in loadedDays {
        summaries[day] = try await loadingStore.summary(day: day)
      }
      guard loadingStore === store else { return }
      for (id, current) in self.documents
      where (documents[id]?.updatedAt ?? .distantPast) < current.updatedAt {
        if loaded.contains(where: { $0.id == id }) { documents[id] = current }
      }
      self.recordings = loaded
      self.documents = documents
      for item in loaded {
        voices.observeArchive(item, lines: documents[item.id]?.transcript ?? [])
      }
      for (day, current) in self.summaries where loadedDays.contains(day)
        && current.updatedAt > (summaries[day]?.updatedAt ?? .distantPast) {
        summaries[day] = current
      }
      self.summaries = summaries
      if selectedDay == nil { showToday() }
    } catch { self.error = "本地资料读取失败：\(error.localizedDescription)" }
  }
  func saveKey(_ value: String) {
    do {
      try Credentials.save(value)
      key = value.trimmingCharacters(in: .whitespacesAndNewlines)
      hasKey = true
      applyPreferences()
      notice = "密钥已保存到本机钥匙串"
      scheduleProcessing()
    } catch { self.error = error.localizedDescription }
  }
  func configureChanged() {
    applyPreferences()
    if preferences.autoConnect, !isolated { card.activate() }
    if preferences.autoSync, !isolated { usb.refresh() }
    scheduleProcessing()
  }
  func chooseFiles() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.wav, .mp3, .mpeg4Audio, .aiff]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.title = "导入本地音频文件"
    panel.prompt = "导入"
    panel.message = "选择 Mac 上的音频文件，文件将复制到本地资料库。"
    if panel.runModal() == .OK { importFiles(panel.urls.map { ($0, "manual") }) }
  }
  private func attachVoices() {
    voiceSubscription = voices.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    pendingCaptionSubscription = Publishers.Merge(
      localCaptions.$lines.map { _ in () }, voices.objectWillChange
    ).receive(on: RunLoop.main).sink { [weak self] in
      guard let self else { return }
      voices.resolvePendingCaptions(in: localCaptions)
    }
    live.voiceSource = { [weak self] in self?.card.state.filename }
    localCaptions.voiceSource = live.voiceSource
    live.onVoice = { [weak self] id, source, packets, seconds in
      self?.voices.observeLive(id: id, source: source, packets: packets, seconds: seconds)
    }
  }
  var displayedLiveFeed: LivePreview {
    if !live.lines.contains(where: { !$0.text.isEmpty }),
       localCaptions.lines.contains(where: { !$0.text.isEmpty }) { return localCaptions }
    return live
  }

  var menuRecentSpeech: (line: LiveLine, speaker: VoiceLabel?)? {
    let feed = displayedLiveFeed
    guard let line = feed.lines.last(where: { !$0.text.isEmpty }) else { return nil }
    return (line, feed === localCaptions ? captionSpeaker(for: line.id).label : voices.label(line.voiceID))
  }

  func captionSpeaker(for lineID: String) -> CaptionSpeaker {
    voices.captionSpeaker(lineID: lineID, evidenceID: captionVoiceID(for: lineID))
  }
  @discardableResult func confirmCaption(_ lineID: String) -> Bool {
    guard let line = localCaptions.lines.first(where: { $0.id == lineID }) else { return false }
    // Cloud turns can span several bubbles. Learn only from this bubble's local audio.
    voices.setCaptionMark(lineID: lineID, mine: true, evidence: line.voiceID)
    return true
  }
  @discardableResult func correctCaption(_ lineID: String, expectedTurn: String) -> Bool {
    guard let line = localCaptions.lines.first(where: { $0.id == lineID }) else { return false }
    let speaker = captionSpeaker(for: lineID)
    guard speaker.id == expectedTurn, speaker.controls == .reject else { return false }
    voices.setCaptionMark(lineID: lineID, mine: false, evidence: line.voiceID)
    return true
  }

  // Cloud and Apple independently divide the same recording. Reuse a cloud speaker
  // only when one identified turn covers the complete local bubble.
  private func captionVoiceID(for lineID: String) -> String? {
    guard let local = localCaptions.lines.first(where: { $0.id == lineID }) else { return nil }
    if let id = local.voiceID,
      localCaptions.confirmationAudio[local.id] == nil || voices.label(id) != nil { return id }
    guard let range = local.recordingRange else { return nil }
    let overlapping = live.lines.filter { $0.recordingRange?.overlaps(range) == true }
    guard overlapping.count == 1, let cloud = overlapping.first, let span = cloud.recordingRange,
      span.lowerBound <= range.lowerBound, span.upperBound >= range.upperBound else { return nil }
    return cloud.voiceID
  }
  private func attachSync() {
    sync.onArchived = { [weak self] recording in
      guard let self else { return }
      await self.applyObservedTiming(recording)
      await self.reload()
      self.notice = "已核验并归档 \(self.sync.completedThisRun) 段录音"
      self.scheduleProcessing()
    }
  }
  func importFiles(_ files: [(URL, String)]) {
    var candidates: [SyncFile] = []
    for (url, source) in files {
      do {
        let stamp = try FileStamp(url)
        candidates.append(
          SyncFile(sourceID: source, path: url.path, size: stamp.size, modified: stamp.modified))
      } catch { self.error = error.localizedDescription }
    }
    sync.offer(candidates)
  }
  private func receiveUSBScan(_ scan: USBScan) {
    associateUSB(scan.ready)
    receiveUSBInventories(scan.inventories)
    // A manual run covers the mounted cards until their saved recordings are copied.
    // Large batches may span many scans. Unplugging ends that card's request.
    if !manualSyncVolumes.isEmpty {
      let archived = Set(sync.ledger.entries.compactMap { $0.recordingID == nil ? nil : $0.id })
      let pending = scan.files.filter {
        $0.supported && !usb.excludedStems.contains($0.stem) && !archived.contains($0.id)
      }
      let incomplete = scan.inventories.filter { !$0.complete }.map(\.sourceID)
      let ids = manualSyncVolumes.intersection(pending.map(\.sourceID) + incomplete)
      if ids != manualSyncVolumes { manualSyncVolumes = ids }
    }
    let eligible = preferences.autoSync ? scan.ready : scan.ready.filter {
      manualSyncVolumes.contains($0.sourceID)
    }
    let safeToClean = usb.activeFilenameUnknown ? [] : scan.ready
    sync.updateUSB(eligible, stableFiles: safeToClean, volumes: usb.volumes)
  }

  func retrySync() {
    guard !usb.volumes.isEmpty else { return }
    sync.retry()
    if !preferences.autoSync { manualSyncVolumes.formUnion(usb.volumes.map(\.id)) }
    usb.issue = nil
    if !isolated { usb.refresh() }
  }
  func scheduleProcessing(force: Bool = false, scope: ProcessingScope = .all) {
    guard !quitting, !processingPaused, processingTask == nil,
      let service = inference ?? self.service
    else { return }
    let runScope = preferences.autoOrganize || force
    let hasRetries = !queuedRecordingRetries.isEmpty || !queuedSummaryRetries.isEmpty
    guard runScope || hasRetries else { return }
    let today = WorkdayDate.day(Date())
    let pending = recordings.filter {
      runScope && scope.includes($0) && documents[$0.id]?.phase != "complete" && !attempted.contains($0.id)
    }.sorted {
      if ($0.day == today) != ($1.day == today) { return $0.day == today }
      return ($0.startedAt ?? $0.importedAt) > ($1.startedAt ?? $1.importedAt)
    }
    let includedDays = runScope ? scope.summaryDays(in: recordings) : []
    let summaryDays = days.filter { day in
      let version = WorkdayTimeline.fingerprint(
        day: day, recordings: recordings, documents: documents)
      return includedDays.contains(day) && !summaryIsCurrent(day)
        && !attempted.contains("day:" + version)
        && recordings.contains {
          WorkdayTimeline.days($0).contains(day) && documents[$0.id]?.phase == "complete"
        }
    }
    guard !pending.isEmpty || !summaryDays.isEmpty || hasRetries else { return }
    processingTask = Task {
      defer {
        processingID = nil
        processingLabel = nil
        processingTask = nil
        // Keep a scoped retry scoped, including any follow-up caused by a changed fingerprint.
        scheduleProcessing(force: force, scope: scope)
      }
      var remaining = pending[...]
      var daysToSummarize = includedDays
      while !Task.isCancelled {
        let day: String
        if !queuedSummaryRetries.isEmpty {
          day = queuedSummaryRetries.removeFirst()
        } else {
          let next: Recording?
          if let id = queuedRecordingRetries.first {
            queuedRecordingRetries.removeFirst()
            guard let recording = recordings.first(where: { $0.id == id }) else { continue }
            daysToSummarize.formUnion(WorkdayTimeline.days(recording))
            next = recording
          } else {
            next = remaining.popFirst()
          }
          if let recording = next {
            guard documents[recording.id]?.phase != "complete", attempted.insert(recording.id).inserted
            else { continue }
            await processRecording(recording, using: service)
            continue
          }
          guard let nextDay = daysToSummarize.max() else { break }
          day = nextDay
        }
        daysToSummarize.remove(day)
        let version = WorkdayTimeline.fingerprint(
          day: day, recordings: recordings, documents: documents)
        let items = recordings.filter {
          WorkdayTimeline.days($0).contains(day) && documents[$0.id]?.phase == "complete"
        }
        guard !items.isEmpty, !summaryIsCurrent(day), !attempted.contains("day:" + version) else {
          continue
        }
        attempted.insert("day:" + version)
        processingSummaryDay = day
        defer { processingSummaryDay = nil }
        processingLabel = "正在整理全天事项"
        processingID = items.first?.id
        do {
          var summary = try await service.summarize(
            day: day,
            conversations: WorkdayTimeline.evidence(
              day: day, recordings: items, documents: documents),
            recordingIDs: items.map(\.id))
          try Task.checkCancellation()
          guard
            version
              == WorkdayTimeline.fingerprint(day: day, recordings: recordings, documents: documents)
          else {
            daysToSummarize.insert(day)
            continue
          }
          summary.inputFingerprint = version
          try await store.save(summary)
          summaries[day] = summary
          summaryErrors[day] = nil
        } catch {
          if !(error is CancellationError) { summaryErrors[day] = error.localizedDescription }
        }
      }
    }
  }
  private func processRecording(_ recording: Recording, using service: any InferenceServing) async {
    processingID = recording.id
    processingLabel = "正在整理 \(recording.originalName)"
    if let previous = documents[recording.id]?.error,
      error == "\(previous)\n录音：\(recording.originalName)"
    {
      error = nil
    }
    do {
      let result = try await pipeline.process(recording, service: service) { [weak self] document in
        await self?.updateDocument(document, id: recording.id)
      }
      documents[recording.id] = result
    } catch {
      if !(error is CancellationError) {
        self.error = "\(error.localizedDescription)\n录音：\(recording.originalName)"
      }
    }
  }
  func retryProcessing(scope: ProcessingScope = .all) {
    guard !quitting else { return }
    if case .recording(let id) = scope {
      guard processingID != id, !queuedRecordingRetries.contains(id),
        recordings.contains(where: { $0.id == id }), documents[id]?.phase != "complete"
      else { return }
    } else if case .summary(let day) = scope {
      guard processingSummaryDay != day, !queuedSummaryRetries.contains(day),
        !summaryIsCurrent(day) else { return }
    } else if processingTask != nil { return }
    guard inference != nil || service != nil else {
      requestSettings(.recognition)
      notice = "请先开启云端处理并保存 API Key"
      return
    }
    processingPaused = false
    if case .recording(let id) = scope { queuedRecordingRetries.append(id) }
    if case .summary(let day) = scope { queuedSummaryRetries.append(day) }
    if scope == .all {
      attempted = []
    } else {
      for recording in recordings where scope.includes(recording) { attempted.remove(recording.id) }
      for day in scope.summaryDays(in: recordings) {
        attempted.remove(
          "day:"
            + WorkdayTimeline.fingerprint(day: day, recordings: recordings, documents: documents))
      }
    }
    scheduleProcessing(force: true, scope: scope)
  }
  private func updateDocument(_ document: ProcessingDocument, id: String) {
    documents[id] = document
    if let recording = recordings.first(where: { $0.id == id }) {
      voices.observeArchive(recording, lines: document.transcript)
    }
    processingLabel = document.label
  }
  func pauseProcessing() {
    processingPaused = true
    queuedRecordingRetries.removeAll()
    queuedSummaryRetries.removeAll()
    processingTask?.cancel()
  }
  func selectDay(_ day: String) {
    if let previous = selectedDay { daySelections[previous] = selectedDetail }
    if selectedDay != day, player.route != nil { player.stop() }
    area = .day
    selectedDay = day
    selectedDetail = daySelections[day]
    destination = day == WorkdayDate.day(Date()) ? .current : .history
  }
  func showToday() {
    selectDay(WorkdayDate.day(Date()))
  }
  func requestSettings(_ section: SettingsSection) {
    settingsSection = section
    settingsRequest = UUID()
  }
  func selectConversation(_ clip: Conversation) {
    selectedDetail = .conversation(clip.id)
  }
  func dayStatus(_ day: String) -> String {
    let items = recordings.filter { WorkdayTimeline.days($0).contains(day) }
    if items.contains(where: { $0.id == processingID }) { return "整理中" }
    if summaryErrors[day] != nil || items.contains(where: { documents[$0.id]?.error != nil }) {
      return "需重试"
    }
    if items.isEmpty { return "尚无本地录音" }
    if items.allSatisfy({ documents[$0.id]?.phase == "complete" }) {
      return summaryIsCurrent(day) ? "已整理" : "摘要待更新"
    }
    return "已保存"
  }
  func recording(for clip: Conversation) -> Recording? {
    recordings.first { $0.id == clip.recordingID }
  }
  func play(_ clip: Conversation, at sourceTime: Double? = nil, autoplay: Bool = true) {
    guard let recording = recording(for: clip) else { return }
    selectConversation(clip)
    let base = clip.audioSourceStart ?? clip.start
    let range = (clip.start - base)...(clip.end - base)
    player.load(
      url: libraryURL.appendingPathComponent(recording.folder).appendingPathComponent(
        clip.audioFile), id: clip.id,
      recordingID: recording.id, title: clip.title,
      sourceOffset: base,
      position: max(0, (sourceTime ?? clip.start) - base),
      autoplay: autoplay,
      playbackRange: range)
  }
  func playDay(from clip: Conversation? = nil, offset: Double? = nil) {
    var route = workspace.audio
    if let clip, let recording = recording(for: clip) {
      let source = max(clip.start, offset ?? clip.start)
      func containsSource(_ span: DayAudioSpan) -> Bool {
        span.recordingID == recording.id && span.sourceStart <= source && source < span.sourceEnd
      }
      if !route.spans.contains(where: containsSource), recording.startedAt != nil {
        route = DayAudioTimeline(day: route.day, recordings: dayRecordings, preferredRecordingID: recording.id)
      }
      if let span = route.spans.first(where: containsSource) {
        player.startDay(route, recordings: dayRecordings, root: libraryURL,
                        clock: span.clockStart + source - span.sourceStart)
      } else {
        playOriginal(recording, at: source)
      }
    } else {
      player.startDay(route, recordings: dayRecordings, root: libraryURL)
    }
  }
  func playOriginal(_ recording: Recording, at offset: Double = 0, autoplay: Bool = true) {
    player.load(
      url: libraryURL.appendingPathComponent(recording.folder).appendingPathComponent(
        recording.originalFile), id: recording.id,
      recordingID: recording.id, title: "完整录音 · \(recording.originalName)", position: offset,
      autoplay: autoplay)
  }
  func reveal(_ recording: Recording? = nil) {
    let url = recording.map { libraryURL.appendingPathComponent($0.folder) } ?? libraryURL
    if FileManager.default.fileExists(atPath: url.path) {
      NSWorkspace.shared.open(url)
    } else {
      notice = "资料库会在首次同步后创建"
    }
  }
  func chooseLibrary() {
    guard !isBusy else {
      error = "请等待同步或整理完成后切换资料库"
      return
    }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.message = "选择 Mac 上的资料库。已有档案保留在原目录；选择以前的资料库可重新查看。"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let v = try url.resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsLocalKey])
      guard v.volumeIsRemovable != true, v.volumeIsLocal == true else {
        throw WorkdayError.invalid("请选择 Mac 本地磁盘目录，不能把录音卡作为归档位置")
      }
      player.stop()
      preferences.libraryPath = url.path
      voices.stop()
      live.reset()
      localCaptions.reset()
      store = ArchiveStore(root: url)
      voices = VoiceRecognition(root: url)
      attachVoices()
      sync = SyncCoordinator(store: store)
      sync.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(
        in: &subscriptions)
      attachSync()
      pipeline = ProcessingPipeline(store: store)
      attempted = []
      daySelections = [:]
      selectedDetail = nil
      summaryErrors = [:]
      selectedDay = nil
      summaries = [:]
      libraryRecordingID = nil
      Task {
        do {
          try await sync.load()
          catalog = try await store.loadDeviceCatalog()
        } catch { self.error = error.localizedDescription }
        await reload()
        usb.refresh()
        scheduleProcessing()
      }
    } catch { self.error = error.localizedDescription }
  }
  func shutdown() async {
    quitting = true
    queuedRecordingRetries.removeAll()
    queuedSummaryRetries.removeAll()
    desktop.stop()
    voices.stop()
    processingTask?.cancel()
    usb.stop()
    live.reset()
    localCaptions.reset()
    card.disconnect()
    player.stop()
    await voices.waitForStoppedTasks()
    await sync.shutdown()
    await catalogSaveTask?.value
    await processingTask?.value
  }
}
