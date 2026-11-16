import AppKit
import Foundation

extension AppModel {
  /// Explicit local diagnostic mode: isolated library, no credentials/cloud,
  /// no USB import and no start/stop recording command. Only subscribe/query.
  func startLiveVoiceValidationReport() {
    guard liveVoiceValidation, liveValidationTask == nil,
          let path = ProcessInfo.processInfo.environment["WORKDAY_LIVE_VOICE_REPORT"] else { return }
    let seconds = min(300, max(15, Int(ProcessInfo.processInfo.environment["WORKDAY_LIVE_VOICE_DURATION"] ?? "60") ?? 60))
    let output = URL(fileURLWithPath: path + ".device.jsonl")
    liveValidationTask = Task { [weak self] in
      guard let self else { return }
      do {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
          withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let file = try FileHandle(forWritingTo: output)
        defer { try? file.close() }
        for _ in 0..<seconds {
          try Task.checkCancellation()
          let row: [String: Any] = ["time": Date().timeIntervalSince1970,
            "connected": card.state.connected, "phase": card.state.phase.rawValue,
            "reportedRecordingSeconds": card.state.seconds.map { $0 as Any } ?? NSNull(),
            "receivedAudioBytes": receivedLiveAudioBytes, "voiceWindows": voices.liveWindowsProcessed,
            "cloudEnabled": preferences.cloudEnabled, "isolated": isolated,
            "deviceStatus": card.status, "deviceChoices": card.choices.count,
            "captionPhase": String(describing: localCaptions.phase),
            "captions": captionHistory.records.count,
            "rollingIdentityCaptions": captionHistory.records.filter { $0.evidenceID?.hasPrefix("realtime:") == true }.count]
          var data = try JSONSerialization.data(withJSONObject: row, options: .sortedKeys)
          data.append(10)
          try file.write(contentsOf: data)
          try await Task.sleep(for: .seconds(1))
        }
      } catch is CancellationError { return }
      catch { self.error = error.localizedDescription }
      NSApp.terminate(nil)
    }
  }
}
