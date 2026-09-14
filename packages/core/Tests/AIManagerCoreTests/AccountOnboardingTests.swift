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

        let second = try await manager.refreshAccounts()
        XCTAssertEqual(second.status.accounts.count, 1)
        XCTAssertEqual(second.status.accounts.first?.id, account.id)
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
            [.codex, .claudeCode, .geminiCLI, .antigravityCLI])
        XCTAssertEqual(AccountManager.providerCatalog.map(\.availability), [.enabled, .disabled, .disabled, .disabled])
    }

    func testStagedLoginUsesIsolatedHomeAndImportsOnCheck() async throws {
        let recorder = LoginRunnerRecorder()
        let manager = try AccountManager(
            paths: paths,
            writerCheck: { _ in .inactive },
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
        XCTAssertEqual(account.credentialFile.lastPathComponent, "\(account.id.uuidString).json")
        let status = try await manager.status()
        XCTAssertNil(status.defaultAccountID)
        let refreshed = try await manager.refreshAccounts()
        XCTAssertTrue(refreshed.pendingLoginSessions.isEmpty)
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
    private func writeAuth(home: URL, account: String, workspace: String) throws -> Data {
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
                "refresh_token": "synthetic",
                "account_id": "account-\(account)",
            ]
        ])
        let url = home.appending(path: "auth.json")
        try auth.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return auth
    }
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
            cancel: { [self] _ in lock.withLock { cancels += 1 } }
        )
    }
}
