import AppKit
import Darwin
import QS668Core
import SwiftUI
import Vision
import WiFiRecorderCore
import WorkdayCore

struct DevicePageCapture {
  var bluetoothID: String?
  var diskSpace: USBVolume.Space?
  var diskIdentifier: String?
  var expandsTechnicalInfo = false
  var width: CGFloat?
}

/// Opt-in development capture of the real Window scene. It is inert for a normal library.
@MainActor enum SceneWindowCapture {
  private static var started = false
  static var isRunning: Bool { started }
  private static var activated = false
  private(set) static var devicePage: DevicePageCapture?
  static var deviceContentWidth: CGFloat = 0

  static var wifiSyncFactory: ((ArchiveStore) -> WiFiRecordingSync)? {
    let environment = ProcessInfo.processInfo.environment
    guard environment["WORKDAY_LIBRARY"] != nil, environment["WORKDAY_SCENE_CAPTURE"] != nil else {
      return nil
    }
    return { WiFiRecordingSync(store: $0, card: CaptureWiFiCard()) }
  }

  static func start(window: NSWindow, model: AppModel) {
    guard model.isolated, let path = ProcessInfo.processInfo.environment["WORKDAY_SCENE_CAPTURE"],
      !started
    else { return }
    started = true
    // A hidden Window scene can attach before applicationDidFinishLaunching; start() is idempotent.
    model.start()
    let output = URL(fileURLWithPath: path, isDirectory: true)
    let pid = ProcessInfo.processInfo.processIdentifier
    activated = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    let token = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { notification in
      guard
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
        app.processIdentifier == pid
      else { return }
      MainActor.assumeIsolated { activated = true }
    }
    window.setFrameOrigin(NSPoint(x: -16000, y: -16000))
    Task {
      defer {
        NSWorkspace.shared.notificationCenter.removeObserver(token)
        // The opt-in process owns only a disposable library; never wait on normal app shutdown.
        Darwin.exit(0)
      }
      do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for _ in 0..<3000 where model.loading { try await Task.sleep(for: .milliseconds(10)) }
        try require(!model.loading, "The isolated library did not finish loading.")
        let day = ProcessInfo.processInfo.environment["WORKDAY_SCENE_DAY"] ?? "2026-11-10"
        model.selectDay(day)
        model.selectedDetail = model.workspace.activities.first(where: \.isRaw).map {
          .conversation($0.id)
        }
        model.card.state.connected = true
        var parser = FrameParser()
        for (sequence, payload) in [[3, 20, 1], [3, 22, 72, 10, 0, 0, 0, 0], [0, 4, 58]]
          .enumerated()
        {
          if let frame = parser.push(Wire.frame(payload.map(UInt8.init), seq: UInt8(sequence)))
            .first
          {
            model.card.state.apply(frame)
          }
        }
        let volumeID = try unwrap(model.libraryURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
                                  "Missing fixture volume identifier.")
        let fixtureDisk = USBVolume(id: "usb:" + volumeID, url: model.libraryURL, name: "CB08")
        var results: [[String: Any]] = []
        for (name, width, height, dark) in [
          ("scene-prototype", 1536.0, 980.0, false),
          ("scene-wide", 1140.0, 760.0, false),
          ("scene-minimum", 690.0, 510.0, false),
          ("scene-dark", 1140.0, 760.0, true),
          ("scene-recorder-fw925", 900.0, 540.0, false),
          ("scene-sidebar-recording", 900.0, 540.0, false),
          ("scene-device-disconnected", 900.0, 540.0, false),
          ("scene-device-first-use", 900.0, 540.0, false),
          ("scene-recorder-usb", 690.0, 510.0, false),
          ("device-usb-transfer", 900.0, 540.0, false),
          ("device-usb-idle", 900.0, 540.0, false),
          ("device-usb-capacity-narrow", 690.0, 510.0, false),
          ("device-usb-complete", 900.0, 540.0, false),
          ("device-wifi-transfer", 900.0, 540.0, false),
          ("device-wifi-narrow", 690.0, 510.0, false),
          ("device-wifi-complete", 900.0, 620.0, false),
          ("device-wifi-cleanup-retry", 900.0, 620.0, false),
        ] {
          if name == "scene-recorder-fw925" {
            model.area = .device
            model.card.name = "FW925"
            model.card.onWiFiBound?(CaptureWiFiCard.id, "FW925")
            model.card.state.updateWiFi(raw: 0, battery: 64,
              storage: .init(totalMegabytes: 59_628, freeMegabytes: 59_627))
            devicePage = DevicePageCapture(bluetoothID: CaptureWiFiCard.id)
            await model.usb.scanMountedVolumes([fixtureDisk])
          } else if name == "scene-sidebar-recording" {
            model.card.state.updateWiFi(raw: 1, battery: 58,
              storage: .init(totalMegabytes: 59_628, freeMegabytes: 59_627))
            model.card.state.updateWiFi(event: .started, filename: "20261117103000")
          } else if name == "scene-device-disconnected" {
            model.area = .device
            model.card.disconnect()
          } else if name == "scene-device-first-use" {
            model.preferences.wifiBoundID = nil
            model.preferences.wifiBoundName = nil
          } else if name == "scene-recorder-usb" {
            model.preferences.autoSync = false
            try require(model.chooseRecorder(fixtureDisk), "Unable to select the fixture USB recorder.")
          } else if name.hasPrefix("device-") {
            if name == "device-usb-transfer" { try await prepareUSBInventory(fixtureDisk, model: model) }
            if name == "device-usb-complete" { try await completeUSBFixture(fixtureDisk, model: model) }
            try configureDevicePage(name, disk: fixtureDisk, model: model)
          } else if name == "scene-prototype" {
            model.selectedDetail = model.workspace.activities.first(where: { !$0.isRaw }).map {
              .conversation($0.id)
            }
          } else {
            model.selectedDetail = model.workspace.activities.first(where: \.isRaw).map {
              .conversation($0.id)
            }
          }
          model.preferences.theme = dark ? "dark" : "light"
          window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
          window.setContentSize(NSSize(width: width, height: height))
          window.setFrameOrigin(NSPoint(x: -16000, y: -16000))
          if model.area == .device && NSApp.isHidden { NSApp.unhideWithoutActivation() }
          window.orderBack(nil)
          model.desktop.refresh()
          try await Task.sleep(for: .milliseconds(400))
          window.contentView?.layoutSubtreeIfNeeded()
          window.displayIfNeeded()
          let frameView = try unwrap(window.contentView?.superview, "Missing native window frame.")
          let toolbar = try unwrap(window.toolbar, "The Window scene has no native toolbar.")
          let close = try unwrap(
            window.standardWindowButton(.closeButton), "Missing native close button.")
          let closeFrame = close.convert(close.bounds, to: frameView)
          let itemViews = toolbar.items.flatMap { ($0 as? NSToolbarItemGroup)?.subitems ?? [$0] }
            .compactMap(\.view).filter { $0.bounds.width > 0 && $0.bounds.height > 0 }
          let itemFrames = itemViews.map { $0.convert($0.bounds, to: frameView) }
          let rowDelta = itemFrames.map { abs($0.midY - closeFrame.midY) }.max() ?? .infinity
          let chromeHeight = window.frame.height - window.contentLayoutRect.maxY
          let trailingGap = window.frame.width - (itemFrames.map(\.maxX).max() ?? 0)
          let png = try capturePNG(frameView)
          try png.write(to: output.appendingPathComponent(name + ".png"))
          let boundaryDelta = try toolbarBoundaryDelta(png: png, size: frameView.bounds.size,
            chromeHeight: chromeHeight)
          try require(
            !activated && !NSApp.isActive, "The capture application took foreground focus.")
          try require(!itemFrames.isEmpty, "The native toolbar has no rendered controls.")
          try require(
            rowDelta <= 8, "Window buttons and toolbar controls are on separate rows: \(rowDelta).")
          try require(
            chromeHeight <= 60, "The native title/toolbar area is too tall: \(chromeHeight).")
          try require(
            trailingGap <= 30,
            "Mac tasks and the More menu are not trailing aligned: \(trailingGap).")
          try require(boundaryDelta <= 0.01,
            "The sidebar background extends through the toolbar: color delta \(boundaryDelta).")
          if model.area == .device {
            try await verifyDeviceControls(in: window, frame: frameView, png: png, name: name, model: model)
          }
          if name.hasPrefix("device-") {
            try verifyDevicePage(name, png: png, model: model)
          }
          if name.hasPrefix("scene-recorder-") {
            let menu = try unwrap(NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "导航" },
                                  "Missing navigation menu.")
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            let command = try unwrap(menu.items.first { $0.keyEquivalent.lowercased() == "r" },
                                     "Missing recorder sync shortcut.")
            let expected = name == "scene-recorder-fw925" ? "同步 FW925 的录音" : "同步 CB08 的录音"
            try require(command.title == expected && command.keyEquivalentModifierMask.contains(.command),
                        "Unexpected recorder sync menu: " + command.title)
            if name == "scene-recorder-fw925" {
              // A hidden application can construct a sheet without attaching it to the window.
              // Show the isolated offscreen parent without transferring keyboard focus.
              NSApp.unhideWithoutActivation()
              window.orderBack(nil)
              model.showRecorderPicker()
              for _ in 0..<100 where window.attachedSheet == nil {
                try await Task.sleep(for: .milliseconds(25))
              }
              let sheet = try unwrap(window.attachedSheet, "The recorder picker did not attach to the window.")
              try require(model.card.state.connected, "Opening the picker disconnected the current recorder.")
              let sheetView = try unwrap(sheet.contentView?.superview, "Missing recorder picker frame.")
              try capturePNG(sheetView).write(to: output.appendingPathComponent("scene-recorder-picker.png"))
              model.showsRecorderPicker = false
              for _ in 0..<100 where window.attachedSheet != nil {
                try await Task.sleep(for: .milliseconds(25))
              }
              try require(window.attachedSheet == nil && model.card.state.connected && model.recorderName == "FW925",
                          "Dismissing the picker changed the current device.")
            } else {
              let key = try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15),
                "Cannot create shortcut event.")
              try require(menu.performKeyEquivalent(with: key) && model.manualSyncVolumes == [fixtureDisk.id],
                          "Command-R did not select the fixture USB volume.")
            }
          }
          var info: [String: Any] = [
            "name": name, "windowWidth": window.frame.width, "windowHeight": window.frame.height,
            "nativeChromeHeight": chromeHeight, "toolbarControlCenterDelta": rowDelta,
            "nativeToolbarStyle": window.toolbarStyle.rawValue,
            "trailingControlGap": trailingGap,
            "toolbarSidebarBoundaryColorDelta": boundaryDelta,
            "tookForegroundFocus": activated, "toolbarItemCount": toolbar.items.count,
          ]
          if model.area == .device || name.hasPrefix("device-") {
            info["deviceContentWidth"] = deviceContentWidth
            info["usesInjectedDeviceData"] = true
            info["recorderSidebarTitle"] = model.recorderSidebarTitle
            info["canStartSync"] = model.recorderSyncTarget != nil
          }
          results.append(info)
        }
        let result: [String: Any] = ["passed": true, "processID": pid, "captures": results]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
          .write(to: output.appendingPathComponent("scene-validation.json"))
      } catch {
        let result: [String: Any] = [
          "passed": false, "error": error.localizedDescription,
          "tookForegroundFocus": activated,
        ]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
          .write(to: output.appendingPathComponent("scene-validation.json"))
      }
    }
  }

  private static func prepareUSBInventory(_ disk: USBVolume, model: AppModel) async throws {
    await model.usb.scanMountedVolumes([])
    let directory = disk.url.appendingPathComponent("record", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for index in 0..<8 {
      let url = directory.appendingPathComponent("note20261119-10321\(index).wav")
      let audio = AudioFiles.wav(pcm: Data(repeating: UInt8(index + 10), count: 64_000))
      try audio.write(to: url)
      try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-20)],
                                            ofItemAtPath: url.path)
      if index < 5 { _ = try await model.store.importAudio(url, sourceID: disk.id) }
    }
    // The USB fixture uses a writable folder on the test volume. Run its real inventory scan.
    model.preferences.cleanCardAfterSync = false
    await model.reload()
    await model.usb.scanMountedVolumes([disk], at: Date().addingTimeInterval(-10))
    await model.usb.scanMountedVolumes([disk])
    for _ in 0..<200 where model.sync.isBusy { try await Task.sleep(for: .milliseconds(20)) }
    try require(!model.sync.isBusy, "The USB fixture did not finish its initial scan.")
  }

  private static func completeUSBFixture(_ disk: USBVolume, model: AppModel) async throws {
    model.syncRecorder(.usb(disk.id))
    await model.usb.scanMountedVolumes([disk])
    for _ in 0..<200 where model.sync.isBusy { try await Task.sleep(for: .milliseconds(20)) }
    try require(model.sync.deviceRun.saved == 3, "The USB coordinator did not archive three new recordings.")
    try require(model.pendingCount.total == 0, "The USB fixture still has pending recordings.")
  }

  private static func configureDevicePage(_ name: String, disk: USBVolume, model: AppModel) throws {
    let now = ProcessInfo.processInfo.systemUptime
    func sample(name: String, total: Int64, copied: Int64, rate: Int64) throws -> DeviceSyncTransfer {
      // Model an existing resume offset, followed by 2 s of fresh bytes.
      let initial = copied - 2 * rate
      var meter = TransferMeter(total: total, initialBytes: initial, at: now - 2)
      _ = meter.update(initial + rate, at: now - 1)
      let progress = try unwrap(meter.update(copied, at: now), "Missing transfer sample.")
      return .init(name: name, position: 2, count: 5, progress: progress)
    }

    if name.hasPrefix("device-usb") {
      if name == "device-usb-transfer" {
        let files = USBMonitor.files(disk).files
        let planned = Array(files.suffix(4)) + Array(files.dropFirst(3).prefix(1))
        let progress = try sample(name: "note20261119-103215.wav", total: 180_000_000,
                                  copied: 84_000_000, rate: 14_600_000).progress
        model.sync.setSceneTransfer(progress, files: planned)
      } else if name == "device-usb-idle" {
        model.sync.setSceneTransfer(nil)
      }
      devicePage = DevicePageCapture(
        diskSpace: .init(free: 28_400_000_000, total: 32_000_000_000),
        diskIdentifier: "12345678-CB08-4321-8000-000000000001",
        expandsTechnicalInfo: name == "device-usb-idle",
        width: name == "device-usb-capacity-narrow" ? 235 : nil)
    } else {
      let id = CaptureWiFiCard.id
      model.card.onWiFiBound?(id, "FW925")
      model.card.name = "FW925"
      let transferring = name == "device-wifi-transfer" || name == "device-wifi-narrow"
      model.card.state.connected = !transferring
      model.card.state.updateWiFi(raw: 0, battery: 64,
        storage: .init(totalMegabytes: 59_628, freeMegabytes: 59_627))
      let cleanupRetry = name == "device-wifi-cleanup-retry"
      model.preferences.cleanCardAfterSync = cleanupRetry
      if transferring {
        let transfer = try sample(name: "20261119103215", total: 60_000_000,
                                  copied: 24_000_000, rate: 2_400_000)
        model.wifiSync.setSceneState(id: id, transfer: transfer,
                                    inventory: .init(discovered: 8, complete: true, pending: 5))
      } else {
        let copies = cleanupRetry ? "已删除 3 段卡内副本。2 段副本待清理，可重新同步。"
          : "卡内副本已保留。"
        model.wifiSync.setSceneState(id: id, outcome: .init(saved: 5, copies: copies),
                                    pendingCleanup: cleanupRetry ? 2 : 0)
      }
      devicePage = DevicePageCapture(
        bluetoothID: transferring ? nil : id,
        width: name == "device-wifi-narrow" ? 235 : nil)
    }
    model.area = .device
  }

  private static func verifyDevicePage(_ name: String, png: Data, model: AppModel) throws {
    let words = try recognize(png)
    let text = words.map(\.0).joined(separator: " ").replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "巳用", with: "已用")
      .replacingOccurrences(of: "己用", with: "已用")
    let transferring = ["device-usb-transfer", "device-wifi-transfer", "device-wifi-narrow"].contains(name)
    if transferring {
      let expected = model.usesWiFiCard ? "FW925" : "CB08"
      try require(model.recorderSidebarTitle == expected && model.recorderName == expected,
                  "The sidebar and page disagree on the active recorder.")
      try require(model.recorderSyncTarget == nil && !model.canChangeCard,
                  "A recorder action is available during transfer.")
      let hasStartButton = words.contains {
        $0.0.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) == "同步录音"
      }
      try require(!hasStartButton && !text.contains("立即同步") && !text.contains("重试同步"),
                  "The transfer scene displays another sync action.")
      if name != "device-wifi-narrow" {
        try require(words.contains { $0.0 == expected && $0.1.midX < 0.17 },
                    "The sidebar does not render the active recorder name.")
      }
    }
    let required: [String]
    switch name {
    case "device-usb-transfer":
      required = ["正在同步录音", "USB数据线", "第2段", "note20261119-103215.wav", "84", "180", "14.6MB/s", "46%"]
    case "device-wifi-transfer", "device-wifi-narrow":
      required = ["正在同步录音", "Wi-Fi热点", "第2段", "20261119103215", "24", "60", "2.4MB/s", "40%"]
    case "device-usb-idle":
      required = ["总容量32GB", "已用3.6GB", "剩余28.4GB", "已用11%", "共8段", "3段待同步", "立即同步", "技术信息", "磁盘标识"]
    case "device-usb-capacity-narrow":
      required = ["总容量32GB", "已用3.6GB", "剩余28.4GB", "已用11%", "立即同步"]
      try require(deviceContentWidth == 235, "Unexpected capacity content width: \(deviceContentWidth)")
    case "device-usb-complete":
      required = ["已保存到Mac3段", "卡内副本已保留", "共8段", "段待同步"]
    case "device-wifi-cleanup-retry":
      required = ["已保存到Mac5段", "已删除3段卡内副本", "2段副本待清理"]
      // Read the action row separately when whole-window OCR merges small button glyphs.
      if !text.contains("重试清理卡内副本") {
        let actions = try recognize(png, region: CGRect(x: 0.15, y: 0.12, width: 0.7, height: 0.28))
        try require(actions.contains { $0.0.replacingOccurrences(of: " ", with: "").contains("重试清理卡内副本") },
                    "Missing cleanup retry button.")
      }
    default:
      required = ["已保存到Mac5段", "卡内副本已保留", "总容量59.628GB", "已用1MB", "剩余59.627GB", "共2段", "2段待同步", "电量64%"]
    }
    try require(required.allSatisfy(text.contains), "Missing device content in \(name): \(text)")
    if name == "device-wifi-narrow" {
      try require(deviceContentWidth == 235, "Unexpected content width: \(deviceContentWidth)")
      let bytes = try unwrap(words.first { $0.0.contains("已传") }, "Missing transferred byte count.")
      let rate = try unwrap(words.first { $0.0.contains("MB/s") }, "Missing transfer speed.")
      try require(rate.1.midY < bytes.1.midY, "Narrow transfer speed did not wrap below the byte count.")
    }
  }

  private static func recognize(_ png: Data, region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1))
    throws -> [(String, CGRect)] {
    let request = VNRecognizeTextRequest()
    request.regionOfInterest = region
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    try VNImageRequestHandler(data: png).perform([request])
    return (request.results ?? []).compactMap { observation in
      observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
    }
  }

  private static func verifyDeviceControls(in window: NSWindow, frame: NSView, png: Data,
                                           name: String, model: AppModel) async throws {
    let action: String
    switch name {
    case "scene-recorder-fw925": action = "同步录音"
    case "scene-sidebar-recording": action = "查看实时字幕"
    case "scene-device-disconnected": action = "重新连接"
    case "scene-device-first-use": action = "选择录音卡"
    default: return
    }

    // SwiftUI draws prominent buttons inside its hosting view. Locate the label in the actual
    // window capture, then dispatch the click only to this offscreen window.
    let words = try recognize(png)
    let labels = words.filter { $0.1.midX > 0.17 && $0.1.midY < 0.90 }
    let button = try unwrap(labels.first { $0.0.trimmingCharacters(in: .punctuationCharacters) == action },
                            "Missing " + action + " in " + name + ": " + labels.map(\.0).joined(separator: " | "))
    let title = name == "scene-device-first-use" ? "录音卡" : "FW925"
    try require(labels.first?.0 == title || labels.contains { $0.0 == title && $0.1.midY > 0.75 },
                "Incorrect device title in " + name)
    try require(!words.contains { $0.1.midY > 0.94 && ($0.0.contains("FW925") || $0.0.contains("录音")) },
                "Duplicate toolbar status on the device page.")
    let pageText = labels.map(\.0).joined(separator: " ")
    if name == "scene-recorder-fw925" {
      let compact = pageText.replacingOccurrences(of: " ", with: "")
      try require(["共2段", "2段待同步"].allSatisfy(compact.contains), "Missing idle Bluetooth inventory: " + pageText)
    }
    if name == "scene-recorder-fw925" || name == "scene-sidebar-recording" {
      try require(["技术信息", "传输方式", "Wi-Fi", "59.628", "59.627"].allSatisfy(pageText.contains),
                  "Missing connected card details: " + pageText)
      if name == "scene-sidebar-recording" {
        try require(pageText.contains("20261117103000"), "Missing current recording filename.")
        try require(pageText.contains("录音保存后读取"), "Recording page should defer its inventory.")
      }
    } else {
      try require(!pageText.contains("59.628") && !pageText.contains("20261117103000"),
                  "Disconnected page shows live details from the last card.")
    }
    func click() throws {
      let center = CGPoint(x: button.1.midX * frame.bounds.width,
                           y: (frame.isFlipped ? 1 - button.1.midY : button.1.midY) * frame.bounds.height)
      let point = frame.convert(center, to: nil)
      func event(_ type: NSEvent.EventType) throws -> NSEvent {
        try unwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0),
          "Cannot generate device action event.")
      }
      NSApp.postEvent(try event(.leftMouseUp), atStart: true)
      window.sendEvent(try event(.leftMouseDown))
      if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
        window.sendEvent(up)
      }
    }
    switch name {
    case "scene-recorder-fw925":
      try click()
      for _ in 0..<80 where model.wifiSync.phase != .hotspot { try await Task.sleep(for: .milliseconds(25)) }
      try require(model.wifiSync.phase == .hotspot, "The idle action did not start fixture synchronization.")
      model.wifiSync.cancel()
      await model.wifiSync.shutdown()
      model.wifiSync.clearDeviceResult()
    case "scene-sidebar-recording":
      try require(model.recorderSyncTarget == nil, "Recording must disable Wi-Fi sync.")
      try click()
      for _ in 0..<40 where model.area != .live { try await Task.sleep(for: .milliseconds(25)) }
      try require(model.area == .live, "The recording action did not open live captions.")
    case "scene-device-first-use":
      try click()
      for _ in 0..<40 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(25)) }
      try require(window.attachedSheet != nil, "The first-use action did not open the recorder picker.")
      model.showsRecorderPicker = false
      for _ in 0..<40 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(25)) }
    default: break
    }
  }

  private static func capturePNG(_ view: NSView) throws -> Data {
    view.layoutSubtreeIfNeeded()
    let bitmap = try unwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds), "Cannot capture native view.")
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return try unwrap(bitmap.representation(using: .png, properties: [:]), "Cannot encode capture.")
  }

  /// Sample the actual sidebar edge below the toolbar, then check that it stops at the toolbar.
  private static func toolbarBoundaryDelta(png: Data, size: NSSize, chromeHeight: CGFloat) throws -> Double {
    let image = try unwrap(NSBitmapImageRep(data: png), "Cannot inspect the native capture.")
    let scaleX = CGFloat(image.pixelsWide) / size.width
    let scaleY = CGFloat(image.pixelsHigh) / size.height
    func rgb(_ x: CGFloat, _ y: CGFloat) throws -> [CGFloat] {
      let color = try unwrap(image.colorAt(x: Int(x * scaleX), y: Int(y * scaleY))?
        .usingColorSpace(.deviceRGB), "Cannot inspect a toolbar pixel.")
      return [color.redComponent, color.greenComponent, color.blueComponent]
    }
    func difference(_ first: [CGFloat], _ second: [CGFloat]) -> CGFloat {
      zip(first, second).map { abs($0 - $1) }.max() ?? 0
    }
    let bodyY = chromeHeight + 3
    let sidebar = try rgb(20, bodyY)
    var edge: CGFloat?
    for x in 30...min(300, Int(size.width) - 20) {
      if try difference(sidebar, rgb(CGFloat(x), bodyY)) > 0.02 {
        edge = CGFloat(x)
        break
      }
    }
    let boundary = try unwrap(edge, "Cannot locate the sidebar background boundary.")
    return Double(try difference(rgb(boundary - 6, 5), rgb(boundary + 6, 5)))
  }

  private static func require(_ condition: Bool, _ message: String) throws {
    if !condition {
      throw NSError(
        domain: "WorkdaySceneCapture", code: 1,
        userInfo: [NSLocalizedDescriptionKey: message])
    }
  }

  private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
      throw NSError(
        domain: "WorkdaySceneCapture", code: 2,
        userInfo: [NSLocalizedDescriptionKey: message])
    }
    return value
  }
}

// Exercises the coordinator up to the hotspot request without touching Bluetooth or the Mac's network.
private final class CaptureWiFiCard: WiFiSyncBluetooth {
  static let id = "12345678-ABCD-4321-8000-000000000925"
  let preferredKind = RecorderKind.wifi
  let boundID: String? = CaptureWiFiCard.id
  var wifiBusy = false, holdReconnect = false
  var onWiFiState: ((UInt8) -> Void)?
  var onHotspot: ((HotspotCredentials) -> Void)?
  var onSocket: (() -> Void)?
  var onWiFiLost: (() -> Void)?
  var onWiFiFilePacket: ((Packet) -> Void)?
  func queryWiFiState() { onWiFiState?(0) }
  func openWiFiHotspot(for id: String) {}
  func releaseForWiFi() {}
  @MainActor func readWiFiFileList(for id: String, duringSync: Bool) async throws -> [RecordingEntry] {
    guard id == boundID && !duringSync else { throw CancellationError() }
    return try ["20261119102100", "20261119103215"].map {
      try RecordingEntry([0] + Array($0.utf8) + WiFiRecorderCore.Wire.beBytes(120_000))
    }
  }
  func deleteWiFiFile(_ file: RecordingEntry, from id: String) -> Bool { false }
}
