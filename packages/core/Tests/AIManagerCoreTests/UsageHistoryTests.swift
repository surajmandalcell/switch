import CSQLite
import Foundation
import XCTest
@testable import AIManagerCore

final class UsageHistoryTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default
    private let now = Date(timeIntervalSince1970: 1_773_144_000) // 2026-03-10T12:00:00Z
    private let accountA = "aaaaaaaa-0000-0000-0000-000000000001"
    private let accountB = "bbbbbbbb-0000-0000-0000-000000000002"
    private let rates = [
        "gpt-5.1-codex": ModelRate(input: 1, output: 10, cacheRead: 0.1),
        "claude-sonnet-4-5": ModelRate(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3),
    ]

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appending(
            path: "UsageHistoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fileManager.removeItem(at: root) }
    }

    // MARK: Helpers

    private func ledger() throws -> CodexUsageStatisticsCache {
        try CodexUsageStatisticsCache(
            databaseURL: root.appending(path: "cache/usage.sqlite"),
            activityDatabaseURL: root.appending(path: "activity/daily.sqlite"))
    }

    private func writeLines(_ records: [[String: Any]], to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            data.append(0x0A)
        }
        try data.write(to: url)
    }

    private func meta(_ id: String, cwd: String) -> [String: Any] {
        ["type": "session_meta", "payload": ["id": id, "cwd": cwd]]
    }

    private func context(_ model: String) -> [String: Any] {
        ["type": "turn_context", "payload": ["model": model, "cwd": "/ignored"]]
    }

    private func tokens(_ total: Int64, input: Int64, cached: Int64, output: Int64, at time: String) -> [String: Any] {
        ["timestamp": time, "type": "event_msg", "payload": [
            "type": "token_count", "info": ["total_token_usage": [
                "input_tokens": input, "cached_input_tokens": cached, "output_tokens": output,
                "total_tokens": total]]]]
    }

    /// Two Codex threads in a shared home: alpha uses m1 then a mini model, beta uses m1.
    private func codexHome() throws -> URL {
        let home = root.appending(path: "codex")
        try writeLines([
            meta("alpha", cwd: "/Projects/alpha"), context("gpt-5.1-codex"),
            tokens(1_000, input: 800, cached: 600, output: 200, at: "2026-03-09T10:00:00Z"),
            tokens(1_500, input: 1_200, cached: 900, output: 300, at: "2026-03-09T11:00:00Z"),
            context("gpt-5-mini"),
            tokens(1_800, input: 1_400, cached: 1_000, output: 400, at: "2026-03-10T09:00:00Z"),
        ], to: home.appending(path: "sessions/alpha.jsonl"))
        try writeLines([
            meta("beta", cwd: "/Projects/beta"), context("gpt-5.1-codex"),
            tokens(400, input: 300, cached: 0, output: 100, at: "2026-03-10T08:00:00Z"),
        ], to: home.appending(path: "sessions/beta.jsonl"))
        return home
    }

    private func utcDay(_ offset: Int) -> String {
        ClaudeCostScanner.utcDayName(Int((now.timeIntervalSince1970 / 86_400).rounded(.down)) + offset)
    }

    private func snapshot(_ points: [UsageHistoryPoint]) -> UsageHistorySnapshot {
        UsageHistorySnapshot(points: points, today: utcDay(0))
    }

    // MARK: Codex ledger

    func testSharedTranscriptsGroupByModelAndProjectNeverByAccount() async throws {
        let ledger = try ledger()
        let index = ChatHistoryIndex(home: try codexHome())
        await index.attachActivityCache(ledger)
        _ = try await index.refresh()
        try await ledger.upsertSuccess(accountID: UUID(uuidString: accountA)!, snapshot: .init(
            account: nil, requiresOpenAIAuthentication: nil, rateLimits: nil, usage: nil,
            dailyUsage: [.init(startDate: utcDay(-1), tokens: 900)], fetchedAt: now))

        let history = UsageHistory(sources: .init(ledger: ledger, pricing: { [rates] in rates }))
        let snap = await history.snapshot(now: now)

        let byAccount = snap.summary(period: .week, grouping: .account)
        XCTAssertEqual(byAccount.groups.map(\.key), [accountA])
        XCTAssertEqual(byAccount.groups.first?.tokens, 900)
        XCTAssertEqual(byAccount.totals.activeAccounts, 1)

        let byModel = snap.summary(period: .week, grouping: .model)
        XCTAssertEqual(byModel.groups.map(\.key), ["gpt-5.1-codex", "gpt-5-mini"])
        XCTAssertEqual(byModel.groups.map(\.tokens), [1_900, 300])
        // m1: yesterday 1500 tokens (in 1200 incl. 900 cached, out 300), today 400 (in 300, out 100).
        let m1 = try XCTUnwrap(byModel.groups.first)
        XCTAssertEqual(m1.daily.suffix(2), [1_500, 400])
        let expected = (Double(300 + 300) * 1 + 900 * 0.1 + 400 * 10) / 1e6
        XCTAssertEqual(try XCTUnwrap(m1.costUSD), expected, accuracy: 1e-9)
        XCTAssertNil(byModel.groups.last?.costUSD, "mini has no price")

        let byProject = snap.summary(period: .week, grouping: .project)
        XCTAssertEqual(byProject.groups.map(\.label), ["alpha", "beta"])
        XCTAssertEqual(byProject.groups.map(\.tokens), [1_800, 400])

        // Day totals take the larger view per service, so account totals and transcripts never add.
        XCTAssertEqual(byAccount.totals.tokens, 2_200)
        XCTAssertEqual(byAccount.dailyTotals.suffix(2), [1_500, 700])
        XCTAssertEqual(byAccount.totals.busiestDay, utcDay(-1))
    }

    func testIncrementalScanNeverDoubleCountsAndModelsSurviveResume() async throws {
        let ledger = try ledger()
        let home = try codexHome()
        let index = ChatHistoryIndex(home: home, cacheFile: root.appending(path: "chat.json"))
        await index.attachActivityCache(ledger)
        _ = try await index.refresh()
        _ = try await index.refresh()
        let before = try await ledger.threadDays(from: utcDay(-3), through: utcDay(0))
        XCTAssertEqual(before.map(\.tokens).reduce(0, +), 2_200)

        let alpha = home.appending(path: "sessions/alpha.jsonl")
        var data = try Data(contentsOf: alpha)
        data.append(try JSONSerialization.data(withJSONObject:
            tokens(2_100, input: 1_600, cached: 1_100, output: 500, at: "2026-03-10T10:00:00Z")))
        data.append(0x0A)
        try data.write(to: alpha)
        _ = try await index.refresh()
        let metrics = await index.refreshMetrics()
        XCTAssertEqual(metrics.incrementallyParsedFileCount, 1)
        _ = try await index.refresh()

        let after = try await ledger.threadDays(from: utcDay(-3), through: utcDay(0))
        XCTAssertEqual(after.map(\.tokens).reduce(0, +), 2_500)
        let mini = after.filter { $0.model == "gpt-5-mini" }.map(\.tokens).reduce(0, +)
        XCTAssertEqual(mini, 600, "the new tokens use the model the resumed parse remembered")
    }

    func testCachedStatesWithoutModelsReparseOnceAndFillTheLedger() async throws {
        let ledger = try ledger()
        let home = try codexHome()
        let cacheFile = root.appending(path: "chat.json")
        let first = ChatHistoryIndex(home: home, cacheFile: cacheFile)
        await first.attachActivityCache(ledger)
        _ = try await first.refresh()

        // Make the saved cache look like the one an older build wrote, and empty the model rows.
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheFile)) as? [String: Any])
        var threads = try XCTUnwrap(document["threads"] as? [[String: Any]])
        for index in threads.indices {
            var state = try XCTUnwrap(threads[index]["parseState"] as? [String: Any])
            for key in ["activityModels", "currentModel", "previousSplit"] { state[key] = nil }
            threads[index]["parseState"] = state
        }
        document["threads"] = threads
        try JSONSerialization.data(withJSONObject: document).write(to: cacheFile)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appending(path: "activity/daily.sqlite").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DELETE FROM model_days", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let emptied = try await ledger.threadDays(from: utcDay(-3), through: utcDay(0))
        XCTAssertTrue(emptied.allSatisfy { $0.model == nil })

        let second = ChatHistoryIndex(home: home, cacheFile: cacheFile)
        await second.attachActivityCache(ledger)
        _ = try await second.refresh()
        let metrics = await second.refreshMetrics()
        XCTAssertEqual(metrics.fullyParsedFileCount, 2)
        let filled = try await ledger.threadDays(from: utcDay(-3), through: utcDay(0))
        XCTAssertEqual(filled.filter { $0.model != nil }.map(\.tokens).reduce(0, +), 2_200)
        _ = try await second.refresh()
        let idle = await second.refreshMetrics()
        XCTAssertEqual(idle.fullyParsedFileCount + idle.incrementallyParsedFileCount, 0)
    }

    func testVersionOneLedgerMigratesWithoutLosingRows() async throws {
        let url = root.appending(path: "activity/daily.sqlite")
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
            CREATE TABLE account_days(account_id TEXT NOT NULL, day TEXT NOT NULL,
                tokens INTEGER NOT NULL CHECK(tokens >= 0), fetched_at REAL NOT NULL,
                PRIMARY KEY(account_id, day)) WITHOUT ROWID;
            CREATE TABLE activity_threads(thread_id TEXT PRIMARY KEY NOT NULL, project TEXT NOT NULL,
                first_event TEXT NOT NULL, event_count INTEGER NOT NULL, total_tokens INTEGER NOT NULL,
                complete INTEGER NOT NULL) WITHOUT ROWID;
            CREATE TABLE project_days(thread_id TEXT NOT NULL, day TEXT NOT NULL,
                tokens INTEGER NOT NULL CHECK(tokens >= 0), PRIMARY KEY(thread_id, day),
                FOREIGN KEY(thread_id) REFERENCES activity_threads(thread_id)) WITHOUT ROWID;
            CREATE TABLE activity_metadata(key TEXT PRIMARY KEY NOT NULL) WITHOUT ROWID;
            INSERT INTO account_days VALUES('\(accountA)', '\(utcDay(-2))', 700, 1.0);
            INSERT INTO activity_threads VALUES('codex:old', '/Projects/old', 'x', 2, 500, 1);
            INSERT INTO project_days VALUES('codex:old', '\(utcDay(-2))', 500);
            PRAGMA user_version = 1;
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let migrated = try ledger()
        let accounts = try await migrated.accountDays(from: utcDay(-5), through: utcDay(0))
        XCTAssertEqual(accounts, [.init(accountID: accountA, day: utcDay(-2), tokens: 700)])
        let threads = try await migrated.threadDays(from: utcDay(-5), through: utcDay(0))
        XCTAssertEqual(threads, [.init(day: utcDay(-2), project: "/Projects/old", model: nil,
                                       tokens: 500, input: 0, cached: 0, output: 0)])
        let again = try ledger()
        let reread = try await again.threadDays(from: utcDay(-5), through: utcDay(0))
        XCTAssertEqual(reread, threads)
    }

    // MARK: Windows and totals

    func testWeekMonthYearWindowsAndTotals() {
        let points = [
            UsageHistoryPoint(day: utcDay(0), service: "codex", accountID: accountA, tokens: 100, costUSD: 1),
            UsageHistoryPoint(day: utcDay(-6), service: "codex", accountID: accountA, tokens: 50),
            UsageHistoryPoint(day: utcDay(-7), service: "codex", accountID: accountB, tokens: 40),
            UsageHistoryPoint(day: utcDay(-29), service: "codex", accountID: accountB, tokens: 30),
            UsageHistoryPoint(day: utcDay(-30), service: "codex", accountID: accountB, tokens: 20),
            UsageHistoryPoint(day: utcDay(-364), service: "codex", accountID: accountB, tokens: 10),
            UsageHistoryPoint(day: utcDay(-365), service: "codex", accountID: accountB, tokens: 5),
        ]
        let snap = snapshot(points)
        let week = snap.summary(period: .week, grouping: .account)
        XCTAssertEqual(week.days.count, 7)
        XCTAssertEqual(week.days.first, utcDay(-6))
        XCTAssertEqual(week.days.last, utcDay(0))
        XCTAssertEqual(week.totals.tokens, 150)
        XCTAssertEqual(week.totals.costUSD, 1)
        XCTAssertEqual(week.totals.activeAccounts, 1)
        XCTAssertEqual(week.totals.busiestDay, utcDay(0))
        XCTAssertEqual(week.totals.busiestDayTokens, 100)
        XCTAssertEqual(week.groups.first?.daily, [50, 0, 0, 0, 0, 0, 100])

        let month = snap.summary(period: .month, grouping: .account)
        XCTAssertEqual(month.days.count, 30)
        XCTAssertEqual(month.totals.tokens, 220)
        XCTAssertEqual(month.totals.activeAccounts, 2)
        XCTAssertEqual(month.groups.map(\.key), [accountA, accountB])
        XCTAssertEqual(month.groups.map(\.tokens), [150, 70])

        let year = snap.summary(period: .year, grouping: .account)
        XCTAssertEqual(year.days.count, 365)
        XCTAssertEqual(year.dailyTotals.count, 365)
        XCTAssertEqual(year.totals.tokens, 250)
        XCTAssertEqual(year.dailyTotals.first, 10)
    }

    func testEmptyHistoryHasZeroTotalsAndNoBusiestDay() {
        let summary = snapshot([]).summary(period: .month, grouping: .model)
        XCTAssertTrue(summary.groups.isEmpty)
        XCTAssertEqual(summary.totals.tokens, 0)
        XCTAssertNil(summary.totals.costUSD)
        XCTAssertNil(summary.totals.busiestDay)
        XCTAssertEqual(summary.dailyTotals, Array(repeating: 0, count: 30))
    }

    func testModelAndProjectGroupingMergeServicesAndKeepUnknowns() {
        let points = [
            UsageHistoryPoint(day: utcDay(0), service: "claude-code", model: "m", project: "/p/one", tokens: 10),
            UsageHistoryPoint(day: utcDay(0), service: "grok-build", model: "m", project: "/p/two", tokens: 20),
            UsageHistoryPoint(day: utcDay(0), service: "codex", model: nil, project: "Unknown project", tokens: 5),
            UsageHistoryPoint(day: utcDay(0), service: "codex", accountID: accountA, tokens: 99),
        ]
        let model = snapshot(points).summary(period: .week, grouping: .model)
        XCTAssertEqual(model.groups.map(\.key), ["m", "unknown"])
        XCTAssertEqual(model.groups.first?.services, ["grok-build", "claude-code"])
        XCTAssertEqual(model.groups.last?.label, "Unknown model")
        let project = snapshot(points).summary(period: .week, grouping: .project)
        XCTAssertEqual(project.groups.map(\.label), ["two", "one", "Unknown project"])
        XCTAssertEqual(project.groups.map(\.tokens), [20, 10, 5])
    }

    // MARK: Claude Code, Grok Build, charts

    private func claudeLine(_ time: String, id: String, model: String = "claude-sonnet-4-5", cwd: String? = "/Projects/web",
                            input: Int = 1_000, output: Int = 500) -> String {
        let place = cwd.map { #""cwd":"\#($0)","# } ?? ""
        return #"{\#(place)"timestamp":"\#(time)","requestId":"r-\#(id)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
    }

    func testClaudeHistoryAttributesOnlyAccountOwnedHomesAndScansIncrementally() async throws {
        let own = root.appending(path: "profile-a", directoryHint: .isDirectory)
        let shared = root.appending(path: "shared", directoryHint: .isDirectory)
        let ownLog = own.appending(path: "projects/-Projects-web/s1.jsonl")
        let sharedLog = shared.appending(path: "projects/-Projects-api/s2.jsonl")
        for (url, lines) in [
            (ownLog, [claudeLine("2026-03-09T10:00:00Z", id: "m1"), claudeLine("2026-03-09T10:00:00Z", id: "m1")]),
            (sharedLog, [claudeLine("2026-03-10T10:00:00Z", id: "m2", cwd: "/Projects/api"),
                         claudeLine("2026-03-10T11:00:00Z", id: "m3", model: "mystery", cwd: nil)]),
            (shared.appending(path: "projects/-Projects-nocwd/s3.jsonl"),
             [claudeLine("2026-03-10T11:30:00Z", id: "m5", cwd: nil)]),
        ] {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        }
        let scanner = ClaudeCostScanner(
            roots: [own.appending(path: "projects"), shared.appending(path: "projects")],
            cacheURL: root.appending(path: "claude-history.json"), pricing: { [rates] in rates })
        let history = UsageHistory(sources: .init(
            claude: scanner, claudeHomes: [accountA: own], pricing: nil))

        let snap = await history.snapshot(now: now)

        let byAccount = snap.summary(period: .week, grouping: .account)
        XCTAssertEqual(byAccount.groups.map(\.key), [accountA])
        XCTAssertEqual(byAccount.groups.first?.tokens, 1_500, "the replayed line counts once")
        let byProject = snap.summary(period: .week, grouping: .project)
        XCTAssertEqual(Set(byProject.groups.map(\.label)), ["web", "api", "-Projects-nocwd"])
        let byModel = snap.summary(period: .week, grouping: .model)
        XCTAssertEqual(Set(byModel.groups.map(\.key)), ["claude-sonnet-4-5", "mystery"])
        let sonnet = try XCTUnwrap(byModel.groups.first { $0.key == "claude-sonnet-4-5" })
        XCTAssertEqual(try XCTUnwrap(sonnet.costUSD), 3 * (1_000 * 3.0 + 500 * 15.0) / 1e6, accuracy: 1e-9)
        XCTAssertNil(byModel.groups.first { $0.key == "mystery" }?.costUSD)
        XCTAssertEqual(byAccount.totals.tokens, 6_000)

        let parsedFirst = await scanner.filesParsed
        _ = await history.snapshot(now: now)
        let parsedSecond = await scanner.filesParsed
        XCTAssertEqual(parsedFirst, 3)
        XCTAssertEqual(parsedSecond, 3, "unchanged logs are not parsed again")

        var data = try Data(contentsOf: sharedLog)
        data.append(Data((claudeLine("2026-03-10T12:30:00Z", id: "m4", cwd: "/Projects/api") + "\n").utf8))
        try data.write(to: sharedLog)
        _ = await history.snapshot(now: now)
        let parsedThird = await scanner.filesParsed
        XCTAssertEqual(parsedThird, 4, "only the changed log is parsed")
    }

    func testGrokSessionsKeepModelProjectAndSingleAccountAndSkipCopiedEvents() async throws {
        let sessions = root.appending(path: "grok/sessions", directoryHint: .isDirectory)
        func turn(_ event: String, at ms: Int, ticks: Int) -> [String: Any] {
            ["params": ["update": ["sessionUpdate": "turn_completed", "usage": [
                "modelUsage": ["grok-4": ["inputTokens": 300, "outputTokens": 100, "costUsdTicks": ticks]]]],
                "_meta": ["agentTimestampMs": ms, "eventId": event]]]
        }
        let dayMs = Int(now.timeIntervalSince1970 * 1000)
        let folder = "%2FProjects%2Fgrokapp"
        try writeLines([turn("e1", at: dayMs, ticks: 20_000_000_000), turn("e2", at: dayMs - 86_400_000, ticks: 10_000_000_000)],
                       to: sessions.appending(path: "\(folder)/s1/updates.jsonl"))
        try writeLines([turn("e1", at: dayMs, ticks: 20_000_000_000)],
                       to: sessions.appending(path: "\(folder)/copy/updates.jsonl"))
        let history = UsageHistory(sources: .init(grokSessions: sessions, grokAccountID: accountB))
        let snap = await history.snapshot(now: now)

        let byAccount = snap.summary(period: .week, grouping: .account)
        XCTAssertEqual(byAccount.groups.map(\.key), [accountB])
        XCTAssertEqual(byAccount.groups.first?.tokens, 800)
        XCTAssertEqual(byAccount.totals.costUSD ?? 0, 3, accuracy: 1e-9)
        XCTAssertEqual(snap.summary(period: .week, grouping: .project).groups.first?.label, "grokapp")
        XCTAssertEqual(snap.summary(period: .week, grouping: .model).groups.first?.key, "grok-4")

        let shared = UsageHistory(sources: .init(grokSessions: sessions, grokAccountID: nil))
        let none = await shared.snapshot(now: now).summary(period: .week, grouping: .account)
        XCTAssertTrue(none.groups.isEmpty, "a home with several accounts is not attributed")
    }

    func testProviderChartsFeedAccountsAndSkipScannedServices() async throws {
        let usd = try XCTUnwrap(UsageChart.daily(id: "c", title: "Spend", unit: "USD",
            values: [utcDay(-1): 4, utcDay(0): 6]))
        let tokens = try XCTUnwrap(UsageChart.daily(id: "t", title: "Tokens", unit: "tokens",
            values: [utcDay(0): 1_000]))
        let history = UsageHistory(sources: .init(charts: [
            .init(service: "openrouter", accountID: accountA, chart: usd),
            .init(service: "zai", accountID: accountB, chart: tokens),
            .init(service: "codex", accountID: accountB, chart: tokens),
        ]))
        let summary = await history.snapshot(now: now).summary(period: .week, grouping: .account)
        XCTAssertEqual(summary.groups.map(\.key), [accountB, accountA])
        XCTAssertEqual(summary.groups.map(\.tokens), [1_000, 0])
        XCTAssertEqual(summary.groups.last?.costUSD, 10)
        XCTAssertEqual(summary.totals.activeAccounts, 2)
    }

    // MARK: Speed

    func testYearOfPointsAggregatesWellUnderOneHundredMilliseconds() {
        var points: [UsageHistoryPoint] = []
        for offset in -364...0 {
            for service in ["codex", "claude-code", "grok-build"] {
                for model in 0..<6 {
                    for project in 0..<5 {
                        points.append(.init(day: utcDay(offset), service: service, model: "model-\(model)",
                                            project: "/Projects/p\(project)", tokens: Int64(offset + 400 + model),
                                            costUSD: 0.01))
                    }
                }
                points.append(.init(day: utcDay(offset), service: service, accountID: "acct-\(service)", tokens: 99))
            }
        }
        let snap = snapshot(points)
        _ = snap.summary(period: .year, grouping: .model)
        let start = Date()
        for grouping in UsageGrouping.allCases {
            for period in UsagePeriod.allCases { _ = snap.summary(period: period, grouping: grouping) }
        }
        let each = Date().timeIntervalSince(start) / 9
        print("usage history: \(points.count) points, \(Int(each * 1000)) ms per summary")
        XCTAssertLessThan(each, 0.1)
    }

    func testLedgerYearReadsWithinBudgetAfterTheFirstScan() async throws {
        let ledger = try ledger()
        for thread in 0..<30 {
            var days: [String: Int64] = [:]
            var models: [String: CodexModelUsage] = [:]
            for offset in -364...0 where (offset + thread) % 3 != 0 {
                days[utcDay(offset)] = 100
                models[utcDay(offset) + "\u{1F}" + "model-\(thread % 4)"] = .init(tokens: 100, input: 60, cached: 20, output: 40)
            }
            try await ledger.recordTranscriptActivity(.init(
                threadID: "t\(thread)", project: "/Projects/p\(thread % 7)", firstEvent: "e\(thread)",
                eventCount: days.count, totalTokens: Int64(days.count * 100), days: days, complete: true,
                models: models), fallbackID: "f\(thread)")
        }
        let history = UsageHistory(sources: .init(ledger: ledger, pricing: { [rates] in rates }))
        let first = await history.snapshot(now: now)
        let start = Date()
        let second = await history.snapshot(now: now)
        let elapsed = Date().timeIntervalSince(start)
        print("usage history: warm ledger snapshot of \(second.points.count) points in \(Int(elapsed * 1000)) ms")
        XCTAssertEqual(first.points.count, second.points.count)
        XCTAssertGreaterThan(second.points.count, 5_000)
        XCTAssertLessThan(elapsed, 0.5)
        XCTAssertEqual(second.summary(period: .year, grouping: .model).groups.count, 4)
    }
}
