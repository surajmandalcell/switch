import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchAppModel

final class AppEngineHistoryTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "AppEngineHistoryTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    func paths(isolated: Bool) -> ManagerPaths {
        .init(applicationSupport: root.appending(path: "support"), defaultHome: root.appending(path: "user/.codex"),
              sharedRoot: root.appending(path: "user/.codex"), orcaAccountsRoot: root.appending(path: "orca"),
              grokHome: root.appending(path: "user/.grok"), droidHome: root.appending(path: "user/.factory"),
              isolationRoot: isolated ? root : nil)
    }

    func account(_ provider: ProviderID) -> AccountRecord {
        AccountRecord(id: UUID(), identity: .init(providerID: provider, authMode: .apiKey), home: root, source: root,
                      importedAt: Date(), verification: .init(state: .verifiedLocally, detail: ""), credentialDigest: "")
    }

    func testSourceListKeepsTestHomesOffRealLogsAndChartsOffScannedProviders() {
        let codex = account(.codex)
        let other = account(ProviderID(rawValue: "test-history"))
        let chart = UsageChart(id: "tokens", title: "Tokens", unit: "tokens",
                               points: [UsagePoint(label: "2026-11-14", value: 10)])
        let usage = [codex.id: ProviderUsage(charts: [chart]), other.id: ProviderUsage(charts: [chart])]
        let owners = [HistoricalUsageAccount(id: codex.id, providerID: .codex)]

        let isolated = UsageHistorySourceList.make(paths: paths(isolated: true), accounts: [codex, other],
                                                   historyAccounts: owners, ledger: nil, providerUsage: usage,
                                                   environment: [:])
        XCTAssertNil(isolated.claude)
        XCTAssertNil(isolated.pricing)
        // The test home's own Grok and Droid folders are read (the CLI history acceptance test needs them).
        XCTAssertEqual(isolated.grokSessions, root.appending(path: "user/.grok/sessions", directoryHint: .isDirectory))
        XCTAssertNotNil(isolated.droidSessions)
        var outside = paths(isolated: true)
        outside.grokHome = URL(fileURLWithPath: "/real/.grok")
        outside.droidHome = URL(fileURLWithPath: "/real/.factory")
        let leaking = UsageHistorySourceList.make(paths: outside, accounts: [], historyAccounts: [], ledger: nil,
                                                  providerUsage: [:], environment: [:])
        XCTAssertNil(leaking.grokSessions, "A test home never reads a Grok folder outside itself")
        XCTAssertNil(leaking.droidSessions)
        XCTAssertEqual(isolated.accounts, ["codex": [codex.id.uuidString.lowercased()]])
        XCTAssertEqual(isolated.charts.map(\.accountID), [other.id.uuidString.lowercased()], "Codex is scanned, not charted")

        let live = UsageHistorySourceList.make(paths: paths(isolated: false), accounts: [codex, other],
                                               historyAccounts: owners, ledger: nil, providerUsage: usage,
                                               environment: [:])
        XCTAssertNotNil(live.claude)
        XCTAssertNotNil(live.pricing)
        XCTAssertEqual(live.grokSessions, root.appending(path: "user/.grok/sessions", directoryHint: .isDirectory))
    }

    func testSnapshotIsReusedForSixtySeconds() async throws {
        let paths = paths(isolated: true)
        let clock = ManualClock()
        let engine = AppEngine(manager: try AccountManager(paths: paths, writerCheck: { _ in .inactive }, providerSpecs: []),
                               paths: paths, clock: clock)
        _ = try await engine.usageHistory()
        let first = await engine.historyLoadedAt
        clock.advance(seconds: 59)
        _ = try await engine.usageHistory()
        var loadedAt = await engine.historyLoadedAt
        XCTAssertEqual(loadedAt, first)
        clock.advance(seconds: 1)
        let (points, sessions) = try await engine.usageDay("2026-11-14")
        loadedAt = await engine.historyLoadedAt
        XCTAssertEqual(loadedAt, clock.now)
        XCTAssertTrue(points.isEmpty)
        XCTAssertTrue(sessions.isEmpty)
    }

    func testUnavailableEngineHasNoHistory() async {
        let engine = AppEngine(manager: nil, paths: paths(isolated: true), clock: ManualClock())
        do {
            _ = try await engine.usageHistory()
            XCTFail("no history without the data folder")
        } catch {
            XCTAssertEqual(error as? AppEngineError, .unavailable)
        }
    }

    func testTodayUsesLocalHoursAndPricesOnFallBackDay() async throws {
        let iso = ISO8601DateFormatter()
        let now = try XCTUnwrap(iso.date(from: "2026-11-01T01:30:00-05:00"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let paths = paths(isolated: true)
        let engine = AppEngine(manager: nil, paths: paths, clock: ManualClock(start: now))
        func slot(_ time: String, tokens: Int64, cost: Double?) throws -> UsageSlotPoint {
            let date = try XCTUnwrap(iso.date(from: time))
            return .init(quarter: Int64(date.timeIntervalSince1970 / 900),
                         point: .init(day: "2026-11-01", service: "codex", model: "Test", tokens: tokens, costUSD: cost))
        }
        let snapshot = try UsageHistorySnapshot(points: [.init(day: "2026-11-01", service: "droid", tokens: 100)],
            today: "2026-11-01", slots: [
                slot("2026-11-01T01:00:00-04:00", tokens: 7, cost: nil),
                slot("2026-11-01T01:15:00-05:00", tokens: 13, cost: 0.25),
                slot("2026-11-01T01:30:00-05:00", tokens: 9, cost: 0.50),
                slot("2026-11-01T01:45:00-05:00", tokens: 99, cost: 2),
            ])
        await engine.seedOverviewSnapshot(snapshot, now: now)
        let (_, today, unavailable) = try await engine.overviewHistory(period: .today, grouping: .model, calendar: calendar)
        XCTAssertEqual(today.days.count, 25)
        XCTAssertEqual(today.startedHours, 3)
        XCTAssertEqual(Array(today.days.prefix(3)),
                       ["2026-11-01T00:00:00-04:00", "2026-11-01T01:00:00-04:00", "2026-11-01T01:00:00-05:00"])
        XCTAssertEqual(Array(today.dailyTotals.prefix(4)), [0, 7, 22, 0])
        XCTAssertEqual(today.totals.tokens, 29)
        XCTAssertEqual(today.totals.busiestHour, "2026-11-01T01:00:00-05:00")
        XCTAssertEqual(today.totals.busiestHourTokens, 22)
        XCTAssertEqual(today.groups.first?.hourlyCostUSD.map { Array($0.prefix(4)) }, [nil, nil, 0.75, nil])
        XCTAssertEqual(Set(unavailable), ["codex-account-totals", "droid", "provider-charts"])

        let spring = try XCTUnwrap(iso.date(from: "2026-03-08T12:00:00-04:00"))
        let springSummary = snapshot.summary(period: .today, grouping: .model, now: spring, calendar: calendar)
        XCTAssertEqual(springSummary.days.count, 23)
        XCTAssertEqual(springSummary.days[2], "2026-03-08T03:00:00-04:00")
    }

    func testConversationAppsFilterBeforeLimitAndCountsIgnoreQuery() async throws {
        let paths = paths(isolated: true)
        let codex = paths.sharedRoot.appending(path: "sessions/2026/11/14/rollout-2026-11-14T10-00-00-codex.jsonl")
        let claude = root.appending(path: ".claude/projects/work/claude.jsonl")
        for file in [codex, claude] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data("""
        {"timestamp":"2026-11-14T10:00:00Z","type":"session_meta","payload":{"id":"codex","cwd":"/work"}}
        {"timestamp":"2026-11-14T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Only in Codex"}]}}

        """.utf8).write(to: codex)
        let longText = "Claude fixture " + String(repeating: "a", count: 21_001)
        try Data("""
        {"timestamp":"2026-11-13T10:00:00Z","type":"user","sessionId":"claude","cwd":"/work","message":{"role":"user","content":"\(longText)"}}

        """.utf8).write(to: claude)
        let engine = AppEngine(manager: nil, paths: paths, clock: ManualClock())
        let (all, _) = try await engine.conversationHistory(query: "", limit: 1)
        XCTAssertEqual(all.threads.map(\.appSource), [.codex])
        let (filtered, counts) = try await engine.conversationHistory(query: "Claude fixture", limit: 1, sources: [.claude])
        XCTAssertEqual(filtered.threads.map(\.appSource), [.claude])
        XCTAssertEqual(counts, ["claude": 1, "codex": 1])
        let (onlyClaude, _) = try await engine.conversationHistory(query: "", limit: 1, sources: [.claude])
        XCTAssertEqual(onlyClaude.threads.map(\.appSource), [.claude])
        let id = try XCTUnwrap(filtered.threads.first?.id)
        let detail = try await engine.conversationDetail(id: id, offset: 0, limit: 1, query: "", filter: .all)
        XCTAssertEqual(detail.messages.first?.text, longText)
    }
}

private extension AppEngine {
    func seedOverviewSnapshot(_ snapshot: UsageHistorySnapshot, now: Date) {
        history = snapshot
        historyLoadedAt = now
    }
}
