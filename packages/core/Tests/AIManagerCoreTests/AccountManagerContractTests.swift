import CSQLite
import Foundation
import XCTest
@testable import AIManagerCore

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

    func testAuthOnlyImportKeepsSourceAndLinksSharedData() async throws {
        let source = root.appending(path: "source")
        try writeAuth(home: source, account: "account-a", workspace: "workspace")
        try Data("shared".utf8).write(to: paths.sharedRoot.appending(path: "config.toml"))
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })

        let plan = try await manager.planImport(source: source, mode: .authOnly)
        let result = try await manager.importAccount(plan: plan)

        XCTAssertEqual(result.account.identity.providerID, .codex)
        XCTAssertEqual(try Data(contentsOf: source.appending(path: "auth.json")), try Data(contentsOf: result.account.home.appending(path: "auth.json")))
        XCTAssertTrue(try result.account.home.appending(path: "config.toml").resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        XCTAssertEqual((try fm.attributesOfItem(atPath: result.account.home.appending(path: "auth.json").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try fm.attributesOfItem(atPath: result.account.home.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
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

    func testSwitchChangesOnlyAuthAndRefusesActiveWriter() async throws {
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
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), try Data(contentsOf: second.account.home.appending(path: "auth.json")))
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "config.toml")), settings)

        let blocked = try AccountManager(paths: paths, writerCheck: { _ in .active })
        await XCTAssertThrowsErrorAsync(try await blocked.switchDefault(to: first.account.id)) { error in
            XCTAssertEqual(error as? AIManagerError, .activeCodexProcesses)
        }
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
        XCTAssertEqual(try Data(contentsOf: account.home.appending(path: "auth.json")), refreshed)
    }

    func testSwitchRefusesWhenDefaultAndManagedCredentialsBothDiverged() async throws {
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
        let managedEdit = try refreshedAuth(account: "first", workspace: "workspace", marker: "managed-edit")
        try defaultEdit.write(to: paths.defaultHome.appending(path: "auth.json"))
        try managedEdit.write(to: first.home.appending(path: "auth.json"))

        await XCTAssertThrowsErrorAsync(try await manager.switchDefault(to: second.id)) { error in
            XCTAssertEqual(error as? AIManagerError, .credentialConflict)
        }
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), defaultEdit)
        XCTAssertEqual(try Data(contentsOf: first.home.appending(path: "auth.json")), managedEdit)
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
        let spec = try await manager.launchSpec(accountID: result.account.id, arguments: ["resume", "--all"])
        XCTAssertEqual(spec.environment["CODEX_HOME"], result.account.home.path)
        XCTAssertNil(spec.environment["OPENAI_API_KEY"])
        XCTAssertEqual(spec.arguments, ["-c", "cli_auth_credentials_store=\"file\"", "resume", "--all"])
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
        let managedDigest = try CoreSupport.digest(file: first.home.appending(path: "auth.json"))
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
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), try Data(contentsOf: second.home.appending(path: "auth.json")))
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
        XCTAssertEqual(derived.sharedRoot.standardizedFileURL.path, isolated.appending(path: "shared-root").path)
        XCTAssertEqual(derived.orcaAccountsRoot.standardizedFileURL.path, isolated.appending(path: "orca-accounts").path)
        XCTAssertEqual(derived.applicationSupport.standardizedFileURL.path, isolated.appending(path: "application-support").path)
        let escaped = ManagerPaths.environment(["AI_MANAGER_ROOT": isolated.path, "AI_MANAGER_DEFAULT_HOME": paths.defaultHome.path, "AI_MANAGER_SHARED_ROOT": paths.sharedRoot.path])
        XCTAssertEqual(escaped.defaultHome.standardizedFileURL.path, isolated.appending(path: "default-home").path)
        XCTAssertEqual(escaped.sharedRoot.standardizedFileURL.path, isolated.appending(path: "shared-root").path)
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
        XCTAssertEqual(plan.warnings.count, 1)
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
        try handle.write(contentsOf: Data(repeating: 0x78, count: 8 * 1_024 * 1_024))
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })

        let plan = try await manager.planImport(source: source, mode: .full)
        let result = try await manager.importAccount(plan: plan)
        XCTAssertEqual(result.importedChats, 1)
        XCTAssertEqual(try fm.attributesOfItem(atPath: paths.sharedRoot.appending(path: "sessions/2026/01/01/thread.jsonl").path)[.size] as? NSNumber, try fm.attributesOfItem(atPath: transcript.path)[.size] as? NSNumber)
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

        let itemRoot = paths.applicationSupport.appending(path: "transactions/\(plan.id.uuidString).items")
        let itemFiles = try fm.contentsOfDirectory(at: itemRoot, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        XCTAssertEqual(itemFiles.count, 40)
        for file in itemFiles {
            let item = try JSONDecoder().decode(RecoveryItem.self, from: Data(contentsOf: file))
            XCTAssertEqual(item.expectedDigest, try CoreSupport.digest(file: item.destination))
        }
        let headerURL = paths.applicationSupport.appending(path: "transactions/\(plan.id.uuidString).json")
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
        XCTAssertEqual(result.state, .needsSignIn)
        let status = try await manager.status()
        XCTAssertEqual(status.accounts.first?.verification.state, .needsSignIn)
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
