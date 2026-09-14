import CSQLite
import Foundation
import XCTest
@testable import AIManagerCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class AccountManagerContractTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appending(path: "AIManagerCoreTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        paths = .init(
            applicationSupport: root.appending(path: "support"),
            credentialStore: root.appending(path: "user/.switch/codex"),
            defaultHome: root.appending(path: "user/.codex"),
            sharedRoot: root.appending(path: "user/.codex"),
            orcaAccountsRoot: root.appending(path: "orca"),
            codexExecutable: URL(fileURLWithPath: "/usr/bin/true")
        )
        try fm.createDirectory(at: paths.defaultHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
    }

    func testLegacyIdentityWithoutProviderDecodesAsCodex() throws {
        let legacy = Data(
            #"{"email":"person@example.test","userID":"user","accountID":"account","workspaceID":"workspace","authMode":"chatGPT"}"#.utf8
        )

        let identity = try JSONDecoder().decode(AccountIdentity.self, from: legacy)

        XCTAssertEqual(identity.providerID, .codex)
        XCTAssertTrue(identity.isResolved)
        XCTAssertTrue(
            String(decoding: try JSONEncoder().encode(identity), as: UTF8.self)
                .contains(#""providerID":"codex""#)
        )
    }

    func testCodexAdapterRejectsUnknownProvider() {
        XCTAssertThrowsError(
            try CodexProviderAdapter(fileManager: fm).requireSupported(
                ProviderID(rawValue: "future-provider")
            )
        ) { error in
            XCTAssertEqual(
                error as? AIManagerError,
                .unsupportedSource("Provider future-provider is not supported by this release.")
            )
        }
    }

    func testCanonicalLocationIgnoresDirectoryHint() {
        let location = root.appending(path: "portable-home")
        let directory = URL(fileURLWithPath: location.path, isDirectory: true)

        XCTAssertTrue(CoreSupport.sameLocation(location, directory))
    }

    func testLegacyImportPlanDecodesWithoutNewDestinationFields() throws {
        let destination = root.appending(path: "legacy-plan/home")
        let original = ImportPlan(
            id: UUID(),
            source: root.appending(path: "legacy-plan/source"),
            destination: destination,
            backup: root.appending(path: "legacy-plan/backup"),
            mode: .authOnly,
            identity: AccountIdentity(
                email: "person@example.test",
                userID: "user",
                accountID: "account",
                workspaceID: "workspace",
                authMode: .chatGPT
            ),
            sourceAuthDigest: "source-digest",
            reviewedDataDigest: "reviewed-digest",
            manifest: [],
            conflicts: [],
            warnings: [],
            requiredBytes: 0
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )
        object.removeValue(forKey: "operationID")
        object.removeValue(forKey: "credentialDestination")
        object.removeValue(forKey: "sharedDestination")

        let decoded = try JSONDecoder().decode(
            ImportPlan.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.operationID, decoded.id)
        XCTAssertEqual(decoded.credentialDestination, destination.appending(path: "auth.json"))
        XCTAssertEqual(decoded.sharedDestination, destination)
    }

    func testDiscoveryIsBoundedOfflineAndDistinguishesWorkspaces() async throws {
        let first = paths.defaultHome
        let second = first.deletingLastPathComponent().appending(path: ".codex2")
        try writeAuth(home: first, account: "account", workspace: "workspace-a", email: "person@example.test")
        try writeAuth(home: second, account: "account", workspace: "workspace-b", email: "person@example.test")
        let original = try Data(contentsOf: first.appending(path: "auth.json"))

        let manager = try AccountManager(paths: paths)
        let found = await manager.discover()

        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(found.allSatisfy { $0.providerID == .codex && $0.identity?.providerID == .codex })
        XCTAssertEqual(Set(found.compactMap(\.identity?.workspaceID)), ["workspace-a", "workspace-b"])
        XCTAssertEqual(try Data(contentsOf: first.appending(path: "auth.json")), original)
    }

    func testDiscoveryReportsKeychainOnlyAndMalformedTokenWithoutCredentialAccess() async throws {
        try Data("cli_auth_credentials_store = \"keyring\"".utf8).write(to: paths.defaultHome.appending(path: "config.toml"))
        let malformed = paths.defaultHome.deletingLastPathComponent().appending(path: ".codex2")
        try fm.createDirectory(at: malformed, withIntermediateDirectories: true)
        let auth: [String: Any] = ["tokens": ["access_token": "not-a-jwt", "account_id": "account", "refresh_token": "synthetic"]]
        try JSONSerialization.data(withJSONObject: auth).write(to: malformed.appending(path: "auth.json"))

        let found = await (try AccountManager(paths: paths)).discover()
        XCTAssertEqual(found.first(where: { $0.path == paths.defaultHome })?.support, .keychainOnly)
        XCTAssertEqual(found.first(where: { $0.path.standardizedFileURL.path == malformed.standardizedFileURL.path })?.support, .malformedAuth)
    }

    func testImportRefusesAuthSymbolicLinkWithoutReadingItsTarget() async throws {
        let source = root.appending(path: "source")
        let external = root.appending(path: "external-auth.json")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let credential = try authData(account: "account", workspace: "workspace")
        try credential.write(to: external)
        try fm.createSymbolicLink(
            at: source.appending(path: "auth.json"), withDestinationURL: external)
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })

        await XCTAssertThrowsErrorAsync(
            try await manager.planImport(source: source, mode: .authOnly)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("not a regular file"))
        }
        XCTAssertEqual(try Data(contentsOf: external), credential)
    }

    func testAuthOnlyImportKeepsSourceAndLinksSharedData() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account-a", workspace: "workspace")
        try Data("shared".utf8).write(to: paths.sharedRoot.appending(path: "config.toml"))
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })

        let plan = try await manager.planImport(source: source, mode: .authOnly)
        let result = try await manager.importAccount(plan: plan)

        XCTAssertEqual(result.account.identity.providerID, .codex)
        XCTAssertEqual(
            result.account.credentialFile.standardizedFileURL,
            paths.credentialStore.appending(path: "\(result.account.id.uuidString).json").standardizedFileURL
        )
        XCTAssertEqual(try Data(contentsOf: source.appending(path: "auth.json")), try Data(contentsOf: result.account.credentialFile))
        XCTAssertTrue(try result.account.home.appending(path: "config.toml").resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        let credentialValues = try result.account.credentialFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        XCTAssertTrue(credentialValues.isRegularFile == true)
        XCTAssertTrue(credentialValues.isSymbolicLink != true)
        XCTAssertEqual((try fm.attributesOfItem(atPath: result.account.credentialFile.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try fm.attributesOfItem(atPath: paths.credentialStore.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try fm.attributesOfItem(atPath: result.account.home.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testLegacyManagedCredentialMigratesToVaultWithoutDeletingSource() async throws {
        let accountID = UUID()
        let home = paths.applicationSupport.appending(path: "accounts/\(accountID.uuidString)/home")
        try writeAuth(home: home, account: "legacy", workspace: "workspace")
        let original = try Data(contentsOf: home.appending(path: "auth.json"))
        let identity = try XCTUnwrap(CodexProviderAdapter(fileManager: fm).inspect(home: home).identity)
        let legacy = AccountRecord(
            id: accountID,
            identity: identity,
            home: home,
            source: home,
            importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            verification: .init(state: .imported, detail: "Legacy account"),
            credentialDigest: CoreSupport.digest(original)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(legacy)) as? [String: Any])
        encoded.removeValue(forKey: "credentialFile")
        let registry = try JSONSerialization.data(withJSONObject: ["accounts": [encoded]])
        try CoreSupport.atomicWrite(
            registry,
            to: paths.applicationSupport.appending(path: "accounts.json"),
            fileManager: fm
        )

        let status = try await AccountManager(paths: paths, writerCheck: { _ in .inactive }).status()
        let migrated = try XCTUnwrap(status.accounts.first)

        XCTAssertEqual(migrated.credentialFile, paths.credentialStore.appending(path: "\(accountID.uuidString).json"))
        XCTAssertEqual(try Data(contentsOf: migrated.credentialFile), original)
        XCTAssertEqual(try Data(contentsOf: home.appending(path: "auth.json")), original)
        XCTAssertTrue(String(decoding: try Data(contentsOf: paths.applicationSupport.appending(path: "accounts.json")), as: UTF8.self).contains("credentialFile"))
    }

    func testRegistryLoadCannotRunOutsideOperationLock() async throws {
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let lockPath = paths.applicationSupport.appending(path: "manager.lock").path
        let descriptor = open(lockPath, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        defer { flock(descriptor, LOCK_UN) }

        await XCTAssertThrowsErrorAsync(try await manager.status()) { error in
            XCTAssertEqual(
                error as? AIManagerError,
                .operationFailed("Another Switch process is changing accounts.")
            )
        }
    }

    func testImportRejectsDestinationsChangedAfterReview() async throws {
        let source = root.appending(path: "reviewed-source")
        try writeAuth(home: source, account: "reviewed", workspace: "workspace")
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await manager.planImport(source: source, mode: .authOnly)
        let outside = root.appending(path: "unreviewed-target")

        var changedPlans: [ImportPlan] = []
        var changed = plan
        changed.destination = outside
        changedPlans.append(changed)
        changed = plan
        changed.backup = outside
        changedPlans.append(changed)
        changed = plan
        changed.sharedDestination = outside
        changedPlans.append(changed)
        changed = plan
        changed.credentialDestination = outside.appending(path: "auth.json")
        changedPlans.append(changed)

        for changedPlan in changedPlans {
            await XCTAssertThrowsErrorAsync(try await manager.importAccount(plan: changedPlan)) { error in
                guard let managerError = error as? AIManagerError,
                      case .unsafePath = managerError else {
                    return XCTFail("Expected an unsafe-path error, got \(error)")
                }
            }
        }
        XCTAssertFalse(CoreSupport.entryExists(outside))
        let finalStatus = try await manager.status()
        XCTAssertTrue(finalStatus.pendingRecovery.isEmpty)
    }

    func testImportKeepsDifferentUsersInTheSameWorkspaceSeparate() async throws {
        let firstSource = root.appending(path: "first-user")
        let secondSource = root.appending(path: "second-user")
        try writeAuth(home: firstSource, account: "shared-workspace", workspace: "workspace", user: "user-one")
        try writeAuth(home: secondSource, account: "shared-workspace", workspace: "workspace", user: "user-two")
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })

        let firstPlan = try await manager.planImport(source: firstSource, mode: .authOnly)
        _ = try await manager.importAccount(plan: firstPlan)
        let secondPlan = try await manager.planImport(source: secondSource, mode: .authOnly)
        _ = try await manager.importAccount(plan: secondPlan)

        let accounts = try await manager.status().accounts
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(Set(accounts.compactMap(\.identity.userID)), ["user-one", "user-two"])
    }

    func testImportAndSwitchKeepWorkspacesForTheSameAccountSeparate() async throws {
        let firstSource = root.appending(path: "first-workspace")
        let secondSource = root.appending(path: "second-workspace")
        try writeAuth(home: firstSource, account: "shared-account", workspace: "workspace-one", user: "shared-user")
        try writeAuth(home: secondSource, account: "shared-account", workspace: "workspace-two", user: "shared-user")
        let firstAuth = try Data(contentsOf: firstSource.appending(path: "auth.json"))
        let secondAuth = try Data(contentsOf: secondSource.appending(path: "auth.json"))
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })

        let firstPlan = try await manager.planImport(source: firstSource, mode: .authOnly)
        let first = try await manager.importAccount(plan: firstPlan).account
        let secondPlan = try await manager.planImport(source: secondSource, mode: .authOnly)
        XCTAssertFalse(secondPlan.conflicts.contains { $0.relativePath == "auth.json" })
        let second = try await manager.importAccount(
            plan: secondPlan,
            decisions: ["auth.json": .useImported]
        ).account

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.home, second.home)
        XCTAssertEqual(try Data(contentsOf: first.home.appending(path: "auth.json")), firstAuth)
        let accounts = try await manager.status().accounts
        XCTAssertEqual(Set(accounts.compactMap(\.identity.workspaceID)), ["workspace-one", "workspace-two"])

        _ = try await manager.switchDefault(to: first.id)
        let firstStatus = try await manager.status()
        XCTAssertEqual(firstStatus.defaultAccountID, first.id)
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), firstAuth)
        _ = try await manager.switchDefault(to: second.id)
        let secondStatus = try await manager.status()
        XCTAssertEqual(secondStatus.defaultAccountID, second.id)
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), secondAuth)
    }

    func testFullImportRequiresConflictChoiceAndPreservesDivergentTranscript() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account-a", workspace: "workspace")
        try Data("imported".utf8).write(to: source.appending(path: "config.toml"))
        try Data("shared".utf8).write(to: paths.sharedRoot.appending(path: "config.toml"))
        try writeTranscript(home: paths.sharedRoot, id: "thread", marker: "shared")
        try writeTranscript(home: source, id: "thread", marker: "divergent")
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await manager.planImport(source: source, mode: .full)

        do {
            _ = try await manager.importAccount(plan: plan)
            XCTFail("A shared settings conflict must be decided before mutation")
        } catch let error as AIManagerError {
            guard case .missingConflictDecisions = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let result = try await manager.importAccount(plan: plan, decisions: ["config.toml": .keepShared])
        XCTAssertEqual(String(decoding: try Data(contentsOf: paths.sharedRoot.appending(path: "config.toml")), as: UTF8.self), "shared")
        XCTAssertTrue(result.unresolved.contains { $0.contains("divergent transcript") })
        XCTAssertTrue(fm.fileExists(atPath: result.backup.appending(path: "conflicts/thread").path))
    }

    func testSwitchChangesOnlyAuthWhileExistingCodexProcessesContinue() async throws {
        try Data("settings".utf8).write(to: paths.defaultHome.appending(path: "config.toml"))
        let firstSource = root.appending(path: "one")
        let secondSource = root.appending(path: "two")
        try writeAuth(home: firstSource, account: "one", workspace: "workspace")
        try writeAuth(home: secondSource, account: "two", workspace: "workspace")
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let firstPlan = try await manager.planImport(source: firstSource, mode: .authOnly)
        let first = try await manager.importAccount(plan: firstPlan)
        let secondPlan = try await manager.planImport(source: secondSource, mode: .authOnly)
        let second = try await manager.importAccount(plan: secondPlan)
        _ = try await manager.switchDefault(to: first.account.id)
        let settings = try Data(contentsOf: paths.defaultHome.appending(path: "config.toml"))
        _ = try await manager.switchDefault(to: second.account.id)
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), try Data(contentsOf: second.account.credentialFile))
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "config.toml")), settings)

        let existingProcess = try AccountManager(paths: paths, writerCheck: { _ in .active })
        _ = try await existingProcess.switchDefault(to: first.account.id)
        XCTAssertEqual(
            try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")),
            try Data(contentsOf: first.account.credentialFile)
        )
    }

    func testSwitchDoesNotConsultWriterStateForNewSessions() async throws {
        let firstSource = root.appending(path: "writer-first")
        let secondSource = root.appending(path: "writer-second")
        try writeAuth(home: firstSource, account: "writer-first", workspace: "workspace")
        try writeAuth(home: secondSource, account: "writer-second", workspace: "workspace")
        let setup = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let firstPlan = try await setup.planImport(source: firstSource, mode: .authOnly)
        let first = try await setup.importAccount(plan: firstPlan).account
        let secondPlan = try await setup.planImport(source: secondSource, mode: .authOnly)
        let second = try await setup.importAccount(plan: secondPlan).account
        _ = try await setup.switchDefault(to: first.id)

        let existingProcess = try AccountManager(paths: paths, writerCheck: { _ in .unknown })
        _ = try await existingProcess.switchDefault(to: second.id)

        let finalStatus = try await setup.status()
        XCTAssertEqual(finalStatus.defaultAccountID, second.id)
        XCTAssertEqual(
            try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")),
            try Data(contentsOf: second.credentialFile)
        )
    }

    func testLinkedSettingRepairRechecksSharedRootWriter() async throws {
        try Data("shared setting".utf8).write(to: paths.sharedRoot.appending(path: "config.toml"))
        let source = root.appending(path: "repair-writer-source")
        try writeAuth(home: source, account: "repair-writer", workspace: "workspace")
        let setup = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await setup.planImport(source: source, mode: .authOnly)
        let account = try await setup.importAccount(plan: plan).account
        let local = account.home.appending(path: "config.toml")
        try fm.removeItem(at: local)
        let localEdit = Data("local edit".utf8)
        try localEdit.write(to: local)
        let status = try await setup.status()
        let issue = try XCTUnwrap(status.linkedSettingsDivergences.first)
        let sharedRoot = paths.sharedRoot
        let blocked = try AccountManager(paths: paths, writerCheck: { home in
            CoreSupport.canonical(home) == CoreSupport.canonical(sharedRoot) ? .active : .inactive
        })

        await XCTAssertThrowsErrorAsync(
            try await blocked.repairLinkedSetting(
                accountID: account.id,
                relativePath: issue.relativePath,
                reviewedFingerprint: issue.localFingerprint
            )
        ) { error in
            XCTAssertEqual(error as? AIManagerError, .activeCodexProcesses)
        }
        XCTAssertEqual(try Data(contentsOf: local), localEdit)
    }

    func testSwitchingAlreadySelectedAccountKeepsRefreshedDefaultCredential() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await manager.planImport(source: source, mode: .authOnly)
        let account = try await manager.importAccount(plan: plan).account
        _ = try await manager.switchDefault(to: account.id)
        let refreshed = try refreshedAuth(account: "account", workspace: "workspace", marker: "refreshed-default")
        try refreshed.write(to: paths.defaultHome.appending(path: "auth.json"))

        _ = try await manager.switchDefault(to: account.id)
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), refreshed)
        XCTAssertEqual(try Data(contentsOf: account.credentialFile), refreshed)
    }

    func testSwitchRefusesWhenDefaultAndSavedCredentialsBothDiverged() async throws {
        let firstSource = root.appending(path: "first")
        let secondSource = root.appending(path: "second")
        try writeAuth(home: firstSource, account: "first", workspace: "workspace")
        try writeAuth(home: secondSource, account: "second", workspace: "workspace")
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let firstPlan = try await manager.planImport(source: firstSource, mode: .authOnly)
        let first = try await manager.importAccount(plan: firstPlan).account
        let secondPlan = try await manager.planImport(source: secondSource, mode: .authOnly)
        let second = try await manager.importAccount(plan: secondPlan).account
        _ = try await manager.switchDefault(to: first.id)
        let defaultEdit = try refreshedAuth(account: "first", workspace: "workspace", marker: "default-edit")
        let savedEdit = try refreshedAuth(account: "first", workspace: "workspace", marker: "saved-edit")
        try defaultEdit.write(to: paths.defaultHome.appending(path: "auth.json"))
        try savedEdit.write(to: first.credentialFile)

        await XCTAssertThrowsErrorAsync(try await manager.switchDefault(to: second.id)) { error in
            XCTAssertEqual(error as? AIManagerError, .credentialConflict)
        }
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), defaultEdit)
        XCTAssertEqual(try Data(contentsOf: first.credentialFile), savedEdit)
        let recovery = try await manager.recover()
        XCTAssertTrue(recovery.isEmpty)
    }

    func testSQLiteSnapshotIncludesWALAndRebasesOnlyExactPrefix() throws {
        let sourceHome = root.appending(path: "source-home")
        let transcript = sourceHome.appending(path: "sessions/a.jsonl")
        try fm.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: transcript)
        let source = root.appending(path: "state.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE threads(id TEXT, rollout_path TEXT); INSERT INTO threads VALUES('a','/old/home/sessions/a.jsonl'),('missing',NULL);", nil, nil, nil), SQLITE_OK)
        let snapshot = root.appending(path: "snapshot.sqlite")
        try SQLiteSupport.snapshot(source: source, destination: snapshot)
        let summary = try SQLiteSupport.rebaseRecognizedRolloutPaths(database: snapshot, sourceHome: sourceHome, destinationHome: URL(fileURLWithPath: "/new/home"), transcriptDestinations: ["a": "sessions/a.jsonl"], projectionDatabase: nil)
        XCTAssertEqual(summary.excludedThreadCount, 1)
        XCTAssertEqual(try queryPaths(snapshot), ["/new/home/sessions/a.jsonl"])
    }

    func testThreadHistoryProjectionSnapshotIsPreservedWithoutPathRewrite() throws {
        let source = root.appending(path: "thread_history_1.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        let statements = [
            "CREATE TABLE _sqlx_migrations(version BIGINT, description TEXT, installed_on TIMESTAMP, success BOOLEAN, checksum BLOB, execution_time BIGINT)",
            "CREATE TABLE thread_items(thread_id TEXT, turn_id TEXT, item_id TEXT, rollout_ordinal INTEGER, created_at_ms INTEGER, item_json TEXT, item_type TEXT, updated_at_ordinal INTEGER)",
            "CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER, status TEXT, error_json TEXT, started_at INTEGER, completed_at INTEGER, duration_ms INTEGER, first_user_item_id TEXT, final_agent_item_id TEXT, rollout_byte_offset INTEGER, rollout_end_ordinal INTEGER, rollout_end_byte_offset INTEGER)",
            "CREATE TABLE thread_history_projection_state(thread_id TEXT, next_rollout_byte_offset INTEGER, next_rollout_ordinal INTEGER)",
            "CREATE TABLE thread_realtime_items(thread_id TEXT, item_id TEXT, rollout_ordinal INTEGER, created_at_ms INTEGER, item_type TEXT, item_json TEXT)",
            "INSERT INTO thread_history_projection_state VALUES('synthetic', 12, 3)"
        ]
        for statement in statements { XCTAssertEqual(sqlite3_exec(db, statement, nil, nil, nil), SQLITE_OK) }
        sqlite3_close(db)
        let snapshot = root.appending(path: "thread-history-snapshot.sqlite")
        try SQLiteSupport.snapshot(source: source, destination: snapshot)
        try SQLiteSupport.rebaseRecognizedRolloutPaths(database: snapshot, sourceHome: root, destinationHome: root.appending(path: "destination"), transcriptDestinations: [:], projectionDatabase: nil)
        XCTAssertEqual(try queryInteger(snapshot, sql: "SELECT next_rollout_byte_offset FROM thread_history_projection_state"), 12)
    }

    func testJSONLReaderRejectsOversizeRecordWhenNewlineCrossesChunkBoundary() throws {
        let file = root.appending(path: "oversize.jsonl")
        var data = Data(repeating: 0x78, count: 1_100_000)
        data.append(0x0A)
        try data.write(to: file)
        let reader = try JSONLReader(url: file, maximumRecordBytes: 1_050_000)
        XCTAssertThrowsError(try reader.next())
    }

    func testLaunchSpecPinsHomeAndFileCredentialStore() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await manager.planImport(source: source, mode: .authOnly)
        let result = try await manager.importAccount(plan: plan)
        _ = try await manager.switchDefault(to: result.account.id)
        let spec = try await manager.launchSpec(accountID: result.account.id, arguments: ["resume", "--all"])
        XCTAssertEqual(spec.environment["CODEX_HOME"], paths.defaultHome.path)
        XCTAssertNil(spec.environment["OPENAI_API_KEY"])
        XCTAssertEqual(spec.arguments, ["-c", "cli_auth_credentials_store=\"file\"", "resume", "--all"])
    }

    func testActivateAndRunHoldsOperationLockThroughProcessStart() async throws {
        let source = root.appending(path: "coordinated-launch-source")
        try writeAuth(home: source, account: "coordinated", workspace: "workspace")
        let lockPath = paths.applicationSupport.appending(path: "manager.lock").path
        let manager = try AccountManager(
            paths: paths,
            writerCheck: { _ in .inactive },
            faultInjector: { point in
                guard point == .afterProcessStart else { return }
                let descriptor = open(lockPath, O_RDWR | O_CLOEXEC)
                guard descriptor >= 0 else {
                    throw AIManagerError.operationFailed("Could not inspect the launch lock.")
                }
                defer { close(descriptor) }
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                    flock(descriptor, LOCK_UN)
                    throw AIManagerError.operationFailed("The account lock was released before process start.")
                }
            }
        )
        let plan = try await manager.planImport(source: source, mode: .authOnly)
        let account = try await manager.importAccount(plan: plan).account

        let status = try await manager.activateAndRun(
            accountID: account.id,
            arguments: ["--version"]
        )

        XCTAssertEqual(status, 0)
        let finalStatus = try await manager.status()
        XCTAssertEqual(finalStatus.defaultAccountID, account.id)
    }

    func testActivateAndRunAllowsRefreshedDefaultWhileAnotherCodexProcessExists() async throws {
        let source = root.appending(path: "refreshed-default-source")
        try writeAuth(home: source, account: "refreshed", workspace: "workspace")
        let setup = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await setup.planImport(source: source, mode: .authOnly)
        let account = try await setup.importAccount(plan: plan).account
        _ = try await setup.switchDefault(to: account.id)

        let refreshed = try refreshedAuth(
            account: "refreshed", workspace: "workspace", marker: "live-token-refresh")
        try refreshed.write(to: paths.defaultHome.appending(path: "auth.json"))
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .unknown })

        let status = try await manager.activateAndRun(
            accountID: account.id,
            arguments: ["--version"]
        )

        XCTAssertEqual(status, 0)
        XCTAssertEqual(
            try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")),
            refreshed
        )
        XCTAssertNotEqual(
            try Data(contentsOf: account.credentialFile),
            refreshed
        )
    }

    func testActivateAndRunChangesTheAccountForNewSessionWhenWriterStateIsUnknown() async throws {
        let firstSource = root.appending(path: "launch-first-source")
        let secondSource = root.appending(path: "launch-second-source")
        try writeAuth(home: firstSource, account: "first", workspace: "workspace")
        try writeAuth(home: secondSource, account: "second", workspace: "workspace")
        let setup = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let firstPlan = try await setup.planImport(source: firstSource, mode: .authOnly)
        let first = try await setup.importAccount(plan: firstPlan).account
        let secondPlan = try await setup.planImport(source: secondSource, mode: .authOnly)
        let second = try await setup.importAccount(plan: secondPlan).account
        _ = try await setup.switchDefault(to: first.id)
        let originalLive = try Data(contentsOf: paths.defaultHome.appending(path: "auth.json"))
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .unknown })

        let exitStatus = try await manager.activateAndRun(
            accountID: second.id,
            arguments: ["--version"]
        )

        XCTAssertEqual(exitStatus, 0)
        XCTAssertNotEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), originalLive)
        XCTAssertEqual(
            try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")),
            try Data(contentsOf: second.credentialFile)
        )
        let finalStatus = try await manager.status()
        XCTAssertEqual(finalStatus.defaultAccountID, second.id)
    }

    func testLaunchRefusesTamperedSavedAuth() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await manager.planImport(source: source, mode: .authOnly)
        let account = try await manager.importAccount(plan: plan).account
        _ = try await manager.switchDefault(to: account.id)
        try refreshedAuth(account: "account", workspace: "workspace", marker: "tampered")
            .write(to: account.credentialFile)

        await XCTAssertThrowsErrorAsync(try await manager.launchSpec(accountID: account.id)) { error in
            XCTAssertEqual(error as? AIManagerError, .credentialConflict)
        }
    }

    func testLaunchRefusesSymlinkedSavedAuth() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await manager.planImport(source: source, mode: .authOnly)
        let account = try await manager.importAccount(plan: plan).account
        _ = try await manager.switchDefault(to: account.id)
        let auth = account.credentialFile
        let target = root.appending(path: "linked-auth.json")
        try fm.moveItem(at: auth, to: target)
        try fm.createSymbolicLink(at: auth, withDestinationURL: target)

        await XCTAssertThrowsErrorAsync(try await manager.launchSpec(accountID: account.id)) { error in
            XCTAssertEqual(error as? AIManagerError, .credentialConflict)
        }
    }

    func testLaunchRefusesSymlinkedLiveAuth() async throws {
        let source = root.appending(path: "live-source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await manager.planImport(source: source, mode: .authOnly)
        let account = try await manager.importAccount(plan: plan).account
        _ = try await manager.switchDefault(to: account.id)
        let auth = paths.defaultHome.appending(path: "auth.json")
        let target = root.appending(path: "linked-live-auth.json")
        try fm.moveItem(at: auth, to: target)
        try fm.createSymbolicLink(at: auth, withDestinationURL: target)

        await XCTAssertThrowsErrorAsync(try await manager.launchSpec(accountID: account.id)) { error in
            XCTAssertEqual(error as? AIManagerError, .credentialConflict)
        }
    }

    func testLaunchRefusesHardLinkedSavedAuth() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await manager.planImport(source: source, mode: .authOnly)
        let account = try await manager.importAccount(plan: plan).account
        _ = try await manager.switchDefault(to: account.id)
        let target = root.appending(path: "hard-linked-auth.json")
        try fm.moveItem(at: account.credentialFile, to: target)
        try fm.linkItem(at: target, to: account.credentialFile)

        await XCTAssertThrowsErrorAsync(try await manager.launchSpec(accountID: account.id)) { error in
            XCTAssertEqual(error as? AIManagerError, .credentialConflict)
        }
    }

    func testLaunchRefusesStaleRegistryIdentity() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await manager.planImport(source: source, mode: .authOnly)
        let account = try await manager.importAccount(plan: plan).account
        let registry = paths.applicationSupport.appending(path: "accounts.json")
        var rootObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as? [String: Any]
        )
        var accounts = try XCTUnwrap(rootObject["accounts"] as? [[String: Any]])
        var identity = try XCTUnwrap(accounts[0]["identity"] as? [String: Any])
        identity["workspaceID"] = "stale-workspace"
        accounts[0]["identity"] = identity
        rootObject["accounts"] = accounts
        try JSONSerialization.data(withJSONObject: rootObject).write(to: registry)

        await XCTAssertThrowsErrorAsync(try await manager.launchSpec(accountID: account.id)) { error in
            XCTAssertEqual(error as? AIManagerError, .credentialConflict)
        }
    }

    func testRegistryRejectsManagedHomeOutsidePrivateAccountRoot() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await manager.planImport(source: source, mode: .authOnly)
        _ = try await manager.importAccount(plan: plan)
        let registry = paths.applicationSupport.appending(path: "accounts.json")
        var rootObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as? [String: Any]
        )
        var accounts = try XCTUnwrap(rootObject["accounts"] as? [[String: Any]])
        accounts[0]["home"] = source.absoluteString
        rootObject["accounts"] = accounts
        try JSONSerialization.data(withJSONObject: rootObject).write(to: registry)

        await XCTAssertThrowsErrorAsync(try await manager.status()) { error in
            XCTAssertEqual(
                error as? AIManagerError,
                .unsafePath("managed account home is outside the private account root"))
        }
    }

    func testCrashAfterHomePublicationRollsBackUnregisteredHome() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let crashing = try AccountManager(paths: paths, writerCheck: { _ in .inactive }, faultInjector: { point in
            if point == .afterHomePublication { throw AIManagerError.operationFailed("injected crash") }
        })
        let plan = try await crashing.planImport(source: source, mode: .authOnly)
        await XCTAssertThrowsErrorAsync(try await crashing.importAccount(plan: plan))
        XCTAssertTrue(fm.fileExists(atPath: plan.destination.path))

        let recovering = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let results = try await recovering.recover()
        XCTAssertEqual(results.first?.outcome, .rolledBack)
        XCTAssertFalse(fm.fileExists(atPath: plan.destination.path))
        let recoveredStatus = try await recovering.status()
        XCTAssertTrue(recoveredStatus.accounts.isEmpty)
    }

    func testImportRecoveryCompletesAfterRegistryCommitInterruption() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let crashing = try AccountManager(paths: paths, writerCheck: { _ in .inactive }, faultInjector: { point in
            if point == .afterRegistryCommit { throw AIManagerError.operationFailed("injected interruption") }
        })
        let plan = try await crashing.planImport(source: source, mode: .authOnly)
        await XCTAssertThrowsErrorAsync(try await crashing.importAccount(plan: plan))

        let recovering = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let results = try await recovering.recover()
        XCTAssertEqual(results.first?.outcome, .completed)
        let status = try await recovering.status()
        XCTAssertEqual(status.accounts.first?.id, plan.id)
        XCTAssertEqual(try Data(contentsOf: plan.destination.appending(path: "auth.json")), try Data(contentsOf: source.appending(path: "auth.json")))
    }

    func testImportRecoveryPreservesVaultEditAfterRegistryCommit() async throws {
        let source = root.appending(path: "vault-edit-source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let crashing = try AccountManager(
            paths: paths,
            writerCheck: { _ in .inactive },
            faultInjector: { point in
                if point == .afterRegistryCommit {
                    throw AIManagerError.operationFailed("injected interruption")
                }
            }
        )
        let plan = try await crashing.planImport(source: source, mode: .authOnly)
        await XCTAssertThrowsErrorAsync(try await crashing.importAccount(plan: plan))
        let edited = try refreshedAuth(
            account: "account",
            workspace: "workspace",
            marker: "vault-edited-after-commit"
        )
        try CoreSupport.atomicWrite(edited, to: plan.credentialDestination, fileManager: fm)

        let recovering = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let results = try await recovering.recover()

        XCTAssertEqual(results.first?.outcome, .conflict)
        XCTAssertEqual(try Data(contentsOf: plan.credentialDestination), edited)
        XCTAssertTrue(CoreSupport.entryExists(plan.destination))
        let finalStatus = try await recovering.status()
        XCTAssertEqual(finalStatus.pendingRecovery.first?.phase, .conflicted)
    }

    func testInterruptedSwitchRestoresMalformedLiveAuth() async throws {
        let source = root.appending(path: "malformed-live-source")
        try writeAuth(home: source, account: "incoming", workspace: "workspace")
        let setup = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await setup.planImport(source: source, mode: .authOnly)
        let incoming = try await setup.importAccount(plan: plan).account
        let malformed = Data("{malformed-live-auth".utf8)
        let liveAuth = paths.defaultHome.appending(path: "auth.json")
        try malformed.write(to: liveAuth)
        let crashing = try AccountManager(
            paths: paths,
            writerCheck: { _ in .inactive },
            faultInjector: { point in
                if point == .afterDefaultCredentialPublication {
                    throw AIManagerError.operationFailed("injected interruption")
                }
            }
        )

        await XCTAssertThrowsErrorAsync(try await crashing.switchDefault(to: incoming.id))
        XCTAssertNotEqual(try Data(contentsOf: liveAuth), malformed)

        let recovering = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let results = try await recovering.recover()

        XCTAssertEqual(results.first?.outcome, .rolledBack)
        XCTAssertEqual(try Data(contentsOf: liveAuth), malformed)
        let recoveredStatus = try await recovering.status()
        XCTAssertTrue(recoveredStatus.pendingRecovery.isEmpty)
    }

    func testCrashAfterDefaultPublicationRestoresOutgoingAuth() async throws {
        let outgoing = try authData(account: "outgoing", workspace: "workspace")
        try outgoing.write(to: paths.defaultHome.appending(path: "auth.json"))
        let source = root.appending(path: "incoming")
        try writeAuth(home: source, account: "incoming", workspace: "workspace")
        let setup = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await setup.planImport(source: source, mode: .authOnly)
        let account = try await setup.importAccount(plan: plan).account
        let crashing = try AccountManager(paths: paths, writerCheck: { _ in .inactive }, faultInjector: { point in
            if point == .afterDefaultCredentialPublication { throw AIManagerError.operationFailed("injected crash") }
        })
        await XCTAssertThrowsErrorAsync(try await crashing.switchDefault(to: account.id))
        XCTAssertNotEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), outgoing)

        let recovering = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        _ = try await recovering.recover()
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), outgoing)
    }

    func testInterruptedSwitchRecoveryRetainsRefreshedOutgoingCredential() async throws {
        let firstSource = root.appending(path: "first")
        let secondSource = root.appending(path: "second")
        try writeAuth(home: firstSource, account: "first", workspace: "workspace")
        try writeAuth(home: secondSource, account: "second", workspace: "workspace")
        let preserved = paths.defaultHome.appending(path: "rules/keep.md")
        try fm.createDirectory(at: preserved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: preserved)
        let preservedDigest = try localTreeDigest(preserved.deletingLastPathComponent())

        let setup = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let firstPlan = try await setup.planImport(source: firstSource, mode: .authOnly)
        let first = try await setup.importAccount(plan: firstPlan).account
        let secondPlan = try await setup.planImport(source: secondSource, mode: .authOnly)
        let second = try await setup.importAccount(plan: secondPlan).account
        _ = try await setup.switchDefault(to: first.id)
        let refreshed = try refreshedAuth(account: "first", workspace: "workspace", marker: "refreshed-outgoing")
        try refreshed.write(to: paths.defaultHome.appending(path: "auth.json"))

        let crashing = try AccountManager(paths: paths, writerCheck: { _ in .inactive }, faultInjector: { point in
            if point == .afterDefaultCredentialPublication { throw AIManagerError.operationFailed("injected crash") }
        })
        await XCTAssertThrowsErrorAsync(try await crashing.switchDefault(to: second.id))

        let recovering = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let recovery = try await recovering.recover()
        XCTAssertEqual(recovery.first?.outcome, .rolledBack)
        _ = try await recovering.switchDefault(to: second.id)
        _ = try await recovering.switchDefault(to: first.id)

        let status = try await recovering.status()
        let registryDigest = try XCTUnwrap(status.accounts.first(where: { $0.id == first.id })?.credentialDigest)
        let managedDigest = try CoreSupport.digest(file: first.credentialFile)
        let defaultDigest = try CoreSupport.digest(file: paths.defaultHome.appending(path: "auth.json"))
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), refreshed)
        XCTAssertEqual(registryDigest, CoreSupport.digest(refreshed))
        XCTAssertEqual(managedDigest, registryDigest)
        XCTAssertEqual(defaultDigest, registryDigest)
        XCTAssertEqual(try localTreeDigest(preserved.deletingLastPathComponent()), preservedDigest)
    }

    func testSwitchRecoveryCompletesAfterRegistryCommitInterruption() async throws {
        let firstSource = root.appending(path: "first")
        let secondSource = root.appending(path: "second")
        try writeAuth(home: firstSource, account: "first", workspace: "workspace")
        try writeAuth(home: secondSource, account: "second", workspace: "workspace")
        let setup = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let firstPlan = try await setup.planImport(source: firstSource, mode: .authOnly)
        let first = try await setup.importAccount(plan: firstPlan).account
        let secondPlan = try await setup.planImport(source: secondSource, mode: .authOnly)
        let second = try await setup.importAccount(plan: secondPlan).account
        _ = try await setup.switchDefault(to: first.id)
        let crashing = try AccountManager(paths: paths, writerCheck: { _ in .inactive }, faultInjector: { point in
            if point == .afterRegistryCommit { throw AIManagerError.operationFailed("injected interruption") }
        })
        await XCTAssertThrowsErrorAsync(try await crashing.switchDefault(to: second.id))

        let recovering = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let results = try await recovering.recover()
        XCTAssertEqual(results.first?.outcome, .completed)
        let status = try await recovering.status()
        XCTAssertEqual(status.defaultAccountID, second.id)
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), try Data(contentsOf: second.credentialFile))
    }

    func testDifferentIdentityAtSameTranscriptPathIsNeverOverwritten() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        try writeTranscript(home: paths.sharedRoot, id: "existing", marker: "keep", filename: "collision.jsonl")
        try writeTranscript(home: source, id: "incoming", marker: "preserve", filename: "collision.jsonl")
        let original = try Data(contentsOf: paths.sharedRoot.appending(path: "sessions/2026/01/01/collision.jsonl"))
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await manager.planImport(source: source, mode: .full)
        let result = try await manager.importAccount(plan: plan)

        XCTAssertEqual(try Data(contentsOf: paths.sharedRoot.appending(path: "sessions/2026/01/01/collision.jsonl")), original)
        XCTAssertTrue(result.unresolved.contains { $0.contains("filename collision") }, "\(result.unresolved)")
        XCTAssertTrue(fm.fileExists(atPath: result.backup.appending(path: "conflicts/incoming/collision.jsonl").path), "\((try? fm.subpathsOfDirectory(atPath: result.backup.path)) ?? [])")
    }

    func testEnvironmentRootIsolatesEveryDiscoveryAndLaunchPath() async throws {
        let isolated = root.appending(path: "isolated")
        let derived = ManagerPaths.environment(["AI_MANAGER_ROOT": isolated.path, "AI_MANAGER_CODEX_EXECUTABLE": "/usr/bin/true"])
        XCTAssertEqual(derived.defaultHome.standardizedFileURL.path, isolated.appending(path: "default-home").path)
        XCTAssertEqual(derived.sharedRoot.standardizedFileURL.path, derived.defaultHome.standardizedFileURL.path)
        XCTAssertEqual(derived.orcaAccountsRoot.standardizedFileURL.path, isolated.appending(path: "orca-accounts").path)
        XCTAssertEqual(derived.applicationSupport.standardizedFileURL.path, isolated.appending(path: "application-support").path)
        XCTAssertEqual(derived.credentialStore.standardizedFileURL.path, isolated.appending(path: ".switch/codex").path)
        let escaped = ManagerPaths.environment(["AI_MANAGER_ROOT": isolated.path, "AI_MANAGER_DEFAULT_HOME": paths.defaultHome.path, "AI_MANAGER_SHARED_ROOT": paths.sharedRoot.path, "AI_MANAGER_ORCA_ACCOUNTS_ROOT": paths.orcaAccountsRoot.path, "AI_MANAGER_CREDENTIAL_STORE": paths.credentialStore.path])
        XCTAssertEqual(escaped.defaultHome.standardizedFileURL.path, isolated.appending(path: "default-home").path)
        XCTAssertEqual(escaped.sharedRoot.standardizedFileURL.path, escaped.defaultHome.standardizedFileURL.path)
        XCTAssertEqual(escaped.orcaAccountsRoot.standardizedFileURL.path, isolated.appending(path: "orca-accounts").path)
        XCTAssertEqual(escaped.credentialStore.standardizedFileURL.path, isolated.appending(path: ".switch/codex").path)
    }

    func testStandardPathsUseOneLiveHomeAndSwitchCredentialStore() {
        let standard = ManagerPaths.standard(fileManager: fm)
        let userHome = fm.homeDirectoryForCurrentUser

        XCTAssertEqual(standard.defaultHome.standardizedFileURL.path, userHome.appending(path: ".codex").path)
        XCTAssertEqual(standard.sharedRoot, standard.defaultHome)
        XCTAssertEqual(standard.credentialStore.standardizedFileURL.path, userHome.appending(path: ".switch/codex").path)

        var explicit = ManagerPaths(
            applicationSupport: root.appending(path: "explicit/support"),
            defaultHome: root.appending(path: "explicit/live"),
            sharedRoot: root.appending(path: "explicit/separate-shared"),
            orcaAccountsRoot: root.appending(path: "explicit/orca")
        )
        XCTAssertEqual(explicit.sharedRoot, explicit.defaultHome)
        explicit.sharedRoot = root.appending(path: "explicit/remapped-live")
        XCTAssertEqual(explicit.defaultHome, explicit.sharedRoot)
    }

    func testFullImportRefusesActiveSourceBeforeSharedMutation() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        try Data("source".utf8).write(to: source.appending(path: "config.toml"))
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .active })
        let plan = try await manager.planImport(source: source, mode: .full)
        await XCTAssertThrowsErrorAsync(try await manager.importAccount(plan: plan)) { error in XCTAssertEqual(error as? AIManagerError, .activeCodexProcesses) }
        XCTAssertFalse(fm.fileExists(atPath: paths.sharedRoot.appending(path: "config.toml").path))
    }

    func testContainedIsolationRootStillRefusesActiveWriter() async throws {
        let isolated = root.appending(path: "isolated")
        let isolatedPaths = ManagerPaths.environment(["AI_MANAGER_ROOT": isolated.path, "AI_MANAGER_CODEX_EXECUTABLE": "/usr/bin/true"])
        let source = isolated.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let manager = try AccountManager(paths: isolatedPaths, writerCheck: { _ in .active })
        let plan = try await manager.planImport(source: source, mode: .full)
        await XCTAssertThrowsErrorAsync(try await manager.importAccount(plan: plan)) { error in XCTAssertEqual(error as? AIManagerError, .activeCodexProcesses) }
    }

    func testReimportOfSameCredentialPreservesManagedHome() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let firstPlan = try await manager.planImport(source: source, mode: .authOnly)
        let first = try await manager.importAccount(plan: firstPlan)
        let local = first.account.home.appending(path: "state_5.sqlite")
        try Data("local-index".utf8).write(to: local)

        let secondPlan = try await manager.planImport(source: source, mode: .authOnly)
        let second = try await manager.importAccount(plan: secondPlan)
        XCTAssertEqual(first.account.id, second.account.id)
        XCTAssertEqual(try Data(contentsOf: local), Data("local-index".utf8))
    }

    func testAuthOnlyPlanDoesNotWalkLargeExcludedTrees() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let vendor = source.appending(path: "packages/vendor")
        try fm.createDirectory(at: vendor, withIntermediateDirectories: true)
        for index in 0..<500 { try Data().write(to: vendor.appending(path: "\(index).cache")) }
        let manager = try AccountManager(paths: paths)

        let plan = try await manager.planImport(source: source, mode: .authOnly)
        XCTAssertEqual(plan.manifest.map(\.relativePath), ["auth.json", "packages"])
        XCTAssertTrue(plan.warnings.isEmpty, "Expected scope exclusions are manifest details, not warnings")
    }

    func testImportPlanRejectsInsufficientDestinationSpace() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let manager = try AccountManager(paths: paths, capacityCheck: { _ in 0 })
        await XCTAssertThrowsErrorAsync(try await manager.planImport(source: source, mode: .authOnly)) { error in
            XCTAssertTrue(error.localizedDescription.contains("only 0 bytes"))
        }
    }

    func testFullImportPreservesArchivedAttachments() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let archived = source.appending(path: "archived_sessions/2026/01/01")
        try fm.createDirectory(at: archived, withIntermediateDirectories: true)
        try writeTranscript(home: source, id: "archived", marker: "done")
        let active = source.appending(path: "sessions/2026/01/01/archived.jsonl")
        try fm.moveItem(at: active, to: archived.appending(path: "archived.jsonl"))
        try Data("attachment".utf8).write(to: archived.appending(path: "image.bin"))
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })

        let plan = try await manager.planImport(source: source, mode: .full)
        let result = try await manager.importAccount(plan: plan)
        XCTAssertEqual(result.importedChats, 2)
        XCTAssertEqual(try Data(contentsOf: paths.sharedRoot.appending(path: "archived_sessions/2026/01/01/image.bin")), Data("attachment".utf8))
        XCTAssertTrue(fm.fileExists(atPath: paths.sharedRoot.appending(path: "archived_sessions/2026/01/01/archived.jsonl").path))
    }

    func testTranscriptComparisonStreamsAcrossChunkBoundaries() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        try writeTranscript(home: paths.sharedRoot, id: "thread", marker: "prefix")
        let sourceFile = source.appending(path: "sessions/2026/01/01/thread.jsonl")
        try fm.createDirectory(at: sourceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: paths.sharedRoot.appending(path: "sessions/2026/01/01/thread.jsonl"), to: sourceFile)
        let handle = try FileHandle(forWritingTo: sourceFile)
        try handle.seekToEnd()
        let record = try JSONSerialization.data(withJSONObject: ["type": "event", "payload": ["text": String(repeating: "x", count: 2 * 1_024 * 1_024)]])
        try handle.write(contentsOf: record + Data([0x0A]))
        try handle.close()
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await manager.planImport(source: source, mode: .full)

        let result = try await manager.importAccount(plan: plan)
        XCTAssertEqual(result.importedChats, 1)
        XCTAssertEqual(try fm.attributesOfItem(atPath: paths.sharedRoot.appending(path: "sessions/2026/01/01/thread.jsonl").path)[.size] as? NSNumber, try fm.attributesOfItem(atPath: sourceFile.path)[.size] as? NSNumber)
    }

    func testLargeLaterTranscriptRecordIsHashedWithoutBuildingAJSONGraph() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        try writeTranscript(home: source, id: "thread", marker: "prefix")
        let transcript = source.appending(path: "sessions/2026/01/01/thread.jsonl")
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        let record = try JSONSerialization.data(withJSONObject: [
            "type": "event",
            "payload": ["text": String(repeating: "x", count: 8 * 1_024 * 1_024)]
        ])
        try handle.write(contentsOf: record + Data([0x0A]))
        try handle.close()
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })

        let plan = try await manager.planImport(source: source, mode: .full)
        let result = try await manager.importAccount(plan: plan)
        XCTAssertEqual(result.importedChats, 1)
        XCTAssertEqual(try fm.attributesOfItem(atPath: paths.sharedRoot.appending(path: "sessions/2026/01/01/thread.jsonl").path)[.size] as? NSNumber, try fm.attributesOfItem(atPath: transcript.path)[.size] as? NSNumber)
    }

    func testMalformedAndUnidentifiedTranscriptsStayAtSourceAndAreReported() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let directory = source.appending(path: "sessions/2026/01/01")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let unidentified = Data(#"{"id":"legacy-top-level-id","type":"event"}"#.utf8)
        let malformed = Data(
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"broken\"}}\nnot-json\n".utf8)
        try unidentified.write(to: directory.appending(path: "unidentified.jsonl"))
        try malformed.write(to: directory.appending(path: "malformed.jsonl"))
        let sharedDirectory = paths.sharedRoot.appending(path: "sessions/2026/01/01")
        try fm.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        try malformed.write(to: sharedDirectory.appending(path: "shared-malformed.jsonl"))
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })

        let plan = try await manager.planImport(source: source, mode: .full)
        let result = try await manager.importAccount(plan: plan)

        XCTAssertEqual(result.importedChats, 0)
        XCTAssertTrue(result.unresolved.contains { $0.contains("unidentified.jsonl") && $0.contains("session_meta.payload.id") })
        XCTAssertTrue(result.unresolved.contains { $0.contains("malformed.jsonl") && $0.contains("malformed JSONL") })
        XCTAssertTrue(result.unresolved.contains { $0.contains("shared-malformed.jsonl") && $0.contains("malformed JSONL") })
        XCTAssertFalse(fm.fileExists(atPath: paths.sharedRoot.appending(path: "sessions/2026/01/01/unidentified.jsonl").path))
        XCTAssertFalse(fm.fileExists(atPath: paths.sharedRoot.appending(path: "sessions/2026/01/01/malformed.jsonl").path))
        XCTAssertEqual(try Data(contentsOf: directory.appending(path: "unidentified.jsonl")), unidentified)
        XCTAssertEqual(try Data(contentsOf: directory.appending(path: "malformed.jsonl")), malformed)
        XCTAssertEqual(
            try Data(contentsOf: sharedDirectory.appending(path: "shared-malformed.jsonl")),
            malformed)
    }

    func testHistoryTraversalSkipsSymlinksAndCountsOnlyRegularJSONLFiles() async throws {
        let source = root.appending(path: "source")
        let external = root.appending(path: "external-history")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        try writeTranscript(home: external, id: "external", marker: "private")
        try fm.createSymbolicLink(
            at: source.appending(path: "sessions"),
            withDestinationURL: external.appending(path: "sessions"))
        try fm.createSymbolicLink(
            at: source.appending(path: "history.jsonl"),
            withDestinationURL: external.appending(path: "sessions/2026/01/01/external.jsonl"))
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })

        let summary = await manager.historySummary(for: source)
        let plan = try await manager.planImport(source: source, mode: .full)
        let result = try await manager.importAccount(plan: plan)

        XCTAssertEqual(summary.activeTranscripts, 0)
        XCTAssertFalse(summary.hasIndexes)
        XCTAssertEqual(plan.manifest.first(where: { $0.relativePath == "sessions" })?.selected, false)
        XCTAssertEqual(
            plan.manifest.first(where: { $0.relativePath == "history.jsonl" })?.disposition,
            "history symbolic links are not imported")
        XCTAssertTrue(result.unresolved.contains { $0.contains("sessions") && $0.contains("symbolic link") })
        XCTAssertFalse(fm.fileExists(atPath: paths.sharedRoot.appending(path: "sessions/2026/01/01/external.jsonl").path))

        let local = root.appending(path: "regular-history")
        try writeTranscript(home: local, id: "regular", marker: "count")
        try fm.createDirectory(at: local.appending(path: "sessions/fake.jsonl"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: local.appending(path: "sessions/link.jsonl"),
            withDestinationURL: external.appending(path: "sessions/2026/01/01/external.jsonl"))
        let localSummary = await manager.historySummary(for: local)
        XCTAssertEqual(localSummary.activeTranscripts, 1)
    }

    func testDuplicateSharedTranscriptIdentityStaysUntouchedAndBlocksIncomingCopy() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        try writeTranscript(home: source, id: "duplicate", marker: "incoming", filename: "incoming.jsonl")
        try writeTranscript(home: paths.sharedRoot, id: "duplicate", marker: "first", filename: "first.jsonl")
        try writeTranscript(home: paths.sharedRoot, id: "duplicate", marker: "second", filename: "second.jsonl")
        let first = paths.sharedRoot.appending(path: "sessions/2026/01/01/first.jsonl")
        let second = paths.sharedRoot.appending(path: "sessions/2026/01/01/second.jsonl")
        let firstData = try Data(contentsOf: first)
        let secondData = try Data(contentsOf: second)
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })

        let plan = try await manager.planImport(source: source, mode: .full)
        let result = try await manager.importAccount(plan: plan)

        XCTAssertEqual(result.importedChats, 0)
        XCTAssertTrue(result.unresolved.contains { $0.contains("duplicate shared transcript ID duplicate") })
        XCTAssertEqual(try Data(contentsOf: first), firstData)
        XCTAssertEqual(try Data(contentsOf: second), secondData)
        XCTAssertFalse(fm.fileExists(atPath: paths.sharedRoot.appending(path: "sessions/2026/01/01/incoming.jsonl").path))
    }

    func testDirectorySettingMergePreservesSharedOnlyFilesAndUsesPerFileChoices() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let importedRules = source.appending(path: "rules")
        let sharedRules = paths.sharedRoot.appending(path: "rules")
        try fm.createDirectory(at: importedRules, withIntermediateDirectories: true)
        try fm.createDirectory(at: sharedRules, withIntermediateDirectories: true)
        try Data("source-only".utf8).write(to: importedRules.appending(path: "source.md"))
        try Data("shared-only".utf8).write(to: sharedRules.appending(path: "shared.md"))
        try Data("incoming".utf8).write(to: importedRules.appending(path: "conflict.md"))
        try Data("existing".utf8).write(to: sharedRules.appending(path: "conflict.md"))
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })

        let plan = try await manager.planImport(source: source, mode: .full)
        XCTAssertEqual(plan.conflicts.map(\.relativePath), ["rules/conflict.md"])
        _ = try await manager.importAccount(plan: plan, decisions: ["rules/conflict.md": .useImported])
        XCTAssertEqual(try Data(contentsOf: sharedRules.appending(path: "source.md")), Data("source-only".utf8))
        XCTAssertEqual(try Data(contentsOf: sharedRules.appending(path: "shared.md")), Data("shared-only".utf8))
        XCTAssertEqual(try Data(contentsOf: sharedRules.appending(path: "conflict.md")), Data("incoming".utf8))
    }

    func testReviewedExternalSkillCanBeKeptWithoutFollowingItsTarget() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let external = root.appending(path: "outside-skills")
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("skill".utf8).write(to: external.appending(path: "SKILL.md"))
        try fm.createSymbolicLink(at: source.appending(path: "skills"), withDestinationURL: external)
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await manager.planImport(source: source, mode: .full)
        XCTAssertTrue(plan.conflicts.contains { $0.relativePath == "skills" })

        let result = try await manager.importAccount(plan: plan, decisions: ["skills": .keepShared])
        XCTAssertFalse(fm.fileExists(atPath: paths.sharedRoot.appending(path: "skills").path))
        XCTAssertTrue(result.unresolved.contains { $0.contains("shared entry is missing") })

        var reviewed = try await manager.planImport(source: source, mode: .full)
        await XCTAssertThrowsErrorAsync(try await manager.importAccount(plan: reviewed, decisions: ["skills": .useImported]))
        reviewed = try await manager.reviewExternalSetting(plan: reviewed, relativePath: "skills")
        let portable = try await manager.importAccount(plan: reviewed, decisions: ["skills": .useImported])
        XCTAssertEqual(try Data(contentsOf: paths.sharedRoot.appending(path: "skills/SKILL.md")), Data("skill".utf8))
        XCTAssertEqual(try Data(contentsOf: portable.backup.appending(path: "linked-source/skills/SKILL.md")), Data("skill".utf8))
        XCTAssertFalse(portable.unresolved.contains { $0.contains("skills: external symbolic-link") })
    }

    func testReviewedExternalSettingRejectsChangedTargetContent() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let external = root.appending(path: "outside-skills")
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        let skill = external.appending(path: "SKILL.md")
        try Data("reviewed".utf8).write(to: skill)
        try fm.createSymbolicLink(at: source.appending(path: "skills"), withDestinationURL: external)
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        var plan = try await manager.planImport(source: source, mode: .full)
        plan = try await manager.reviewExternalSetting(plan: plan, relativePath: "skills")
        try Data("changed after review".utf8).write(to: skill)

        await XCTAssertThrowsErrorAsync(
            try await manager.importAccount(plan: plan, decisions: ["skills": .useImported])
        ) { error in
            XCTAssertEqual(error as? AIManagerError, .sourceChanged)
        }
        XCTAssertFalse(CoreSupport.entryExists(paths.sharedRoot.appending(path: "skills")))
        let status = try await manager.status()
        XCTAssertTrue(status.accounts.isEmpty)
    }

    func testNestedExternalSettingCannotBeApprovedButCanStayShared() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let rules = source.appending(path: "rules")
        let external = root.appending(path: "outside-rule")
        let sharedRules = paths.sharedRoot.appending(path: "rules")
        try fm.createDirectory(at: rules, withIntermediateDirectories: true)
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        try fm.createDirectory(at: sharedRules, withIntermediateDirectories: true)
        try Data("external".utf8).write(to: external.appending(path: "rule.md"))
        try Data("shared".utf8).write(to: sharedRules.appending(path: "rule.md"))
        try fm.createSymbolicLink(at: rules.appending(path: "linked"), withDestinationURL: external)
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await manager.planImport(source: source, mode: .full)

        await XCTAssertThrowsErrorAsync(
            try await manager.reviewExternalSetting(plan: plan, relativePath: "rules")
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Nested external links"))
        }
        _ = try await manager.importAccount(plan: plan, decisions: ["rules": .keepShared])
        XCTAssertEqual(
            try Data(contentsOf: sharedRules.appending(path: "rule.md")), Data("shared".utf8))
    }

    func testFullImportRejectsDatabaseChangesAfterReview() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let database = source.appending(path: "state_5.sqlite")
        try Data("before".utf8).write(to: database)
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await manager.planImport(source: source, mode: .full)
        try Data("after".utf8).write(to: database)

        await XCTAssertThrowsErrorAsync(try await manager.importAccount(plan: plan)) { error in
            XCTAssertEqual(error as? AIManagerError, .sourceChanged)
        }
        let status = try await manager.status()
        XCTAssertTrue(status.accounts.isEmpty)
    }

    func testSourceMutationDuringCopyRollsBackSharedAddition() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        try writeTranscript(home: source, id: "thread", marker: "before")
        let transcript = source.appending(path: "sessions/2026/01/01/thread.jsonl")
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive }, faultInjector: { point in
            if point == .duringHistoryCopy {
                let handle = try FileHandle(forWritingTo: transcript)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("{}\n".utf8))
                try handle.close()
            }
        })
        let plan = try await manager.planImport(source: source, mode: .full)
        await XCTAssertThrowsErrorAsync(try await manager.importAccount(plan: plan)) { error in XCTAssertEqual(error as? AIManagerError, .sourceChanged) }
        let recovering = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        _ = try await recovering.recover()
        XCTAssertFalse(fm.fileExists(atPath: paths.sharedRoot.appending(path: "sessions/2026/01/01/thread.jsonl").path))
    }

    func testRecoveryPreservesLaterEditAndReportsConflict() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let crashing = try AccountManager(paths: paths, writerCheck: { _ in .inactive }, faultInjector: { point in
            if point == .afterHomePublication { throw AIManagerError.operationFailed("injected crash") }
        })
        let plan = try await crashing.planImport(source: source, mode: .authOnly)
        await XCTAssertThrowsErrorAsync(try await crashing.importAccount(plan: plan))
        let laterEdit = Data("later-user-edit".utf8)
        try laterEdit.write(to: plan.destination.appending(path: "auth.json"))

        let recovering = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let result = try await recovering.recover()
        XCTAssertEqual(result.first?.outcome, .conflict)
        XCTAssertEqual(try Data(contentsOf: plan.destination.appending(path: "auth.json")), laterEdit)
    }

    func testRecoveryConflictCanPreserveCurrentAndFinalize() async throws {
        let fixture = try await makeConflictedReimport()
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })

        await XCTAssertThrowsErrorAsync(
            try await manager.launchSpec(accountID: fixture.accountID)
        ) { error in
            XCTAssertEqual(error as? AIManagerError, .recoveryRequired)
        }

        let result = try await manager.resolveRecoveryConflict(
            operationID: fixture.plan.operationID,
            choice: .preserveCurrent
        )

        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appending(path: "auth.json")),
            fixture.later
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.plan.backup.appending(path: "account-home/auth.json")),
            fixture.initial
        )
        let status = try await manager.status()
        XCTAssertTrue(status.pendingRecovery.isEmpty)
        let account = try XCTUnwrap(status.accounts.first(where: { $0.id == fixture.accountID }))
        XCTAssertEqual(account.credentialDigest, CoreSupport.digest(fixture.later))
        _ = try await manager.switchDefault(to: fixture.accountID)
        let launch = try await manager.launchSpec(accountID: fixture.accountID)
        XCTAssertEqual(launch.environment["CODEX_HOME"], paths.defaultHome.path)
    }

    func testRecoveryConflictPreserveRegistersNewImportAndAllowsLaunch() async throws {
        let source = root.appending(path: "conflicted-new-import-source")
        try writeAuth(home: source, account: "new-account", workspace: "workspace")
        let crashing = try AccountManager(
            paths: paths,
            writerCheck: { _ in .inactive },
            faultInjector: { point in
                if point == .afterHomePublication {
                    throw AIManagerError.operationFailed("injected interruption")
                }
            }
        )
        let plan = try await crashing.planImport(source: source, mode: .authOnly)
        await XCTAssertThrowsErrorAsync(try await crashing.importAccount(plan: plan))
        let later = try refreshedAuth(
            account: "new-account", workspace: "workspace", marker: "later-live-edit")
        try later.write(to: plan.destination.appending(path: "auth.json"))

        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let recovered = try await manager.recover()
        XCTAssertEqual(recovered.first?.outcome, .conflict)
        let resolution = try await manager.resolveRecoveryConflict(
            operationID: plan.operationID,
            choice: .preserveCurrent
        )

        XCTAssertEqual(resolution.outcome, .completed)
        let status = try await manager.status()
        XCTAssertTrue(status.pendingRecovery.isEmpty)
        let account = try XCTUnwrap(status.accounts.first(where: { $0.id == plan.id }))
        XCTAssertEqual(account.credentialDigest, CoreSupport.digest(later))
        XCTAssertEqual(account.home.standardizedFileURL, plan.destination.standardizedFileURL)
        _ = try await manager.switchDefault(to: plan.id)
        let launch = try await manager.launchSpec(accountID: plan.id)
        XCTAssertEqual(launch.environment["CODEX_HOME"], paths.defaultHome.path)
    }

    func testRecoveryConflictPreserveReconcilesSwitchAndTouchedOutgoingCredential() async throws {
        let firstSource = root.appending(path: "preserve-switch-first")
        let secondSource = root.appending(path: "preserve-switch-second")
        try writeAuth(home: firstSource, account: "first", workspace: "workspace")
        try writeAuth(home: secondSource, account: "second", workspace: "workspace")
        let setup = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let firstPlan = try await setup.planImport(source: firstSource, mode: .authOnly)
        let first = try await setup.importAccount(plan: firstPlan).account
        let secondPlan = try await setup.planImport(source: secondSource, mode: .authOnly)
        let second = try await setup.importAccount(plan: secondPlan).account
        _ = try await setup.switchDefault(to: first.id)
        let refreshedFirst = try refreshedAuth(
            account: "first", workspace: "workspace", marker: "refreshed-outgoing")
        try refreshedFirst.write(to: paths.defaultHome.appending(path: "auth.json"))

        var interruptedOperationID: UUID?
        let crashing = try AccountManager(
            paths: paths,
            writerCheck: { _ in .inactive },
            faultInjector: { point in
                if point == .afterDefaultCredentialPublication {
                    throw AIManagerError.operationFailed("injected interruption")
                }
            }
        )
        await XCTAssertThrowsErrorAsync(try await crashing.switchDefault(to: second.id))
        interruptedOperationID = try await crashing.status().pendingRecovery.first?.id
        let refreshedSecond = try refreshedAuth(
            account: "second", workspace: "workspace", marker: "later-default-edit")
        try refreshedSecond.write(to: paths.defaultHome.appending(path: "auth.json"))

        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let recovered = try await manager.recover()
        XCTAssertEqual(recovered.first?.outcome, .conflict)
        let operationID = try XCTUnwrap(interruptedOperationID)
        let resolution = try await manager.resolveRecoveryConflict(
            operationID: operationID,
            choice: .preserveCurrent
        )

        XCTAssertEqual(resolution.outcome, .completed)
        let status = try await manager.status()
        XCTAssertTrue(status.pendingRecovery.isEmpty)
        XCTAssertEqual(status.defaultAccountID, second.id)
        XCTAssertEqual(
            status.accounts.first(where: { $0.id == first.id })?.credentialDigest,
            CoreSupport.digest(refreshedFirst)
        )
        _ = try await manager.switchDefault(to: first.id)
        let firstLaunch = try await manager.launchSpec(accountID: first.id)
        _ = try await manager.switchDefault(to: second.id)
        let secondLaunch = try await manager.launchSpec(accountID: second.id)
        XCTAssertEqual(firstLaunch.environment["CODEX_HOME"], paths.defaultHome.path)
        XCTAssertEqual(secondLaunch.environment["CODEX_HOME"], paths.defaultHome.path)
    }

    func testRecoveryConflictCanRestoreBackupAndPreserveCurrent() async throws {
        let fixture = try await makeConflictedReimport()
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })

        let result = try await manager.resolveRecoveryConflict(
            operationID: fixture.plan.operationID,
            choice: .restoreBackup
        )

        XCTAssertEqual(result.outcome, .rolledBack)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appending(path: "auth.json")),
            fixture.initial
        )
        XCTAssertTrue(try preservedRecoveryAuth(for: fixture.plan).contains(fixture.later))
        let status = try await manager.status()
        XCTAssertTrue(status.pendingRecovery.isEmpty)
        XCTAssertEqual(
            status.accounts.first(where: { $0.id == fixture.accountID })?.credentialDigest,
            CoreSupport.digest(fixture.initial)
        )
        _ = try await manager.switchDefault(to: fixture.accountID)
        let launch = try await manager.launchSpec(accountID: fixture.accountID)
        XCTAssertEqual(launch.environment["CODEX_HOME"], paths.defaultHome.path)
    }

    func testRecoveryConflictRestoreRejectsChangedBackupWithoutMutatingLiveFiles() async throws {
        let fixture = try await makeConflictedReimport()
        try Data("changed-backup".utf8)
            .write(to: fixture.plan.backup.appending(path: "account-home/auth.json"))
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })

        await XCTAssertThrowsErrorAsync(
            try await manager.resolveRecoveryConflict(
                operationID: fixture.plan.operationID,
                choice: .restoreBackup
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed after it was recorded"))
        }

        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appending(path: "auth.json")),
            fixture.later
        )
        let status = try await manager.status()
        XCTAssertEqual(status.pendingRecovery.first?.phase, .conflicted)
    }

    func testAutomaticRecoveryRejectsChangedBackupBeforeRollbackMutation() async throws {
        let source = root.appending(path: "changed-automatic-backup-source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let setup = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let initialPlan = try await setup.planImport(source: source, mode: .authOnly)
        let account = try await setup.importAccount(plan: initialPlan).account
        let incoming = try refreshedAuth(
            account: "account", workspace: "workspace", marker: "incoming")
        try incoming.write(to: source.appending(path: "auth.json"))
        let crashing = try AccountManager(
            paths: paths,
            writerCheck: { _ in .inactive },
            faultInjector: { point in
                if point == .afterHomePublication {
                    throw AIManagerError.operationFailed("injected interruption")
                }
            }
        )
        let plan = try await crashing.planImport(source: source, mode: .authOnly)
        await XCTAssertThrowsErrorAsync(
            try await crashing.importAccount(
                plan: plan,
                decisions: ["auth.json": .useImported]
            )
        )
        try Data("changed-backup".utf8)
            .write(to: plan.backup.appending(path: "account-home/auth.json"))
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })

        await XCTAssertThrowsErrorAsync(try await manager.recover()) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed after it was recorded"))
        }

        XCTAssertEqual(
            try Data(contentsOf: account.home.appending(path: "auth.json")),
            incoming
        )
        let status = try await manager.status()
        XCTAssertFalse(status.pendingRecovery.isEmpty)
    }

    func testRecoveryConflictRestoreCreatesMissingDestinationParent() async throws {
        let fixture = try await makeConflictedReimport()
        try fm.removeItem(at: fixture.destination.deletingLastPathComponent())
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })

        let result = try await manager.resolveRecoveryConflict(
            operationID: fixture.plan.operationID,
            choice: .restoreBackup
        )

        XCTAssertEqual(result.outcome, .rolledBack)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appending(path: "auth.json")),
            fixture.initial
        )
        let status = try await manager.status()
        XCTAssertTrue(status.pendingRecovery.isEmpty)
    }

    func testRecoveryConflictResolverRejectsUnknownAndNonConflictedOperations() async throws {
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        await XCTAssertThrowsErrorAsync(
            try await manager.resolveRecoveryConflict(
                operationID: UUID(), choice: .preserveCurrent)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("not found"))
        }

        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let crashing = try AccountManager(
            paths: paths,
            writerCheck: { _ in .inactive },
            faultInjector: { point in
                if point == .afterHomePublication {
                    throw AIManagerError.operationFailed("injected interruption")
                }
            }
        )
        let plan = try await crashing.planImport(source: source, mode: .authOnly)
        await XCTAssertThrowsErrorAsync(try await crashing.importAccount(plan: plan))

        await XCTAssertThrowsErrorAsync(
            try await manager.resolveRecoveryConflict(
                operationID: plan.operationID, choice: .preserveCurrent)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("not conflicted"))
        }
    }

    func testRecoveryConflictResolverRechecksAffectedWriters() async throws {
        let fixture = try await makeConflictedReimport()
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .active })

        await XCTAssertThrowsErrorAsync(
            try await manager.resolveRecoveryConflict(
                operationID: fixture.plan.operationID, choice: .restoreBackup)
        ) { error in
            XCTAssertEqual(error as? AIManagerError, .activeCodexProcesses)
        }
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appending(path: "auth.json")),
            fixture.later
        )
        let status = try await manager.status()
        XCTAssertEqual(status.pendingRecovery.first?.phase, .conflicted)
    }

    func testRecoveryConflictRestoreResumesAfterInterruption() async throws {
        let fixture = try await makeConflictedReimport()
        let crashing = try AccountManager(
            paths: paths,
            writerCheck: { _ in .inactive },
            faultInjector: { point in
                if point == .afterRecoveryConflictRestore {
                    throw AIManagerError.operationFailed("injected resolution interruption")
                }
            }
        )

        await XCTAssertThrowsErrorAsync(
            try await crashing.resolveRecoveryConflict(
                operationID: fixture.plan.operationID, choice: .restoreBackup)
        )
        let interruptedStatus = try await crashing.status()
        XCTAssertEqual(interruptedStatus.pendingRecovery.first?.phase, .conflicted)
        XCTAssertEqual(
            try Data(contentsOf: fixture.destination.appending(path: "auth.json")),
            fixture.initial
        )

        let recovering = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let result = try await recovering.resolveRecoveryConflict(
            operationID: fixture.plan.operationID,
            choice: .restoreBackup
        )
        XCTAssertEqual(result.outcome, .rolledBack)
        XCTAssertTrue(try preservedRecoveryAuth(for: fixture.plan).contains(fixture.later))
        let status = try await recovering.status()
        XCTAssertTrue(status.pendingRecovery.isEmpty)
    }

    func testAutomaticRecoveryRechecksActiveAndUnknownWriters() async throws {
        let source = root.appending(path: "recovery-writer-source")
        try writeAuth(home: source, account: "recovery-writer", workspace: "workspace")
        let crashing = try AccountManager(
            paths: paths,
            writerCheck: { _ in .inactive },
            faultInjector: { point in
                if point == .afterHomePublication {
                    throw AIManagerError.operationFailed("injected interruption")
                }
            }
        )
        let plan = try await crashing.planImport(source: source, mode: .authOnly)
        await XCTAssertThrowsErrorAsync(try await crashing.importAccount(plan: plan))
        let published = try Data(contentsOf: plan.destination.appending(path: "auth.json"))

        let active = try AccountManager(paths: paths, writerCheck: { _ in .active })
        await XCTAssertThrowsErrorAsync(try await active.recover()) { error in
            XCTAssertEqual(error as? AIManagerError, .activeCodexProcesses)
        }
        let unknown = try AccountManager(paths: paths, writerCheck: { _ in .unknown })
        await XCTAssertThrowsErrorAsync(try await unknown.recover()) { error in
            XCTAssertEqual(error as? AIManagerError, .writerStateUnknown)
        }
        XCTAssertEqual(
            try Data(contentsOf: plan.destination.appending(path: "auth.json")),
            published
        )
        let status = try await unknown.status()
        XCTAssertEqual(status.pendingRecovery.first?.id, plan.operationID)
    }

    func testRecoveryPreservesRecordedInterruptedTemporaryOutsideLiveSharedTree() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        try Data("imported".utf8).write(to: source.appending(path: "config.toml"))
        try Data("shared".utf8).write(to: paths.sharedRoot.appending(path: "config.toml"))
        let crashing = try AccountManager(paths: paths, writerCheck: { _ in .inactive }, faultInjector: { point in
            if point == .afterTemporaryCopy { throw AIManagerError.operationFailed("injected interruption") }
        })
        let plan = try await crashing.planImport(source: source, mode: .full)
        await XCTAssertThrowsErrorAsync(try await crashing.importAccount(plan: plan, decisions: ["config.toml": .useImported]))
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: paths.sharedRoot.path).contains { $0.hasSuffix(".stage") })

        let recovering = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        _ = try await recovering.recover()
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: paths.sharedRoot.path).contains { $0.hasSuffix(".stage") })
        let preserved = plan.backup.appending(path: "interrupted-staging")
        XCTAssertFalse((try fm.contentsOfDirectory(atPath: preserved.path)).isEmpty)
        XCTAssertEqual(try Data(contentsOf: paths.sharedRoot.appending(path: "config.toml")), Data("shared".utf8))
    }

    func testRecoveryLoadsIncrementalJournalForManyPublishedTranscripts() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        for index in 0..<40 { try writeTranscript(home: source, id: "thread-\(index)", marker: "event", filename: "thread-\(index).jsonl") }
        let crashing = try AccountManager(paths: paths, writerCheck: { _ in .inactive }, faultInjector: { point in
            if point == .afterHomePublication { throw AIManagerError.operationFailed("injected interruption") }
        })
        let plan = try await crashing.planImport(source: source, mode: .full)
        await XCTAssertThrowsErrorAsync(try await crashing.importAccount(plan: plan))

        let itemRoot = paths.applicationSupport.appending(
            path: "transactions/\(plan.operationID.uuidString).items")
        let itemFiles = try fm.contentsOfDirectory(at: itemRoot, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        XCTAssertEqual(itemFiles.count, 40)
        for file in itemFiles {
            let item = try JSONDecoder().decode(RecoveryItem.self, from: Data(contentsOf: file))
            XCTAssertEqual(item.expectedDigest, try CoreSupport.digest(file: item.destination))
        }
        let headerURL = paths.applicationSupport.appending(
            path: "transactions/\(plan.operationID.uuidString).json")
        let header = try JSONDecoder().decode(RecoveryOperation.self, from: Data(contentsOf: headerURL))
        XCTAssertEqual(header.expectedDigest, try localTreeDigest(header.destination))
        let recovering = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let recovered = try await recovering.recover()
        XCTAssertEqual(recovered.first?.outcome, .rolledBack)
        XCTAssertEqual(transcriptFileCount(paths.sharedRoot.appending(path: "sessions")), 0)
        XCTAssertFalse(fm.fileExists(atPath: itemRoot.path))
    }

    func testUnknownSQLiteSchemaIsRejectedAndFailedSnapshotIsRemoved() throws {
        let source = root.appending(path: "unknown.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE unknown(value TEXT)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let snapshot = root.appending(path: "unknown-snapshot.sqlite")
        try SQLiteSupport.snapshot(source: source, destination: snapshot)
        XCTAssertThrowsError(try SQLiteSupport.rebaseRecognizedRolloutPaths(database: snapshot, sourceHome: root, destinationHome: root.appending(path: "new"), transcriptDestinations: [:], projectionDatabase: nil))

        let corrupt = root.appending(path: "corrupt.sqlite")
        try Data("not sqlite".utf8).write(to: corrupt)
        let partial = root.appending(path: "partial.sqlite")
        XCTAssertThrowsError(try SQLiteSupport.snapshot(source: corrupt, destination: partial))
        XCTAssertFalse(fm.fileExists(atPath: partial.path))
    }

    func testLocalVerificationIsBoundedAndPersistsResult() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let hanging = root.appending(path: "hanging-codex")
        try Data("#!/bin/sh\nwhile :; do :; done\n".utf8).write(to: hanging)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hanging.path)
        paths.codexExecutable = hanging
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive }, verificationTimeout: 0.1)
        let plan = try await manager.planImport(source: source, mode: .authOnly)
        let account = try await manager.importAccount(plan: plan).account

        let started = Date()
        let result = await manager.verifyLocal(accountID: account.id)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(result.state, .verifiedLocally)
        let status = try await manager.status()
        XCTAssertEqual(status.accounts.first?.verification.state, .verifiedLocally)
    }

    func testCorruptRecoveryJournalBlocksMutation() async throws {
        let transaction = paths.applicationSupport.appending(path: "transactions/broken.json")
        try fm.createDirectory(at: transaction.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: transaction)
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })

        await XCTAssertThrowsErrorAsync(try await manager.planImport(source: source, mode: .authOnly))
        await XCTAssertThrowsErrorAsync(try await manager.recover())
    }

    private func makeConflictedReimport() async throws -> (
        plan: ImportPlan,
        accountID: UUID,
        destination: URL,
        initial: Data,
        later: Data
    ) {
        let source = root.appending(path: "conflicted-reimport-source")
        try writeAuth(home: source, account: "account", workspace: "workspace")
        let setup = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let initialPlan = try await setup.planImport(source: source, mode: .authOnly)
        let account = try await setup.importAccount(plan: initialPlan).account
        let initial = try Data(contentsOf: account.home.appending(path: "auth.json"))
        try refreshedAuth(account: "account", workspace: "workspace", marker: "incoming")
            .write(to: source.appending(path: "auth.json"))

        let crashing = try AccountManager(
            paths: paths,
            writerCheck: { _ in .inactive },
            faultInjector: { point in
                if point == .afterHomePublication {
                    throw AIManagerError.operationFailed("injected interruption")
                }
            }
        )
        let plan = try await crashing.planImport(source: source, mode: .authOnly)
        await XCTAssertThrowsErrorAsync(
            try await crashing.importAccount(
                plan: plan,
                decisions: ["auth.json": .useImported]
            )
        )
        let later = try refreshedAuth(
            account: "account", workspace: "workspace", marker: "later-live-edit")
        try later.write(to: account.home.appending(path: "auth.json"))
        let recovering = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let result = try await recovering.recover()
        XCTAssertEqual(result.first?.outcome, .conflict)
        return (plan, account.id, account.home, initial, later)
    }

    private func preservedRecoveryAuth(for plan: ImportPlan) throws -> [Data] {
        let root = plan.backup.appending(path: "recovery-conflict/current")
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { try? Data(contentsOf: $0.appending(path: "auth.json")) }
    }

    private func writeAuth(home: URL, account: String, workspace: String, email: String = "person@example.test", user: String? = nil) throws {
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try authData(account: account, workspace: workspace, email: email, user: user).write(to: home.appending(path: "auth.json"))
    }

    private func authData(account: String, workspace: String, email: String = "person@example.test", user: String? = nil) throws -> Data {
        let claims = try JSONSerialization.data(withJSONObject: ["email": email, "chatgpt_user_id": user ?? "user-\(email)", "chatgpt_account_id": account, "workspace_id": workspace])
            .base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let auth: [String: Any] = ["last_refresh": "2026-01-01T00:00:00Z", "tokens": ["access_token": "header.\(claims).signature", "account_id": account, "refresh_token": "synthetic"]]
        return try JSONSerialization.data(withJSONObject: auth)
    }

    private func refreshedAuth(account: String, workspace: String, marker: String) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: authData(account: account, workspace: workspace)) as! [String: Any]
        object["last_refresh"] = marker
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func writeTranscript(home: URL, id: String, marker: String, filename: String? = nil) throws {
        let directory = home.appending(path: "sessions/2026/01/01")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id]])
        let second = try JSONSerialization.data(withJSONObject: ["type": "event", "payload": ["marker": marker]])
        var data = first; data.append(0x0A); data.append(second); data.append(0x0A)
        try data.write(to: directory.appending(path: filename ?? "\(id).jsonl"))
    }

    private func transcriptFileCount(_ directory: URL) -> Int {
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "jsonl" { count += 1 }
        }
        return count
    }

    private func localTreeDigest(_ root: URL) throws -> String {
        var hasher = SHA256()
        func update(_ url: URL, relative: String) throws {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                let target = try fm.destinationOfSymbolicLink(atPath: url.path)
                let resolved = target.hasPrefix("/") ? URL(fileURLWithPath: target) : url.deletingLastPathComponent().appending(path: target)
                try update(resolved, relative: relative)
            } else {
                hasher.update(data: Data(relative.utf8))
                if values.isDirectory == true {
                    for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                        try update(child, relative: relative.isEmpty ? child.lastPathComponent : "\(relative)/\(child.lastPathComponent)")
                    }
                } else if values.isRegularFile == true {
                    hasher.update(data: try Data(contentsOf: url))
                }
            }
        }
        try update(root, relative: "")
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func queryPaths(_ database: URL) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT rollout_path FROM threads ORDER BY id", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) { result.append(String(cString: text)) }
        return result
    }

    private func queryInteger(_ database: URL, sql: String) throws -> Int64? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : nil
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ handler: (Error) -> Void = { _ in }, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("Expected error", file: file, line: line) }
    catch { handler(error) }
}
