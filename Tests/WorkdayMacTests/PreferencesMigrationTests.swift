import Foundation
import XCTest

@testable import WorkdayMac

final class PreferencesMigrationTests: XCTestCase {
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
