import CSQLite
import Foundation
import XCTest
@testable import AIManagerCore

/// Synthetic temporary home only. The fake droid never calls Factory or the Keychain.
final class AccountDiscoveryTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appending(path: "AccountDiscoveryTests-\(UUID().uuidString)")
        try CoreSupport.privateDirectory(root, fileManager: fm)
        let fake = root.appending(path: "fake-droid")
        try "#!/bin/sh\ncat \"$(dirname \"$0\")/doctor.json\"\n".write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        paths = .init(applicationSupport: root.appending(path: "support"),
            credentialStore: root.appending(path: "user/.switch/codex"),
            defaultHome: root.appending(path: "user/.codex"), sharedRoot: root.appending(path: "user/.codex"),
            orcaAccountsRoot: root.appending(path: "orca"), droidExecutable: fake, isolationRoot: root)
    }

    override func tearDownWithError() throws {
        if let root { try fm.removeItem(at: root) }
    }

    private func manager() throws -> AccountManager {
        try AccountManager(paths: paths, writerCheck: { _ in .inactive },
            providerSpecs: [ProviderCatalog.agentOpenCodeGo, ProviderCatalog.agentKimi],
            droidProcessLister: { [] })
    }

    private func openCodeLogin(_ key: String) throws {
        let file = paths.userHome.appending(path: ".local/share/opencode/auth.json")
        try CoreSupport.privateDirectory(file.deletingLastPathComponent(), fileManager: fm)
        let data = try JSONSerialization.data(withJSONObject: ["opencode-go": ["type": "api", "key": key]])
        try CoreSupport.atomicWrite(data, to: file, fileManager: fm)
    }

    private func droidLogin(_ value: String) throws {
        try CoreSupport.privateDirectory(paths.droidHome, fileManager: fm)
        try CoreSupport.atomicWrite(Data(value.utf8), to: paths.droidHome.appending(path: "auth.v2.loginkeychain"), fileManager: fm)
    }

    private func doctor(_ mask: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["results": [
            ["id": "auth.verify", "status": "pass", "detail": "authenticated as \(mask) via stored login session"]
        ]])
        try CoreSupport.atomicWrite(data, to: root.appending(path: "doctor.json"), fileManager: fm)
    }

    private func saved(_ manager: AccountManager) async throws -> [AccountRecord] {
        try await manager.status().accounts
    }

    func testImportsLiveDroidAndOpenCodeGoOnceAndMarksThem() async throws {
        try openCodeLogin("synthetic-key-1")
        try doctor("s***@gmail.com")
        try droidLogin("synthetic-droid-A")
        let manager = try manager()
        let first = await manager.importLiveLogins()
        XCTAssertEqual(Set(first.map(\.identity.providerID)), [.droid, ProviderID(rawValue: "opencodego")])
        XCTAssertTrue(first.allSatisfy(\.autoImported))
        let again = await manager.importLiveLogins()
        XCTAssertTrue(again.isEmpty)
        let accounts = try await saved(manager)
        XCTAssertEqual(accounts.count, 2)
        XCTAssertTrue(accounts.allSatisfy(\.autoImported))
        // The flag survives a reload from disk.
        let reloaded = try await self.manager().status().accounts
        XCTAssertTrue(reloaded.allSatisfy(\.autoImported))
    }

    func testRefreshAccountsRunsDiscovery() async throws {
        try openCodeLogin("synthetic-key-1")
        let snapshot = try await manager().refreshAccounts(includeDiscoveries: false)
        XCTAssertEqual(snapshot.status.accounts.map(\.identity.providerID.rawValue), ["opencodego"])
    }

    func testDeletedAccountIsNotImportedAgain() async throws {
        try openCodeLogin("synthetic-key-1")
        try doctor("s***@gmail.com")
        try droidLogin("synthetic-droid-A")
        let manager = try manager()
        await manager.importLiveLogins()
        // A second Droid login with another mask is not the default, so it can be deleted alone.
        try doctor("w***@corp.com")
        try droidLogin("synthetic-droid-B")
        await manager.importLiveLogins()
        let all = try await saved(manager)
        XCTAssertEqual(all.count, 3)
        // The imported Droid B is the default, so deleting it names A as the replacement.
        let droidA = try XCTUnwrap(all.first { $0.identity.email == "s***@gmail.com" })
        for account in all where account.identity.email == "w***@corp.com" || account.identity.providerID.rawValue == "opencodego" {
            _ = try await manager.deleteAccount(accountID: account.id, replacementDefaultAccountID: account.identity.providerID == .droid ? droidA.id : nil)
        }
        let afterDelete = try await saved(manager)
        XCTAssertEqual(afterDelete.count, 1)
        // The switch to A replaced the live login; sign in as B again.
        try droidLogin("synthetic-droid-B")
        let added = await manager.importLiveLogins()
        XCTAssertTrue(added.isEmpty)
        // A new manager reads the remembered identities from disk.
        let fresh = try self.manager()
        let freshAdded = await fresh.importLiveLogins()
        XCTAssertTrue(freshAdded.isEmpty)
        let removed = try String(contentsOf: paths.applicationSupport.appending(path: "provider-accounts/removed-logins.json"))
        XCTAssertFalse(removed.contains("synthetic-key-1"))
        XCTAssertFalse(removed.contains("synthetic-droid"))
    }

    func testDifferentLiveOpenCodeLoginIsImportedAndBecomesDefault() async throws {
        try openCodeLogin("synthetic-key-1")
        let manager = try manager()
        _ = await manager.importLiveLogins()
        try openCodeLogin("synthetic-key-2")
        let second = await manager.importLiveLogins()
        XCTAssertEqual(second.count, 1)
        let status = try await manager.status()
        XCTAssertEqual(status.accounts.count, 2)
        XCTAssertEqual(status.defaultAccountIDs["opencodego"], second.first?.id)
    }

    func testEqualDroidMasksAndUnknownMasksSkip() async throws {
        try doctor("s***@gmail.com")
        try droidLogin("synthetic-droid-A")
        let manager = try manager()
        let first = await manager.importLiveLogins()
        XCTAssertEqual(first.count, 1)
        // Another login with the same mask proves nothing, so it is skipped.
        try droidLogin("synthetic-droid-B")
        let equal = await manager.importLiveLogins()
        XCTAssertTrue(equal.isEmpty)
        // A login that doctor cannot name is skipped once a Droid account exists.
        try fm.removeItem(at: root.appending(path: "doctor.json"))
        try droidLogin("synthetic-droid-C")
        let unknown = await manager.importLiveLogins()
        XCTAssertTrue(unknown.isEmpty)
        let droid = try await saved(manager)
        XCTAssertEqual(droid.count, 1)
    }

    func testClearlyDifferentDroidMaskBecomesDefaultAndSwitchBackKeepsEachLoginsOwnBytes() async throws {
        try doctor("s***@gmail.com")
        try droidLogin("synthetic-droid-A")
        let manager = try manager()
        let imported = await manager.importLiveLogins()
        let first = try XCTUnwrap(imported.first)
        try doctor("w***@corp.com")
        try droidLogin("synthetic-droid-B")
        let second = await manager.importLiveLogins()
        let secondRecord = try XCTUnwrap(second.first)
        XCTAssertEqual(second.count, 1)
        var status = try await manager.status()
        XCTAssertEqual(status.accounts.count, 2)
        XCTAssertEqual(status.defaultAccountIDs["droid"], secondRecord.id)
        // The live file was never written by discovery.
        let live = paths.droidHome.appending(path: "auth.v2.loginkeychain")
        XCTAssertEqual(try Data(contentsOf: live), Data("synthetic-droid-B".utf8))
        // Switching back restores A's own bytes and keeps B's login saved under B.
        _ = try await manager.switchDefault(to: first.id)
        XCTAssertEqual(try Data(contentsOf: live), Data("synthetic-droid-A".utf8))
        status = try await manager.status()
        XCTAssertEqual(status.defaultAccountIDs["droid"], first.id)
        let saved = { (record: AccountRecord) in
            try Data(contentsOf: record.credentialFile.appending(path: "auth.v2.loginkeychain"))
        }
        XCTAssertEqual(try saved(first), Data("synthetic-droid-A".utf8))
        XCTAssertEqual(try saved(secondRecord), Data("synthetic-droid-B".utf8))
    }

    func testProviderWithoutLiveLoginImportsNothing() async throws {
        let manager = try manager()
        let added = await manager.importLiveLogins()
        XCTAssertTrue(added.isEmpty)
        let accounts = try await saved(manager)
        XCTAssertTrue(accounts.isEmpty)
    }
}

