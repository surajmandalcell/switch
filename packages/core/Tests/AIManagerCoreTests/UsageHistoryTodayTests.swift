import CSQLite
import Foundation
import XCTest
@testable import AIManagerCore

/// Today's hourly view: local hours, DST days, midnight edges, and the additive ledger table that feeds it.
final class UsageHistoryTodayTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "UsageHistoryTodayTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func slot(_ iso: String, service: String = "claude", account: String? = "acct-1",
                      model: String = "m1", project: String = "/p/alpha", tokens: Int64) -> UsageSlotPoint {
        let quarter = Int64(date(iso).timeIntervalSince1970 / 900)
        return UsageSlotPoint(quarter: quarter, service: service, accountID: account, model: model,
                              project: project, tokens: tokens, costUSD: Double(tokens) / 1000)
    }

    func testLocalHoursInIndiaKeepEventsNearMidnightOnTheRightDay() {
        let india = calendar("Asia/Kolkata")
        let now = date("2026-03-10T10:30:00+05:30")
        let snap = UsageHistorySnapshot(points: [], today: "2026-03-10", slots: [
            slot("2026-03-09T23:50:00+05:30", tokens: 999),  // yesterday, left out
            slot("2026-03-10T00:05:00+05:30", tokens: 10),
            slot("2026-03-10T00:50:00+05:30", tokens: 5),
            slot("2026-03-10T09:45:00+05:30", model: "m2", project: "/p/beta", tokens: 40),
            slot("2026-03-11T00:00:00+05:30", tokens: 777),  // tomorrow, left out
        ])
        let summary = snap.summary(period: .today, grouping: .model, now: now, calendar: india)
        XCTAssertEqual(summary.days.count, 24)
        XCTAssertEqual(summary.days.first, "2026-03-10T00:00:00+05:30")
        XCTAssertEqual(summary.startedHours, 11)
        XCTAssertEqual(summary.totals.tokens, 55)
        XCTAssertEqual(summary.dailyTotals[0], 15)
        XCTAssertEqual(summary.dailyTotals[9], 40)
        XCTAssertEqual(summary.totals.busiestDay, "2026-03-10T09:00:00+05:30")
        XCTAssertEqual(summary.groups.map(\.key), ["m2", "m1"])

        XCTAssertEqual(snap.summary(period: .today, grouping: .project, now: now, calendar: india)
            .groups.map(\.label), ["beta", "alpha"])
        let byAccount = snap.summary(period: .today, grouping: .account, now: now, calendar: india)
        XCTAssertEqual(byAccount.groups.map(\.key), ["acct-1"])
        XCTAssertEqual(byAccount.totals.activeAccounts, 1)
    }

    func testDSTDaysHaveTwentyThreeOrTwentyFiveHours() {
        let newYork = calendar("America/New_York")
        let spring = UsageHistorySnapshot(points: [], today: "2026-03-08", slots: [
            slot("2026-03-08T03:15:00-04:00", tokens: 7),  // first hour after the jump
        ]).summary(period: .today, grouping: .model, now: date("2026-03-08T23:00:00-04:00"), calendar: newYork)
        XCTAssertEqual(spring.days.count, 23)
        XCTAssertEqual(spring.dailyTotals[2], 7)
        XCTAssertEqual(spring.startedHours, 23)

        let fall = UsageHistorySnapshot(points: [], today: "2026-11-01", slots: [
            slot("2026-11-01T01:30:00-05:00", tokens: 3),  // the repeated 1 AM hour
        ]).summary(period: .today, grouping: .model, now: date("2026-11-01T23:59:00-05:00"), calendar: newYork)
        XCTAssertEqual(fall.days.count, 25)
        XCTAssertEqual(fall.dailyTotals[2], 3)
        XCTAssertEqual(fall.startedHours, 25)
    }

    func testFutureHoursAreNotStartedAndDayPointsStayOut() {
        let utc = calendar("UTC")
        let snap = UsageHistorySnapshot(
            points: [UsageHistoryPoint(day: "2026-03-10", service: "droid", accountID: nil, tokens: 500, costUSD: nil)],
            today: "2026-03-10", slots: [slot("2026-03-10T00:10:00Z", tokens: 4)])
        let summary = snap.summary(period: .today, grouping: .model, now: date("2026-03-10T00:20:00Z"), calendar: utc)
        XCTAssertEqual(summary.startedHours, 1)
        XCTAssertEqual(summary.totals.tokens, 4, "daily-only sources are not in the hourly view")
        XCTAssertNil(snap.summary(period: .week, grouping: .model).startedHours)
    }

    // MARK: Ledger

    private func ledgerURL() -> URL { root.appending(path: "activity/daily.sqlite") }

    private func ledger() throws -> CodexUsageStatisticsCache {
        try CodexUsageStatisticsCache(databaseURL: root.appending(path: "cache/usage.sqlite"),
                                      activityDatabaseURL: ledgerURL())
    }

    private func query(_ sql: String) -> [String] {
        var db: OpaquePointer?
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        guard sqlite3_open(ledgerURL().path, &db) == SQLITE_OK,
              sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return ["error"] }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map {
                sqlite3_column_text(statement, $0).map { String(cString: $0) } ?? "null"
            }.joined(separator: "|"))
        }
        return rows
    }

    private func exec(_ sql: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(ledgerURL().path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
    }

    private func writeHome(at times: [Date]) throws -> URL {
        let home = root.appending(path: "codex")
        let url = home.appending(path: "sessions/alpha.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        var records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "alpha", "cwd": "/Projects/alpha"]],
            ["type": "turn_context", "payload": ["model": "gpt-5.1-codex", "cwd": "/ignored"]],
        ]
        for (index, time) in times.enumerated() {
            let total = Int64(index + 1) * 100
            records.append(["timestamp": formatter.string(from: time), "type": "event_msg", "payload": [
                "type": "token_count", "info": ["total_token_usage": [
                    "input_tokens": total, "cached_input_tokens": 0, "output_tokens": 0, "total_tokens": total]]]])
        }
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            data.append(0x0A)
        }
        try data.write(to: url)
        return home
    }

    func testTranscriptsFillQuarterRowsAndOldSchemaMigratesAdditively() async throws {
        let now = Date()
        let home = try writeHome(at: [now.addingTimeInterval(-7_200), now.addingTimeInterval(-60)])
        let first = try ledger()
        let index = ChatHistoryIndex(home: home, cacheFile: root.appending(path: "chat.json"))
        await index.attachActivityCache(first)
        _ = try await index.refresh()
        let nowQuarter = Int64(now.timeIntervalSince1970 / 900)
        let quarters = try await first.threadQuarters(from: nowQuarter - 96, through: nowQuarter)
        XCTAssertEqual(quarters.map(\.tokens).reduce(0, +), 200)
        XCTAssertEqual(Set(quarters.map(\.model)), ["gpt-5.1-codex"])
        XCTAssertEqual(Set(quarters.map(\.project)), ["/Projects/alpha"])

        // Turn the database into the old schema an earlier build wrote: no quarter table.
        exec("DROP TABLE thread_quarters")
        let tables = "SELECT name FROM sqlite_master WHERE type = 'table' AND name != 'thread_quarters' ORDER BY name"
        let dump = ["SELECT * FROM project_days ORDER BY 1, 2", "SELECT * FROM activity_threads ORDER BY 1",
                    "SELECT * FROM account_days ORDER BY 1, 2", tables]
        let before = dump.map(query)
        XCTAssertEqual(query("PRAGMA user_version"), ["3"])

        let migrated = try ledger()
        XCTAssertEqual(dump.map(query), before, "old rows stay exactly as they were")
        XCTAssertEqual(query("PRAGMA user_version"), ["3"], "an older build still opens it")
        XCTAssertEqual(query("SELECT count(*) FROM thread_quarters"), ["0"])
        let empty = try await migrated.threadQuarters(from: nowQuarter - 96, through: nowQuarter)
        XCTAssertTrue(empty.isEmpty)

        // Reopening again (as an older build or this one) changes nothing.
        _ = try ledger()
        XCTAssertEqual(dump.map(query), before)
    }
}
