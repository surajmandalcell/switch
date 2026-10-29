import XCTest
@testable import AIManagerCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class DroidLoginReaderTests: XCTestCase {
    private final class Keys: DroidLoginReader.KeyProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [Bool] = []
        let value: Data
        let denied: Bool
        init(value: Data = Data(repeating: 7, count: 32), denied: Bool = false) {
            self.value = value
            self.denied = denied
        }
        func key(interactive: Bool) throws -> Data {
            lock.lock()
            calls.append(interactive)
            lock.unlock()
            if denied { throw DroidLoginError.needsKeychainAccess }
            return value
        }
        var interactions: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    // Independent fixture made with Node's createCipheriv, matching the embedded Droid JS.
    private let fixture = "AwMDAwMDAwMDAwMDAwMDAw==:EkpUVlVRdJxqW6lLCyFIbw==:el0kIxn7lu64YseB8oT1fD5JQygpmF0Y0qbQw3MbZUk1sfco6nvtzVK7pcUwHadoxrNU+1JI0J91DxuXxkxew9Ez6r/dIR+1/Q3I3BcZhwA8gIkhplkEIBFC6Pg/QEXhb4oaOVUcz/07rEG5qcBYFFbXO15Oqg89caUdksyOtMtmue/MtwiOoYcC"
    private var files: [String: Data] { ["auth.v2.loginkeychain": Data(fixture.utf8)] }

    private func token(expiry: Int) -> String {
        let payload = Data("{\"exp\":\(expiry)}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(payload).synthetic"
    }

    private func encrypted(expiry: Int) throws -> Data {
        let clear = try JSONSerialization.data(withJSONObject: [
            "access_token": token(expiry: expiry), "refresh_token": "unused-synthetic",
        ])
        let box = try AES.GCM.seal(clear, using: SymmetricKey(data: Data(repeating: 7, count: 32)),
                                   nonce: AES.GCM.Nonce(data: Data(repeating: 3, count: 16)))
        return Data([Data(box.nonce), box.tag, box.ciphertext].map { $0.base64EncodedString() }.joined(separator: ":").utf8)
    }

    func testIndependentFixtureTokenExpiryAndBackgroundNeverRequestsUI() throws {
        let keys = Keys()
        let login = try DroidLoginReader(keyProvider: keys).read(files: files)
        XCTAssertTrue(login.accessToken == token(expiry: 4_102_444_800))
        XCTAssertEqual(login.expiresAt, Date(timeIntervalSince1970: 4_102_444_800))
        XCTAssertEqual(keys.interactions, [false])
    }

    func testInteractiveReadRequestsUIOnlyOnce() throws {
        let keys = Keys()
        _ = try DroidLoginReader(keyProvider: keys).read(files: files, interactive: true)
        XCTAssertEqual(keys.interactions, [true])
    }

    func testDeniedKeyHasActionableStateAndNoAutomaticPrompt() {
        let keys = Keys(denied: true)
        XCTAssertThrowsError(try DroidLoginReader(keyProvider: keys).read(files: files)) {
            XCTAssertEqual($0 as? DroidLoginError, .needsKeychainAccess)
            XCTAssertEqual($0.localizedDescription, "Allow Switch to read Droid's login")
        }
        XCTAssertEqual(keys.interactions, [false])
    }

    func testWrongKeyAndMalformedLayoutFailCleanly() {
        let keys = Keys(value: Data(repeating: 8, count: 32))
        let reader = DroidLoginReader(keyProvider: keys)
        XCTAssertThrowsError(try reader.read(files: files)) { XCTAssertEqual($0 as? DroidLoginError, .invalidLogin) }
        for text in ["", "a:b", "a:b:c:d", "AAAA:AAAA:AAAA"] {
            XCTAssertThrowsError(try reader.read(files: ["auth.v2.loginkeychain": Data(text.utf8)])) {
                XCTAssertEqual($0 as? DroidLoginError, .invalidLogin)
            }
        }
        XCTAssertEqual(keys.interactions, [false])
    }

    private func gate(_ keys: Keys) -> (DroidLoginReader.GatedKeyProvider, UserDefaults) {
        let defaults = UserDefaults(suiteName: "switch-droid-gate-\(UUID().uuidString)")!
        return (.init(base: keys, defaults: defaults), defaults)
    }

    func testBackgroundNeverTouchesKeychainUntilOwnerClickAllowedIt() throws {
        let keys = Keys()
        let (gated, defaults) = gate(keys)
        XCTAssertThrowsError(try gated.key(interactive: false)) { XCTAssertEqual($0 as? DroidLoginError, .needsKeychainAccess) }
        XCTAssertTrue(keys.interactions.isEmpty)
        _ = try gated.key(interactive: true)
        XCTAssertTrue(defaults.bool(forKey: DroidLoginReader.GatedKeyProvider.allowedFlag))
        // The key stays in memory: later reads, even background ones, do not reach the Keychain.
        _ = try gated.key(interactive: false)
        XCTAssertEqual(keys.interactions, [true])
    }

    func testPersistedFlagLetsBackgroundReadAfterRestartAndFailureClearsIt() throws {
        let keys = Keys(denied: true)
        let (gated, defaults) = gate(keys)
        defaults.set(true, forKey: DroidLoginReader.GatedKeyProvider.allowedFlag)
        XCTAssertThrowsError(try gated.key(interactive: false)) { XCTAssertEqual($0 as? DroidLoginError, .needsKeychainAccess) }
        XCTAssertEqual(keys.interactions, [false])
        XCTAssertFalse(defaults.bool(forKey: DroidLoginReader.GatedKeyProvider.allowedFlag))
        XCTAssertThrowsError(try gated.key(interactive: false))
        XCTAssertEqual(keys.interactions, [false])
    }

    func testFileKeyModeNeverReadsKeychain() throws {
        let keys = Keys(denied: true)
        let login = try DroidLoginReader(keyProvider: keys).read(files: [
            "auth.v2.file": Data(fixture.utf8),
            "auth.v2.key": Data(Data(repeating: 7, count: 32).base64EncodedString().utf8),
        ])
        XCTAssertTrue(login.accessToken == token(expiry: 4_102_444_800))
        XCTAssertTrue(keys.interactions.isEmpty)
    }

    func testExpiryBoundaryShowsDroidRefreshReason() throws {
        let reader = DroidLoginReader(keyProvider: Keys())
        let bytes = try encrypted(expiry: 100)
        _ = try reader.read(files: ["auth.v2.loginkeychain": bytes], now: Date(timeIntervalSince1970: 99))
        for time: TimeInterval in [100, 101] {
            XCTAssertThrowsError(try reader.read(files: ["auth.v2.loginkeychain": bytes], now: Date(timeIntervalSince1970: time))) {
                XCTAssertEqual($0 as? DroidLoginError, .expired)
                XCTAssertEqual($0.localizedDescription, "Droid sign-in token expired; usage returns after Droid refreshes it")
            }
        }
    }

    func testUsageUsesLiveDefaultSavedOtherAndAPIKeyFirstWithoutWritingLogins() async throws {
        let fm = FileManager.default
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repo.appending(path: "tmp/droid-login-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let paths = ManagerPaths(applicationSupport: root.appending(path: "support"),
            defaultHome: root.appending(path: "user/.codex"), sharedRoot: root.appending(path: "user/.codex"),
            orcaAccountsRoot: root.appending(path: "orca"), droidExecutable: root.appending(path: "missing-droid"),
            isolationRoot: root)
        let expected = token(expiry: 4_102_444_800)
        let factory = ProviderSpec(id: "factory", name: "Factory", usage: { credential in
            XCTAssertTrue(credential.fields["apiKey"] == expected || credential.fields["apiKey"] == "synthetic-api-key")
            XCTAssertTrue(credential.files.isEmpty)
            return ProviderUsage(windows: [.init(id: "session", title: "5-hour", usedPercent: 25)])
        })
        let keys = Keys()
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive }, providerSpecs: [factory],
            droidProcessLister: { [] }, droidLoginReader: .init(keyProvider: keys))
        try CoreSupport.privateDirectory(paths.droidHome, fileManager: fm)
        let live = paths.droidHome.appending(path: "auth.v2.loginkeychain")
        try CoreSupport.atomicWrite(Data(fixture.utf8), to: live, fileManager: fm)
        let first = try await manager.importDroidAccount(name: "First")
        try CoreSupport.atomicWrite(try encrypted(expiry: 100), to: live, fileManager: fm)
        let second = try await manager.importDroidAccount(name: "Second")
        // The active account follows Droid's newly refreshed live token; the other uses its saved copy.
        try CoreSupport.atomicWrite(Data(fixture.utf8), to: live, fileManager: fm)
        let before = try Data(contentsOf: live)
        let usage = try await manager.readProviderUsage(accountID: second.id, interactive: true)
        XCTAssertEqual(usage.windows.first?.usedPercent, 25)
        _ = try await manager.readProviderUsage(accountID: first.id)
        XCTAssertEqual(keys.interactions, [true, false])
        // One sealed value: JSON key order (and so the bytes) can differ between two encryptions.
        let expired = try encrypted(expiry: 100)
        try CoreSupport.atomicWrite(expired, to: live, fileManager: fm)
        do { _ = try await manager.readProviderUsage(accountID: second.id); XCTFail("Expired login accepted") }
        catch { XCTAssertEqual(error as? DroidLoginError, .expired) }
        try await manager.setDroidUsageAPIKey(accountID: second.id, apiKey: "synthetic-api-key")
        _ = try await manager.readProviderUsage(accountID: second.id)
        XCTAssertEqual(keys.interactions, [true, false, false])
        XCTAssertTrue(try Data(contentsOf: first.credentialFile.appending(path: "auth.v2.loginkeychain")) == before)
        XCTAssertTrue(try Data(contentsOf: live) == expired)
        XCTAssertFalse(CoreSupport.entryExists(paths.droidHome.appending(path: "auth.v2.key")))
    }
}
