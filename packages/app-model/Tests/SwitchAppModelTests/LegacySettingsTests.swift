import Foundation
import XCTest
@testable import SwitchAppModel

/// The one-time import of the old Linux `UserDefaults` suite into `settings.json`.
final class LegacySettingsTests: XCTestCase {
    func testImportsKnownKeysOnceIntoANewFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "LegacySettings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "settings.json")
        let legacy: [String: Any] = [
            "showUsageAsUsed": NSNumber(value: true), "timeFormat": "24h",
            "menuBarHiddenServices": ["droid"], "unknownKey": "x", "privacyMode": "not a bool",
        ]
        XCTAssertEqual(JSONFileSettingsStore.importLegacy(legacy, into: url), 3)
        let store = JSONFileSettingsStore(url: url)
        XCTAssertEqual(store.value("showUsageAsUsed"), .bool(true))
        XCTAssertEqual(store.value("timeFormat"), .string("24h"))
        XCTAssertEqual(store.value("menuBarHiddenServices"), .array([.string("droid")]))
        XCTAssertNil(store.value("privacyMode"))
        XCTAssertFalse(store.storedKeys.contains("unknownKey"))
        // An existing file is never overwritten.
        XCTAssertEqual(JSONFileSettingsStore.importLegacy(["timeFormat": "12h"], into: url), 0)
        XCTAssertEqual(JSONFileSettingsStore(url: url).value("timeFormat"), .string("24h"))
    }
}
