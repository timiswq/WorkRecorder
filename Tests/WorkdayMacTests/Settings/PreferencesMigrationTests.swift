import Foundation
import XCTest
import WorkdayCore

@testable import WorkdayMac

final class PreferencesMigrationTests: XCTestCase {
  func testESPModelSelectionPersistsAndFileTransMigratesToSentenceReview() throws {
    let decoder = JSONDecoder()
    for json in [#"{"boundName":"我的录音卡"}"#, #"{"boundName":"我的录音卡","liveModel":"retired"}"#] {
      let old = try decoder.decode(Preferences.self, from: Data(json.utf8))
      XCTAssertEqual(old.boundName, "我的录音卡")
      XCTAssertEqual(old.liveModel, .streaming)
      XCTAssertTrue(old.cleanCardAfterSync)
    }
    var prefs = Preferences()
    prefs.cleanCardAfterSync = false
    let previous = try decoder.decode(Preferences.self, from: Data(#"{"onlyMySpeech":true}"#.utf8))
    XCTAssertTrue(previous.captions.enabled)
    let migrated = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(previous)) as? [String: Any])
    XCTAssertNil(migrated["onlyMySpeech"])
    let legacy = #"{"liveModel":"qwen-audio-3.1-asr-flash-filetrans","recordingModel":"qwen-audio-3.0-asr-flash"}"#
    XCTAssertEqual(try decoder.decode(Preferences.self, from: Data(legacy.utf8)).liveModel, .segment)
    for live in LiveASRModel.allCases {
      prefs.liveModel = live
      let saved = try decoder.decode(Preferences.self, from: JSONEncoder().encode(prefs))
      XCTAssertEqual(saved.liveModel, live)
      XCTAssertFalse(saved.cleanCardAfterSync)
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
    var legacyFields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(previous)) as? [String: Any])
    legacyFields.removeValue(forKey: "useMacMicrophone")
    legacyFields["workspaceID"] = "retired-workspace"
    let data = try JSONSerialization.data(withJSONObject: legacyFields)
    defaults.setPersistentDomain([key: data], forName: legacy)

    let imported = Preferences.load(defaults: defaults, legacyDomain: legacy)
    XCTAssertFalse(imported.useMacMicrophone)
    XCTAssertEqual(imported.boundID, previous.boundID)
    XCTAssertEqual(imported.libraryPath, previous.libraryPath)
    XCTAssertTrue(imported.cloudEnabled)
    XCTAssertFalse(imported.realtime)
    let stored = try XCTUnwrap(defaults.data(forKey: key))
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
    XCTAssertNil(fields["workspaceID"])
    let saved = try JSONDecoder().decode(Preferences.self, from: stored)
    XCTAssertEqual(saved.libraryPath, previous.libraryPath)
    XCTAssertEqual(saved.boundID, previous.boundID)

    defaults.set(try JSONEncoder().encode(Preferences()), forKey: key)
    XCTAssertNil(Preferences.load(defaults: defaults, legacyDomain: legacy).boundID)
    XCTAssertEqual(defaults.persistentDomain(forName: legacy)?[key] as? Data, data)
  }
}
