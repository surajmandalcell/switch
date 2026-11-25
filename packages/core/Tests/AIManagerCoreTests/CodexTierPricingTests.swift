import CSQLite
import Foundation
import XCTest
@testable import AIManagerCore

final class CodexTierPricingTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_773_144_000) // 2026-03-10T12:00:00Z

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "CodexTierPricingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func ledger() throws -> CodexUsageStatisticsCache {
        try CodexUsageStatisticsCache(
            databaseURL: root.appending(path: "cache/usage.sqlite"),
            activityDatabaseURL: root.appending(path: "activity/daily.sqlite"))
    }

    private func write(_ records: [[String: Any]], name: String) throws -> URL {
        let home = root.appending(path: "codex")
        let url = home.appending(path: "sessions/\(name).jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            data.append(0x0A)
        }
        try data.write(to: url)
        return home
    }

    private func settings(_ tier: String) -> [String: Any] {
        ["type": "event_msg", "payload": ["type": "thread_settings_applied", "thread_settings": ["service_tier": tier]]]
    }

    private func tokens(_ input: Int64, cached: Int64, output: Int64, at time: String) -> [String: Any] {
        ["timestamp": time, "type": "event_msg", "payload": [
            "type": "token_count", "info": ["total_token_usage": [
                "input_tokens": input, "cached_input_tokens": cached, "output_tokens": output,
                "total_tokens": input + output]]]]
    }

    private func factors(_ model: String, _ tier: String?, input: Int64, at date: Date = Date(timeIntervalSince1970: 0))
        -> [Double] {
        let f = CodexRequestPricing.multipliers(model: model, tier: tier, date: date, input: input)
        return [f.input, f.cached, f.output]
    }

    func testFastIsDoubleForTerraAndLunaOnBothSidesOfLongContext() {
        for model in ["gpt-6.1-terra", "openai/gpt-6.1-terra-2099-01-01", "gpt-6-luna", "openai/gpt-6-luna-2099-01-01"] {
            XCTAssertEqual(factors(model, nil, input: 272_000), [1, 1, 1], model)
            XCTAssertEqual(factors(model, "priority", input: 272_000), [2, 2, 2], model)
            XCTAssertEqual(factors(model, nil, input: 272_001), [2, 2, 1.5], model)
            XCTAssertEqual(factors(model, "priority", input: 272_001), [4, 4, 3], model)
        }
        // Models without published long-context Fast rates keep standard pricing above 272K.
        XCTAssertEqual(factors("gpt-5.6-sol", "priority", input: 300_000), [2, 2, 1.5])
        XCTAssertEqual(factors("gpt-5.6-sol", "priority", input: 1_000), [2, 2, 2])
    }

    func testUltrafastFollowsModelAndPromotionDate() {
        let before = Date(timeIntervalSince1970: 1_803_887_999)
        let end = CodexRequestPricing.ultrafastPromotionEnd
        XCTAssertEqual(end, ISO8601DateFormatter().date(from: "2027-03-01T08:00:00Z"))
        for model in ["gpt-6.2-sol", "gpt-6.2-astra"] {
            XCTAssertEqual(factors(model, "ultrafast", input: 1_000, at: before), [3, 3, 3], model)
            XCTAssertEqual(factors(model, "ultrafast", input: 1_000, at: end), [6, 6, 6], model)
            XCTAssertEqual(factors(model, "ultrafast", input: 300_000, at: before), [6, 6, 4.5], model)
        }
        XCTAssertEqual(factors("gpt-6.1-sol", "ultrafast", input: 1_000, at: before), [6, 6, 6])
        XCTAssertEqual(factors("gpt-5.4", "ultrafast", input: 1_000, at: before), [1, 1, 1])
    }

    func testResolverFallsBackToTerraListPrice() async throws {
        let resolver = CodexAPIPricingResolver(cacheURL: root.appending(path: "pricing.json")) { _ in
            Data(#"{"gpt-5.6-sol":{"litellm_provider":"openai","input_cost_per_token":0.000004,"output_cost_per_token":0.00002}}"#.utf8)
        }
        let price = try await resolver.price(for: "gpt-6.1-terra")
        XCTAssertEqual(price, CodexAPIPrice(model: "gpt-6.1-terra", inputPerMillion: 1, cachedInputPerMillion: 0.05,
                                            outputPerMillion: 5))
        let offline = CodexAPIPricingResolver(cacheURL: root.appending(path: "none.json")) { _ in
            throw URLError(.notConnectedToInternet)
        }
        let offlinePrice = try await offline.price(for: "gpt-6-luna")
        XCTAssertEqual(offlinePrice?.inputPerMillion, 0.1)
    }

    func testTranscriptTierPricesTerraFastLongContextAndSurvivesReopen() async throws {
        let home = try write([
            ["type": "session_meta", "payload": ["id": "terra", "cwd": "/Projects/terra"]],
            ["type": "turn_context", "payload": ["model": "gpt-6.1-terra"]],
            settings("priority"),
            tokens(300_000, cached: 100_000, output: 1_000, at: "2026-03-10T09:00:00Z"),
            settings("default"),
            tokens(301_000, cached: 100_000, output: 1_100, at: "2026-03-10T09:05:00Z"),
        ], name: "terra")
        let ledger = try ledger()
        let index = ChatHistoryIndex(home: home)
        await index.attachActivityCache(ledger)
        _ = try await index.refresh()

        // Fast long context: 4x input, 4x cached, 3x output; then one standard short request.
        let rows = try await ledger.threadDays(from: "2026-03-10", through: "2026-03-10")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first.map { [$0.billedInput, $0.billedCached, $0.billedOutput] }, [801_000, 400_000, 3_100])

        // No catalog rate for Terra: the list price ($1 / $0.05 / $5) prices it.
        let history = UsageHistory(sources: .init(ledger: ledger, pricing: { [:] }))
        let snap = await history.snapshot(now: now)
        let cost = snap.summary(period: .week, grouping: .model).groups.first?.costUSD
        XCTAssertEqual(try XCTUnwrap(cost), (801_000 + 400_000 * 0.05 + 3_100 * 5) / 1e6, accuracy: 1e-9)

        let reopened = try await self.ledger().threadDays(from: "2026-03-10", through: "2026-03-10")
        XCTAssertEqual(reopened, rows)
    }

    func testUltrafastSwitchesRateAtPromotionEnd() async throws {
        let home = try write([
            ["type": "session_meta", "payload": ["id": "ultra", "cwd": "/Projects/ultra"]],
            ["type": "turn_context", "payload": ["model": "gpt-6.2-sol"]],
            settings("ultrafast"),
            tokens(800, cached: 600, output: 200, at: "2027-03-01T07:59:59Z"),
            tokens(1_600, cached: 1_200, output: 400, at: "2027-03-01T08:00:00Z"),
        ], name: "ultra")
        let ledger = try ledger()
        let index = ChatHistoryIndex(home: home)
        await index.attachActivityCache(ledger)
        _ = try await index.refresh()
        let row = try await ledger.threadDays(from: "2027-03-01", through: "2027-03-01").first
        // Each request: 200 uncached, 600 cached, 200 output; 3x then 6x.
        XCTAssertEqual(row.map { [$0.billedInput, $0.billedCached, $0.billedOutput] }, [1_800, 5_400, 1_800])
    }

    func testVersionThreeLedgerReadsOldRowsAsStandard() async throws {
        let url = root.appending(path: "activity/daily.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
            CREATE TABLE activity_threads(thread_id TEXT PRIMARY KEY NOT NULL, project TEXT NOT NULL,
                first_event TEXT NOT NULL, event_count INTEGER NOT NULL, total_tokens INTEGER NOT NULL,
                complete INTEGER NOT NULL) WITHOUT ROWID;
            CREATE TABLE model_days(thread_id TEXT NOT NULL, day TEXT NOT NULL, model TEXT NOT NULL,
                tokens INTEGER NOT NULL CHECK(tokens >= 0),
                input INTEGER NOT NULL, cached INTEGER NOT NULL, output INTEGER NOT NULL,
                PRIMARY KEY(thread_id, day, model)) WITHOUT ROWID;
            CREATE TABLE thread_quarters(thread_id TEXT NOT NULL, quarter INTEGER NOT NULL, model TEXT NOT NULL,
                tokens INTEGER NOT NULL CHECK(tokens >= 0),
                input INTEGER NOT NULL, cached INTEGER NOT NULL, output INTEGER NOT NULL,
                PRIMARY KEY(thread_id, quarter, model)) WITHOUT ROWID;
            INSERT INTO activity_threads VALUES('codex:old', '/Projects/old', 'x', 1, 1100, 1);
            INSERT INTO model_days VALUES('codex:old', '2026-03-09', 'gpt-6.1-terra', 1100, 1000, 600, 100);
            PRAGMA user_version = 3;
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        let rows = try await ledger().threadDays(from: "2026-03-09", through: "2026-03-09")
        XCTAssertEqual(rows.first.map { [$0.billedInput, $0.billedCached, $0.billedOutput] }, [400, 600, 100])
        let reread = try await ledger().threadDays(from: "2026-03-09", through: "2026-03-09")
        XCTAssertEqual(reread, rows)
    }
}
