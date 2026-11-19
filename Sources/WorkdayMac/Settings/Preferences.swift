import Foundation
import Security
import WorkdayCore

struct Preferences: Codable {
  var usbOnlyVolumeID: String?
  var usbOnlyVolumeName: String?
  var boundID: String?
  var boundName = "未绑定录音卡"
  var recorderKind = RecorderKind.usb
  var wifiBoundID: String?
  var wifiBoundName: String?
  var selectedRecorderID: String? { recorderKind == .wifi ? wifiBoundID : boundID }
  var selectedRecorderName: String { recorderKind == .wifi ? wifiBoundName ?? "Wi-Fi 录音卡" : boundName }
  var autoConnect = true
  var autoSync = true
  var cleanCardAfterSync = true
  var autoOrganize = true
  var cloudEnabled = false
  var realtime = true
  var liveModel: LiveASRModel = .streaming
  var theme = "system"
  var useMacMicrophone = false
  var captions = CaptionPreferences()
  var libraryPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
    "Documents/工作留声"
  ).path
  init() {}
  private enum CodingKeys: String, CodingKey {
    case boundID, boundName, autoConnect, autoSync, cleanCardAfterSync, autoOrganize, cloudEnabled, realtime
    case recorderKind, wifiBoundID, wifiBoundName, usbOnlyVolumeID, usbOnlyVolumeName
    case liveModel, theme, captions, libraryPath, useMacMicrophone
  }
  init(from decoder: Decoder) throws {
    self.init()
    let values = try decoder.container(keyedBy: CodingKeys.self)
    recorderKind = try values.decodeIfPresent(RecorderKind.self, forKey: .recorderKind) ?? .usb
    usbOnlyVolumeID = try values.decodeIfPresent(String.self, forKey: .usbOnlyVolumeID)
    usbOnlyVolumeName = try values.decodeIfPresent(String.self, forKey: .usbOnlyVolumeName)
    wifiBoundID = try values.decodeIfPresent(String.self, forKey: .wifiBoundID)
    wifiBoundName = try values.decodeIfPresent(String.self, forKey: .wifiBoundName)
    boundID = try values.decodeIfPresent(String.self, forKey: .boundID)
    boundName = try values.decodeIfPresent(String.self, forKey: .boundName) ?? boundName
    autoConnect = try values.decodeIfPresent(Bool.self, forKey: .autoConnect) ?? autoConnect
    autoSync = try values.decodeIfPresent(Bool.self, forKey: .autoSync) ?? autoSync
    cleanCardAfterSync = try values.decodeIfPresent(Bool.self, forKey: .cleanCardAfterSync)
      ?? cleanCardAfterSync
    autoOrganize = try values.decodeIfPresent(Bool.self, forKey: .autoOrganize) ?? autoOrganize
    cloudEnabled = try values.decodeIfPresent(Bool.self, forKey: .cloudEnabled) ?? cloudEnabled
    realtime = try values.decodeIfPresent(Bool.self, forKey: .realtime) ?? realtime
    if let saved = try? values.decode(String.self, forKey: .liveModel) {
      // Carry the former file-review preference forward to ESP sentence review.
      liveModel = saved == "qwen-audio-3.1-asr-flash-filetrans" ? .segment : LiveASRModel(rawValue: saved) ?? .streaming
    }
    theme = try values.decodeIfPresent(String.self, forKey: .theme) ?? theme
    useMacMicrophone = try values.decodeIfPresent(Bool.self, forKey: .useMacMicrophone) ?? false
    captions = try values.decodeIfPresent(CaptionPreferences.self, forKey: .captions) ?? captions
    libraryPath = try values.decodeIfPresent(String.self, forKey: .libraryPath) ?? libraryPath
  }
  private static let storageKey = "WorkdayPreferences"

  static func load(defaults: UserDefaults = .standard, legacyDomain: String = "cn.workday.recorder")
    -> Preferences
  {
    if defaults.object(forKey: storageKey) != nil {
      guard let data = defaults.data(forKey: storageKey) else { return Self() }
      return (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
    }
    // Import only settings supported by this version into the new preferences domain.
    guard let data = defaults.persistentDomain(forName: legacyDomain)?[storageKey] as? Data,
      let preferences = try? JSONDecoder().decode(Self.self, from: data)
    else { return Self() }
    if let migrated = try? JSONEncoder().encode(preferences) {
      defaults.set(migrated, forKey: storageKey)
    }
    return preferences
  }
  func save() {
    if let data = try? JSONEncoder().encode(self) {
      UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
  }
}

enum Credentials {
  private static var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "cn.workday.recorder", kSecAttrAccount as String: "esp",
    ]
  }
  static func load() -> String? {
    var query = query
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }
  static func save(_ value: String) throws {
    let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, key.count <= 2048, !key.contains("\n") else {
      throw NSError(
        domain: "Workday", code: 1, userInfo: [NSLocalizedDescriptionKey: "请输入有效的 API Key"])
    }
    let data = Data(key.utf8)
    let status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var entry = query
      entry[kSecValueData as String] = data
      entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else {
        throw NSError(domain: "Workday", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法保存到钥匙串"])
      }
      return
    }
    guard status == errSecSuccess else {
      throw NSError(
        domain: "Workday", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "钥匙串保存失败"])
    }
  }
}
