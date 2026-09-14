import Foundation
import XCTest
@testable import AIManagerCore

final class AccountManagerUsageCoordinatorTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appending(
            path: "AccountManagerUsageCoordinatorTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        paths = .init(
            applicationSupport: root.appending(path: "support", directoryHint: .isDirectory),
            credentialStore: root.appending(path: "user/.switch/codex", directoryHint: .isDirectory),
            defaultHome: root.appending(path: "user/.codex", directoryHint: .isDirectory),
            sharedRoot: root.appending(path: "user/.codex", directoryHint: .isDirectory),
            orcaAccountsRoot: root.appending(path: "orca", directoryHint: .isDirectory),
            codexExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            isolationRoot: root
        )
        try privateDirectory(paths.defaultHome)
    }

    override func tearDownWithError() throws {
        if let root { try? fileManager.removeItem(at: root) }
    }

    func testUnchangedCredentialDoesNotMutateVaultRegistryOrBackups() async throws {
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let account = try await importAndSelect("primary", manager: manager)
        let savedBefore = try Data(contentsOf: account.credentialFile)
        let registryURL = paths.applicationSupport.appending(path: "accounts.json")
        let registryBefore = try Data(contentsOf: registryURL)
        let backupsBefore = backupNames()
        let transport = UsageTransport()

        _ = try await manager.readCodexAccountUsage(
            accountID: account.id,
            reader: .init(transport: transport, environment: { [:] }),
            limits: .init(timeout: 1, maximumOutputBytes: 4_096, maximumLineBytes: 2_048)
        )

        XCTAssertTrue(transport.wasInvoked)
        let source = try XCTUnwrap(transport.capturedSource)
        XCTAssertNotEqual(source.codexHome, paths.defaultHome)
        XCTAssertTrue(CoreSupport.isContained(source.codexHome, by: usageReadsRoot))
        XCTAssertEqual(transport.capturedAuth, savedBefore)
        XCTAssertEqual(try Data(contentsOf: account.credentialFile), savedBefore)
        XCTAssertEqual(try Data(contentsOf: registryURL), registryBefore)
        XCTAssertEqual(backupNames(), backupsBefore)
        XCTAssertTrue(usageReadNames().isEmpty)
    }

    func testIsolatedTokenRotationDoesNotMutateLiveVaultOrRegistry() async throws {
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let account = try await importAndSelect("primary", manager: manager)
        let savedBefore = try Data(contentsOf: account.credentialFile)
        let liveBefore = try Data(contentsOf: paths.defaultHome.appending(path: "auth.json"))
        let registryURL = paths.applicationSupport.appending(path: "accounts.json")
        let registryBefore = try Data(contentsOf: registryURL)
        let rotated = try authData(account: "primary", marker: "rotated")
        let transport = UsageTransport(rotation: rotated)

        _ = try await manager.readCodexAccountUsage(
            accountID: account.id,
            reader: .init(transport: transport, environment: { [:] })
        )

        XCTAssertEqual(try Data(contentsOf: account.credentialFile), savedBefore)
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), liveBefore)
        XCTAssertEqual(try Data(contentsOf: registryURL), registryBefore)
        XCTAssertTrue(usageReadNames().isEmpty)
    }

    func testLegacyUsageCredentialRefreshJournalCompletesSafely() async throws {
        let setup = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let account = try await importAndSelect("primary", manager: setup)
        let previous = try Data(contentsOf: account.credentialFile)
        let rotated = try authData(account: "primary", marker: "legacy-rotated")
        let liveAuth = paths.defaultHome.appending(path: "auth.json")
        try CoreSupport.atomicWrite(rotated, to: liveAuth, fileManager: fileManager)

        let operationID = UUID()
        let operation = RecoveryOperation(
            id: operationID,
            kind: "usage-credential-refresh",
            phase: .published,
            source: liveAuth,
            destination: account.credentialFile,
            backup: paths.applicationSupport.appending(
                path: "backups/\(operationID.uuidString)", directoryHint: .isDirectory),
            expectedDigest: CoreSupport.digest(rotated),
            previousDigest: CoreSupport.digest(previous),
            registryAccountID: account.id,
            previousDefaultAccountID: account.id,
            registryCredentialDigest: CoreSupport.digest(rotated),
            previousAccount: account
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try CoreSupport.atomicWrite(
            try encoder.encode(operation),
            to: paths.applicationSupport.appending(
                path: "transactions/\(operationID.uuidString).json"),
            fileManager: fileManager
        )

        let recovering = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let results = try await recovering.recover()

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.operationID, operationID)
        XCTAssertEqual(results.first?.outcome, .completed)
        XCTAssertEqual(try Data(contentsOf: liveAuth), rotated)
        XCTAssertEqual(try Data(contentsOf: account.credentialFile), rotated)
        let status = try await recovering.status()
        XCTAssertEqual(
            status.accounts.first { $0.id == account.id }?.credentialDigest,
            CoreSupport.digest(rotated)
        )
        XCTAssertTrue(status.pendingRecovery.isEmpty)
    }

    func testInactiveAccountIsRejectedBeforeTransport() async throws {
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let active = try await importAndSelect("active", manager: manager)
        let inactive = try await importAccount("inactive", manager: manager)
        let status = try await manager.status()
        XCTAssertEqual(status.defaultAccountID, active.id)
        let transport = UsageTransport()

        await XCTAssertThrowsUsageError(
            try await manager.readCodexAccountUsage(
                accountID: inactive.id,
                reader: .init(transport: transport, environment: { [:] })
            )
        ) { error in
            XCTAssertEqual(
                error as? AIManagerError,
                .operationFailed("Use this account before refreshing usage."))
        }
        XCTAssertFalse(transport.wasInvoked)
    }

    func testActiveCodexWriterStillReadsFromIsolatedHome() async throws {
        let setup = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let account = try await importAndSelect("primary", manager: setup)
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .active })
        let transport = UsageTransport()

        _ = try await manager.readCodexAccountUsage(
            accountID: account.id,
            reader: .init(transport: transport, environment: { [:] })
        )

        XCTAssertTrue(transport.wasInvoked)
        XCTAssertNotEqual(transport.capturedSource?.codexHome, paths.defaultHome)
        XCTAssertTrue(usageReadNames().isEmpty)
    }

    func testSwitchCanProceedWhileUsageTransportIsSuspendedAndStaleReadFailsClosed() async throws {
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let active = try await importAndSelect("active", manager: manager)
        let inactive = try await importAccount("inactive", manager: manager)
        let transport = SuspendingUsageTransport()
        let read = Task {
            try await manager.readCodexAccountUsage(
                accountID: active.id,
                reader: .init(transport: transport, environment: { [:] })
            )
        }
        await transport.waitUntilStarted()

        _ = try await manager.switchDefault(to: inactive.id)
        await transport.resume()

        await XCTAssertThrowsUsageError(try await read.value) { error in
            XCTAssertEqual(error as? AIManagerError, .sourceChanged)
        }
        XCTAssertTrue(usageReadNames().isEmpty)
    }

    func testAccountImportCanProceedWhileUsageTransportIsSuspended() async throws {
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let active = try await importAndSelect("active", manager: manager)
        let source = root.appending(path: "source-added", directoryHint: .isDirectory)
        try privateDirectory(source)
        try privateWrite(
            try authData(account: "added", marker: "initial"),
            to: source.appending(path: "auth.json")
        )
        let plan = try await manager.planImport(source: source, mode: .authOnly)
        let transport = SuspendingUsageTransport()
        let read = Task {
            try await manager.readCodexAccountUsage(
                accountID: active.id,
                reader: .init(transport: transport, environment: { [:] })
            )
        }
        await transport.waitUntilStarted()

        let added = try await manager.importAccount(plan: plan).account
        await transport.resume()

        _ = try await read.value
        XCTAssertEqual(added.identity.email, "added@example.test")
        XCTAssertTrue(usageReadNames().isEmpty)
    }

    func testLiveCredentialChangeDuringReadFailsClosedAndCleansTemporaryHome() async throws {
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let account = try await importAndSelect("primary", manager: manager)
        let transport = SuspendingUsageTransport()
        let read = Task {
            try await manager.readCodexAccountUsage(
                accountID: account.id,
                reader: .init(transport: transport, environment: { [:] })
            )
        }
        await transport.waitUntilStarted()
        try privateWrite(
            try authData(account: "primary", marker: "changed-live"),
            to: paths.defaultHome.appending(path: "auth.json")
        )
        await transport.resume()

        await XCTAssertThrowsUsageError(try await read.value) { error in
            XCTAssertEqual(error as? AIManagerError, .sourceChanged)
        }
        XCTAssertTrue(usageReadNames().isEmpty)
    }

    func testVaultCredentialChangeDuringReadFailsClosedAndCleansTemporaryHome() async throws {
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let account = try await importAndSelect("primary", manager: manager)
        let transport = SuspendingUsageTransport()
        let read = Task {
            try await manager.readCodexAccountUsage(
                accountID: account.id,
                reader: .init(transport: transport, environment: { [:] })
            )
        }
        await transport.waitUntilStarted()
        try privateWrite(
            try authData(account: "primary", marker: "changed-vault"),
            to: account.credentialFile
        )
        await transport.resume()

        await XCTAssertThrowsUsageError(try await read.value) { error in
            XCTAssertEqual(error as? AIManagerError, .sourceChanged)
        }
        XCTAssertTrue(usageReadNames().isEmpty)
    }

    func testTransportFailureCleansTemporaryHome() async throws {
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let account = try await importAndSelect("primary", manager: manager)

        await XCTAssertThrowsUsageError(
            try await manager.readCodexAccountUsage(
                accountID: account.id,
                reader: .init(transport: FailingUsageTransport(), environment: { [:] })
            )
        ) { error in
            XCTAssertEqual(error as? InjectedUsageFailure, .read)
        }
        XCTAssertTrue(usageReadNames().isEmpty)
    }

    private func importAndSelect(_ name: String, manager: AccountManager) async throws -> AccountRecord {
        let account = try await importAccount(name, manager: manager)
        _ = try await manager.switchDefault(to: account.id)
        return account
    }

    private func importAccount(_ name: String, manager: AccountManager) async throws -> AccountRecord {
        let source = root.appending(path: "source-\(name)", directoryHint: .isDirectory)
        try privateDirectory(source)
        try privateWrite(try authData(account: name, marker: "initial"), to: source.appending(path: "auth.json"))
        let plan = try await manager.planImport(source: source, mode: .authOnly)
        return try await manager.importAccount(plan: plan).account
    }

    private func authData(account: String, marker: String) throws -> Data {
        let claims = try JSONSerialization.data(withJSONObject: [
            "email": "\(account)@example.test",
            "chatgpt_user_id": "user-\(account)",
            "chatgpt_account_id": "account-\(account)",
            "workspace_id": "workspace-\(account)",
        ])
        let payload = claims.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "id_token": "header.\(payload).signature",
                "access_token": "synthetic-access-\(marker)",
                "refresh_token": "synthetic-refresh-\(marker)",
                "account_id": "account-\(account)",
            ],
        ], options: [.sortedKeys])
    }

    private func privateDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func privateWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func backupNames() -> Set<String> {
        let root = paths.applicationSupport.appending(path: "backups", directoryHint: .isDirectory)
        let entries = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return Set(entries.map(\.lastPathComponent))
    }

    private var usageReadsRoot: URL {
        paths.applicationSupport.appending(path: "usage-reads", directoryHint: .isDirectory)
    }

    private func usageReadNames() -> Set<String> {
        let entries = (try? fileManager.contentsOfDirectory(
            at: usageReadsRoot, includingPropertiesForKeys: nil)) ?? []
        return Set(entries.map(\.lastPathComponent))
    }
}

