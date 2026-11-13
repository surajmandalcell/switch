import Foundation
import XCTest
@testable import AIManagerCore

final class DeletedAccountUsageHistoryTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appending(path: "DeletedAccountUsageHistoryTests-\(UUID().uuidString)")
        paths = .init(applicationSupport: root.appending(path: "support"),
                      credentialStore: root.appending(path: "user/.switch/codex"),
                      defaultHome: root.appending(path: "user/.codex"),
                      sharedRoot: root.appending(path: "user/.codex"),
                      orcaAccountsRoot: root.appending(path: "orca"), isolationRoot: root)
    }

    override func tearDownWithError() throws { if let root { try? fileManager.removeItem(at: root) } }

    private func cache() throws -> CodexUsageStatisticsCache {
        try .init(databaseURL: paths.applicationSupport.appending(path: "cache/account-usage.sqlite"),
                  activityDatabaseURL: paths.applicationSupport.appending(path: "activity/daily.sqlite"))
    }

    private func usage(_ value: Double, fetchedAt: Date = Date()) -> ProviderUsage {
        .init(plan: "private-plan-must-not-be-retained", email: "private@example.test",
              fetchedAt: fetchedAt,
              charts: [.init(id: "daily", title: "private-chart-label", unit: "tokens",
                             points: [.init(label: "private-point-label", date: Date(), value: value)])])
    }

    private func manager() throws -> AccountManager {
        let result = usage(123)
        let spec = ProviderSpec(id: "test-history", name: "History", style: .secret,
                                fields: [.apiKey("TEST_HISTORY_KEY")], fetch: { _ in FetchResult(result) })
        return try .init(paths: paths, writerCheck: { _ in .inactive }, providerSpecs: [spec])
    }

    func testProviderNumericHistorySurvivesAccountDeletionAndRestart() async throws {
        let manager = try manager()
        let account = try await manager.addProviderAccount(providerID: ProviderID(rawValue: "test-history"),
                                                          fields: ["apiKey": "synthetic-private-key"])
        _ = try await manager.readProviderUsage(accountID: account.id)
        _ = try await manager.deleteAccount(accountID: account.id)
        let status = try await manager.status()
        XCTAssertTrue(status.accounts.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: account.credentialFile.path))
        let ledger = try cache()
        let snapshot = await UsageHistory(sources: .init(ledger: ledger)).snapshot()
        XCTAssertEqual(snapshot.summary(period: .week, grouping: .account).totals.tokens, 123)
        XCTAssertEqual(snapshot.summary(period: .week, grouping: .account).groups.first?.key,
                       account.id.uuidString.lowercased())
        try await ledger.purgeAll()
        let reopened = try cache()
        let restarted = await UsageHistory(sources: .init(ledger: reopened)).snapshot()
        XCTAssertEqual(restarted.summary(period: .week, grouping: .account).totals.tokens, 123)
        let database = try Data(contentsOf: paths.applicationSupport.appending(path: "activity/daily.sqlite"))
        for excluded in ["synthetic-private-key", "private@example.test", "private-plan-must-not-be-retained",
                         "private-chart-label", "private-point-label"] {
            XCTAssertNil(database.range(of: Data(excluded.utf8)), excluded)
        }
    }

    func testLegacyProviderCacheMigrationCannotReplaceNewerHistory() async throws {
        let manager = try manager()
        let account = try await manager.addProviderAccount(providerID: ProviderID(rawValue: "test-history"), fields: ["apiKey": "synthetic-key"])
        _ = try await manager.readProviderUsage(accountID: account.id)
        struct Legacy: Encodable { let version = 1; let usage: [String: ProviderUsage] }
        let legacy = Legacy(usage: [account.id.uuidString: usage(999, fetchedAt: Date().addingTimeInterval(-3600))])
        try JSONEncoder().encode(legacy).write(to: paths.applicationSupport.appending(path: "provider-usage-cache.json"))
        _ = try await manager.deleteAccount(accountID: account.id)
        let ledger = try cache()
        let snapshot = await UsageHistory(sources: .init(ledger: ledger)).snapshot()
        XCTAssertEqual(snapshot.summary(period: .week, grouping: .account).totals.tokens, 123)
    }

    func testDeletionStopsBeforeCredentialRemovalWhenHistoryCannotBeSaved() async throws {
        let manager = try manager()
        let account = try await manager.addProviderAccount(providerID: ProviderID(rawValue: "test-history"), fields: ["apiKey": "synthetic-key"])
        let database = paths.applicationSupport.appending(path: "activity/daily.sqlite")
        try fileManager.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid-history-database".utf8).write(to: database)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path)
        do {
            _ = try await manager.deleteAccount(accountID: account.id)
            XCTFail("Deletion must stop when history cannot be retained")
        } catch {
            let status = try await manager.status()
            XCTAssertEqual(status.accounts.map(\.id), [account.id])
            XCTAssertTrue(fileManager.fileExists(atPath: account.credentialFile.path))
            XCTAssertEqual(try Data(contentsOf: database), Data("invalid-history-database".utf8))
        }
    }
}
