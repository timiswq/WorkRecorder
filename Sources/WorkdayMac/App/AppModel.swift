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
  @Published var recordings: [Recording] = [] { didSet { invalidateDayInputs() } }
  @Published var documents: [String: ProcessingDocument] = [:] { didSet { invalidateDayInputs() } }
  @Published var summaries: [String: DaySummary] = [:] { didSet { cachedDays.removeAll() } }
  @Published var dayUpdates = DayResultUpdates()
  var dayUpdatesLoaded = false
  var dayUpdatesRevision = 0
  var dayUpdatesSaveTask: Task<Void, Never>?
  @Published private var organizations: [String: DayOrganization] = [:] { didSet { cachedDays.removeAll() } }
  @Published var selectedDay: String? = WorkdayDate.day(Date())
  @Published private(set) var originalsDay: String?
  @Published var libraryRecordingID: String?
  @Published var area: WorkspaceArea = .day {
    didSet { needsInitialArea = false }
  }
  @Published var captionPosition: CaptionReadingPosition = .latest {
    didSet {
      if oldValue == .latest, captionPosition != .latest { heldCaptionLeadID = liveCaptionLeadID(at: Date()) }
      if captionPosition == .latest {
        heldCaptionLeadID = nil
        captionReadingAnchor = nil
        selectedCaption = nil
      }
      captionHistory.holdReading(captionPosition != .latest)
    }
  }
  @Published private(set) var selectedCaption: CaptionSelection?
  // Saved outside the SwiftUI page so sidebar navigation can restore the first visible sentence.
  // Scrolling updates this frequently; it does not need to invalidate the whole workspace.
  var captionReadingAnchor: CaptionSelection?
  private var heldCaptionLeadID: String?

  private func liveCaptionLeadID(at time: Date) -> String? {
    guard preferences.captions.enabled, deviceStatus(at: time).kind == .recording else { return nil }
    return localCaptions.lines.last?.id
  }

  func captionLeadID(at time: Date) -> String? {
    captionPosition == .latest ? liveCaptionLeadID(at: time) : heldCaptionLeadID
  }
  private var needsInitialArea = true
  private var cachedDays: [String: DayWorkspace] = [:]
  private var fingerprints: [String: String] = [:]
  @Published var selectedDetail: RecordDetailSelection?
  @Published var settingsSection: SettingsSection = .device
  @Published var settingsRequest = UUID()
  @Published var summaryErrors: [String: String] = [:]
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
  let audioMeter = LiveAudioMeter()
  let usb = USBMonitor()
  let player = Player()
  @Published private(set) var captionHistory: CaptionHistory
  let captionSelection = LiveCaptionRouter()
  let localCaptions: LivePreview
  private var recordingOffset = 0
  let live: LivePreview
  private(set) var voices: VoiceRecognition
  private var voiceSubscription: AnyCancellable?
  private var pendingCaptionSubscription: AnyCancellable?
  let desktop = DesktopCompanion()
  let isolated: Bool
  let demo: Bool
  let liveVoiceValidation: Bool
  var liveValidationTask: Task<Void, Never>?
  var receivedLiveAudioBytes: Int { recordingOffset }
  private(set) var store: ArchiveStore
  private var pipeline: ProcessingPipeline
  private var key: String?
  private let inference: (any InferenceServing)?
  private let fileReviewer: (any CaptionFileTranscribing)?
  private var subscriptions = Set<AnyCancellable>()
  private var processingTask: Task<Void, Never>?
  @Published private(set) var scheduledRecordingIDs = Set<String>()
  @Published private(set) var scheduledSummaryDays = Set<String>()
  private var automaticProcessingScope: ProcessingScope?
  var processingIsRunning: Bool { processingTask != nil }

  func recordingIsScheduled(_ recording: Recording) -> Bool {
    guard !processingPaused else { return false }
    if queuedRecordingRetries.contains(recording.id) || scheduledRecordingIDs.contains(recording.id) { return true }
    return processingIsRunning && automaticProcessingScope?.includes(recording) == true
      && documents[recording.id]?.phase != "complete" && !attempted.contains(recording.id)
  }

  func summaryIsScheduled(_ day: String) -> Bool {
    guard !processingPaused, !summaryIsCurrent(day) else { return false }
    if queuedSummaryRetries.contains(day) || scheduledSummaryDays.contains(day) { return true }
    return processingIsRunning && automaticProcessingScope?.summaryDays(in: recordings).contains(day) == true
      && !attempted.contains("day:" + summaryVersion(day))
  }
  private var attempted = Set<String>()
  private var started = false
  private var quitting = false
  @Published private(set) var processingPaused = false
  var processingIsAvailable: Bool { inference != nil || service != nil }
  var isBusy: Bool { sync.isBusy || processingTask != nil || catalogSaveTask != nil || dayUpdatesSaveTask != nil }
  var libraryURL: URL { store.root }
  var days: [String] { Array(Set(recordings.flatMap(WorkdayTimeline.days))).sorted(by: >) }
  var workspace: DayWorkspace {
    workspace(for: selectedDay ?? "")
  }
  func workspace(for day: String) -> DayWorkspace {
    if let cached = cachedDays[day] { return cached }
    let value = DayWorkspace(day: day, recordings: recordings, documents: documents, summary: summaries[day],
                             organization: organizations[day] ?? DayOrganization())
    cachedDays[day] = value
    return value
  }
  var dayRecordings: [Recording] { workspace.recordings }
  var dayConversations: [Conversation] { workspace.conversations }
  private func invalidateDayInputs() {
    cachedDays.removeAll()
    fingerprints.removeAll()
  }
  private func summaryVersion(_ day: String) -> String {
    if let known = fingerprints[day] { return known }
    let version = WorkdayTimeline.fingerprint(day: day, recordings: recordings, documents: documents)
    fingerprints[day] = version
    return version
  }
  func summaryIsCurrent(_ day: String) -> Bool {
    guard let saved = summaries[day]?.inputFingerprint else { return false }
    return saved == summaryVersion(day)
  }
  var service: AIService? {
    guard preferences.cloudEnabled, let key, !key.isEmpty else { return nil }
    return AIService(key: key, host: preferences.host, recordingModel: preferences.recordingModel)
  }

  init(libraryURL: URL? = nil, inference: (any InferenceServing)? = nil, live: LivePreview? = nil,
       localCaptions: LivePreview? = nil, fileReviewer: (any CaptionFileTranscribing)? = nil) {
    self.inference = inference
    self.fileReviewer = fileReviewer
    self.live = live ?? LivePreview()
    self.localCaptions = localCaptions ?? LivePreview(makeLocalStream: {
      if #available(macOS 26, *) { return AppleCaptionConnection() }
      return try DictationCaptionConnection()
    })
    let environment = ProcessInfo.processInfo.environment
    isolated = libraryURL != nil || environment["WORKDAY_LIBRARY"] != nil
    liveVoiceValidation = isolated && environment["WORKDAY_LIVE_VOICE_VALIDATION_ONLY"] == "1"
    demo = isolated && environment["WORKDAY_DEMO"] == "1"
    var prefs = isolated ? Preferences() : Preferences.load()
    if let path = libraryURL?.path ?? environment["WORKDAY_LIBRARY"] {
      prefs.libraryPath = path
      prefs.autoConnect = false
    }
    if liveVoiceValidation {
      prefs.boundID = environment["WORKDAY_LIVE_VOICE_DEVICE_ID"].flatMap { UUID(uuidString: $0)?.uuidString }
      prefs.autoSync = false
      prefs.autoOrganize = false
      prefs.cloudEnabled = false
      prefs.captions.enabled = environment["WORKDAY_LIVE_VOICE_VALIDATE_CAPTIONS"] == "1"
    }
    preferences = prefs
    let store = ArchiveStore(root: URL(fileURLWithPath: prefs.libraryPath, isDirectory: true))
    captionHistory = CaptionHistory(root: store.root)
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
      self.localCaptions.$pendingSpeech.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      sync.objectWillChange.eraseToAnyPublisher(),
    ] {
      publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
    }
    $captionHistory.map(\.reviewCompleted).switchToLatest()
      .sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
    card.onBound = { [weak self] id, name in
      self?.preferences.boundID = id
      self?.preferences.boundName = name
    }
    card.onPause = { [weak self] name, gap in self?.receivePause(name: name, pause: gap) }
    card.onInventory = { [weak self] value in self?.receiveInventory(value) }
    card.onAudio = { [weak self] data in
      guard let self else { return }
      self.audioMeter.append(data, offset: recordingOffset)
      if self.preferences.captions.enabled || self.liveVoiceValidation {
        self.voices.appendLiveAudio(data, offset: recordingOffset,
          source: VoiceRecognition.source(self.card.state.filename, fallback: "live-card"))
      }
      self.live.append(data, recordingOffset: recordingOffset)
      self.localCaptions.append(data, recordingOffset: recordingOffset)
      recordingOffset += data.count
    }
    card.onStreamReset = { [weak self] reason in
      guard let self else { return }
      self.audioMeter.reset()
      self.voices.resetLiveAudio()
      if case .started = reason { recordingOffset = 0 }
      self.live.boundary(reason)
      self.localCaptions.boundary(reason)
    }
    card.onRecordingStarted = { [weak self] in
      guard let self, self.area != .live else { return }
      self.captionPosition = .latest
      self.showLiveCaptions()
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
    self.localCaptions.cacheCaptionAudio = true
    captionSelection.onChange = { [weak self] line in
      guard let self else { return }
      saveCaption(line, evidenceID: captionVoiceID(for: line))
    }
    self.localCaptions.$lines.sink { [weak self] lines in
      self?.voices.observeLiveLines(lines)
      self?.captionSelection.receiveLocal(lines)
    }
      .store(in: &subscriptions)
    self.live.$lines.sink { [weak self] in self?.captionSelection.receiveCloud($0) }
      .store(in: &subscriptions)
    self.live.$phase.removeDuplicates().sink { [weak self] phase in
      self?.captionSelection.setAvailable(phase == .connecting || phase == .recognizing || phase == .finishing)
    }.store(in: &subscriptions)
    self.localCaptions.onLineChanged = { [weak self] raw in
      guard let self, raw.isFinal, let row = captionSelection.lines.first(where: { $0.id == raw.id }) else { return }
      saveCaption(row, evidenceID: captionVoiceID(for: raw))
    }
    self.localCaptions.onPreviousRecordingFinal = { [weak self] line in
      self?.saveCaption(line, evidenceID: nil)
    }
    self.live.onLineChanged = { [weak self] cloud in
      guard let self, let range = cloud.recordingRange else { return }
      for local in captionSelection.lines where local.recordingRange?.overlaps(range) == true {
        captionHistory.accept(local, evidenceID: captionVoiceID(for: local.id))
      }
    }
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
    if !liveVoiceValidation { desktop.start(model: self) }
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
      } else if liveVoiceValidation, preferences.boundID != nil {
        card.activate(.reconnectBound)
        startLiveVoiceValidationReport()
      }
      scheduleProcessing()
    }
  }
  private func applyPreferences() {
    card.boundID = preferences.boundID
    card.autoConnect = preferences.autoConnect
    if preferences.autoSync, !manualSyncVolumes.isEmpty { manualSyncVolumes = [] }
    configureCaptions(service: service)
    if !preferences.captions.enabled && !liveVoiceValidation { voices.resetLiveAudio() }
    if !preferences.cloudEnabled {
      queuedRecordingRetries.removeAll()
      queuedSummaryRetries.removeAll()
      processingTask?.cancel()
    }
  }
  func configureCaptions(service: AIService?) {
    let cloudEnabled = preferences.realtime && preferences.cloudEnabled
    let fileMode = preferences.liveModel == .fileTrans
    let reviewConfig = cloudEnabled && fileMode && preferences.captions.enabled
      ? service.map { LiveASRConfiguration(key: $0.key, host: $0.host, model: .fileTrans) } : nil
    localCaptions.collectForFileReview = reviewConfig != nil
    captionHistory.configureReview(reviewConfig, reviewer: reviewConfig != nil ? fileReviewer ?? service : nil)
    live.configure(enabled: cloudEnabled && !fileMode, service: fileMode ? nil : service, model: preferences.liveModel)
    let streamCloud = cloudEnabled && !fileMode && service != nil
    captionSelection.configure(enabled: streamCloud)
    localCaptions.configure(enabled: preferences.captions.enabled, service: nil)
    localCaptions.onVoice = { [weak self] id, source, packets, seconds in
      self?.voices.observeLive(id: id, source: source, packets: packets, seconds: seconds, countDuration: !streamCloud)
    }
    localCaptions.onDraftVoice = { [weak self] id, source, packets, seconds in
      self?.voices.observeLive(id: id, source: source, packets: packets, seconds: seconds, countDuration: false)
    }
    localCaptions.draftVoiceIsUsable = { [weak self] in self?.voices.hasLiveVoice($0) == true }
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
      var organizations: [String: DayOrganization] = [:]
      let loadedDays = Set(loaded.flatMap(WorkdayTimeline.days))
      for day in loadedDays {
        summaries[day] = try await loadingStore.summary(day: day)
        organizations[day] = try await loadingStore.organization(day: day)
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
      for (day, current) in self.organizations where loadedDays.contains(day)
        && current.revision > (organizations[day]?.revision ?? 0) {
        organizations[day] = current
      }
      self.organizations = organizations
      self.summaries = summaries
      if !dayUpdatesLoaded {
        let updates = try await loadingStore.dayResultUpdates()
        guard loadingStore === store else { return }
        dayUpdates = updates
        try dayUpdates.seed(summaries.values.map { dayResultContent($0) })
        dayUpdatesLoaded = true
      }
      for summary in summaries.values { try dayUpdates.record(dayResultContent(summary)) }
      dayUpdates.retain(days: loadedDays)
      if needsInitialArea { showToday() }
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
    voices.onRealtimeIdentityChanged = { [weak self] lines in
      guard let self else { return }
      for line in lines {
        guard var shown = self.captionSelection.lines.first(where: { $0.id == line.id }) else { continue }
        shown.voiceID = line.voiceID
        shown.voicePackets = line.voicePackets
        shown.voiceRange = line.voiceRange
        shown.draftVoice = line.draftVoice
        self.captionHistory.accept(shown, evidenceID: line.bubbleVoiceID)
      }
    }
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
  var menuRecentSpeech: (line: CaptionRecord, speaker: VoiceLabel?)? {
    guard let line = CaptionWindow(now: Date()).visible(in: captionHistory.records).last else { return nil }
    return (line, captionSpeaker(for: line).label)
  }

  func captionSpeaker(for record: CaptionRecord) -> CaptionSpeaker {
    if localCaptions.lines.contains(where: { $0.id == record.id }) { return captionSpeaker(for: record.id) }
    if let evidence = record.evidenceID, evidence.hasPrefix("realtime:") {
      return voices.captionSpeaker(lineID: record.id, evidenceID: evidence)
    }
    let local = record.localVoiceID.flatMap { voices.label($0) == nil ? nil : $0 }
    return voices.captionSpeaker(lineID: record.id, evidenceID: local ?? record.evidenceID)
  }

  func captionSpeaker(for lineID: String) -> CaptionSpeaker {
    voices.captionSpeaker(lineID: lineID, evidenceID: captionVoiceID(for: lineID))
  }
  func captionSpeaker(for line: LiveLine) -> CaptionSpeaker {
    voices.captionSpeaker(lineID: line.id, evidenceID: captionVoiceID(for: line))
  }
  @discardableResult func confirmCaption(_ lineID: String) -> Bool {
    let local = localCaptions.lines.first { $0.id == lineID }
    let saved = local == nil ? captionHistory.records.last { $0.id == lineID } : nil
    guard local != nil || saved != nil else { return false }
    // Cloud turns can span several bubbles. Learn only from this bubble's local audio.
    voices.setCaptionMark(lineID: lineID, mine: true, evidence: local.flatMap(localFeedbackID) ?? saved?.localVoiceID)
    return true
  }
  @discardableResult func correctCaption(_ lineID: String, expectedTurn: String) -> Bool {
    let local = localCaptions.lines.first { $0.id == lineID }
    let saved = local == nil ? captionHistory.records.last { $0.id == lineID } : nil
    guard local != nil || saved != nil else { return false }
    let speaker = saved.map { captionSpeaker(for: $0) } ?? captionSpeaker(for: lineID)
    guard speaker.id == expectedTurn, speaker.controls == .reject else { return false }
    voices.setCaptionMark(lineID: lineID, mine: false, evidence: local.flatMap(localFeedbackID) ?? saved?.localVoiceID)
    return true
  }

  // Cloud and Apple independently divide the same recording. Reuse a cloud speaker
  // only when one identified turn covers the complete local bubble.
  private func captionVoiceID(for lineID: String) -> String? {
    guard let local = localCaptions.lines.first(where: { $0.id == lineID }) else { return nil }
    return captionVoiceID(for: local)
  }
  private func localFeedbackID(_ line: LiveLine) -> String? {
    let shown = voices.presentationLine(line)
    if let id = shown.bubbleVoiceID, id.hasPrefix("realtime:"), voices.hasLiveVoice(id) { return id }
    if let id = line.voiceID { return id }
    guard let id = line.draftVoice?.id, voices.hasLiveVoice(id) else { return nil }
    return id
  }
  private func captionVoiceID(for local: LiveLine) -> String? {
    if let id = localFeedbackID(local),
      localCaptions.confirmationAudio[local.id] == nil || voices.label(id) != nil { return id }
    guard preferences.liveModel != .fileTrans, let range = local.recordingRange else { return nil }
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
      inference != nil || service != nil
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
      return includedDays.contains(day) && !summaryIsCurrent(day)
        && !attempted.contains("day:" + summaryVersion(day))
        && recordings.contains {
          WorkdayTimeline.days($0).contains(day) && documents[$0.id]?.phase == "complete"
        }
    }
    guard !pending.isEmpty || !summaryDays.isEmpty || hasRetries else { return }
    scheduledRecordingIDs = Set(pending.map(\.id))
    scheduledSummaryDays = includedDays
    automaticProcessingScope = runScope ? scope : nil
    processingTask = Task {
      defer {
        processingID = nil
        processingLabel = nil
        processingTask = nil
        scheduledRecordingIDs.removeAll()
        scheduledSummaryDays.removeAll()
        automaticProcessingScope = nil
        // Keep a scoped retry scoped, including any follow-up caused by a changed fingerprint.
        scheduleProcessing(force: force, scope: scope)
      }
      var remaining = pending[...]
      var daysToSummarize = includedDays
      while !Task.isCancelled {
        guard let service = inference ?? self.service else { break }
        let day: String
        if !queuedSummaryRetries.isEmpty {
          day = queuedSummaryRetries.removeFirst()
        } else {
          let next: Recording?
          if let id = queuedRecordingRetries.first {
            queuedRecordingRetries.removeFirst()
            guard let recording = recordings.first(where: { $0.id == id }) else { continue }
            daysToSummarize.formUnion(WorkdayTimeline.days(recording))
            scheduledSummaryDays.formUnion(WorkdayTimeline.days(recording))
            next = recording
          } else {
            next = remaining.popFirst()
          }
          if let recording = next {
            scheduledRecordingIDs.remove(recording.id)
            guard documents[recording.id]?.phase != "complete", attempted.insert(recording.id).inserted
            else { continue }
            await processRecording(recording, using: service)
            continue
          }
          guard let nextDay = daysToSummarize.max() else { break }
          day = nextDay
        }
        daysToSummarize.remove(day)
        scheduledSummaryDays.remove(day)
        let version = summaryVersion(day)
        let items = recordings.filter {
          WorkdayTimeline.days($0).contains(day) && documents[$0.id]?.phase == "complete"
        }
        guard !items.isEmpty, !summaryIsCurrent(day), !attempted.contains("day:" + version) else {
          continue
        }
        attempted.insert("day:" + version)
        processingSummaryDay = day
        defer { processingSummaryDay = nil }
        processingLabel = "正在生成当天概述"
        processingID = items.first?.id
        do {
          var summary = try await service.summarize(
            day: day, conversations: WorkdayTimeline.evidence(day: day, recordings: items, documents: documents),
            recordingIDs: items.map(\.id))
          try Task.checkCancellation()
          guard version == summaryVersion(day) else {
            attempted.remove("day:" + version)
            daysToSummarize.insert(day)
            scheduledSummaryDays.insert(day)
            continue
          }
          summary.inputFingerprint = version
          try await store.save(summary)
          summaries[day] = summary
          recordDayUpdate(summary)
          attempted.remove("day:" + version)
          summaryErrors[day] = nil
        } catch {
          if !(error is CancellationError), version == summaryVersion(day) {
            summaryErrors[day] = error.localizedDescription
          }
          if error is CancellationError || version != summaryVersion(day) { attempted.remove("day:" + version) }
        }
      }
    }
  }
  private func processRecording(_ recording: Recording, using service: any InferenceServing) async {
    processingID = recording.id
    processingLabel = "正在处理录音 \(recording.originalName)"
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
        attempted.remove("day:" + summaryVersion(day))
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
    area = .day
    selectedDay = day
    selectedDetail = daySelections[day]
    destination = day == WorkdayDate.day(Date()) ? .current : .history
  }
  var visibleOriginals: [Recording] {
    guard let originalsDay else { return recordings }
    return workspace(for: originalsDay).recordings
  }

  func showOriginals(for day: String? = nil) {
    originalsDay = day
    libraryRecordingID = nil
    area = .originals
  }

  var playbackActivity: ActivityEntry? {
    guard let day = player.route?.day else { return nil }
    return workspace(for: day).activities.first { $0.containsPlayback(player) }
  }

  func showPlaybackDay() {
    guard let day = player.route?.day else { return }
    selectDay(day)
    if let entry = playbackActivity {
      selectedDetail = .conversation(entry.id)
    } else {
      selectedDetail = player.recordingID.map(RecordDetailSelection.original)
    }
  }

  func selectCaptionRange(_ range: ClosedRange<Date>, in window: CaptionWindow) {
    let clipped = window.selection(range)
    guard clipped != window.minutes || captionPosition != .latest else { return }
    let rows = window.visible(in: captionHistory.readingRecords, during: clipped)
    let visibleAnchor = captionReadingAnchor
    let selected = selectedCaption
    let position: CaptionReadingPosition = clipped == window.minutes ? .scrolling : .range(clipped)
    guard position != captionPosition else { return }
    captionPosition = position
    let nearestVisible = visibleAnchor.flatMap { rows.nearest(to: $0) }
    let nearestSelected = selected.flatMap { rows.nearest(to: $0) }
    if selected != nearestSelected { selectedCaption = nearestSelected }
    if let nearestVisible, nearestVisible == visibleAnchor {
      captionReadingAnchor = nearestVisible
    } else {
      captionReadingAnchor = nearestSelected ?? nearestVisible ?? rows.last?.readingAnchor
    }
  }

  func showNeighboringCaption(_ record: CaptionRecord, in window: CaptionWindow) {
    let minute = CaptionWindow.minute(record.time)
    selectCaptionRange(minute...minute, in: window)
    selectCaption(record)
    captionReadingAnchor = record.readingAnchor
  }

  func selectCaption(_ record: CaptionRecord) {
    let target = record.readingAnchor
    if selectedCaption != target { selectedCaption = target }
  }

  func replayCaption(_ record: CaptionRecord) {
    guard record.replay != nil else { return }
    if captionPosition == .latest { captionPosition = .scrolling }
    selectCaption(record)
    let history = captionHistory
    player.playCaption(record, title: "字幕回听 · " + CaptionTime.seconds.string(from: record.time)) {
      try await history.replayAudio(for: record)
    }
  }

  private func saveCaption(_ line: LiveLine, evidenceID: String?) {
    if player.captionID == line.id,
       player.captionFrames != line.replay?.frames || !LiveLine.containsSpeech(line.text) { player.stop() }
    captionHistory.accept(line, evidenceID: evidenceID)
  }

  func showLiveCaptions() {
    if let range = captionPosition.selectedRange, range.upperBound < CaptionWindow(now: Date()).minutes.lowerBound {
      captionPosition = .latest
    }
    area = .live
  }

  func openDefaultWorkspace() {
    if loading { needsInitialArea = true } else { showToday() }
  }

  func showToday() {
    selectDay(WorkdayDate.day(Date()))
    if dayRecordings.isEmpty { showLiveCaptions() }
  }
  func requestSettings(_ section: SettingsSection) {
    settingsSection = section
    settingsRequest = UUID()
  }
  func selectConversation(_ clip: Conversation) {
    selectedDetail = .conversation(clip.id)
  }
  func dayStatus(_ day: String) -> String {
    if workspace(for: day).recordings.isEmpty { return "尚无本地录音" }
    return dayOverviewState(for: day).message ?? "概述已生成"
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
  private func excerptRange(_ clip: Conversation, line: TranscriptLine?, through endClip: Conversation?) -> ClosedRange<Double>? {
    let start = max(clip.start, line?.start ?? clip.start)
    let end = min(endClip?.end ?? clip.end, line?.end ?? .infinity)
    guard start < end, endClip == nil || endClip?.recordingID == clip.recordingID else { return nil }
    return start...end
  }

  func excerptID(_ clip: Conversation, line: TranscriptLine? = nil, through endClip: Conversation? = nil) -> String? {
    excerptRange(clip, line: line, through: endClip).map {
      "excerpt:\(clip.recordingID)/\($0.lowerBound)/\($0.upperBound)"
    }
  }

  func excerptPlaying(_ clip: Conversation, line: TranscriptLine) -> Bool {
    player.playing && player.selectionID == excerptID(clip, line: line)
  }

  func playExcerpt(_ clip: Conversation, line: TranscriptLine? = nil, through endClip: Conversation? = nil) {
    if player.selectionID == excerptID(clip, line: line, through: endClip), player.error == nil {
      player.toggle()
    } else {
      loadExcerpt(clip, line: line, through: endClip, at: nil, autoplay: true)
    }
  }

  func seekExcerpt(_ clip: Conversation, through endClip: Conversation, to position: Double) {
    if player.selectionID == excerptID(clip, through: endClip) && player.error == nil {
      player.seek(position)
    } else {
      loadExcerpt(clip, line: nil, through: endClip, at: position, autoplay: false)
    }
  }

  private func loadExcerpt(_ clip: Conversation, line: TranscriptLine?, through endClip: Conversation?,
                           at position: Double?, autoplay: Bool) {
    guard let source = recording(for: clip), let range = excerptRange(clip, line: line, through: endClip),
          let id = excerptID(clip, line: line, through: endClip) else { return }
    player.load(url: libraryURL.appendingPathComponent(source.folder).appendingPathComponent(source.originalFile),
                id: id, recordingID: source.id, title: line == nil ? "回听这段对话" : "逐句回听",
                position: position ?? range.lowerBound, autoplay: autoplay, playbackRange: range)
  }

  @discardableResult
  func organize(day: String, sentenceIDs: Set<String>, title: String = "", summary: String = "",
                into targetID: String? = nil) async throws -> String {
    let current = workspace(for: day)
    let raw = current.activities.filter(\.isRaw).flatMap(\.clips).map(\.id).filter(sentenceIDs.contains)
    guard !raw.isEmpty, raw.count == sentenceIDs.count else {
      throw WorkdayError.invalid("原话归属已有变化，请回到时间线重新选择。")
    }
    let savingStore = store
    var next = organizations[day] ?? DayOrganization()
    let id: String
    if let targetID {
      guard let target = current.activities.first(where: { !$0.isRaw && $0.id == targetID }) else {
        throw WorkdayError.invalid("该事项已更新，请重新选择。")
      }
      if let index = next.items.firstIndex(where: { target.manualIDs.contains($0.id) }) {
        id = next.items[index].id
        next.items[index].sentences.append(contentsOf: raw)
      } else {
        let item = DayOrganization.Item(title: target.activity.title, summary: target.activity.summary,
                                        anchors: target.activity.conversationIDs, anchorSentences: target.anchorSentences,
                                        sentences: raw)
        id = item.id
        next.items.append(item)
      }
    } else {
      let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { throw WorkdayError.invalid("请填写事项名称。") }
      let item = DayOrganization.Item(title: name, summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                                      anchors: [], anchorSentences: [], sentences: raw)
      id = item.id
      next.items.append(item)
    }
    do {
      let saved = try await savingStore.saveOrganization(next, day: day)
      guard store === savingStore else { throw WorkdayError.invalid("资料库已切换。") }
      if saved.revision >= (organizations[day]?.revision ?? 0) { organizations[day] = saved }
      return id
    } catch {
      if store === savingStore { await reload() }
      throw error
    }
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
      audioMeter.reset()
      live.reset()
      localCaptions.reset()
      captionHistory.configureReview(nil, reviewer: nil)
      captionPosition = .latest
      captionHistory = CaptionHistory(root: url)
      configureCaptions(service: service)
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
      dayUpdates = DayResultUpdates()
      dayUpdatesLoaded = false
      selectedDay = WorkdayDate.day(Date())
      needsInitialArea = true
      summaries = [:]
      organizations = [:]
      libraryRecordingID = nil
      originalsDay = nil
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
    liveValidationTask?.cancel()
    liveValidationTask = nil
    quitting = true
    captionHistory.configureReview(nil, reviewer: nil)
    queuedRecordingRetries.removeAll()
    queuedSummaryRetries.removeAll()
    desktop.stop()
    voices.stop()
    audioMeter.reset()
    processingTask?.cancel()
    usb.stop()
    live.reset()
    localCaptions.reset()
    card.disconnect()
    player.stop()
    await localCaptions.waitForSpeechActivityToStop()
    await live.waitForSpeechActivityToStop()
    await captionHistory.flush()
    await voices.waitForStoppedTasks()
    await sync.shutdown()
    await catalogSaveTask?.value
    await dayUpdatesSaveTask?.value
    await processingTask?.value
  }
}
