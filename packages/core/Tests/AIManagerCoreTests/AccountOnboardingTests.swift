import Foundation
import XCTest
@testable import AIManagerCore

final class AccountOnboardingTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appending(path: "AccountOnboardingTests-\(UUID().uuidString)")
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
        try fileManager.createDirectory(at: paths.defaultHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fileManager.removeItem(at: root) }
    }

    func testRefreshAdoptsValidLiveAccountOnceAndMakesItDefault() async throws {
        let original = try writeAuth(home: paths.defaultHome, account: "live", workspace: "personal")
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })

        let first = try await manager.refreshAccounts()
        let account = try XCTUnwrap(first.status.accounts.first)

        XCTAssertEqual(first.status.accounts.count, 1)
        XCTAssertEqual(first.status.defaultAccountID, account.id)
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), original)
        XCTAssertEqual(account.credentialFile.lastPathComponent, "\(account.id.uuidString).json")
        XCTAssertEqual(try Data(contentsOf: account.credentialFile), original)

        let second = try await manager.refreshAccounts(includeDiscoveries: false)
        XCTAssertEqual(second.status.accounts.count, 1)
        XCTAssertEqual(second.status.accounts.first?.id, account.id)
        XCTAssertTrue(second.discoveries.isEmpty)
    }

    func testRefreshRecoversCommittedLiveAdoptionAfterInterruption() async throws {
        _ = try writeAuth(home: paths.defaultHome, account: "recover", workspace: "personal")
        let crashing = try AccountManager(
            paths: paths,
            writerCheck: { _ in .inactive },
            faultInjector: { if $0 == .afterRegistryCommit { throw AIManagerError.operationFailed("stop") } }
        )

        await assertOnboardingThrows(try await crashing.refreshAccounts())

        let recovered = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let snapshot = try await recovered.refreshAccounts()
        XCTAssertEqual(snapshot.status.accounts.count, 1)
        XCTAssertEqual(snapshot.status.defaultAccountID, snapshot.status.accounts.first?.id)
        XCTAssertTrue(snapshot.status.pendingRecovery.isEmpty)
    }

    func testRefreshDoesNotAdoptSymlinkedLiveCredential() async throws {
        let source = root.appending(path: "outside-auth.json")
        let auth = try writeAuth(
            home: source.deletingLastPathComponent().appending(path: "outside"),
            account: "linked",
            workspace: "personal")
        try auth.write(to: source, options: .atomic)
        try fileManager.createSymbolicLink(
            at: paths.defaultHome.appending(path: "auth.json"),
            withDestinationURL: source)
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })

        let snapshot = try await manager.refreshAccounts()

        XCTAssertTrue(snapshot.status.accounts.isEmpty)
        XCTAssertNil(snapshot.status.defaultAccountID)
        XCTAssertFalse(fileManager.fileExists(atPath: paths.credentialStore.path))
        XCTAssertEqual(snapshot.discoveries.first?.support, .malformedAuth)
    }

    func testDisabledProviderHasNoFilesystemOrRunnerSideEffect() async throws {
        let recorder = LoginRunnerRecorder()
        let manager = try AccountManager(
            paths: paths,
            writerCheck: { _ in .inactive },
            loginRunner: recorder.runner
        )

        for providerID in [ProviderID.claudeCode, .geminiCLI, .antigravityCLI] {
            await assertOnboardingThrows(try await manager.startAccountLogin(providerID: providerID))
        }

        XCTAssertEqual(recorder.launchCount, 0)
        XCTAssertFalse(fileManager.fileExists(
            atPath: paths.applicationSupport.appending(path: "account-login").path))
        XCTAssertEqual(
            AccountManager.providerCatalog.map(\.id),
            [.codex, .grokBuild, .claudeCode, .geminiCLI, .antigravityCLI])
        XCTAssertEqual(
            AccountManager.providerCatalog.map(\.displayName),
            ["Codex CLI", "Grok Build", "Claude Code", "Gemini CLI", "Antigravity CLI"])
        XCTAssertEqual(
            AccountManager.providerCatalog.map(\.availability),
            [.enabled, .enabled, .disabled, .disabled, .disabled])
    }

    func testGrokLoginSwitchAndLaunchUseIsolatedOfficialCLIHome() async throws {
        let recorder = LoginRunnerRecorder()
        let manager = try AccountManager(
            paths: paths,
            writerCheck: { _ in .inactive },
            loginRunner: recorder.runner)

        let firstLogin = try await manager.startAccountLogin(providerID: .grokBuild)
        let firstHome = try XCTUnwrap(firstLogin.launchSpec.environment["GROK_HOME"])
        XCTAssertEqual(firstLogin.launchSpec.arguments, ["login", "--oauth"])
        XCTAssertNil(firstLogin.launchSpec.environment["XAI_API_KEY"])
        _ = try writeGrokAuth(home: URL(fileURLWithPath: firstHome), user: "first")
        let firstCheck = try await manager.checkAccountLogin(id: firstLogin.session.id)
        let first = try XCTUnwrap(firstCheck.account)

        let secondLogin = try await manager.startAccountLogin(providerID: .grokBuild)
        let secondHome = try XCTUnwrap(secondLogin.launchSpec.environment["GROK_HOME"])
        let secondAuth = try writeGrokAuth(
            home: URL(fileURLWithPath: secondHome), user: "second")
        let secondCheck = try await manager.checkAccountLogin(id: secondLogin.session.id)
        let second = try XCTUnwrap(secondCheck.account)

        var status = try await manager.status()
        XCTAssertEqual(status.accounts.map(\.identity.providerID), [.grokBuild, .grokBuild])
        XCTAssertEqual(status.defaultAccountID, first.id)

        _ = try await manager.switchDefault(to: second.id)
        status = try await manager.status()
        XCTAssertEqual(status.defaultAccountID, second.id)
        XCTAssertEqual(
            try Data(contentsOf: paths.grokHome.appending(path: "auth.json")),
            secondAuth)

        let launch = try await manager.launchSpec(accountID: second.id)
        XCTAssertEqual(launch.arguments, [])
        XCTAssertEqual(launch.environment["GROK_HOME"], paths.grokHome.path)
        XCTAssertNil(launch.environment["XAI_API_KEY"])
        let check = await manager.checkAccount(accountID: second.id)
        XCTAssertEqual(check.verification.state, .verifiedLocally)

        let crashing = try AccountManager(
            paths: paths,
            writerCheck: { _ in .inactive },
            faultInjector: {
                if $0 == .afterDefaultCredentialPublication {
                    throw AIManagerError.operationFailed("stop")
                }
            })
        await assertOnboardingThrows(try await crashing.switchDefault(to: first.id))

        let recovered = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let recoveredStatus = try await recovered.refreshAccounts().status
        XCTAssertEqual(recoveredStatus.defaultAccountID, second.id)
        XCTAssertEqual(
            try Data(contentsOf: paths.grokHome.appending(path: "auth.json")),
            secondAuth)
    }

    func testStagedLoginUsesIsolatedHomeAndImportsOnCheck() async throws {
        let recorder = LoginRunnerRecorder()
        let manager = try AccountManager(
            paths: paths,
            writerCheck: { _ in recorder.cancelCount > 0 ? .inactive : .unknown },
            loginRunner: recorder.runner
        )

        let started = try await manager.startAccountLogin(providerID: .codex)
        let stagedHome = try XCTUnwrap(started.launchSpec.environment["CODEX_HOME"])
        XCTAssertTrue(stagedHome.contains(started.session.id.uuidString))
        XCTAssertEqual(
            started.launchSpec.arguments,
            ["-c", "cli_auth_credentials_store=\"file\"", "login"])
        XCTAssertEqual(recorder.launchCount, 1)
        let sessionURL = paths.applicationSupport
            .appending(path: "account-login/\(started.session.id.uuidString)/session.json")
        let sessionObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: sessionURL)) as? [String: Any])
        XCTAssertEqual(sessionObject["version"] as? Int, 1)
        let pending = try await manager.refreshAccounts()
        XCTAssertEqual(pending.pendingLoginSessions.map(\.id), [started.session.id])

        let waiting = try await manager.checkAccountLogin(id: started.session.id)
        XCTAssertEqual(waiting.state, .waitingForLogin)

        _ = try writeAuth(home: URL(fileURLWithPath: stagedHome), account: "new", workspace: "personal")
        let completed = try await manager.checkAccountLogin(id: started.session.id)
        let account = try XCTUnwrap(completed.account)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(recorder.cancelCount, 1)
        XCTAssertEqual(account.credentialFile.lastPathComponent, "\(account.id.uuidString).json")
        let status = try await manager.status()
        XCTAssertEqual(status.defaultAccountID, account.id)
        XCTAssertEqual(
            try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")),
            try Data(contentsOf: account.credentialFile))
        let refreshed = try await manager.refreshAccounts()
        XCTAssertTrue(refreshed.pendingLoginSessions.isEmpty)
    }

    func testFirstLoginReplacesUnregisteredSameIdentityWithoutLosingNewAccess() async throws {
        let old = try writeAuth(
            home: paths.defaultHome, account: "same", workspace: "personal", marker: "old")
        let recorder = LoginRunnerRecorder()
        let manager = try AccountManager(
            paths: paths, writerCheck: { _ in .inactive }, loginRunner: recorder.runner)
        let started = try await manager.startAccountLogin(providerID: .codex)
        let stagedHome = try XCTUnwrap(started.launchSpec.environment["CODEX_HOME"])
        let new = try writeAuth(
            home: URL(fileURLWithPath: stagedHome),
            account: "same", workspace: "personal", marker: "new")

        let completed = try await manager.checkAccountLogin(id: started.session.id)
        let account = try XCTUnwrap(completed.account)

        XCTAssertNotEqual(old, new)
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), new)
        XCTAssertEqual(try Data(contentsOf: account.credentialFile), new)
        let status = try await manager.status()
        XCTAssertEqual(status.defaultAccountID, account.id)
    }

    func testRepeatedCurrentAccountLoginUsesFreshRecoveryLocations() async throws {
        _ = try writeAuth(home: paths.defaultHome, account: "repeat", workspace: "personal")
        let manager = try AccountManager(
            paths: paths, writerCheck: { _ in .inactive }, loginRunner: LoginRunnerRecorder().runner)
        let adopted = try await manager.refreshAccounts()
        let accountID = try XCTUnwrap(adopted.status.defaultAccountID)
        var expected = Data()

        for index in 1...3 {
            let started = try await manager.startAccountLogin(providerID: .codex)
            let stagedHome = try XCTUnwrap(started.launchSpec.environment["CODEX_HOME"])
            expected = try writeAuth(
                home: URL(fileURLWithPath: stagedHome),
                account: "repeat", workspace: "personal", marker: "refresh-\(index)")
            _ = try await manager.checkAccountLogin(
                id: started.session.id, credentialChoice: .useImported)
        }

        let status = try await manager.status()
        let account = try XCTUnwrap(status.accounts.first { $0.id == accountID })
        XCTAssertEqual(status.accounts.count, 1)
        XCTAssertEqual(status.defaultAccountID, accountID)
        XCTAssertEqual(try Data(contentsOf: account.credentialFile), expected)
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), expected)
    }

    func testLaunchFailureRemovesFalsePendingSession() async throws {
        let manager = try AccountManager(
            paths: paths,
            loginRunner: AccountLoginRunner(launch: { _, _ in throw LoginRunnerFailure.failed })
        )

        await assertOnboardingThrows(try await manager.startAccountLogin(providerID: .codex))

        let snapshot = try await manager.refreshAccounts(includeDiscoveries: false)
        XCTAssertTrue(snapshot.pendingLoginSessions.isEmpty)
        let entries = try fileManager.contentsOfDirectory(
            at: paths.applicationSupport.appending(path: "account-login"),
            includingPropertiesForKeys: nil)
        XCTAssertTrue(entries.isEmpty)
    }

    func testUnknownRestartedLoginIsRetiredWithoutDeletingItsHome() async throws {
        let manager = try AccountManager(
            paths: paths,
            writerCheck: { _ in .unknown },
            loginRunner: AccountLoginRunner(
                launch: { _, _ in }, cancel: { _ in false })
        )
        let started = try await manager.startAccountLogin(providerID: .codex)
        let root = paths.applicationSupport.appending(
            path: "account-login/\(started.session.id.uuidString)")

        try await manager.cancelAccountLogin(id: started.session.id)

        XCTAssertTrue(fileManager.fileExists(atPath: root.path))
        let snapshot = try await manager.refreshAccounts(includeDiscoveries: false)
        XCTAssertTrue(snapshot.pendingLoginSessions.isEmpty)
        await assertOnboardingThrows(try await manager.cancelAccountLogin(id: started.session.id))
        await assertOnboardingThrows(try await manager.checkAccountLogin(id: started.session.id))
    }

    func testRestartedCompletedLoginIgnoresUnrelatedUnknownWriter() async throws {
        let liveAuth = try writeAuth(
            home: paths.defaultHome, account: "current", workspace: "personal")
        let config = paths.defaultHome.appending(path: "config.toml")
        let configData = Data("model = \"shared\"".utf8)
        try configData.write(to: config)
        let runner = AccountLoginRunner(launch: { _, _ in }, cancel: { _ in false })
        let setup = try AccountManager(
            paths: paths, writerCheck: { _ in .inactive }, loginRunner: runner)
        let adopted = try await setup.refreshAccounts()
        let currentID = try XCTUnwrap(adopted.status.defaultAccountID)
        let started = try await setup.startAccountLogin(providerID: .codex)
        let stagedHome = try XCTUnwrap(started.launchSpec.environment["CODEX_HOME"])
        _ = try writeAuth(
            home: URL(fileURLWithPath: stagedHome), account: "added", workspace: "team")

        let restarted = try AccountManager(
            paths: paths, writerCheck: { _ in .unknown }, loginRunner: runner)
        let completed = try await restarted.checkAccountLogin(id: started.session.id)

        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.account?.identity.accountID, "account-added")
        let status = try await restarted.refreshAccounts(includeDiscoveries: false)
        XCTAssertEqual(status.status.defaultAccountID, currentID)
        XCTAssertEqual(status.status.accounts.count, 2)
        XCTAssertTrue(status.pendingLoginSessions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), liveAuth)
        XCTAssertEqual(try Data(contentsOf: config), configData)
        XCTAssertTrue(fileManager.fileExists(
            atPath: paths.applicationSupport.appending(
                path: "account-login/\(started.session.id.uuidString)/home").path))
        await assertOnboardingThrows(try await restarted.checkAccountLogin(id: started.session.id))
    }

    func testRetiredLoginIsPrunedAfterRestartOnlyWhenItsWriterIsInactive() async throws {
        let liveAuth = try writeAuth(home: paths.defaultHome, account: "kept", workspace: "personal")
        let runner = AccountLoginRunner(launch: { _, _ in }, cancel: { _ in false })
        let original = try AccountManager(paths: paths, writerCheck: { _ in .unknown }, loginRunner: runner)
        let started = try await original.startAccountLogin(providerID: .codex)
        let staging = paths.applicationSupport.appending(path: "account-login/\(started.session.id.uuidString)")
        try await original.cancelAccountLogin(id: started.session.id)

        for state in [WriterState.active, .unknown] {
            let restarted = try AccountManager(paths: paths, writerCheck: { _ in state }, loginRunner: runner)
            let snapshot = try await restarted.refreshAccounts(includeDiscoveries: false)
            XCTAssertTrue(snapshot.pendingLoginSessions.isEmpty)
            XCTAssertTrue(fileManager.fileExists(atPath: staging.path))
        }

        let stopped = try AccountManager(paths: paths, writerCheck: { _ in .inactive }, loginRunner: runner)
        let snapshot = try await stopped.refreshAccounts(includeDiscoveries: false)
        XCTAssertTrue(snapshot.pendingLoginSessions.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: staging.path))
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), liveAuth)
        await assertOnboardingThrows(try await stopped.checkAccountLogin(id: started.session.id))
        _ = try await stopped.refreshAccounts(includeDiscoveries: false)
    }

    func testRetiredLoginHomeSurvivesConflictedRecovery() async throws {
        let crashing = try AccountManager(
            paths: paths, writerCheck: { _ in .inactive }, loginRunner: .init(launch: { _, _ in }),
            faultInjector: { if $0 == .afterRegistryCommit { throw AIManagerError.operationFailed("stop") } })
        let started = try await crashing.startAccountLogin(providerID: .codex)
        let staging = paths.applicationSupport.appending(path: "account-login/\(started.session.id.uuidString)")
        _ = try writeAuth(home: staging.appending(path: "home"), account: "recover", workspace: "personal")
        await assertOnboardingThrows(try await crashing.checkAccountLogin(id: started.session.id))
        let status = try await crashing.status()
        let account = try XCTUnwrap(status.accounts.first)
        let later = try writeAuth(home: root.appending(path: "later"), account: "recover", workspace: "personal", marker: "later")
        try later.write(to: account.credentialFile)
        let sessionURL = staging.appending(path: "session.json")
        var record = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: sessionURL)) as? [String: Any])
        record["retiredAt"] = "2026-09-18T00:00:00Z"
        try JSONSerialization.data(withJSONObject: record).write(to: sessionURL)

        let restarted = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let snapshot = try await restarted.refreshAccounts(includeDiscoveries: false)
        XCTAssertEqual(snapshot.status.pendingRecovery.first?.phase, .conflicted)
        XCTAssertTrue(snapshot.pendingLoginSessions.isEmpty)
        XCTAssertTrue(fileManager.fileExists(atPath: staging.path))
        XCTAssertEqual(try Data(contentsOf: account.credentialFile), later)
    }

    func testRetiredLoginPruningRejectsARootSymlinkWithoutDeletingItsTarget() async throws {
        let original = try AccountManager(
            paths: paths, writerCheck: { _ in .unknown }, loginRunner: .init(launch: { _, _ in }))
        let started = try await original.startAccountLogin(providerID: .codex)
        let staging = paths.applicationSupport.appending(path: "account-login/\(started.session.id.uuidString)")
        try await original.cancelAccountLogin(id: started.session.id)
        let outside = root.appending(path: "outside")
        try fileManager.moveItem(at: staging, to: outside)
        try fileManager.createSymbolicLink(at: staging, withDestinationURL: outside)

        let restarted = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        await assertOnboardingThrows(try await restarted.refreshAccounts(includeDiscoveries: false))
        XCTAssertTrue(fileManager.fileExists(atPath: outside.appending(path: "session.json").path))
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: staging.path), outside.path)
    }

    func testAdditionalLoginDoesNotReplaceCurrentDefault() async throws {
        let liveAuth = try writeAuth(
            home: paths.defaultHome, account: "current", workspace: "personal")
        let recorder = LoginRunnerRecorder()
        let manager = try AccountManager(
            paths: paths,
            writerCheck: { _ in .inactive },
            loginRunner: recorder.runner
        )
        let adopted = try await manager.refreshAccounts()
        let currentID = try XCTUnwrap(adopted.status.defaultAccountID)

        let started = try await manager.startAccountLogin(providerID: .codex)
        let stagedHome = try XCTUnwrap(started.launchSpec.environment["CODEX_HOME"])
        _ = try writeAuth(
            home: URL(fileURLWithPath: stagedHome), account: "additional", workspace: "team")

        let completed = try await manager.checkAccountLogin(id: started.session.id)
        let addedID = try XCTUnwrap(completed.account?.id)
        let status = try await manager.status()

        XCTAssertNotEqual(addedID, currentID)
        XCTAssertEqual(status.defaultAccountID, currentID)
        XCTAssertEqual(status.accounts.count, 2)
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), liveAuth)
    }

    func testStagedLoginSurvivesImportCrashAndCompletesAfterRecovery() async throws {
        let recorder = LoginRunnerRecorder()
        let crashing = try AccountManager(
            paths: paths,
            writerCheck: { _ in .inactive },
            loginRunner: recorder.runner,
            faultInjector: { if $0 == .afterRegistryCommit { throw AIManagerError.operationFailed("stop") } }
        )
        let started = try await crashing.startAccountLogin(providerID: .codex)
        let stagedHome = try XCTUnwrap(started.launchSpec.environment["CODEX_HOME"])
        _ = try writeAuth(home: URL(fileURLWithPath: stagedHome), account: "crash", workspace: "personal")

        await assertOnboardingThrows(try await crashing.checkAccountLogin(id: started.session.id))

        let recovered = try AccountManager(
            paths: paths,
            writerCheck: { _ in .inactive },
            loginRunner: recorder.runner)
        let snapshot = try await recovered.refreshAccounts()
        XCTAssertEqual(snapshot.status.accounts.count, 1)
        XCTAssertTrue(snapshot.status.pendingRecovery.isEmpty)
        XCTAssertEqual(snapshot.pendingLoginSessions.map(\.id), [started.session.id])

        let completed = try await recovered.checkAccountLogin(id: started.session.id)
        XCTAssertEqual(completed.state, .completed)
        let finalStatus = try await recovered.status()
        XCTAssertTrue(finalStatus.pendingRecovery.isEmpty)
    }

    func testCancelRemovesOnlyTheOwnedLoginSession() async throws {
        let recorder = LoginRunnerRecorder()
        let manager = try AccountManager(paths: paths, loginRunner: recorder.runner)
        let started = try await manager.startAccountLogin(providerID: .codex)

        try await manager.cancelAccountLogin(id: started.session.id)

        XCTAssertEqual(recorder.cancelCount, 1)
        let refreshed = try await manager.refreshAccounts()
        XCTAssertTrue(refreshed.pendingLoginSessions.isEmpty)
    }

    func testLegacyRecoveryOperationDecodesWithoutDefaultFlag() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","kind":"import","phase":"prepared","source":"file:///tmp/source","destination":"file:///tmp/destination","backup":"file:///tmp/backup"}"#
        let operation = try JSONDecoder().decode(RecoveryOperation.self, from: Data(json.utf8))
        XCTAssertNil(operation.setsDefaultAccount)
    }

    @discardableResult
    private func writeAuth(
        home: URL,
        account: String,
        workspace: String,
        marker: String = "base"
    ) throws -> Data {
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        let claims: [String: Any] = [
            "email": "\(account)@example.test",
            "chatgpt_user_id": "user-\(account)",
            "chatgpt_account_id": "account-\(account)",
            "workspace_id": workspace,
        ]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let auth = try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "id_token": "e30.\(payload).signature",
                "access_token": "e30.\(payload).signature",
                "refresh_token": "synthetic-\(marker)",
                "account_id": "account-\(account)",
            ]
        ])
        let url = home.appending(path: "auth.json")
        try auth.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return auth
    }

    @discardableResult
    private func writeGrokAuth(home: URL, user: String) throws -> Data {
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        let auth = try JSONSerialization.data(withJSONObject: [
            "https://auth.x.ai::synthetic-client": [
                "key": "synthetic-access-\(user)",
                "auth_mode": "oidc",
                "create_time": "2026-09-20T00:00:00Z",
                "user_id": "user-\(user)",
                "email": "\(user)@example.test",
                "refresh_token": "synthetic-refresh-\(user)",
                "expires_at": "2030-01-01T00:00:00Z",
                "oidc_issuer": "https://auth.x.ai",
                "oidc_client_id": "synthetic-client",
            ]
        ], options: [.sortedKeys])
        let url = home.appending(path: "auth.json")
        try auth.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return auth
    }
}

private enum LoginRunnerFailure: Error {
    case failed
}

private func assertOnboardingThrows<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}

private final class LoginRunnerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var launches = 0
    private var cancels = 0

    var launchCount: Int { lock.withLock { launches } }
    var cancelCount: Int { lock.withLock { cancels } }

    var runner: AccountLoginRunner {
        AccountLoginRunner(
            launch: { [self] _, _ in lock.withLock { launches += 1 } },
            cancel: { [self] _ in lock.withLock { cancels += 1 }; return true }
        )
    }
}
