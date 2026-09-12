import Foundation
import XCTest
@testable import AIManagerCore

final class SettingsLinkContractTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appending(path: "ai-manager-link-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        paths = .init(
            applicationSupport: root.appending(path: "support"),
            defaultHome: root.appending(path: "default"),
            sharedRoot: root.appending(path: "shared"),
            orcaAccountsRoot: root.appending(path: "orca"),
            codexExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            isolationRoot: root
        )
        try fileManager.createDirectory(at: paths.sharedRoot, withIntermediateDirectories: true)
        try Data("shared setting".utf8).write(to: paths.sharedRoot.appending(path: "config.toml"))
    }

    override func tearDownWithError() throws {
        if let root { try? fileManager.removeItem(at: root) }
    }

    func testRepairPreservesLocalEditAndRestoresReviewedLink() async throws {
        let (manager, account) = try await importedAccount(writer: { _ in .inactive })
        let local = account.home.appending(path: "config.toml")
        try fileManager.removeItem(at: local)
        let localEdit = Data("local editor replacement".utf8)
        try localEdit.write(to: local)

        let status = try await manager.status()
        let issue = try XCTUnwrap(status.linkedSettingsDivergences.first)
        XCTAssertEqual(issue.accountID, account.id)
        do {
            _ = try await manager.launchSpec(accountID: account.id)
            XCTFail("Expected launch to refuse divergent shared settings")
        } catch {}

        let repaired = try await manager.repairLinkedSetting(
            accountID: account.id,
            relativePath: issue.relativePath,
            reviewedFingerprint: issue.localFingerprint
        )
        XCTAssertEqual(try Data(contentsOf: repaired.backup.appending(path: "\(account.id.uuidString)/config.toml")), localEdit)
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: local.path), paths.sharedRoot.appending(path: "config.toml").path)
        let repairedStatus = try await manager.status()
        XCTAssertTrue(repairedStatus.linkedSettingsDivergences.isEmpty)
        _ = try await manager.launchSpec(accountID: account.id)
    }

    func testFilesystemAliasToSharedSettingIsNotDivergent() async throws {
        try fileManager.removeItem(at: root)
        root = URL(fileURLWithPath: "/private/tmp/ai-manager-link-tests-\(UUID().uuidString)", isDirectory: true)
        paths = .init(
            applicationSupport: root.appending(path: "support"),
            defaultHome: root.appending(path: "default"),
            sharedRoot: root.appending(path: "shared"),
            orcaAccountsRoot: root.appending(path: "orca"),
            codexExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            isolationRoot: root
        )
        try fileManager.createDirectory(at: paths.sharedRoot, withIntermediateDirectories: true)
        try Data("shared setting".utf8).write(to: paths.sharedRoot.appending(path: "config.toml"))
        try fileManager.createDirectory(at: paths.sharedRoot.appending(path: "rules"), withIntermediateDirectories: false)
        let (manager, account) = try await importedAccount(writer: { _ in .inactive })
        let local = account.home.appending(path: "rules")
        try fileManager.removeItem(at: local)
        let aliasTarget = URL(fileURLWithPath: paths.sharedRoot.appending(path: "rules").path.replacingOccurrences(
            of: "/private/tmp/",
            with: "/tmp/"
        ))
        try fileManager.createSymbolicLink(at: local, withDestinationURL: aliasTarget)

        let status = try await manager.status()
        XCTAssertTrue(status.linkedSettingsDivergences.isEmpty)
        _ = try await manager.launchSpec(accountID: account.id)
    }

    func testRepairRejectsAnEditMadeAfterReview() async throws {
        let (manager, account) = try await importedAccount(writer: { _ in .inactive })
        let local = account.home.appending(path: "config.toml")
        try fileManager.removeItem(at: local)
        try Data("first local edit".utf8).write(to: local)
        let reviewedStatus = try await manager.status()
        let issue = try XCTUnwrap(reviewedStatus.linkedSettingsDivergences.first)
        let laterEdit = Data("later local edit".utf8)
        try laterEdit.write(to: local)

        do {
            _ = try await manager.repairLinkedSetting(accountID: account.id, relativePath: issue.relativePath, reviewedFingerprint: issue.localFingerprint)
            XCTFail("Expected the changed local entry to invalidate review")
        } catch {
            XCTAssertEqual(error as? AIManagerError, .sourceChanged)
        }
        XCTAssertEqual(try Data(contentsOf: local), laterEdit)
    }

    func testRepairRefusesAnActiveWriter() async throws {
        let (setup, account) = try await importedAccount(writer: { _ in .inactive })
        let local = account.home.appending(path: "config.toml")
        try fileManager.removeItem(at: local)
        let localEdit = Data("active local edit".utf8)
        try localEdit.write(to: local)
        let reviewedStatus = try await setup.status()
        let issue = try XCTUnwrap(reviewedStatus.linkedSettingsDivergences.first)
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .active })

        do {
            _ = try await manager.repairLinkedSetting(accountID: account.id, relativePath: issue.relativePath, reviewedFingerprint: issue.localFingerprint)
            XCTFail("Expected an active writer to block repair")
        } catch {
            XCTAssertEqual(error as? AIManagerError, .activeCodexProcesses)
        }
        XCTAssertEqual(try Data(contentsOf: local), localEdit)
    }

    func testRepairPreservesABrokenRelativeLinkInBackup() async throws {
        let (manager, account) = try await importedAccount(writer: { _ in .inactive })
        let local = account.home.appending(path: "config.toml")
        try fileManager.removeItem(at: local)
        try fileManager.createSymbolicLink(atPath: local.path, withDestinationPath: "../missing-local-setting")
        let reviewedStatus = try await manager.status()
        let issue = try XCTUnwrap(reviewedStatus.linkedSettingsDivergences.first)

        let repaired = try await manager.repairLinkedSetting(
            accountID: account.id,
            relativePath: issue.relativePath,
            reviewedFingerprint: issue.localFingerprint
        )
        let preserved = repaired.backup.appending(path: "\(account.id.uuidString)/config.toml")
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: preserved.path), "../missing-local-setting")
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: local.path), paths.sharedRoot.appending(path: "config.toml").path)
    }

    func testRecoveryRestoresLocalEditAfterInterruptedLinkPublication() async throws {
        let (setup, account) = try await importedAccount(writer: { _ in .inactive })
        let local = account.home.appending(path: "config.toml")
        try fileManager.removeItem(at: local)
        let localEdit = Data("recoverable local edit".utf8)
        try localEdit.write(to: local)
        let reviewedStatus = try await setup.status()
        let issue = try XCTUnwrap(reviewedStatus.linkedSettingsDivergences.first)
        let crashing = try AccountManager(paths: paths, writerCheck: { _ in .inactive }, faultInjector: { point in
            if point == .afterHomePublication { throw AIManagerError.operationFailed("synthetic interruption") }
        })

        do {
            _ = try await crashing.repairLinkedSetting(accountID: account.id, relativePath: issue.relativePath, reviewedFingerprint: issue.localFingerprint)
            XCTFail("Expected a synthetic interruption")
        } catch {}
        let recovering = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        _ = try await recovering.recover()
        XCTAssertEqual(try Data(contentsOf: local), localEdit)
    }

    private func importedAccount(writer: @escaping AccountManager.WriterCheck) async throws -> (AccountManager, AccountRecord) {
        let source = root.appending(path: "source")
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try syntheticAuth().write(to: source.appending(path: "auth.json"), options: .atomic)
        let manager = try AccountManager(paths: paths, writerCheck: writer)
        let plan = try await manager.planImport(source: source, mode: .authOnly)
        let result = try await manager.importAccount(plan: plan)
        return (manager, result.account)
    }

    private func syntheticAuth() throws -> Data {
        let claims = try JSONSerialization.data(withJSONObject: ["email": "link@example.test", "chatgpt_user_id": "link-user", "chatgpt_account_id": "link-account", "workspace_id": "link-workspace"])
        let payload = claims.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return try JSONSerialization.data(withJSONObject: [
            "tokens": ["access_token": "synthetic.\(payload).signature", "account_id": "link-account", "refresh_token": "synthetic"]
        ])
    }
}