/// Builds the OpenCode 2 `credential` table in a temporary home. Synthetic rows only.
enum OpenCodeDatabaseFixture {
    static func write(home: URL, rows: [(integration: String, value: String)], active: Int = 1) throws {
        let directory = home.appending(path: ".local/share/opencode")
        try CoreSupport.privateDirectory(directory, fileManager: .default)
        var db: OpaquePointer?
        guard sqlite3_open(directory.appending(path: "opencode.db").path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        var sql = """
            CREATE TABLE credential (id TEXT, integration_id TEXT, label TEXT, value TEXT, connector_id TEXT, method_id TEXT,
                                     active INTEGER, time_created INTEGER, time_updated INTEGER);
            """
        for (index, row) in rows.enumerated() {
            sql += "INSERT INTO credential VALUES ('c\(index)', '\(row.integration)', NULL, '\(row.value)', NULL, NULL, \(active), 1, \(index + 1));"
        }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// OpenCode 2 keeps its Go login in `opencode.db`, not in auth.json.
final class OpenCodeDatabaseLoginTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!
    private let fm = FileManager.default
    private let goID = ProviderID(rawValue: "opencodego")

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appending(path: "OpenCodeDatabaseLoginTests-\(UUID().uuidString)")
        try CoreSupport.privateDirectory(root, fileManager: fm)
        paths = .init(applicationSupport: root.appending(path: "support"),
            credentialStore: root.appending(path: "user/.switch/codex"),
            defaultHome: root.appending(path: "user/.codex"), sharedRoot: root.appending(path: "user/.codex"),
            orcaAccountsRoot: root.appending(path: "orca"), isolationRoot: root)
    }

    override func tearDownWithError() throws {
        if let root { try fm.removeItem(at: root) }
    }

    private func manager() throws -> AccountManager {
        try AccountManager(paths: paths, writerCheck: { _ in .inactive },
            providerSpecs: [ProviderCatalog.agentOpenCodeGo], droidProcessLister: { [] })
    }

    private func goRow(_ key: String) -> (integration: String, value: String) {
        ("opencode-go", #"{"type":"key","key":"\#(key)"}"#)
    }

    private var authFile: URL { paths.userHome.appending(path: ".local/share/opencode/auth.json") }

    private func writeAuth(_ key: String) throws {
        try CoreSupport.privateDirectory(authFile.deletingLastPathComponent(), fileManager: fm)
        try CoreSupport.atomicWrite(JSONSerialization.data(withJSONObject: ["opencode-go": ["type": "api", "key": key]]),
                                    to: authFile, fileManager: fm)
    }

    func testKeyOnlyInTheDatabaseIsImportedAsTheDefaultWithoutWritingAuthJson() async throws {
        try OpenCodeDatabaseFixture.write(home: paths.userHome, rows: [goRow("synthetic-db-key"), ("github-copilot", #"{"type":"oauth"}"#)])
        let manager = try manager()
        let added = await manager.importLiveLogins()
        let record = try XCTUnwrap(added.first)
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(record.identity.providerID, goID)
        XCTAssertTrue(record.autoImported)
        let status = try await manager.status()
        XCTAssertEqual(status.defaultAccountIDs["opencodego"], record.id)
        XCTAssertTrue(try savedLogin(record).contains("synthetic-db-key"))
        XCTAssertFalse(fm.fileExists(atPath: authFile.path))
        let again = await manager.importLiveLogins()
        XCTAssertTrue(again.isEmpty)
    }

    /// The saved and the live credential give `["key"]` through the accessor that identify and usage use.
    func testSavedAndLiveDatabaseCredentialsYieldTheKeyForUsage() async throws {
        try OpenCodeDatabaseFixture.write(home: paths.userHome, rows: [goRow("synthetic-db-key")])
        let manager = try manager()
        let added = await manager.importLiveLogins()
        let record = try XCTUnwrap(added.first)
        let saved = try JSONDecoder().decode(ProviderCredential.self, from: Data(contentsOf: record.credentialFile))
        let id = ".local/share/opencode/auth.json#opencode-go"
        XCTAssertEqual(saved.json(id)?["key"].string, "synthetic-db-key")
        let identify = try XCTUnwrap(ProviderCatalog.agentOpenCodeGo.identify)
        XCTAssertEqual(identify(saved)?.key, AgentCLIsKit.fingerprint("synthetic-db-key"))
        let live = await manager.liveProviderIdentity(providerID: goID)
        XCTAssertEqual(live?.key, identify(saved)?.key)
    }

    func testAuthJsonEntryStillWinsOverTheDatabase() async throws {
        try writeAuth("synthetic-file-key")
        try OpenCodeDatabaseFixture.write(home: paths.userHome, rows: [goRow("synthetic-db-key")])
        let manager = try manager()
        let added = await manager.importLiveLogins()
        let record = try XCTUnwrap(added.first)
        let saved = try savedLogin(record)
        XCTAssertTrue(saved.contains("synthetic-file-key"))
        XCTAssertFalse(saved.contains("synthetic-db-key"))
    }

    /// The stored auth.json member of one saved account, as text.
    private func savedLogin(_ record: AccountRecord) throws -> String {
        let credential = try JSONDecoder().decode(ProviderCredential.self, from: Data(contentsOf: record.credentialFile))
        return String(decoding: try XCTUnwrap(credential.files[".local/share/opencode/auth.json#opencode-go"]), as: UTF8.self)
    }

    func testRemovedLoginIsNotImportedAgain() async throws {
        try OpenCodeDatabaseFixture.write(home: paths.userHome, rows: [goRow("synthetic-db-key")])
        let manager = try manager()
        let first = await manager.importLiveLogins()
        _ = try await manager.deleteAccount(accountID: try XCTUnwrap(first.first).id)
        let again = await manager.importLiveLogins()
        XCTAssertTrue(again.isEmpty)
        let fresh = try self.manager()
        let freshAgain = await fresh.importLiveLogins()
        XCTAssertTrue(freshAgain.isEmpty)
    }

    func testMissingDatabaseMissingTableMalformedAndInactiveRowsImportNothing() async throws {
        let manager = try manager()
        var added = await manager.importLiveLogins()
        XCTAssertTrue(added.isEmpty)
        let directory = paths.userHome.appending(path: ".local/share/opencode")
        try CoreSupport.privateDirectory(directory, fileManager: fm)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appending(path: "opencode.db").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE other (id TEXT);", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        added = await manager.importLiveLogins()
        XCTAssertTrue(added.isEmpty)
        try fm.removeItem(at: directory.appending(path: "opencode.db"))
        for value in ["not json", #"{"type":"key"}"#, #"{"type":"key","key":"  "}"#] {
            try OpenCodeDatabaseFixture.write(home: paths.userHome, rows: [("opencode-go", value)])
            added = await manager.importLiveLogins()
            XCTAssertTrue(added.isEmpty)
            try fm.removeItem(at: directory.appending(path: "opencode.db"))
        }
        try OpenCodeDatabaseFixture.write(home: paths.userHome, rows: [goRow("synthetic-db-key")], active: 0)
        added = await manager.importLiveLogins()
        XCTAssertTrue(added.isEmpty)
        let accounts = try await manager.status().accounts
        XCTAssertTrue(accounts.isEmpty)
    }

    func testSwitchingAwayFromTheDatabaseLoginFailsAndLeavesEveryFileAlone() async throws {
        try writeAuth("synthetic-key-1")
        let manager = try manager()
        let firstImport = await manager.importLiveLogins()
        let first = try XCTUnwrap(firstImport.first)
        try writeAuth("synthetic-key-2")
        let secondImport = await manager.importLiveLogins()
        let second = try XCTUnwrap(secondImport.first)
        // OpenCode 1 style: auth.json is live, so a switch writes it.
        _ = try await manager.switchDefault(to: first.id)
        XCTAssertTrue(String(decoding: try Data(contentsOf: authFile), as: UTF8.self).contains("synthetic-key-1"))
        _ = try await manager.switchDefault(to: second.id)
        // OpenCode 2: only the database holds the login.
        try fm.removeItem(at: authFile)
        try OpenCodeDatabaseFixture.write(home: paths.userHome, rows: [goRow("synthetic-key-2")])
        do {
            _ = try await manager.switchDefault(to: first.id)
            XCTFail("The switch must fail")
        } catch {
            XCTAssertEqual((error as? LocalizedError)?.errorDescription,
                           "OpenCode 2 keeps its login in its database. Run opencode auth login to change it.")
        }
        XCTAssertFalse(fm.fileExists(atPath: authFile.path))
        let status = try await manager.status()
        XCTAssertEqual(status.defaultAccountIDs["opencodego"], second.id)
        // The account that is already live switches without a write.
        _ = try await manager.switchDefault(to: second.id)
        XCTAssertFalse(fm.fileExists(atPath: authFile.path))
    }
}