private enum InjectedUsageFailure: Error, Equatable {
    case read
}

private final class UsageTransport: CodexAppServerRPCTransport, @unchecked Sendable {
    private let rotation: Data?
    private let lock = NSLock()
    private var invoked = false
    private var source: CodexAppServerSource?
    private var auth: Data?

    init(rotation: Data? = nil) {
        self.rotation = rotation
    }

    var wasInvoked: Bool { lock.withLock { invoked } }
    var capturedSource: CodexAppServerSource? { lock.withLock { source } }
    var capturedAuth: Data? { lock.withLock { auth } }

    func performAccountRead(
        launch: CodexAppServerLaunch,
        limits: CodexAppServerLimits
    ) async throws -> [Data] {
        lock.withLock {
            invoked = true
            source = launch.source
            auth = try? Data(contentsOf: launch.source.authFile)
        }
        if let rotation {
            try CoreSupport.atomicWrite(rotation, to: launch.source.authFile, fileManager: .default)
        }
        return [
            response(id: 2, result: ["requiresOpenaiAuth": false]),
            response(id: 3, result: [:]),
            response(id: 4, result: [:]),
        ]
    }

    private func response(id: Int, result: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["id": id, "result": result], options: [.sortedKeys])
    }
}

private final class SuspendingUsageTransport: CodexAppServerRPCTransport, @unchecked Sendable {
    private let gate = UsageTransportGate()

    func waitUntilStarted() async {
        await gate.waitUntilStarted()
    }

    func resume() async {
        await gate.resume()
    }

    func performAccountRead(
        launch: CodexAppServerLaunch,
        limits: CodexAppServerLimits
    ) async throws -> [Data] {
        await gate.suspend()
        return usageResponses()
    }
}

private actor UsageTransportGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var readContinuation: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func suspend() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { readContinuation = $0 }
    }

    func resume() {
        readContinuation?.resume()
        readContinuation = nil
    }
}

private struct FailingUsageTransport: CodexAppServerRPCTransport {
    func performAccountRead(
        launch: CodexAppServerLaunch,
        limits: CodexAppServerLimits
    ) async throws -> [Data] {
        throw InjectedUsageFailure.read
    }
}

private func usageResponses() -> [Data] {
    [2, 3, 4].map { id in
        try! JSONSerialization.data(
            withJSONObject: [
                "id": id,
                "result": id == 2 ? ["requiresOpenaiAuth": false] : [:],
            ],
            options: [.sortedKeys]
        )
    }
}

private func XCTAssertThrowsUsageError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {
        handler(error)
    }
}
