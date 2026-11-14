import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchAppModel

final class SettingsStoreTests: XCTestCase {
    var root: URL!
    var url: URL { root.appending(path: "config/settings.json") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "SettingsStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "config"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    func file() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func write(_ text: String) throws { try Data(text.utf8).write(to: url) }

    func testMissingFileGivesDefaultsAndTrueBoolsMeanOnWhenAbsent() {
        let store = JSONFileSettingsStore(url: url)
        XCTAssertNil(store.value("checkProviderStatus"))
        XCTAssertEqual(store.effective("checkProviderStatus"), .bool(true))
        XCTAssertEqual(store.effective("privacyMode"), .bool(false))
        XCTAssertEqual(store.effective("autoSwitchThreshold"), .int(1))
        XCTAssertEqual(Set(SettingsRegistry.keys.filter(\.absentMeansOn).map(\.key)),
                       ["checkProviderStatus", "showAccountUsageInMenuBar"])
        XCTAssertNil(store.notice)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "reading never creates the file")
    }

    func testWriteUsesTheEnvelopeKeepsUnknownKeysAndIsOwnerOnly() throws {
        try write(#"{"schemaVersion":1,"values":{"futureKey":{"a":1},"privacyMode":true}}"#)
        let store = JSONFileSettingsStore(url: url)
        XCTAssertEqual(store.value("privacyMode"), .bool(true))
        try store.set("globalShortcut", .object(["keyCode": .int(1), "modifiers": .int(4096)]))
        try store.set("hiddenUsageRows.\(UUID().uuidString.lowercased())", .string("session\nweekly"))
        let saved = try file()
        XCTAssertEqual(saved["schemaVersion"] as? Int, 1)
        let values = try XCTUnwrap(saved["values"] as? [String: Any])
        XCTAssertNotNil(values["futureKey"], "unknown keys are kept")
        XCTAssertEqual((values["globalShortcut"] as? [String: Any])?["keyCode"] as? Int, 1, "Data keys are nested JSON")
        XCTAssertEqual(store.keys(prefix: "hiddenUsageRows.").count, 1)
        #if !os(Windows)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        #endif
        try store.remove(["privacyMode"])
        XCTAssertEqual(store.effective("privacyMode"), .bool(false))
    }

    func testValidationRefusesUnknownKeysWrongTypesChoicesAndLargeValues() throws {
        let store = JSONFileSettingsStore(url: url)
        XCTAssertThrowsError(try store.set("noSuchKey", .bool(true))) { XCTAssertEqual($0 as? SettingsError, .unknownKey("noSuchKey")) }
        XCTAssertThrowsError(try store.set("privacyMode", .string("yes"))) { XCTAssertEqual($0 as? SettingsError, .invalidValue("privacyMode")) }
        XCTAssertThrowsError(try store.set("autoSwitchThreshold", .int(3)))
        XCTAssertThrowsError(try store.set("timeFormat", .string("36h")))
        let big = String(repeating: "x", count: SettingsRegistry.maximumValueBytes)
        XCTAssertThrowsError(try store.set("autoSwitchResumeMessage", .string(big))) {
            XCTAssertEqual($0 as? SettingsError, .tooLarge("autoSwitchResumeMessage"))
        }
        try store.set("chat.threadsScroll", .int(12))
        XCTAssertEqual(store.value("chat.threadsScroll"), .int(12), "a whole number is a valid Double")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path.replacingOccurrences(of: ".json", with: ".tmp")))
    }

    func testWrongTypeAndOversizedValuesReadAsDefaultAndAreLoggedOnce() throws {
        let big = String(repeating: "x", count: SettingsRegistry.maximumValueBytes + 1)
        try write(#"{"schemaVersion":1,"values":{"privacyMode":"on","autoSwitchResumeMessage":"\#(big)"}}"#)
        var lines: [String] = []
        let store = JSONFileSettingsStore(url: url, log: { lines.append($0) })
        XCTAssertEqual(store.effective("privacyMode"), .bool(false))
        XCTAssertEqual(store.effective("privacyMode"), .bool(false))
        XCTAssertNil(store.value("autoSwitchResumeMessage"))
        XCTAssertEqual(lines.count, 2)
    }

    func testCorruptFileIsMovedAsideKeepingTheNewestThree() throws {
        for stamp in [100, 200, 300] {
            try Data("old".utf8).write(to: root.appending(path: "config/settings.corrupt-\(stamp).json"))
        }
        try write("{not json")
        let store = JSONFileSettingsStore(url: url, now: Date(timeIntervalSince1970: 400))
        XCTAssertNotNil(store.notice)
        XCTAssertEqual(store.effective("timeFormat"), .string("auto"))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "config").path).sorted()
        XCTAssertEqual(names, ["settings.corrupt-200.json", "settings.corrupt-300.json", "settings.corrupt-400.json"])
        try store.set("timeFormat", .string("24h"))
        XCTAssertEqual(try file()["schemaVersion"] as? Int, 1)

        try write(#"{"values":{}}"#)
        XCTAssertNotNil(JSONFileSettingsStore(url: url, now: Date(timeIntervalSince1970: 500)).notice, "no envelope is corrupt")
    }

    func testNewerSchemaIsReadButNeverWritten() throws {
        let text = #"{"schemaVersion":2,"values":{"privacyMode":true,"newThing":1}}"#
        try write(text)
        let store = JSONFileSettingsStore(url: url)
        XCTAssertEqual(store.value("privacyMode"), .bool(true))
        XCTAssertNotNil(store.notice)
        XCTAssertThrowsError(try store.set("privacyMode", .bool(false))) { XCTAssertEqual($0 as? SettingsError, .readOnly) }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
    }

    func engine(_ store: any SettingsStore) -> AppEngine {
        let paths = ManagerPaths(applicationSupport: root.appending(path: "support"),
                                 credentialStore: root.appending(path: "user/.switch/codex"),
                                 defaultHome: root.appending(path: "user/.codex"), sharedRoot: root.appending(path: "user/.codex"),
                                 orcaAccountsRoot: root.appending(path: "orca"), isolationRoot: root)
        return AppEngine(manager: nil, paths: paths, clock: ManualClock(), settings: store)
    }

    func testResetRemovesTheSettingsGroupOnly() async throws {
        try write(#"{"schemaVersion":1,"values":{"futureKey":1,"privacyMode":true,"lastPage":"overview","#
            + #""hiddenUsageRows.ABC":"session","showAccountUsageInMenuBar.account.ABC":false,"checkProviderStatus":false}}"#)
        let store = JSONFileSettingsStore(url: url)
        let engine = engine(store)
        try await engine.resetSettings()
        XCTAssertEqual(store.storedKeys, ["futureKey", "lastPage"], "kept keys and unknown keys stay")
        XCTAssertEqual(store.effective("checkProviderStatus"), .bool(true))
        try await engine.resetSettings(.kept)
        XCTAssertEqual(store.storedKeys, ["futureKey"])
    }

    func testErrorTextsFollowPrivacyMode() async throws {
        let store = JSONFileSettingsStore(url: url)
        let engine = engine(store)
        let confirm = DroidAccountError.confirmSignIn("Alice Work")
        let mismatch = AIManagerError.signInIdentityMismatch(signedIn: "ada@mail.co.uk", target: "org-7")
        XCTAssertEqual(engine.describe(confirm), confirm.localizedDescription)
        XCTAssertEqual(engine.describe(mismatch), mismatch.localizedDescription, "the Mac shows full text without privacy")
        try store.set("privacyMode", .bool(true))
        XCTAssertFalse(engine.describe(confirm).contains("Alice"))
        XCTAssertTrue(engine.describe(confirm).contains(PrivacyText.fakeName(seed: "Alice Work")))
        let masked = engine.describe(mismatch)
        XCTAssertFalse(masked.contains("ada@") || masked.contains("org-7"), masked)
        try store.set("privacyMode", .bool(false))
        try store.set("hideEmailAddresses", .bool(true))
        XCTAssertTrue(engine.describe(mismatch).contains("a••••@mail"))
    }

    func testEngineTopicFollowsWrites() async throws {
        let clock = ManualClock()
        let store = JSONFileSettingsStore(url: url)
        let paths = ManagerPaths(applicationSupport: root.appending(path: "support"),
                                 credentialStore: root.appending(path: "user/.switch/codex"),
                                 defaultHome: root.appending(path: "user/.codex"), sharedRoot: root.appending(path: "user/.codex"),
                                 orcaAccountsRoot: root.appending(path: "orca"), isolationRoot: root)
        XCTAssertEqual(JSONFileSettingsStore.location(paths: paths, environment: [:]), root.appending(path: "settings.json"))
        let engine = AppEngine(manager: nil, paths: paths, clock: clock, settings: store)
        var changes = engine.changes.makeAsyncIterator()
        let before = try await engine.settingsValues(["showUsageAsUsed", "checkProviderStatus"])
        XCTAssertEqual(before.values, ["showUsageAsUsed": .bool(false), "checkProviderStatus": .bool(true)])
        try await engine.setSetting("showUsageAsUsed", .bool(true))
        let deadline = Date().addingTimeInterval(5)
        while clock.sleeperCount == 0, Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        clock.advance(seconds: AppEngine.coalesceInterval)
        let change = await changes.next()
        XCTAssertEqual(change?.topic, .settings)
        XCTAssertEqual((change?.value as? SettingsTopicValue)?.values["showUsageAsUsed"], .bool(true))
        do {
            _ = try await engine.settingsValues(["nope"])
            XCTFail("unknown key")
        } catch {
            XCTAssertEqual(error as? SettingsError, .unknownKey("nope"))
        }
    }
}
