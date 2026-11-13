import Foundation
import XCTest
import WorkdayCore

@testable import WorkdayMac

final class PreferencesMigrationTests: XCTestCase {
  func testASRSelectionsPersistIndependentlyAndOlderSettingsKeepTheirValues() throws {
    let decoder = JSONDecoder()
    for json in [#"{"boundName":"我的录音卡"}"#, #"{"boundName":"我的录音卡","liveModel":"retired"}"#] {
      let old = try decoder.decode(Preferences.self, from: Data(json.utf8))
      XCTAssertEqual(old.boundName, "我的录音卡")
      XCTAssertEqual(old.liveModel, .streaming)
      XCTAssertEqual(old.recordingModel, .flash31)
    }
    var prefs = Preferences()
    let previous = try decoder.decode(Preferences.self, from: Data(#"{"onlyMySpeech":true}"#.utf8))
    XCTAssertTrue(previous.captions.enabled)
    let migrated = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(previous)) as? [String: Any])
    XCTAssertNil(migrated["onlyMySpeech"])
    for live in LiveASRModel.allCases {
      for file in RecordingASRModel.allCases {
        prefs.liveModel = live
        prefs.recordingModel = file
        let saved = try decoder.decode(Preferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(saved.liveModel, live)
        XCTAssertEqual(saved.recordingModel, file)
      }
    }
  }

  func testLegacyPreferencesAreImportedOnceWithoutOverwritingCurrentSettings() throws {
    let suite = "WorkRecorderTests." + UUID().uuidString
    let legacy = suite + ".legacy"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      defaults.removePersistentDomain(forName: legacy)
    }
    let key = "WorkdayPreferences"
    var previous = Preferences()
    previous.boundID = UUID().uuidString
    previous.libraryPath = "/example/custom-library"
    previous.cloudEnabled = true
    previous.realtime = false
    let data = try JSONEncoder().encode(previous)
    defaults.setPersistentDomain([key: data], forName: legacy)

    let imported = Preferences.load(defaults: defaults, legacyDomain: legacy)
    XCTAssertEqual(imported.boundID, previous.boundID)
    XCTAssertEqual(imported.libraryPath, previous.libraryPath)
    XCTAssertTrue(imported.cloudEnabled)
    XCTAssertFalse(imported.realtime)
    XCTAssertEqual(defaults.data(forKey: key), data)

    defaults.set(try JSONEncoder().encode(Preferences()), forKey: key)
    XCTAssertNil(Preferences.load(defaults: defaults, legacyDomain: legacy).boundID)
    XCTAssertEqual(defaults.persistentDomain(forName: legacy)?[key] as? Data, data)
  }
}
