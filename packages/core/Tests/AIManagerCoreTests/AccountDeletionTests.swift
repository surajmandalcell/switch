import Foundation
import XCTest
@testable import AIManagerCore

final class AccountDeletionTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appending(
            path: "AccountDeletionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
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

    func testDeletesOnlyManagedHomeVaultAndRegistryRecord() async throws {
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let source = root.appending(path: "source", directoryHint: .isDirectory)
        let shared = paths.sharedRoot.appending(path: "config.toml")
        try privateDirectory(source)
        try privateWrite(authData(account: "one"), to: source.appending(path: "auth.json"))
        try Data("shared".utf8).write(to: shared)
        let plan = try await manager.planImport(source: source, mode: .authOnly)
        let account = try await manager.importAccount(plan: plan).account

        let result = try await manager.deleteAccount(accountID: account.id)

        XCTAssertEqual(result.accountID, account.id)
        XCTAssertTrue(result.removedManagedHome)
        XCTAssertTrue(result.removedCredential)
        XCTAssertFalse(CoreSupport.entryExists(account.home))
        XCTAssertFalse(CoreSupport.entryExists(account.credentialFile))
        XCTAssertTrue(CoreSupport.entryExists(source))
        XCTAssertEqual(try Data(contentsOf: shared), Data("shared".utf8))
        let status = try await manager.status()
        XCTAssertTrue(status.accounts.isEmpty)
    }

    func testDefaultDeletionRequiresExplicitReplacement() async throws {
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let first = try await importAccount("first", manager: manager)
        let second = try await importAccount("second", manager: manager)
        _ = try await manager.switchDefault(to: first.id)

        await XCTAssertThrowsDeletionError(
            try await manager.deleteAccount(accountID: first.id)
        ) { error in
            XCTAssertEqual(error as? AIManagerError, .defaultAccountReplacementRequired)
        }

        let status = try await manager.status()
        XCTAssertEqual(status.defaultAccountID, first.id)
        XCTAssertEqual(Set(status.accounts.map(\.id)), [first.id, second.id])
        XCTAssertTrue(CoreSupport.entryExists(first.home))
        XCTAssertTrue(CoreSupport.entryExists(first.credentialFile))
    }

    func testDefaultDeletionActivatesExplicitReplacementThenDeletes() async throws {
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let first = try await importAccount("first", manager: manager)
        let second = try await importAccount("second", manager: manager)
        _ = try await manager.switchDefault(to: first.id)

        let result = try await manager.deleteAccount(
            accountID: first.id,
            replacementDefaultAccountID: second.id
        )

        XCTAssertEqual(result.replacementDefaultAccountID, second.id)
        let status = try await manager.status()
        XCTAssertEqual(status.defaultAccountID, second.id)
        XCTAssertEqual(status.accounts.map(\.id), [second.id])
        XCTAssertEqual(
            try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")),
            try Data(contentsOf: second.credentialFile)
        )
        XCTAssertFalse(CoreSupport.entryExists(first.home))
        XCTAssertFalse(CoreSupport.entryExists(first.credentialFile))
    }

    func testInterruptedDeletionFinishesAfterRegistryCommit() async throws {
        let setup = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let account = try await importAccount("delete", manager: setup)
        let crashing = try AccountManager(
            paths: paths,
            writerCheck: { _ in .inactive },
            faultInjector: { point in
                if point == .afterRegistryCommit {
                    throw AIManagerError.operationFailed("injected interruption")
                }
            }
        )

        await XCTAssertThrowsDeletionError(
            try await crashing.deleteAccount(accountID: account.id)
        )

        XCTAssertTrue(CoreSupport.entryExists(account.home))
        XCTAssertTrue(CoreSupport.entryExists(account.credentialFile))
        let recovering = try AccountManager(paths: paths, writerCheck: { _ in .unknown })
        let recovered = try await recovering.recover()
        XCTAssertEqual(recovered.first?.outcome, .completed)
        XCTAssertFalse(CoreSupport.entryExists(account.home))
        XCTAssertFalse(CoreSupport.entryExists(account.credentialFile))
        let status = try await recovering.status()
        XCTAssertTrue(status.accounts.isEmpty)
    }

    func testAccountOrderSurvivesReopenActivationAppendAndDeletion() async throws {
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let first = try await importAccount("first", manager: manager)
        let second = try await importAccount("second", manager: manager)
        _ = try await manager.switchDefault(to: first.id)
        let auth = try Data(contentsOf: paths.defaultHome.appending(path: "auth.json"))
        let reordered = try await manager.reorderAccounts([second.id, first.id])
        XCTAssertEqual(reordered.accounts.map(\.id), [second.id, first.id])
        XCTAssertEqual(reordered.defaultAccountID, first.id)
        XCTAssertEqual(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")), auth)

        let registry = paths.applicationSupport.appending(path: "accounts.json")
        let inode = try fileManager.attributesOfItem(atPath: registry.path)[.systemFileNumber] as? NSNumber
        _ = try await manager.reorderAccounts([second.id, first.id])
        XCTAssertEqual(try fileManager.attributesOfItem(atPath: registry.path)[.systemFileNumber] as? NSNumber, inode)
        let reopened = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let saved = try await reopened.status()
        XCTAssertEqual(saved.accounts.map(\.id), [second.id, first.id])
        let third = try await importAccount("third", manager: reopened)
        _ = try await reopened.switchDefault(to: third.id)
        let appended = try await reopened.status()
        XCTAssertEqual(appended.accounts.map(\.id), [second.id, first.id, third.id])
        _ = try await reopened.deleteAccount(accountID: first.id)
        let remaining = try await reopened.status()
        XCTAssertEqual(remaining.accounts.map(\.id), [second.id, third.id])
    }

    func testAccountOrderRejectsStaleDuplicateAndForeignIDs() async throws {
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let first = try await importAccount("first", manager: manager)
        let second = try await importAccount("second", manager: manager)
        for invalid in [[first.id], [first.id, first.id], [first.id, UUID()]] {
            await XCTAssertThrowsDeletionError(try await manager.reorderAccounts(invalid)) { error in
                XCTAssertEqual(error as? AIManagerError, .sourceChanged)
            }
        }
        let unchanged = try await manager.status()
        XCTAssertEqual(unchanged.accounts.map(\.id), [first.id, second.id])
    }

    private func importAccount(_ name: String, manager: AccountManager) async throws -> AccountRecord {
        let source = root.appending(path: "source-\(name)", directoryHint: .isDirectory)
        try privateDirectory(source)
        try privateWrite(authData(account: name), to: source.appending(path: "auth.json"))
        let plan = try await manager.planImport(source: source, mode: .authOnly)
        return try await manager.importAccount(plan: plan).account
    }

    private func authData(account: String) throws -> Data {
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
                "access_token": "synthetic-access",
                "refresh_token": "synthetic-refresh",
                "account_id": "account-\(account)",
            ],
        ], options: [.sortedKeys])
    }

    private func privateDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func privateWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private func XCTAssertThrowsDeletionError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
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
