import XCTest
@testable import AIManagerCore

/// Synthetic fixtures only. OpenUsage 1bfd3175 (merged Cursor, X and Grok pool), CodexBar 43f3c2805
/// (Tokscale spend cache) and the Grok part of CodexBar 94cc400e1 ($0 prepaid wallet).
final class UpstreamCursorMergedGrokTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }

    // MARK: Merged weekly pool

    private let usage = #"{"enabled":true,"billingCycleStart":1780000000000,"billingCycleEnd":1780604800000,"planUsage":{"limit":2000,"totalPercentUsed":40,"autoPercentUsed":30,"apiPercentUsed":10},"spendLimitUsage":{"individualLimit":5000,"individualUsed":700}}"#
    private let grokBot = #"{"usagePercent":12,"hasNonZeroIncludedLimit":true}"#

    private func merged(credits: String?, status: String?) throws -> ProviderUsage {
        try CursorUsage.map(
            usage: json(usage), plan: json(#"{"planInfo":{"planName":"Pro"},"isMerged":true}"#),
            credits: json(#"{"hasCreditGrants":true,"totalCents":9000,"usedCents":0}"#), membership: "pro", email: nil,
            grokBot: json(grokBot), stripeCents: 500,
            merged: CursorUsage.Merged(credits: credits.map { try json($0) }, status: status.map { try json($0) }))
    }

    func testMergedAccountShowsOnePoolCreditsAndCappedExtraUsage() throws {
        let mapped = try merged(
            credits: #"{"usdRemainingCents":1234}"#,
            status: #"{"availability":"available","monthlyUsage":{"usedCents":250,"limitCents":2000,"resetsAt":"2026-12-01T00:00:00Z"}}"#)
        XCTAssertEqual(mapped.windows.map(\.id), ["total"], "No Cursor models, Other models or Grok Bot rows")
        XCTAssertEqual(mapped.windows.first?.usedPercent, 40)
        XCTAssertEqual(mapped.cost?.balance, 12.34, "Credits replace grants and the Stripe balance")
        XCTAssertEqual(mapped.cost?.used, 2.5)
        XCTAssertEqual(mapped.cost?.limit, 20)
        XCTAssertEqual(mapped.cost?.period, "Extra usage")
        XCTAssertNotNil(mapped.cost?.resetsAt)
    }

    func testMergedUncappedDisabledAndZeroCredit() throws {
        let uncapped = try merged(credits: #"{"usdRemainingCents":0}"#, status: #"{"monthlyUsage":{"usedCents":0}}"#)
        XCTAssertEqual(uncapped.cost?.balance, 0, "A $0 credit balance stays visible")
        XCTAssertEqual(uncapped.cost?.used, 0, "Uncapped extra usage shows its amount even at $0")
        XCTAssertNil(uncapped.cost?.limit)
        XCTAssertNil(uncapped.cost?.resetsAt)
        for off in [#"{"monthlyUsage":{"usedCents":90,"limitCents":2000,"additionalUsageOff":true}}"#,
                    #"{"monthlyUsage":{"usedCents":90,"limitCents":0}}"#,
                    #"{"availability":"unavailable","monthlyUsage":{"usedCents":90,"limitCents":2000}}"#] {
            let mapped = try merged(credits: #"{"usdRemainingCents":100}"#, status: off)
            XCTAssertNil(mapped.cost?.used, off)
            XCTAssertNil(mapped.cost?.period, off)
            XCTAssertEqual(mapped.cost?.balance, 1, off)
        }
        XCTAssertNil(try merged(credits: nil, status: nil).cost)
    }

    func testNonMergedAccountIsUnchanged() throws {
        let mapped = try CursorUsage.map(
            usage: json(usage), plan: json(#"{"planInfo":{"planName":"Pro"}}"#),
            credits: json(#"{"hasCreditGrants":true,"totalCents":9000,"usedCents":0}"#), membership: "pro", email: nil,
            grokBot: json(grokBot), stripeCents: 500)
        XCTAssertEqual(mapped.windows.map(\.id), ["total", "auto", "api", "grok-bot"])
        XCTAssertEqual(mapped.cost?.balance, 95)
        XCTAssertEqual(mapped.cost?.used, 7)
        XCTAssertEqual(mapped.cost?.period, "On-demand")
    }

    // MARK: Tokscale spend cache

    private func cache(_ text: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tokscale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("usage.json")
        try Data(text.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return url
    }

    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private var ms: Int { Int(now.timeIntervalSince1970 * 1000) - 60_000 }

    func testRepeatedEventIDsCountOnceAndKeepTheLargestSnapshot() throws {
        let url = try cache("""
        {"usageEventsDisplay":[
          {"usageEventId":"evt-1","conversationId":"c1","timestamp":"\(ms)","model":"gpt","tokenUsage":{"inputTokens":100,"totalCents":10}},
          {"usageEventId":"evt-1","conversationId":"c1","timestamp":"\(ms)","model":"gpt","tokenUsage":{"inputTokens":300,"totalCents":30}},
          {"usageEventId":"evt-2","conversationId":"c2","timestamp":\(ms),"model":"gpt","tokenUsage":{"outputTokens":50,"totalCents":5}},
          ["c1","\(ms)","gpt",null,[300,0,0,0,30]],
          ["c3",\(ms),"claude","20",{"inputTokens":"7"}]
        ]}
        """)
        let report = try XCTUnwrap(CursorUsage.tokscaleSpend(at: url, now: now))
        let today = try XCTUnwrap(report.section?.rows.first { $0.label == "Today" })
        // evt-1 once at 300 tokens and 30 cents (its id-less copy joins it), evt-2, and the id-less claude row.
        XCTAssertEqual(today.value, "$0.55 \u{00B7} 357 tokens")
    }

    func testBadRowKeepsTokensButDropsDollarsAndTagsMustAgree() throws {
        let partial = try cache(#"{"usageEventsDisplay":[{"timestamp":"\#(ms)","model":"gpt","tokenUsage":{"inputTokens":10,"totalCents":4}},{"model":"no-time"}]}"#)
        let today = try XCTUnwrap(CursorUsage.tokscaleSpend(at: partial, now: now)?.section?.rows.first)
        XCTAssertEqual(today.value, "10 tokens")
        let hash = CoreSupport.digest(Data("acct-1".utf8)), generation = UUID().uuidString
        let rows = #""usageEventsDisplay":[{"timestamp":"\#(ms)","model":"gpt","tokenUsage":{"inputTokens":10}}]"#
        let good = try cache(#"{"_tokscale":{"version":1,"accountId":"acct-1"},"_owner":{"version":1,"ownerHash":"\#(hash)","generation":"\#(generation)"},\#(rows),"zzTokscaleOwner":{"version":1,"generation":"\#(generation)"}}"#)
        XCTAssertNotNil(CursorUsage.tokscaleSpend(at: good, now: now))
        let torn = try cache(#"{"_tokscale":{"version":1,"accountId":"acct-1"},"_owner":{"version":1,"ownerHash":"\#(hash)","generation":"\#(generation)"},\#(rows),"zzTokscaleOwner":{"version":1,"generation":"\#(UUID().uuidString)"}}"#)
        XCTAssertNil(CursorUsage.tokscaleSpend(at: torn, now: now))
        XCTAssertNil(CursorUsage.tokscaleSpend(at: URL(fileURLWithPath: "/nonexistent/usage.json"), now: now))
    }

    // MARK: Grok prepaid wallet

    func testGrokReportedZeroPrepaidBalanceStaysVisible() throws {
        let zero = try GrokBuildUsage.map(billing: json(#"{"config":{"prepaidBalance":{"val":0}}}"#))
        XCTAssertEqual(zero.cost?.balance, 0)
        XCTAssertNil(try GrokBuildUsage.map(billing: json(#"{"config":{}}"#)).cost, "A missing balance stays unknown")
    }
}
