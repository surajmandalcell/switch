import Foundation
import XCTest
@testable import AIManagerCore

final class UsageHistoryRetentionTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default
    private let accountA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let accountB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    private let now = Date(timeIntervalSince1970: 1_773_144_000)

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appending(path: "UsageHistoryRetentionTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { if let root { try? fileManager.removeItem(at: root) } }

    private func ledger() throws -> CodexUsageStatisticsCache {
        try .init(databaseURL: root.appending(path: "cache/usage.sqlite"),
                  activityDatabaseURL: root.appending(path: "activity/daily.sqlite"))
    }

    private func charts(_ tokens: Double, cost: Double) -> [ProviderChartSource] {
        [("tokens", tokens), ("USD", cost)].map { unit, value in
            .init(service: "openrouter", accountID: accountA.uuidString.lowercased(),
                  chart: .init(id: unit, title: "Private display title", unit: unit,
                               points: [.init(label: "Private display label", date: now, value: value)]))
        }
    }

    func testArchivedChartsReplaceCorrectionsAndNeverDoubleCountLiveOrStaleValues() async throws {
        let cache = try ledger()
        let old = charts(100, cost: 4)
        try await cache.retainHistoryPoints(UsageHistory.retainedChartPoints(old, fetchedAt: now))
        let correction = charts(25, cost: 1)
        try await cache.retainHistoryPoints(UsageHistory.retainedChartPoints(correction, fetchedAt: now.addingTimeInterval(1)))
        try await cache.retainHistoryPoints(UsageHistory.retainedChartPoints(old, fetchedAt: now.addingTimeInterval(-1)))
        let snap = await UsageHistory(sources: .init(ledger: cache, charts: old)).snapshot(now: now)
        XCTAssertTrue(snap.unavailableSources.isEmpty)
        let summary = snap.summary(period: .week, grouping: .account)
        XCTAssertEqual(summary.totals.tokens, 25)
        XCTAssertEqual(summary.totals.costUSD, 1)
        try await cache.retainHistoryPoints(UsageHistory.retainedChartPoints(charts(0, cost: 0), fetchedAt: now.addingTimeInterval(2)))
        let zero = await UsageHistory(sources: .init(ledger: cache)).snapshot(now: now)
        XCTAssertEqual(zero.summary(period: .week, grouping: .account).totals.tokens, 0)
        XCTAssertEqual(zero.summary(period: .week, grouping: .account).totals.costUSD, 0)
    }

    func testNativeHistorySurvivesSourceRemovalWithoutReattributionOrDoubleCounting() async throws {
        let cache = try ledger()
        try await cache.retainUsageAccounts([.init(id: accountA, providerID: .claudeCode)])
        let home = root.appending(path: "claude")
        let log = home.appending(path: "projects/web/session.jsonl")
        try fileManager.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rows = (1...2).map { id in
            #"{"cwd":"/Projects/web","timestamp":"2026-03-10T10:00:00Z","requestId":"r-\#(id)","message":{"id":"m-\#(id)","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"output_tokens":500}}}"#
        }
        try Data((rows.joined(separator: "\n") + "\n").utf8).write(to: log)
        let scanner = ClaudeCostScanner(roots: [home], cacheURL: root.appending(path: "claude-cache.json"), pricing: { [:] })
        let first = await UsageHistory(sources: .init(ledger: cache, claude: scanner)).snapshot(now: now)
        XCTAssertEqual(first.summary(period: .week, grouping: .account).totals.tokens, 3000)
        XCTAssertEqual(first.summary(period: .week, grouping: .account).groups.first?.key, accountA.uuidString.lowercased())

        try await cache.retainUsageAccounts([.init(id: accountB, providerID: .claudeCode)])
        let multiple = await UsageHistory(sources: .init(ledger: cache, claude: scanner)).snapshot(now: now)
        XCTAssertEqual(multiple.summary(period: .week, grouping: .account).totals.tokens, 3000)
        XCTAssertEqual(multiple.summary(period: .week, grouping: .account).groups.map(\.key), ["shared:claude-code"])
        let survivor = UsageHistory(sources: .init(ledger: cache, claude: scanner,
                                                  accounts: ["claude-code": [accountB.uuidString.lowercased()]]))
        let sessions = await survivor.daySessions(day: "2026-03-10")
        XCTAssertEqual(Set(sessions.compactMap(\.accountID)), ["shared:claude-code"])
        let afterRemoval = await survivor.snapshot(now: now)
        XCTAssertEqual(afterRemoval.summary(period: .week, grouping: .account).totals.tokens, 3000)
        try fileManager.removeItem(at: home)
        let reopened = try ledger()
        let retained = await UsageHistory(sources: .init(ledger: reopened)).snapshot(now: now)
        XCTAssertEqual(retained.summary(period: .week, grouping: .account).totals.tokens, 3000)
        XCTAssertEqual(retained.summary(period: .week, grouping: .model).groups.first?.key, "claude-sonnet-4-5")
        XCTAssertEqual(retained.summary(period: .week, grouping: .project).groups.first?.label, "web")
    }

    func testHistoricalAccountsRejectProviderChangesAndInvalidServices() async throws {
        let cache = try ledger()
        try await cache.retainUsageAccounts([.init(id: accountA, providerID: .claudeCode)])
        do {
            try await cache.retainUsageAccounts([.init(id: accountA, providerID: .droid)])
            XCTFail("An account must not change its historical provider")
        } catch { XCTAssertEqual(error as? CodexUsageStatisticsCacheError, .invalidSnapshot) }
        do {
            try await cache.retainUsageAccounts([.init(id: accountB, providerID: ProviderID(rawValue: "bad/provider"))])
            XCTFail("Invalid provider IDs must not be retained")
        } catch { XCTAssertEqual(error as? CodexUsageStatisticsCacheError, .invalidSnapshot) }
        let accounts = try await cache.usageHistoryAccounts()
        XCTAssertEqual(accounts, [.init(id: accountA, providerID: .claudeCode)])
    }

    func testProviderArchiveRejectsInvalidDatesAndNonfiniteValues() {
        let points: [UsagePoint] = [
            .init(label: "Valid", date: now, value: 5),
            .init(label: "Huge date", date: Date(timeIntervalSince1970: 1e300), value: 10),
            .init(label: "Infinite date", date: Date(timeIntervalSince1970: .infinity), value: 10),
            .init(label: "Infinite tokens", date: now, value: .infinity),
            .init(label: "Invalid tokens", date: now, value: .nan),
        ]
        let chart = UsageChart(id: "valid", title: "Tokens", unit: "tokens", points: points)
        let rows = UsageHistory.retainedChartPoints([
            .init(service: "openrouter", accountID: accountA.uuidString.lowercased(), chart: chart)], fetchedAt: now)
        XCTAssertEqual(rows.map { $0.point.tokens }, [5])
    }

    func testDeletingPrivateClaudeProfilePreservesModelProjectAndRecordedCost() async throws {
        let paths = ManagerPaths(applicationSupport: root.appending(path: "support"),
                                 credentialStore: root.appending(path: "user/.switch/codex"),
                                 defaultHome: root.appending(path: "user/.codex"),
                                 sharedRoot: root.appending(path: "user/.codex"),
                                 orcaAccountsRoot: root.appending(path: "orca"),
                                 claudeExecutable: TestCLI.trueExecutable, isolationRoot: root)
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let profiles = try ClaudeCodeProfiles(paths: paths, fileManager: fileManager,
                                              loginRunner: .init(launch: { _, _ in }),
                                              statusCheck: { _ in .init(loggedIn: true, email: "synthetic@example.test") },
                                              logout: { _ in })
        let login = try profiles.startLogin()
        let initial = try await profiles.checkLogin(login.session.id)
        let account = try XCTUnwrap(initial.account)
        let replacement = try profiles.startLogin()
        let replacementResult = try await profiles.checkLogin(replacement.session.id)
        let replacementAccount = try XCTUnwrap(replacementResult.account)
        let projects = account.home.appending(path: "projects")
        try fileManager.removeItem(at: projects)
        let log = projects.appending(path: "web/session.jsonl")
        try fileManager.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let current = Date()
        let timestamp = ISO8601DateFormatter().string(from: current)
        let row = #"{"cwd":"/Projects/web","timestamp":"\#(timestamp)","requestId":"private-r","message":{"id":"private-m","model":"claude-sonnet-4-5","usage":{"input_tokens":1000,"output_tokens":500}}}"#
        try Data((row + "\n").utf8).write(to: log)
        let cache = try CodexUsageStatisticsCache(
            databaseURL: paths.applicationSupport.appending(path: "cache/account-usage.sqlite"),
            activityDatabaseURL: paths.applicationSupport.appending(path: "activity/daily.sqlite"))
        _ = try await manager.usageHistoryAccounts()
        let scanner = ClaudeCostScanner(roots: [account.home], cacheURL: root.appending(path: "private-scan.json"),
                                        pricing: { ["claude-sonnet-4-5": ModelRate(input: 3, output: 15)] })
        let before = await UsageHistory(sources: .init(
            ledger: cache, claude: scanner, claudeHomes: [account.id.uuidString.lowercased(): account.home])).snapshot(now: current)
        let cost = try XCTUnwrap(before.summary(period: .week, grouping: .account).totals.costUSD)
        XCTAssertEqual(before.summary(period: .week, grouping: .account).totals.tokens, 1500)
        _ = try await manager.deleteAccount(accountID: account.id, replacementDefaultAccountID: replacementAccount.id)
        XCTAssertFalse(fileManager.fileExists(atPath: account.home.path))
        let after = await UsageHistory(sources: .init(ledger: cache)).snapshot(now: current)
        XCTAssertEqual(after.summary(period: .week, grouping: .account).totals.tokens, 1500)
        XCTAssertEqual(after.summary(period: .week, grouping: .account).totals.costUSD, cost)
        XCTAssertEqual(after.summary(period: .week, grouping: .model).groups.first?.key, "claude-sonnet-4-5")
        XCTAssertEqual(after.summary(period: .week, grouping: .project).groups.first?.label, "web")
    }
}
