import Foundation
import XCTest
@testable import AIManagerCore

final class ClaudeCostScanTests: XCTestCase {
    private var root: URL!
    private var projects: URL!
    private var cacheURL: URL!
    private let now = Date(timeIntervalSince1970: 1_773_144_000) // 2026-03-10T12:00:00Z
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private let sonnet = ModelRate(
        input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3,
        inputAbove200k: 6, outputAbove200k: 22.5, cacheWriteAbove200k: 7.5, cacheReadAbove200k: 0.6)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "ClaudeCostScanTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        projects = root.appending(path: "projects/-proj", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        cacheURL = root.appending(path: "cache/claude-cost.json")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: Helpers

    private func line(_ time: String = "2026-03-10T10:00:00Z", id: String? = "msg-1", request: String? = "req-1",
                      model: String = "claude-sonnet-4-5", input: Int = 1000, output: Int = 500,
                      usageExtra: String = "", top: String = "") -> String {
        let ids = id.map { #""id":"\#($0)","# } ?? ""
        let req = request.map { #""requestId":"\#($0)","# } ?? ""
        return #"{"timestamp":"\#(time)",\#(req)\#(top)"message":{\#(ids)"model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output)\#(usageExtra)}}}"#
    }

    @discardableResult
    private func write(_ lines: [String], to name: String = "session.jsonl") throws -> URL {
        let url = projects.appending(path: name)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private func scanner(rates: [String: ModelRate]? = nil, roots: [URL]? = nil) -> ClaudeCostScanner {
        let table = rates ?? ["claude-sonnet-4-5": sonnet]
        return ClaudeCostScanner(roots: roots ?? [root.appending(path: "projects")], cacheURL: cacheURL,
                                 pricing: { table }, calendar: utc)
    }

    private func money(_ input: Int, _ output: Int) -> Double {
        Double(input) * 3 / 1e6 + Double(output) * 15 / 1e6
    }

    // MARK: Records and dedupe

    func testDuplicateLinesAndSidechainReplayCountOnce() async throws {
        try write([
            line(id: "a", request: "r1"),
            line(id: "a", request: "r1"),                                   // exact duplicate
            line(id: "b", request: "r2", top: #""isSidechain":true,"#),     // sidechain replay first...
            line(id: "b", request: "r3", input: 1000, output: 500),         // ...parent under another request
            line(id: nil, request: nil),                                    // no message id: always kept
            line(id: nil, request: nil),
            "not json with \"usage\":{ inside",
            #"{"timestamp":"2026-03-10T10:00:00Z","message":{"model":"x"}}"#, // no usage
        ])
        let days = try await scanner().daily(now: now)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].date, "2026-03-10")
        XCTAssertEqual(days[0].inputTokens, 4 * 1000)  // a, b, and two id-less lines
        XCTAssertEqual(days[0].outputTokens, 4 * 500)
        XCTAssertEqual(try XCTUnwrap(days[0].costUSD), 4 * money(1000, 500), accuracy: 1e-9)
        XCTAssertEqual(days[0].unpricedModels, [])
    }

    func testDedupeKeepsLargerTotalAndInvalidLinesAreSkipped() async throws {
        try write([
            line(id: "a", request: "r1", input: 100, output: 10),
            line(id: "a", request: "r1", input: 1000, output: 500),         // cumulative re-emit wins
            line(id: "c", request: "r9", top: #""version":"unknown","#),    // bad version
            line(id: "d", request: "r8", usageExtra: #","speed":"turbo""#), // bad speed
            line(id: "e", request: "r7", usageExtra: #","cache_read_input_tokens":null"#),
            line(id: "", request: "r6"),                                    // empty id
        ])
        let days = try await scanner().daily(now: now)
        XCTAssertEqual(days.first?.inputTokens, 1000)
        XCTAssertEqual(days.first?.outputTokens, 500)
    }

    func testSyntheticModelCountsTokensAtZeroCost() async throws {
        try write([line(id: "s", request: "r", model: "<synthetic>", input: 7, output: 3)])
        let pricingCalls = Counter()
        let scanner = ClaudeCostScanner(
            roots: [root.appending(path: "projects")], cacheURL: cacheURL,
            pricing: { pricingCalls.bump(); return [:] }, calendar: utc)
        let days = try await scanner.daily(now: now)
        XCTAssertEqual(days.first?.inputTokens, 7)
        XCTAssertEqual(days.first?.costUSD, 0)
        XCTAssertEqual(days.first?.unpricedModels, [])
        XCTAssertEqual(pricingCalls.value, 0)
    }

    func testCacheSplitFastAndLegacyCreation() async throws {
        try write([
            line(id: "split", request: "r1", input: 0, output: 0, usageExtra: """
            ,"cache_read_input_tokens":10000,"cache_creation_input_tokens":3000,\
            "cache_creation":{"ephemeral_5m_input_tokens":1000,"ephemeral_1h_input_tokens":2000}
            """),
            line(id: "legacy", request: "r2", input: 0, output: 0, usageExtra: #","cache_creation_input_tokens":4000"#),
        ])
        let days = try await scanner().daily(now: now)
        let day = try XCTUnwrap(days.first)
        XCTAssertEqual(day.cacheReadTokens, 10000)
        XCTAssertEqual(day.cacheWriteTokens, 3000 + 4000)
        // 5m at 3.75, 1h at 2x input = 6, legacy all 5m, read at 0.3.
        let expected = (1000 * 3.75 + 2000 * 6 + 10000 * 0.3 + 4000 * 3.75) / 1e6
        XCTAssertEqual(try XCTUnwrap(day.costUSD), expected, accuracy: 1e-9)

        let fastRate = ModelRate(input: 3, output: 15, fastMultiplier: 2)
        XCTAssertEqual(fastRate.cost(input: 1_000_000, output: 0, cacheRead: 0, cacheWrite5m: 0,
                                     cacheWrite1h: 0, fast: true), 6, accuracy: 1e-9)
        // Defaults: cache write 1.25x, cache read 0.1x input.
        XCTAssertEqual(fastRate.cacheWritePerMillion, 3.75, accuracy: 1e-9)
        XCTAssertEqual(fastRate.cacheReadPerMillion, 0.3, accuracy: 1e-9)
    }

    func testLongContextTierBillsWholeRequest() async throws {
        try write([line(id: "big", request: "r", input: 150_000, output: 1000,
                        usageExtra: #","cache_read_input_tokens":60000"#)])
        let days = try await scanner().daily(now: now)
        let expected = (150_000 * 6.0 + 1000 * 22.5 + 60_000 * 0.6) / 1e6
        XCTAssertEqual(try XCTUnwrap(days.first?.costUSD), expected, accuracy: 1e-9)
    }

    func testUnpricedModelListedAndCarriedCostWins() async throws {
        try write([
            line(id: "a", request: "r1"),
            line(id: "b", request: "r2", model: "mystery-model-x"),
            line(id: "c", request: "r3", model: "mystery-model-y", top: #""costUSD":0.25,"#),
        ])
        let days = try await scanner().daily(now: now)
        let day = try XCTUnwrap(days.first)
        XCTAssertEqual(day.unpricedModels, ["mystery-model-x"])
        XCTAssertEqual(try XCTUnwrap(day.costUSD), money(1000, 500) + 0.25, accuracy: 1e-9)
        XCTAssertEqual(day.inputTokens, 3000)

        try write([line(id: "z", request: "q", model: "mystery-model-x")], to: "session.jsonl")
        let only = try await scanner().daily(now: now)
        XCTAssertNil(only.first?.costUSD)
        XCTAssertEqual(only.first?.unpricedModels, ["mystery-model-x"])
    }

    func testAdvisorIterationBecomesItsOwnModelEntry() async throws {
        try write([line(id: "m", request: "r", usageExtra: """
        ,"iterations":[{"type":"message","model":null,"input_tokens":1,"output_tokens":1},\
        {"type":"advisor_message","model":"mystery-advisor","input_tokens":200,"output_tokens":50}]
        """)])
        let days = try await scanner().daily(now: now)
        XCTAssertEqual(days.first?.inputTokens, 1200)
        XCTAssertEqual(days.first?.unpricedModels, ["mystery-advisor"])
    }

    // MARK: Days and window

    func testLocalDayBucketingAndWindow() async throws {
        try write([
            line("2026-03-10T03:00:00Z", id: "a", request: "1"),
            line("2026-03-09T23:30:00Z", id: "b", request: "2"),
            line("2026-03-09T09:00:00.250Z", id: "c", request: "3"),
            line("2026-03-07T12:00:00Z", id: "old", request: "4"),
        ])
        var west = Calendar(identifier: .gregorian)
        west.timeZone = TimeZone(secondsFromGMT: -8 * 3600)!
        let scanner = ClaudeCostScanner(roots: [root.appending(path: "projects")], cacheURL: cacheURL,
                                        pricing: { ["claude-sonnet-4-5": self.sonnet] }, calendar: west)
        // Local (UTC-8) now = 2026-03-10 04:00. Day 03-10 holds nothing before 08:00Z; 03:00Z is 03-09 19:00.
        let days = try await scanner.daily(days: 2, now: now)
        XCTAssertEqual(days.map(\.date), ["2026-03-09"])
        XCTAssertEqual(days.first?.inputTokens, 3000)

        let wide = try await scanner.daily(days: 30, now: now)
        XCTAssertEqual(wide.map(\.date), ["2026-03-07", "2026-03-09"])
    }

    func testOldFilesAreNotRead() async throws {
        let url = try write([line(id: "a", request: "1")])
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-90 * 86_400)], ofItemAtPath: url.path)
        let scanner = scanner()
        let days = try await scanner.daily(now: now)
        XCTAssertEqual(days, [])
        let parsed = await scanner.filesParsed
        XCTAssertEqual(parsed, 0)
    }

    // MARK: Incremental cache

    func testSecondRunServesUnchangedFilesFromCache() async throws {
        let url = try write([line(id: "a", request: "1"), line(id: "b", request: "2")])
        // Whole-second mtime so restoring it later is exact.
        let fixed = Date(timeIntervalSince1970: 1_773_100_000)
        try FileManager.default.setAttributes([.modificationDate: fixed], ofItemAtPath: url.path)
        let first = scanner()
        let one = try await first.daily(now: now)
        let parsedFirst = await first.filesParsed
        XCTAssertEqual(parsedFirst, 1)

        // A new scanner has no memory; only the cache file can answer. Same size and mtime,
        // different bytes: a re-read would give different tokens.
        let original = try Data(contentsOf: url)
        try Data(repeating: UInt8(ascii: "x"), count: original.count).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: fixed], ofItemAtPath: url.path)

        let second = scanner()
        let two = try await second.daily(now: now)
        let parsedSecond = await second.filesParsed
        XCTAssertEqual(parsedSecond, 0)
        XCTAssertEqual(one, two)

        // A changed file is parsed again.
        try write([line(id: "a", request: "1")])
        let third = scanner()
        let changed = try await third.daily(now: now)
        let parsedThird = await third.filesParsed
        XCTAssertEqual(parsedThird, 1)
        XCTAssertEqual(changed.first?.inputTokens, 1000)
    }

    func testCacheStoresEventsNotDollarsWithPrivateMode() async throws {
        try write([line(id: "a", request: "1")])
        let first = try await scanner(rates: ["claude-sonnet-4-5": sonnet]).daily(now: now)
        let permissions = try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, ClaudeCostScanner.cacheVersion)
        // Repricing from the cached events: a different rate changes the cost without re-reading.
        let cheaper = ModelRate(input: 1, output: 1)
        let second = scanner(rates: ["claude-sonnet-4-5": cheaper])
        let repriced = try await second.daily(now: now)
        let parsedSecond = await second.filesParsed
        XCTAssertEqual(parsedSecond, 0)
        XCTAssertNotEqual(first.first?.costUSD, repriced.first?.costUSD)
        XCTAssertEqual(try XCTUnwrap(repriced.first?.costUSD), 1500.0 / 1e6, accuracy: 1e-12)
    }

    func testOversizeLineSkippedAndSymlinkedRootsCountOnce() async throws {
        let huge = String(repeating: "a", count: ClaudeLogParser.maxLineBytes + 10)
        try write([line(id: "big", request: "1", usageExtra: #","pad":"\#(huge)""#), line(id: "ok", request: "2")])
        // The same directory through a profile-style symlinked `projects` and the real path.
        let profile = root.appending(path: "profile", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: profile.appending(path: "projects"), withDestinationURL: root.appending(path: "projects"))
        let scanner = scanner(roots: [root.appending(path: "projects"), profile, profile.appending(path: "projects")])
        let days = try await scanner.daily(now: now)
        XCTAssertEqual(days.first?.inputTokens, 1000)
        let parsed = await scanner.filesParsed
        XCTAssertEqual(parsed, 1)
    }

    // MARK: Pricing

    func testModelNameResolution() {
        var table = ModelRateTable([
            "claude-sonnet-4-5": ModelRate(input: 3, output: 15),
            "claude-sonnet-4": ModelRate(input: 30, output: 150),
            "claude-opus-4-1": ModelRate(input: 15, output: 75),
            "bedrock/anthropic.claude-haiku-4-5-20251001-v1:0": ModelRate(input: 1, output: 5),
        ])
        XCTAssertEqual(table.resolve("claude-sonnet-4-5")?.inputPerMillion, 3)
        XCTAssertEqual(table.resolve("claude-sonnet-4-5-20250929")?.inputPerMillion, 3)
        XCTAssertEqual(table.resolve("anthropic/claude-sonnet-4.5")?.inputPerMillion, 3)
        XCTAssertEqual(table.resolve("claude-sonnet-4-20250514")?.inputPerMillion, 30)
        XCTAssertEqual(table.resolve("claude-opus-4-1@20250805")?.inputPerMillion, 15)
        XCTAssertEqual(table.resolve("claude-haiku-4-5")?.inputPerMillion, 1)
        XCTAssertEqual(table.resolve("claude-opus-4-6[1m]")?.inputPerMillion, nil)

        // claude-sonnet-4 must not resolve to the claude-sonnet-4-5 entry.
        var onlyFive = ModelRateTable(["claude-sonnet-4-5": ModelRate(input: 3, output: 15)])
        XCTAssertNil(onlyFive.resolve("claude-sonnet-4"))
        XCTAssertNil(onlyFive.resolve("claude-sonnet-4-20250514"))
        XCTAssertNil(onlyFive.resolve("totally-unknown"))
    }

    func testCatalogParsing() throws {
        let rates = ModelRate.catalog(from: Data(#"""
        {
          "sample_spec": {"max_tokens": "x"},
          "claude-sonnet-4-5": {
            "input_cost_per_token": 3e-6, "output_cost_per_token": 1.5e-5,
            "cache_creation_input_token_cost": 3.75e-6, "cache_read_input_token_cost": 3e-7,
            "input_cost_per_token_above_200k_tokens": 6e-6, "output_cost_per_token_above_200k_tokens": 2.25e-5,
            "provider_specific_entry": {"fast": 2.5}
          },
          "no-output": {"input_cost_per_token": 1e-6},
          "plain": {"input_cost_per_token": 1e-6, "output_cost_per_token": 2e-6}
        }
        """#.utf8))
        XCTAssertEqual(Set(rates.keys), ["claude-sonnet-4-5", "plain"])
        let sonnet = try XCTUnwrap(rates["claude-sonnet-4-5"])
        XCTAssertEqual(sonnet.inputPerMillion, 3, accuracy: 1e-9)
        XCTAssertEqual(sonnet.cacheReadPerMillion, 0.3, accuracy: 1e-9)
        XCTAssertEqual(sonnet.inputAbove200k ?? 0, 6, accuracy: 1e-9)
        XCTAssertNil(sonnet.cacheReadAbove200k)
        XCTAssertEqual(sonnet.fastMultiplier, 2.5)
        let plain = try XCTUnwrap(rates["plain"])
        XCTAssertEqual(plain.cacheWritePerMillion, 1.25, accuracy: 1e-9)
        XCTAssertEqual(plain.cacheReadPerMillion, 0.1, accuracy: 1e-9)
        XCTAssertEqual(ModelRate.catalog(from: Data("[]".utf8)), [:])
    }

    func testPricingSourceUsesCacheThenStaleOffline() async throws {
        let catalog = Data(#"{"claude-x":{"input_cost_per_token":1e-6,"output_cost_per_token":2e-6}}"#.utf8)
        let cache = root.appending(path: "pricing/model-pricing.json")
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let fetches = Counter()
        let online = ClaudePricingSource(cacheURL: cache, now: { clock.date }, fetch: { url in
            XCTAssertEqual(url, CodexAPIPricingResolver.catalogURL)
            fetches.bump()
            return catalog
        })
        let first = await online.rates()
        XCTAssertEqual(first["claude-x"]?.outputPerMillion, 2)
        _ = await online.rates()
        XCTAssertEqual(fetches.value, 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)

        // 48 h later with no network: the stale file still prices.
        clock.date = clock.date.addingTimeInterval(48 * 3600)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)], ofItemAtPath: cache.path)
        let offline = ClaudePricingSource(cacheURL: cache, now: { clock.date }, fetch: { _ in
            throw URLError(.notConnectedToInternet)
        })
        let stale = await offline.rates()
        XCTAssertEqual(stale["claude-x"]?.inputPerMillion, 1)

        let empty = ClaudePricingSource(cacheURL: root.appending(path: "none.json"), fetch: { _ in
            throw URLError(.notConnectedToInternet)
        })
        let nothing = await empty.rates()
        XCTAssertEqual(nothing, [:])
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var date: Date {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}
