import CSQLite
import Foundation
import XCTest
@testable import AIManagerCore

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ProviderCredential] = []
    func add(_ credential: ProviderCredential) { lock.lock(); stored.append(credential); lock.unlock() }
    var all: [ProviderCredential] { lock.lock(); defer { lock.unlock() }; return stored }
}

final class ProviderAccountStoreTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!
    private let fileManager = FileManager.default
    private let authPath = ".testcli/auth.json"
    private var userHome: URL { root.appending(path: "user") }
    private var recorder = Recorder()

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appending(path: "ProviderAccountStoreTests-\(UUID().uuidString)")
        paths = .init(
            applicationSupport: root.appending(path: "support"),
            credentialStore: root.appending(path: "user/.switch/codex"),
            defaultHome: root.appending(path: "user/.codex"),
            sharedRoot: root.appending(path: "user/.codex"),
            orcaAccountsRoot: root.appending(path: "orca"),
            codexExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            grokExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            isolationRoot: root
        )
        try fileManager.createDirectory(at: userHome, withIntermediateDirectories: true)
        recorder = Recorder()
    }

    override func tearDownWithError() throws {
        if let root { try? fileManager.removeItem(at: root) }
    }

    // MARK: Fixtures

    private var secretSpec: ProviderSpec {
        let recorder = recorder
        return ProviderSpec(
            id: "test-secret", name: "Test Secret", style: .secret,
            fields: [.apiKey("TEST_KEY"), .init("org", "Organization", secure: false, optional: true)],
            fetch: { credential in
                recorder.add(credential)
                if credential["apiKey"] == "sk-bad" { throw ProviderError.unauthorized("Bad key.") }
                return FetchResult(ProviderUsage(plan: "secret"))
            })
    }

    private func filesSpec(rotate: Bool = false, id: String = "test-files",
                           login: [String]? = ["true"]) -> ProviderSpec {
        let recorder = recorder
        return ProviderSpec(
            id: id, name: "Test Files", style: .files,
            files: [
                LiveFile(authPath, homeEnv: "TESTCLI_HOME"),
                LiveFile(".config/shared.json", key: "testcli"),
                LiveFile(sqlite: "Library/app/state.vscdb", table: "ItemTable", keys: ["tok", "mail"]),
            ],
            login: login, loginEnv: ["SSH_TTY": "1"],
            identify: { credential in
                guard let json = credential.json(".testcli/auth.json"), let id = json["id"].string else { return nil }
                return CredentialIdentity(key: id, email: json["email"].string)
            },
            fetch: { credential in
                recorder.add(credential)
                var updated: ProviderCredential?
                if rotate {
                    var next = credential
                    next.files[".testcli/auth.json"] = Data(
                        #"{"id":"A","email":"A@x.com","token":"rotated"}"#.utf8)
                    updated = next
                }
                return FetchResult(ProviderUsage(plan: "files"), updated: updated)
            })
    }

    private func makeStore(_ specs: [ProviderSpec], environment: [String: String] = [:]) throws -> ProviderAccountStore {
        try ProviderAccountStore(paths: paths, environment: ["PATH": "/usr/bin:/bin"].merging(environment) { $1 },
                                 specs: specs)
    }

    private func makeManager(_ specs: [ProviderSpec], runner: AccountLoginRunner = .init(launch: { _, _ in })) throws
        -> AccountManager {
        try AccountManager(paths: paths, writerCheck: { _ in .inactive }, loginRunner: runner,
                           providerSpecs: specs)
    }

    /// Writes one signed-in state (auth file, a member of shared.json, and two SQLite rows) into `home`.
    private func writeState(_ name: String, in home: URL, token: String? = nil) throws {
        let auth = home.appending(path: authPath)
        try fileManager.createDirectory(at: auth.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"id":"\#(name)","email":"\#(name)@x.com","token":"\#(token ?? "t-\(name)")"}"#.utf8).write(to: auth)
        let shared = home.appending(path: ".config/shared.json")
        try fileManager.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: shared))) as? [String: Any] ?? [:]
        object["testcli"] = ["tok": "s-\(name)"]
        try JSONSerialization.data(withJSONObject: object).write(to: shared)
        try sqlite(home, "INSERT OR REPLACE INTO ItemTable(key, value) VALUES('tok', 'tk-\(name)'), ('mail', '\(name)@x.com')")
    }

    private func sqlite(_ home: URL, _ sql: String) throws {
        let url = home.appending(path: "Library/app/state.vscdb")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS ItemTable(key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)",
                                    nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    private func row(_ key: String, in home: URL) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open(home.appending(path: "Library/app/state.vscdb").path, &db) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?1", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: text)
    }

    private func authObject(in home: URL? = nil) throws -> [String: Any] {
        let data = try Data(contentsOf: (home ?? userHome).appending(path: authPath))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func sharedObject() throws -> [String: Any] {
        let data = try Data(contentsOf: userHome.appending(path: ".config/shared.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func vaultCredential(_ account: AccountRecord) throws -> ProviderCredential {
        try JSONDecoder().decode(ProviderCredential.self, from: Data(contentsOf: account.credentialFile))
    }

    private func mode(_ url: URL) throws -> Int {
        try (fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// Saves accounts A and B; A ends up as the live default, B is vaulted from a temp home.
    private func seedAB(_ store: ProviderAccountStore) throws -> (a: AccountRecord, b: AccountRecord) {
        try writeState("A", in: userHome)
        let a = try store.importLive(ProviderID(rawValue: "test-files"))
        let other = root.appending(path: "other-home")
        try writeState("B", in: other)
        let b = try store.importLive(ProviderID(rawValue: "test-files"), from: other)
        return (a, b)
    }

    // MARK: Secret accounts

    func testAddSecretValidatesTrimsAndDedupesByIdentity() throws {
        let store = try makeStore([secretSpec])
        let provider = ProviderID(rawValue: "test-secret")

        XCTAssertThrowsError(try store.addSecret(provider, fields: ["apiKey": "   "]))
        XCTAssertThrowsError(try store.addSecret(.codex, fields: ["apiKey": "x"]))
        XCTAssertTrue(try store.accounts().isEmpty)

        let first = try store.addSecret(provider, fields: ["apiKey": "  sk-1  "])
        XCTAssertEqual(try store.defaults()[provider.rawValue], first.id)
        XCTAssertEqual(first.identity.authMode, .apiKey)
        XCTAssertEqual(try vaultCredential(first).fields["apiKey"], "sk-1")
        XCTAssertEqual(try mode(first.credentialFile), 0o600)
        let index = try String(contentsOf: paths.applicationSupport.appending(path: "provider-accounts/accounts.json"),
                               encoding: .utf8)
        XCTAssertFalse(index.contains("sk-1"), "the index must never hold the raw secret")

        let again = try store.addSecret(provider, fields: ["apiKey": "sk-1", "org": " acme "])
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(try store.accounts().count, 1)
        XCTAssertEqual(try vaultCredential(again).fields["org"], "acme")

        let second = try store.addSecret(provider, fields: ["apiKey": "sk-2"])
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(try store.defaults()[provider.rawValue], first.id)
    }

    func testDeleteSecretDefaultPicksAnotherAccount() throws {
        let store = try makeStore([secretSpec])
        let provider = ProviderID(rawValue: "test-secret")
        let first = try store.addSecret(provider, fields: ["apiKey": "sk-1"])
        let second = try store.addSecret(provider, fields: ["apiKey": "sk-2"])

        let result = try store.delete(first.id)

        XCTAssertEqual(result.replacementDefaultAccountID, second.id)
        XCTAssertEqual(try store.defaults()[provider.rawValue], second.id)
        XCTAssertFalse(fileManager.fileExists(atPath: first.credentialFile.path))
        XCTAssertThrowsError(try store.delete(first.id))
        _ = try store.delete(second.id)
        XCTAssertNil(try store.defaults()[provider.rawValue])
    }

    // MARK: Live files

    func testImportLiveRequiresFilesSetsDefaultAndDedupes() throws {
        let store = try makeStore([filesSpec()])
        let provider = ProviderID(rawValue: "test-files")
        XCTAssertThrowsError(try store.importLive(provider))
        XCTAssertNil(store.liveIdentity(provider))

        try writeState("A", in: userHome)
        XCTAssertEqual(store.liveIdentity(provider), CredentialIdentity(key: "A", email: "A@x.com"))
        let account = try store.importLive(provider)

        XCTAssertEqual(try store.defaults()[provider.rawValue], account.id)
        XCTAssertEqual(account.identity.email, "A@x.com")
        XCTAssertEqual(account.identity.userID, "A")
        XCTAssertEqual(account.identity.authMode, .oauth)
        XCTAssertEqual(account.home.standardizedFileURL.path, userHome.standardizedFileURL.path)
        let saved = try vaultCredential(account)
        XCTAssertEqual(Set(saved.files.keys), [authPath, ".config/shared.json#testcli", "Library/app/state.vscdb#ItemTable"])
        XCTAssertEqual(try mode(account.credentialFile), 0o600)
        XCTAssertEqual(CoreSupport.digest(try Data(contentsOf: account.credentialFile)), account.credentialDigest)

        try writeState("A", in: userHome, token: "newer")
        let again = try store.importLive(provider)
        XCTAssertEqual(again.id, account.id)
        XCTAssertEqual(try store.accounts().count, 1)
        XCTAssertTrue(String(decoding: try vaultCredential(again).files[authPath] ?? Data(), as: UTF8.self)
            .contains("newer"))
    }

    func testHomeEnvReplacesParentDirectoryOfThePath() throws {
        let provider = ProviderID(rawValue: "test-files")
        let custom = root.appending(path: "custom")
        try writeState("A", in: userHome)
        try fileManager.createDirectory(at: custom, withIntermediateDirectories: true)
        // Move the auth file out of ~/.testcli: only the env override can find it now.
        try fileManager.moveItem(at: userHome.appending(path: authPath), to: custom.appending(path: "auth.json"))

        XCTAssertNil(try makeStore([filesSpec()]).liveIdentity(provider))
        let outside = try makeStore([filesSpec()], environment: ["TESTCLI_HOME": "/tmp/not-inside-the-test-root"])
        XCTAssertNil(outside.liveIdentity(provider))

        let store = try makeStore([filesSpec()], environment: ["TESTCLI_HOME": custom.path])
        XCTAssertEqual(store.liveIdentity(provider)?.key, "A")
        _ = try store.importLive(provider)
        let other = root.appending(path: "other-home")
        try writeState("B", in: other)
        let b = try store.importLive(provider, from: other)

        _ = try store.makeDefault(b.id)

        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: custom.appending(path: "auth.json")))
        XCTAssertEqual((written as? [String: Any])?["id"] as? String, "B")
        XCTAssertFalse(fileManager.fileExists(atPath: userHome.appending(path: authPath).path))
    }

    func testMakeDefaultSwapsOnlyOwnedBytesAndCapturesOutgoingLogin() throws {
        let store = try makeStore([filesSpec()])
        let (a, b) = try seedAB(store)
        // Unrelated state that a switch must never touch.
        try Data("conversation".utf8).write(to: userHome.appending(path: ".testcli/history.jsonl"))
        var shared = try sharedObject()
        shared["other"] = "keep"
        try JSONSerialization.data(withJSONObject: shared).write(to: userHome.appending(path: ".config/shared.json"))
        try sqlite(userHome, "INSERT INTO ItemTable(key, value) VALUES('unrelated', 'stay')")
        // The CLI rotated A's token while A was live.
        try Data(#"{"id":"A","email":"A@x.com","token":"rotated"}"#.utf8)
            .write(to: userHome.appending(path: authPath))

        let result = try store.makeDefault(b.id)

        XCTAssertEqual(result.accountID, b.id)
        XCTAssertEqual(result.previousAccountID, a.id)
        XCTAssertEqual(try store.defaults()["test-files"], b.id)
        XCTAssertEqual(try authObject()["id"] as? String, "B")
        XCTAssertEqual(try mode(userHome.appending(path: authPath)), 0o600)
        let after = try sharedObject()
        XCTAssertEqual(after["other"] as? String, "keep")
        XCTAssertEqual((after["testcli"] as? [String: String])?["tok"], "s-B")
        XCTAssertEqual(row("tok", in: userHome), "tk-B")
        XCTAssertEqual(row("mail", in: userHome), "B@x.com")
        XCTAssertEqual(row("unrelated", in: userHome), "stay")
        XCTAssertEqual(try String(contentsOf: userHome.appending(path: ".testcli/history.jsonl"), encoding: .utf8),
                       "conversation")
        let captured = try vaultCredential(try XCTUnwrap(store.accounts().first { $0.id == a.id }))
        XCTAssertTrue(String(decoding: try XCTUnwrap(captured.files[authPath]), as: UTF8.self).contains("rotated"))
        XCTAssertTrue(fileManager.fileExists(atPath: result.backup.path))
        XCTAssertEqual(try mode(result.backup), 0o600)
    }

    func testMakeDefaultSavesAnUnsavedLiveLoginBeforeReplacingIt() throws {
        let store = try makeStore([filesSpec()])
        let (_, b) = try seedAB(store)
        try writeState("C", in: userHome)

        _ = try store.makeDefault(b.id)

        let accounts = try store.accounts()
        XCTAssertEqual(accounts.count, 3)
        let saved = try XCTUnwrap(accounts.first { $0.identity.userID == "C" })
        XCTAssertEqual(try store.defaults()["test-files"], b.id)
        XCTAssertTrue(String(decoding: try XCTUnwrap(vaultCredential(saved).files[authPath]), as: UTF8.self)
            .contains("t-C"))
        XCTAssertEqual(try authObject()["id"] as? String, "B")
    }

    func testBackupsKeepOnlyTheNewestTenPerProvider() throws {
        let store = try makeStore([filesSpec()])
        let (a, b) = try seedAB(store)
        for index in 0..<12 { _ = try store.makeDefault(index.isMultiple(of: 2) ? b.id : a.id) }

        let directory = paths.applicationSupport.appending(path: "provider-accounts/backups/test-files")
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: directory.path).count, 10)
    }

    func testMakeDefaultReportsALockedDatabaseAndLeavesTheFilesBehindIntact() throws {
        let store = try makeStore([filesSpec()])
        let (_, b) = try seedAB(store)
        var db: OpaquePointer?
        let url = userHome.appending(path: "Library/app/state.vscdb")
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)

        XCTAssertThrowsError(try store.makeDefault(b.id)) {
            XCTAssertTrue($0.localizedDescription.contains("busy"), "\($0)")
        }
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        XCTAssertEqual(try authObject()["id"] as? String, "A", "a failed switch restores the previous files")
        XCTAssertEqual(try store.defaults()["test-files"], try store.accounts().first { $0.identity.userID == "A" }?.id)
    }

    func testCredentialPrefersLiveFilesOfTheDefaultAccount() throws {
        let store = try makeStore([filesSpec()])
        let (a, b) = try seedAB(store)
        try writeState("A", in: userHome, token: "rotated")

        let live = try store.credential(for: a.id)
        XCTAssertTrue(live.live)
        XCTAssertTrue(live.credential.isLive)
        XCTAssertNotNil(live.liveDigest)
        XCTAssertTrue(String(decoding: try XCTUnwrap(live.credential.files[authPath]), as: UTF8.self).contains("rotated"))

        let vault = try store.credential(for: b.id)
        XCTAssertFalse(vault.live)
        XCTAssertFalse(vault.credential.isLive)
        XCTAssertNil(vault.liveDigest)

        try writeState("C", in: userHome)
        let moved = try store.credential(for: a.id)
        XCTAssertFalse(moved.live, "live files of another login must not be used")
    }

    func testPersistWritesLiveOnlyWhenTheDigestIsUnchanged() throws {
        let store = try makeStore([filesSpec()])
        let (a, _) = try seedAB(store)
        let first = try store.credential(for: a.id)
        var updated = first.credential
        updated.files[authPath] = Data(#"{"id":"A","email":"A@x.com","token":"fresh"}"#.utf8)

        XCTAssertTrue(try store.persist(a.id, updated, live: true, liveDigest: first.liveDigest))
        XCTAssertEqual(try authObject()["token"] as? String, "fresh")
        XCTAssertTrue(String(decoding: try XCTUnwrap(vaultCredential(try XCTUnwrap(store.accounts().first)).files[authPath]),
                             as: UTF8.self).contains("fresh"))

        // The CLI wrote again after the digest was taken: keep the live files, still save the vault.
        let stale = first.liveDigest
        try writeState("A", in: userHome, token: "cli-wrote-this")
        updated.files[authPath] = Data(#"{"id":"A","email":"A@x.com","token":"late"}"#.utf8)
        XCTAssertFalse(try store.persist(a.id, updated, live: true, liveDigest: stale))
        XCTAssertEqual(try authObject()["token"] as? String, "cli-wrote-this")
        XCTAssertTrue(String(decoding: try XCTUnwrap(vaultCredential(try XCTUnwrap(store.accounts().first { $0.id == a.id }))
            .files[authPath]), as: UTF8.self).contains("late"))

        XCTAssertFalse(try store.persist(a.id, updated, live: false, liveDigest: nil))
    }

    func testDeleteFilesDefaultClearsDefaultAndLeavesLiveFiles() throws {
        let store = try makeStore([filesSpec()])
        let (a, b) = try seedAB(store)

        let result = try store.delete(a.id)

        XCTAssertNil(result.replacementDefaultAccountID)
        XCTAssertNil(try store.defaults()["test-files"])
        XCTAssertEqual(try authObject()["id"] as? String, "A")
        XCTAssertEqual(try store.accounts().map(\.id), [b.id])
        XCTAssertThrowsError(try store.delete(b.id, replacement: b.id))
    }

    // MARK: Sign-in

    func testLoginStartCheckAndCancelUseAPrivateTempHome() throws {
        let store = try makeStore([filesSpec()])
        let provider = ProviderID(rawValue: "test-files")
        let start = try store.startLogin(provider)
        let home = URL(fileURLWithPath: try XCTUnwrap(start.launchSpec.environment["HOME"]))

        XCTAssertEqual(start.launchSpec.executable.path, "/usr/bin/true")
        XCTAssertEqual(start.launchSpec.environment["SSH_TTY"], "1")
        XCTAssertEqual(start.launchSpec.environment["TESTCLI_HOME"], home.appending(path: ".testcli").path)
        XCTAssertTrue(fileManager.fileExists(atPath: home.appending(path: ".testcli").path))
        XCTAssertTrue(home.path.contains("provider-accounts/logins/\(start.session.id.uuidString)/home"))
        XCTAssertEqual(try store.pending().map(\.id), [start.session.id])

        let waiting = try store.checkLogin(start.session.id)
        XCTAssertEqual(waiting.state, .waitingForLogin)

        try writeState("L", in: home)
        let done = try store.checkLogin(start.session.id)
        XCTAssertEqual(done.state, .completed)
        XCTAssertEqual(done.account?.identity.userID, "L")
        XCTAssertTrue(try store.defaults().isEmpty, "a sign-in from a temp home is not the live login")
        XCTAssertTrue(try store.pending().isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: home.path))
        XCTAssertThrowsError(try store.checkLogin(start.session.id))

        let second = try store.startLogin(provider)
        let secondHome = second.launchSpec.environment["HOME"] ?? ""
        try store.cancelLogin(second.session.id)
        XCTAssertFalse(fileManager.fileExists(atPath: secondHome))
        XCTAssertThrowsError(try store.cancelLogin(second.session.id))
    }

    func testLoginNeedsTheCLIAndAHomeEnvParentDirectory() throws {
        let missing = filesSpec(id: "test-missing", login: ["definitely-missing-cli", "login"])
        let store = try makeStore([missing])
        XCTAssertThrowsError(try store.startLogin(ProviderID(rawValue: "test-missing"))) {
            XCTAssertEqual($0 as? AIManagerError, .cliNotFound)
        }
        let nested = ProviderSpec(
            id: "test-nested", name: "Nested", style: .files,
            files: [LiveFile(".config/gcloud/adc.json", homeEnv: "CLOUDSDK_CONFIG")],
            login: ["true", "auth", "login"], usage: { _ in ProviderUsage() })
        let start = try makeStore([nested]).startLogin(ProviderID(rawValue: "test-nested"))
        let home = try XCTUnwrap(start.launchSpec.environment["HOME"])
        XCTAssertEqual(start.launchSpec.environment["CLOUDSDK_CONFIG"], home + "/.config/gcloud")
        XCTAssertEqual(start.launchSpec.arguments, ["auth", "login"])
    }

    func testPendingLoginsOlderThanADayArePruned() throws {
        let store = try makeStore([filesSpec()])
        let start = try store.startLogin(ProviderID(rawValue: "test-files"))
        let index = paths.applicationSupport.appending(path: "provider-accounts/accounts.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
        var pending = try XCTUnwrap(object["pending"] as? [[String: Any]])
        pending[0]["createdAt"] = "2000-01-01T00:00:00Z"
        object["pending"] = pending
        try JSONSerialization.data(withJSONObject: object).write(to: index)

        let reopened = try makeStore([filesSpec()])

        XCTAssertTrue(try reopened.pending().isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: try XCTUnwrap(start.launchSpec.environment["HOME"])))
    }

    // MARK: AccountManager wiring

    func testManagerStatusListsStoreAccountsDefaultsAndReorders() async throws {
        let manager = try makeManager([secretSpec, filesSpec()])
        let grok = try await addGrokAccount(manager)
        let one = try await manager.addProviderAccount(providerID: ProviderID(rawValue: "test-secret"),
                                                       fields: ["apiKey": "sk-1"])
        let two = try await manager.addProviderAccount(providerID: ProviderID(rawValue: "test-secret"),
                                                       fields: ["apiKey": "sk-2"])
        try writeState("A", in: userHome)
        let live = try await manager.importLiveProviderAccount(providerID: ProviderID(rawValue: "test-files"))

        let status = try await manager.status()
        XCTAssertEqual(Set(status.accounts.map(\.id)), [grok.id, one.id, two.id, live.id])
        XCTAssertEqual(status.defaultAccountIDs["test-secret"], one.id)
        XCTAssertEqual(status.defaultAccountIDs["test-files"], live.id)
        let liveIdentity = await manager.liveProviderIdentity(providerID: ProviderID(rawValue: "test-files"))
        XCTAssertEqual(liveIdentity?.email, "A@x.com")

        let order = [two.id, live.id, grok.id, one.id]
        let reordered = try await manager.reorderAccounts(order)
        XCTAssertEqual(reordered.accounts.map(\.id), order)
        let missing: [UUID] = [two.id, grok.id, one.id]
        await assertThrows { _ = try await manager.reorderAccounts(missing) }

        let switched = try await manager.switchDefault(to: two.id)
        XCTAssertEqual(switched.previousAccountID, one.id)
        let deleted = try await manager.deleteAccount(accountID: two.id)
        XCTAssertEqual(deleted.replacementDefaultAccountID, one.id)
        XCTAssertTrue(deleted.removedCredential)
        let remaining = try await manager.status().accounts.count
        XCTAssertEqual(remaining, 3)
    }

    func testProviderCatalogListsEveryAddableSpecAndSupersedesPlaceholders() throws {
        let catalog = AccountManager.providerCatalog
        XCTAssertEqual(catalog.prefix(3).map(\.id), [.codex, .grokBuild, .claudeCode])
        for spec in ProviderCatalog.addable {
            XCTAssertEqual(catalog.first { $0.id == spec.id }?.availability, .enabled, spec.id.rawValue)
        }
        let gemini = ProviderSpec(id: "gemini-cli", name: "Gemini", usage: { _ in ProviderUsage() })
        let custom = AccountManager.descriptors(for: [gemini, secretSpec])
        XCTAssertEqual(custom.filter { $0.id == .geminiCLI }.map(\.availability), [.enabled])
        XCTAssertEqual(custom.first { $0.id == .antigravityCLI }?.availability, .disabled)
        XCTAssertEqual(custom.first { $0.id.rawValue == "test-secret" }?.displayName, "Test Secret")
    }

    func testManagerRoutesGenericSignInThroughTerminalLaunch() async throws {
        let manager = try makeManager([filesSpec()])
        let start = try await manager.startAccountLogin(providerID: ProviderID(rawValue: "test-files"))
        XCTAssertTrue(start.opensInTerminal)
        let snapshot = try await manager.refreshAccounts(includeDiscoveries: false)
        XCTAssertTrue(snapshot.pendingLoginSessions.contains { $0.id == start.session.id })
        XCTAssertTrue(snapshot.providers.contains { $0.id.rawValue == "test-files" })

        let waiting = try await manager.checkAccountLogin(id: start.session.id)
        XCTAssertEqual(waiting.state, .waitingForLogin)
        try writeState("L", in: URL(fileURLWithPath: try XCTUnwrap(start.launchSpec.environment["HOME"])))
        let done = try await manager.checkAccountLogin(id: start.session.id)
        XCTAssertEqual(done.state, .completed)

        let second = try await manager.startAccountLogin(providerID: ProviderID(rawValue: "test-files"))
        try await manager.cancelAccountLogin(id: second.session.id)
        let after = try await manager.refreshAccounts(includeDiscoveries: false)
        XCTAssertTrue(after.pendingLoginSessions.isEmpty)
    }

    func testReadProviderUsagePersistsRefreshedStoreCredentialsAndChecksAccounts() async throws {
        let manager = try makeManager([secretSpec, filesSpec(rotate: true)])
        try writeState("A", in: userHome)
        let account = try await manager.importLiveProviderAccount(providerID: ProviderID(rawValue: "test-files"))

        let usage = try await manager.readProviderUsage(accountID: account.id)

        XCTAssertEqual(usage.plan, "files")
        XCTAssertTrue(try XCTUnwrap(recorder.all.first).isLive)
        XCTAssertEqual(try authObject()["token"] as? String, "rotated", "refresh is written back to the live files")
        XCTAssertTrue(String(decoding: try XCTUnwrap(vaultCredential(account).files[authPath]), as: UTF8.self)
            .contains("rotated"))
        let result = await manager.checkAccount(accountID: account.id)
        XCTAssertEqual(result.verification.state, .verifiedLocally)

        let bad = try await manager.addProviderAccount(providerID: ProviderID(rawValue: "test-secret"),
                                                       fields: ["apiKey": "sk-bad"])
        let failed = await manager.checkAccount(accountID: bad.id)
        XCTAssertEqual(failed.verification.state, .needsSignIn)
        XCTAssertEqual(failed.verification.detail, "Bad key.")
        let status = try await manager.status()
        XCTAssertEqual(status.accounts.first { $0.id == bad.id }?.verification.state, .needsSignIn)
    }

    func testReadProviderUsageForRegistryAccountNeverPersistsUpdatedCredentials() async throws {
        let recorder = recorder
        let grokSpec = ProviderSpec(
            id: "grok-build", name: "Grok Build", style: .files,
            files: [LiveFile(".grok/auth.json", homeEnv: "GROK_HOME")],
            fetch: { credential in
                recorder.add(credential)
                var next = credential
                next.files[".grok/auth.json"] = Data("{\"tampered\":true}".utf8)
                return FetchResult(ProviderUsage(plan: "grok"), updated: next)
            })
        let manager = try makeManager([grokSpec])
        let account = try await addGrokAccount(manager)
        let savedBefore = try Data(contentsOf: account.credentialFile)
        let liveBefore = try? Data(contentsOf: paths.grokHome.appending(path: "auth.json"))

        let usage = try await manager.readProviderUsage(accountID: account.id)

        XCTAssertEqual(usage.plan, "grok")
        let credential = try XCTUnwrap(recorder.all.first)
        let isDefault = try await manager.status().isDefault(account)
        XCTAssertEqual(credential.isLive, isDefault)
        XCTAssertEqual(credential.files[".grok/auth.json"], isDefault ? liveBefore : savedBefore)
        XCTAssertEqual(try Data(contentsOf: account.credentialFile), savedBefore)
        XCTAssertEqual(try? Data(contentsOf: paths.grokHome.appending(path: "auth.json")), liveBefore)

        let bare = try makeManager([])
        await assertThrows { _ = try await bare.readProviderUsage(accountID: account.id) }
        await assertThrows { _ = try await bare.readProviderUsage(accountID: UUID()) }
    }

    // MARK: Helpers

    private func addGrokAccount(_ manager: AccountManager) async throws -> AccountRecord {
        let start = try await manager.startAccountLogin(providerID: .grokBuild)
        let home = URL(fileURLWithPath: try XCTUnwrap(start.launchSpec.environment["GROK_HOME"]))
        let auth = home.appending(path: "auth.json")
        try Data(#"{"xai":{"auth_mode":"oidc","key":"grok-key","user_id":"u1","principal_id":"p1","email":"g@x.com"}}"#
            .utf8).write(to: auth)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
        let check = try await manager.checkAccountLogin(id: start.session.id)
        XCTAssertEqual(check.state, .completed)
        return try XCTUnwrap(check.account)
    }

    private func assertThrows(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("Expected an error", file: file, line: line)
        } catch {}
    }
}
