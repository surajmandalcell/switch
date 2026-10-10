import CSQLite
import Foundation
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import AIManagerCore

/// Parity tests for the "majors" providers. Fixtures come from the OpenUsage and CodexBar test suites.
final class ProvidersAuditMajorsTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }
    private func iso(_ text: String) -> Date { Fmt.iso(text)! }
    private func window(_ usage: ProviderUsage, _ id: String) -> UsageWindow? { usage.windows.first { $0.id == id } }
    private func rows(_ usage: ProviderUsage) -> [String: String] {
        Dictionary(usage.sections.flatMap(\.rows).map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Cursor

    func testCursorGrokBotWindowAndGuards() throws {
        let bot = try XCTUnwrap(CursorUsage.grokBotWindow(json("""
        {"usagePercent":37.5,"currentPeriodStart":"2026-08-20T00:00:00Z","nextResetTimestampUtc":"2026-08-27T00:00:00Z","hasNonZeroIncludedLimit":true}
        """)))
        XCTAssertEqual(bot.id, "grok-bot")
        XCTAssertEqual(bot.usedPercent, 37.5)
        XCTAssertEqual(bot.windowMinutes, 10_080)
        XCTAssertEqual(bot.resetsAt, iso("2026-08-27T00:00:00Z"))
        XCTAssertEqual(CursorUsage.grokBotWindow(try json(#"{"usagePercent":0}"#))?.usedPercent, 0)
        XCTAssertEqual(CursorUsage.grokBotWindow(try json(#"{"usagePercent":125}"#))?.usedPercent, 125)
        for body in [#"{"usagePercent":42,"usesPooledEnterpriseAllowance":true}"#,
                     #"{"usagePercent":0,"hasNonZeroIncludedLimit":false}"#,
                     #"{"usagePercent":0,"includedLimitZero":true}"#, #"{"usagePercent":true}"#,
                     #"{"usagePercent":-1}"#, #"{"hasNonZeroIncludedLimit":true}"#] {
            XCTAssertNil(CursorUsage.grokBotWindow(try json(body)), body)
        }
        // An unexpired trial counts but has no recurring reset.
        let now = iso("2026-08-01T00:00:00Z")
        let trial = try json(#"{"usagePercent":5,"includedLimitZero":true,"sandTrialExpiresAt":"2026-09-01T00:00:00Z","nextResetTimestampUtc":"2026-08-08T00:00:00Z"}"#)
        XCTAssertNil(CursorUsage.grokBotWindow(trial, now: now)?.resetsAt)
        XCTAssertNil(CursorUsage.grokBotWindow(trial, now: iso("2026-10-01T00:00:00Z")))
    }

    func testCursorMainPathAddsGrokBotCreditsAndStripeBalance() throws {
        let usage = try json("""
        {"billingCycleStart":"1770000000000","billingCycleEnd":"1772592000000","enabled":true,
         "planUsage":{"limit":2000,"remaining":1500,"totalSpend":500,"totalPercentUsed":25,"autoPercentUsed":10,"apiPercentUsed":40},
         "spendLimitUsage":{"limitType":"individual","individualLimit":5000,"individualRemaining":4000,"individualUsed":1000}}
        """)
        let credits = try json(#"{"hasCreditGrants":true,"totalCents":"1000","usedCents":"250"}"#)
        let bot = try json(#"{"usagePercent":37.5,"nextResetTimestampUtc":"2026-08-27T00:00:00Z","hasNonZeroIncludedLimit":true}"#)
        XCTAssertEqual(CursorUsage.stripeCents(try json(#"{"customerBalance":"-50000"}"#)), 50_000)
        XCTAssertEqual(CursorUsage.stripeCents(try json(#"{"customerBalance":100}"#)), 0)
        let mapped = try CursorUsage.map(usage: usage, plan: nil, credits: credits, membership: "pro", email: nil,
                                         grokBot: bot, stripeCents: 50_000)
        XCTAssertEqual(mapped.windows.map(\.id), ["total", "auto", "api", "grok-bot"])
        XCTAssertEqual(mapped.cost?.balance, 507.5)
        XCTAssertEqual(mapped.cost?.used, 10)
        XCTAssertEqual(mapped.cost?.limit, 50)
        // Credits can come from the Stripe balance alone.
        let stripeOnly = try CursorUsage.map(usage: usage, plan: nil, credits: json(#"{"hasCreditGrants":false}"#),
                                             membership: nil, email: nil, stripeCents: 50_000)
        XCTAssertEqual(stripeOnly.cost?.balance, 500)
    }

    func testCursorEnterpriseCombinesRequestsAndSummary() throws {
        let summary = try json("""
        {"billingCycleStart":"2026-07-01T00:00:00.000Z","billingCycleEnd":"2026-08-01T00:00:00.000Z",
         "membershipType":"enterprise","limitType":"team",
         "individualUsage":{"plan":{"enabled":true,"limit":0,"autoPercentUsed":0,"apiPercentUsed":6.25,"totalPercentUsed":6.25},
                            "onDemand":{"enabled":true,"used":0,"limit":25000,"remaining":25000}},
         "teamUsage":{"onDemand":{"enabled":true,"used":75000,"limit":600000,"remaining":525000}}}
        """)
        let requests = try json(#"{"gpt-4":{"numRequests":37,"numRequestsTotal":37,"maxRequestUsage":750},"startOfMonth":"2026-07-01T00:00:00.000Z"}"#)
        let usage = try json(#"{"enabled":true,"planUsage":{}}"#)
        let plan = try json(#"{"planInfo":{"planName":"Enterprise"}}"#)
        XCTAssertTrue(CursorUsage.wantsFallback(usage: usage, planName: "Enterprise", planInfoUnavailable: false))
        let mapped = try CursorUsage.map(usage: usage, plan: plan, credits: nil, membership: nil, email: nil,
                                         requests: requests, summary: summary)
        XCTAssertEqual(mapped.windows.map(\.id), ["total", "requests", "auto", "api"])
        XCTAssertEqual(mapped.windows[0].usedPercent ?? -1, 37.0 / 750 * 100, accuracy: 1e-9)
        XCTAssertEqual(mapped.windows[0].detail, "37 / 750 requests")
        XCTAssertEqual(mapped.windows[0].resetsAt, iso("2026-08-01T00:00:00Z"))
        XCTAssertEqual(mapped.windows[0].windowMinutes, 31 * 24 * 60)
        XCTAssertEqual(mapped.windows[3].usedPercent, 6.25)
        // The user-scoped on-demand bucket wins over the team aggregate: $250 cap.
        XCTAssertEqual(mapped.cost?.limit, 250)
        XCTAssertEqual(mapped.cost?.used, 0)
        XCTAssertEqual(mapped.plan, "Enterprise")
    }

    func testCursorTeamFallsBackToPooledTotalAndTeamOnDemand() throws {
        let summary = try json("""
        {"membershipType":"team","limitType":"team",
         "teamUsage":{"pooled":{"enabled":true,"used":125000,"limit":4000000,"remaining":3875000},
                      "onDemand":{"enabled":true,"used":50000,"limit":500000,"remaining":450000}}}
        """)
        let mapped = try CursorUsage.map(usage: json(#"{"enabled":true,"planUsage":{}}"#), plan: nil, credits: nil,
                                         membership: "team", email: nil, summary: summary)
        XCTAssertEqual(mapped.windows.first?.title, "Total usage")
        XCTAssertEqual(mapped.windows.first?.usedPercent ?? -1, 3.125, accuracy: 1e-9)
        XCTAssertEqual(mapped.windows.first?.detail, "$1,250.00 / $40,000.00")
        XCTAssertEqual(mapped.cost?.used, 500)
        XCTAssertEqual(mapped.cost?.limit, 5000)
        XCTAssertEqual(mapped.plan, "Team")
        // Neither payload usable -> an error, not an empty card.
        XCTAssertThrowsError(try CursorUsage.map(
            usage: json(#"{"enabled":true,"planUsage":{}}"#), plan: json(#"{"planInfo":{"planName":"Enterprise"}}"#),
            credits: nil, membership: nil, email: nil, requests: json(#"{"gpt-4":{"maxRequestUsage":0}}"#),
            summary: json(#"{"individualUsage":{"plan":{"limit":0}}}"#)))
    }

    func testCursorGenericRequestFallbackAddsRequestsWindow() throws {
        let usage = try json(#"{"enabled":true,"planUsage":{"remaining":0}}"#)
        let requests = try json(#"{"gpt-4":{"numRequests":19,"maxRequestUsage":300},"startOfMonth":"2026-07-01T00:00:00.000Z"}"#)
        XCTAssertTrue(CursorUsage.Facts(usage).wantsGenericRequestFallback)
        let mapped = try CursorUsage.map(usage: usage, plan: nil, credits: nil, membership: "pro", email: nil, requests: requests)
        XCTAssertEqual(mapped.windows.map(\.id), ["requests"])
        XCTAssertEqual(mapped.windows[0].usedPercent ?? -1, 19.0 / 300 * 100, accuracy: 1e-9)
        XCTAssertEqual(mapped.windows[0].resetsAt, iso("2026-07-01T00:00:00Z").addingTimeInterval(43_200 * 60))
    }

    func testCursorUsageEventsBecomeSpendRows() throws {
        let page = try json("""
        {"totalUsageEventsCount":3,"usageEventsDisplay":[
         {"timestamp":"1800000000123","model":"composer-1","tokenUsage":{"inputTokens":11,"outputTokens":17,"cacheWriteTokens":13,"cacheReadTokens":19,"totalCents":250}},
         {"timestamp":1799999990000,"model":"auto","tokenUsage":{"inputTokens":1000,"outputTokens":0,"totalCents":50}},
         {"timestamp":"1799900000000","model":"auto","tokenUsage":{"inputTokens":2000000,"totalCents":100}}]}
        """)
        let events = CursorUsage.parseEvents(page)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].tokens, 60)
        XCTAssertEqual(events[0].cents, 250)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let entries = events.map { MajorsSpend.Entry(date: $0.date, cost: $0.cents.map { $0 / 100 }, tokens: $0.tokens) }
        let spend = try XCTUnwrap(MajorsSpend.section(entries, now: now, calendar: utc))
        XCTAssertEqual(spend.rows.map(\.label), ["Today", "Yesterday", "Last 30 days"])
        XCTAssertEqual(spend.rows[0].value, "$3.00 \u{00B7} 1.1K tokens")
        XCTAssertEqual(spend.rows[1].value, "$1.00 \u{00B7} 2M tokens")
        XCTAssertEqual(spend.rows[2].value, "$4.00 \u{00B7} 2M tokens")
        // A period that the fetched pages do not fully cover is left out.
        let partial = try XCTUnwrap(MajorsSpend.section(entries, now: now, completeFrom: Date(timeIntervalSince1970: 1_799_971_200), calendar: utc))
        XCTAssertEqual(partial.rows.map(\.label), ["Today"])
        // An event without a price shows tokens only, never a guessed dollar total.
        let unpriced = try XCTUnwrap(MajorsSpend.section([MajorsSpend.Entry(date: now, cost: nil, tokens: 1500)], now: now, calendar: utc))
        XCTAssertEqual(unpriced.rows[0].value, "1.5K tokens")
        XCTAssertNil(MajorsSpend.section([], now: now))
        // 30 zero-filled days ending today: $3.00 today, $1.00 yesterday; a partial window drops the older days.
        let chart = try XCTUnwrap(MajorsSpend.chart(entries, now: now, calendar: utc))
        XCTAssertEqual(chart.unit, "USD")
        XCTAssertEqual(chart.points.count, 30)
        XCTAssertEqual(chart.points.map(\.value).suffix(2), [1, 3])
        XCTAssertEqual(chart.total, 4)
        XCTAssertEqual(MajorsSpend.chart(entries, now: now, completeFrom: Date(timeIntervalSince1970: 1_799_971_200), calendar: utc)?.points.count, 1)
        // Unpriced records chart tokens.
        let tokens = MajorsSpend.chart([MajorsSpend.Entry(date: now, cost: nil, tokens: 1500)], now: now, calendar: utc)
        XCTAssertEqual(tokens?.unit, "tokens")
        XCTAssertEqual(tokens?.points.last?.value, 1500)
        XCTAssertNil(MajorsSpend.chart([], now: now, calendar: utc))
    }

    func testCursorSessionCookieFromToken() {
        let claims = #"{"sub":"auth0|user_abc123"}"#
        let part = Data(claims.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let token = "e30.\(part).sig"
        XCTAssertEqual(CursorUsage.session(token)?.userID, "user_abc123")
        XCTAssertEqual(CursorUsage.session(token)?.cookie, "WorkosCursorSessionToken=user_abc123%3A%3A\(token)")
        XCTAssertNil(CursorUsage.session("not-a-jwt"))
    }

    // MARK: Copilot

    func testCopilotOrgBillingSumsOnlyCopilotCreditItems() throws {
        let summary = try json("""
        {"usageItems":[
         {"product":"Copilot","sku":"copilot_ai_unit","unitType":"ai-units","grossQuantity":100.5,"netAmount":1.25},
         {"product":"Copilot","sku":"Copilot AI Credits","unitType":"ai-credits","grossQuantity":50,"netAmount":0.5},
         {"product":"Actions","sku":"actions_linux","unitType":"minutes","grossQuantity":120,"netAmount":0.96},
         {"product":"Copilot","sku":"copilot_business_seat","unitType":"user-months","grossQuantity":10,"netAmount":190}]}
        """)
        let section = try XCTUnwrap(CopilotUsage.orgSection(summary))
        XCTAssertEqual(section.rows, [UsageRow("Org credits", "150.5 credits"), UsageRow("Org spend", "$1.75")])
        // Seat fees alone are not credit usage, so the next organization is probed.
        XCTAssertNil(CopilotUsage.orgSection(try json(#"{"usageItems":[{"product":"Copilot","unitType":"user-months","grossQuantity":10,"netAmount":190}]}"#)))
        XCTAssertNil(CopilotUsage.orgSection(try json(#"{"organization":"acme"}"#)))
        // A fully covered item is a real zero spend.
        let covered = try XCTUnwrap(CopilotUsage.orgSection(json(#"{"usageItems":[{"product":"Copilot","unitType":"ai-units","grossQuantity":298.698546,"netAmount":0.0}]}"#)))
        XCTAssertEqual(covered.rows.last?.value, "$0.00")
    }

    func testCopilotOrgManagedSeatKeepsPersonalCreditsAndPaidSeatShowsCreditsUsed() throws {
        let placeholder = try json("""
        {"copilot_plan":"business","token_based_billing":true,"quota_snapshots":{
         "chat":{"entitlement":0,"remaining":0,"unlimited":true,"overage_permitted":false,"overage_count":0},
         "completions":{"entitlement":0,"remaining":0,"unlimited":true,"overage_permitted":false,"overage_count":0},
         "premium_interactions":{"entitlement":0,"remaining":0,"unlimited":true,"overage_permitted":true,"overage_count":0,"credits_used":42}}}
        """)
        let seat = try CopilotUsage.map(placeholder)
        XCTAssertTrue(CopilotUsage.isOrgManaged(placeholder, seat))
        XCTAssertEqual(rows(seat), ["Credits used": "42"])
        XCTAssertEqual(seat.plan, "Business")
        // A paid seat with a real pool also shows its own credits used, before the extra usage row.
        let paid = try CopilotUsage.map(json("""
        {"copilot_plan":"individual_pro","quota_snapshots":{"premium_interactions":{"entitlement":500,"remaining":450,"percent_remaining":90,"overage_permitted":true,"overage_count":3,"credits_used":50}}}
        """))
        XCTAssertEqual(paid.sections.first?.rows.map(\.label), ["Credits used", "Extra usage"])
        XCTAssertFalse(CopilotUsage.isOrgManaged(try json(#"{"token_based_billing":false}"#), paid))
    }

    // MARK: Grok Build

    private func varint(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        var rest = value
        repeat {
            var byte = UInt8(rest & 0x7F)
            rest >>= 7
            if rest != 0 { byte |= 0x80 }
            out.append(byte)
        } while rest != 0
        return out
    }
    private func field(_ number: UInt64, bytes: [UInt8]) -> [UInt8] { varint(number << 3 | 2) + varint(UInt64(bytes.count)) + bytes }
    private func field(_ number: UInt64, varint value: UInt64) -> [UInt8] { varint(number << 3) + varint(value) }

    /// A GetRemainingResets reply: one record (field 10) per token, with the expiry as a timestamp in field 30.
    private func resetReply(_ expiries: [UInt64], framed: Bool) -> Data {
        var body: [UInt8] = []
        for (index, seconds) in expiries.enumerated() {
            let token = field(10, bytes: Array("token-\(index)".utf8)) + field(20, bytes: field(1, varint: 1_790_000_000))
                + field(30, bytes: field(1, varint: seconds) + field(2, varint: 0))
            body += field(10, bytes: token)
        }
        guard framed else { return Data(body) }
        let length = UInt32(body.count)
        return Data([0] + [UInt8(length >> 24), UInt8(length >> 16 & 255), UInt8(length >> 8 & 255), UInt8(length & 255)] + body
                    + [0x80, 0, 0, 0, 0])
    }

    func testGrokResetCreditsParseFramedAndRawProtobuf() {
        let now = Date(timeIntervalSince1970: 1_790_100_000)
        let expiries: [UInt64] = [1_791_500_000, 1_790_000_100, 1_790_900_000]   // the middle one is already expired
        for framed in [true, false] {
            let parsed = GrokBuildUsage.resetExpiries(resetReply(expiries, framed: framed), now: now)
            XCTAssertEqual(parsed, [Date(timeIntervalSince1970: 1_790_900_000), Date(timeIntervalSince1970: 1_791_500_000)])
        }
        XCTAssertEqual(GrokBuildUsage.resetExpiries(Data(), now: now), [])
        XCTAssertNil(GrokBuildUsage.resetExpiries(Data([0x0A, 0x7F, 0x01]), now: now))
    }

    func testGrokFetchAddsResetCreditsRowAndSurvivesItsFailure() async throws {
        let id = ProviderCatalog.agentGrok.files[0].id
        let file = """
        {"https://auth.x.ai::b1a00492":{"key":"tok","refresh_token":"r","expires_at":"2099-01-01T00:00:00Z","user_id":"u","email":"u@example.com"}}
        """
        let billing = #"{"config":{"creditUsagePercent":12,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2099-06-30T00:00:00Z","end":"2099-07-07T00:00:00Z"}}}"#
        let future = UInt64(Date().addingTimeInterval(5 * 86_400).timeIntervalSince1970)
        func send(resets: Data?) -> GrokBuildUsage.Send {
            { url, _, _, _ in
                if url.contains("/v1/billing") { return HTTPResponse(status: 200, data: Data(billing.utf8), headers: [:]) }
                if url.contains("/v1/settings") { return HTTPResponse(status: 200, data: Data(#"{"subscription_tier_display":"SuperGrok"}"#.utf8), headers: [:]) }
                guard let resets else { throw ProviderError.network("down") }
                XCTAssertTrue(url.hasSuffix("ConsumerUiSvc/GetRemainingResets"))
                return HTTPResponse(status: 200, data: resets, headers: [:])
            }
        }
        let credential = ProviderCredential(files: [id: Data(file.utf8)])
        let with = try await GrokBuildUsage.fetch(credential, fileID: id, send: send(resets: resetReply([future, future + 10], framed: true)))
        XCTAssertEqual(with.usage.windows.first?.usedPercent, 12)
        XCTAssertTrue(rows(with.usage)["Limit reset credits"]?.hasPrefix("2 available") == true)
        let without = try await GrokBuildUsage.fetch(credential, fileID: id, send: send(resets: nil))
        XCTAssertNil(rows(without.usage)["Limit reset credits"])
        XCTAssertEqual(without.usage.windows.count, 1)
    }

    func testGrokBillingPeriodFallbackNamesWindowByLength() throws {
        let weekly = try GrokBuildUsage.map(billing: json(#"{"config":{"creditUsagePercent":5,"billingPeriodStart":"2026-07-01T00:00:00Z","billingPeriodEnd":"2026-07-08T00:00:00Z"}}"#))
        XCTAssertEqual(weekly.windows.first?.title, "Weekly")
        XCTAssertEqual(weekly.windows.first?.resetsAt, iso("2026-07-08T00:00:00Z"))
        let monthly = try GrokBuildUsage.map(billing: json(#"{"config":{"creditUsagePercent":5,"billingPeriodStart":"2026-07-01T00:00:00Z","billingPeriodEnd":"2026-08-01T00:00:00Z"}}"#))
        XCTAssertEqual(monthly.windows.first?.title, "Monthly")
    }

    func testGrokLocalSpendUsesRecordedTurnCostAndCountsEventsOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("majors-grok-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("proj/session-1")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let now = Date()
        let ms = Int(now.timeIntervalSince1970 * 1000)
        func turn(_ event: String, model: String, input: Int, output: Int, ticks: Int?, ageMs: Int = 0) -> String {
            let cost = ticks.map { #","costUsdTicks":\#($0)"# } ?? ""
            return #"{"params":{"_meta":{"eventId":"\#(event)","agentTimestampMs":\#(ms - ageMs)},"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":\#(input),"outputTokens":\#(output),"modelUsage":{"\#(model)":{"inputTokens":\#(input),"outputTokens":\#(output)\#(cost)}}}}}}"#
        }
        let lines = [turn("a", model: "grok-4.6-build", input: 1_000_000, output: 50_000, ticks: 2_357_158_800),
                     turn("a", model: "grok-4.6-build", input: 1_000_000, output: 50_000, ticks: 2_357_158_800),   // copied transcript
                     #"{"params":{"update":{"sessionUpdate":"agent_message"}}}"#,
                     turn("b", model: "grok-4.5-build", input: 100, output: 20, ticks: 1_000_000_000, ageMs: 5 * 86_400_000)]
        try lines.joined(separator: "\n").write(to: session.appendingPathComponent("updates.jsonl"), atomically: true, encoding: .utf8)
        let report = try XCTUnwrap(GrokBuildUsage.localSpend(sessions: root, now: now))
        let section = try XCTUnwrap(report.section)
        let chart = try XCTUnwrap(report.chart)
        XCTAssertEqual(chart.unit, "USD")
        XCTAssertEqual(chart.points.count, 30)
        XCTAssertEqual(chart.total, 0.2357158800 + 0.1, accuracy: 0.0001)
        XCTAssertEqual(chart.points.last?.value ?? 0, 0.23571588, accuracy: 0.0001)
        XCTAssertEqual(section.rows.map(\.label).last, "Last 30 days")
        let last30 = try XCTUnwrap(section.rows.last?.value)
        // $0.2357 + $0.10 = $0.34, and 1,050,000 + 120 tokens.
        XCTAssertEqual(last30, "$0.34 \u{00B7} 1.1M tokens")
        XCTAssertNil(GrokBuildUsage.localSpend(sessions: root.appendingPathComponent("missing"), now: now))
    }

    // MARK: Ollama

    func testOllamaCurrentPlanMapsMonthlyCreditsPurchasedAndActivity() throws {
        let balance = try json("""
        {"included":{"balance_usd":72.5,"allowance_usd":100,"period":{"from":"2026-09-15T09:30:00Z","until":"2026-10-15T09:30:00Z"}},
         "purchased":{"balance_usd":25}}
        """)
        let activity = try json(#"{"activity":{"cost":"1.25000"}}"#)
        let usage = try OllamaUsage.map(balance: balance, usage: activity, account: json(#"{"Plan":"pro","Email":"o@x.com"}"#))
        XCTAssertEqual(usage.windows.map(\.id), ["monthly"])
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 27.5, accuracy: 1e-9)
        XCTAssertEqual(usage.windows[0].resetsAt, iso("2026-10-15T09:30:00Z"))
        XCTAssertEqual(usage.windows[0].windowMinutes, 30 * 24 * 60)
        XCTAssertEqual(usage.windows[0].detail, "$27.50 / $100.00")
        XCTAssertEqual(usage.cost?.used ?? -1, 27.5, accuracy: 1e-9)
        XCTAssertEqual(usage.cost?.limit, 100)
        XCTAssertEqual(usage.cost?.balance, 25)
        XCTAssertEqual(rows(usage)["Cost, last 4 weeks"], "$1.25")
        XCTAssertEqual(usage.plan, "Pro")
        XCTAssertEqual(usage.email, "o@x.com")
        // An overspent or unused allowance stays inside the meter.
        XCTAssertEqual(try OllamaUsage.map(balance: json(#"{"included":{"balance_usd":-5,"allowance_usd":60}}"#), usage: nil, account: nil).windows[0].usedPercent, 100)
        XCTAssertEqual(try OllamaUsage.map(balance: json(#"{"included":{"balance_usd":60,"allowance_usd":60}}"#), usage: nil, account: nil).windows[0].usedPercent, 0)
    }

    func testOllamaLegacyPlanMapsSessionAndWeeklyRemainingPercent() throws {
        let usage = try OllamaUsage.map(balance: json("""
        {"included":{"session":{"remaining_percent":75,"resets_at":"2026-10-01T07:00:00Z"},
                     "weekly":{"remaining_percent":40,"resets_at":"2026-10-05T00:00:00Z"},"balance_usd":10,"allowance_usd":60},
         "purchased":{"balance_usd":0}}
        """), usage: nil, account: nil)
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly", "monthly"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [25, 60, 50 / 60.0 * 100])
        XCTAssertEqual(usage.windows[0].windowMinutes, 300)
        XCTAssertEqual(usage.windows[1].resetsAt, iso("2026-10-05T00:00:00Z"))
        XCTAssertEqual(usage.cost?.balance, 0)
        // Purchased credits alone still show; an empty reply is an error.
        XCTAssertEqual(try OllamaUsage.map(balance: json(#"{"purchased":{"balance_usd":"12.5"}}"#), usage: nil, account: nil).cost?.balance, 12.5)
        XCTAssertThrowsError(try OllamaUsage.map(balance: json(#"{"included":{}}"#), usage: nil, account: nil))
    }

    // MARK: OpenCode Go

    func testOpenCodeGoLocalSpendReadsHostedMessagesOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("majors-opencode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("opencode.db").path, &db), SQLITE_OK)
        let now = Date()
        let ms = Int(now.timeIntervalSince1970 * 1000)
        func message(_ id: String, provider: String, cost: Double, total: Int, ageDays: Int = 0) -> String {
            let data = #"{"role":"assistant","providerID":"\#(provider)","modelID":"glm-5","cost":\#(cost),"tokens":{"total":\#(total)}}"#
            return "INSERT INTO message VALUES ('\(id)', \(ms - ageDays * 86_400_000), '\(data)');"
        }
        let sql = """
        CREATE TABLE message (id TEXT, time_created INTEGER, data TEXT);
        CREATE TABLE session_message (id TEXT, time_created INTEGER, type TEXT, data TEXT);
        \(message("m1", provider: "opencode-go", cost: 0.5, total: 1000))
        \(message("m2", provider: "opencode", cost: 1.5, total: 2000))
        \(message("m3", provider: "anthropic", cost: 9, total: 99999))
        \(message("m4", provider: "opencode-go", cost: 2, total: 3000, ageDays: 3))
        INSERT INTO session_message VALUES ('m1', \(ms), 'assistant', '{"model":{"id":"glm-5","providerID":"opencode-go"},"cost":0.5,"tokens":{"input":600,"output":400}}');
        INSERT INTO session_message VALUES ('m5', \(ms), 'assistant', '{"model":{"id":"glm-5","providerID":"opencode-go"},"cost":0.25,"tokens":{"input":100,"output":50,"cache":{"read":50,"write":0}}}');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let report = try XCTUnwrap(OpenCodeGoUsage.localSpend(directory: dir, now: now))
        let section = try XCTUnwrap(report.section)
        // Daily spend chart: 30 zero-filled days, today $2.25 and three days ago $2.
        let chart = try XCTUnwrap(report.chart)
        XCTAssertEqual(chart.points.count, 30)
        XCTAssertEqual(chart.points.last?.value ?? 0, 2.25, accuracy: 0.001)
        XCTAssertEqual(chart.points[26].value, 2, accuracy: 0.001)
        XCTAssertEqual(chart.total, 4.25, accuracy: 0.001)
        let today = try XCTUnwrap(section.rows.first { $0.label == "Today" })
        // m1 once (the OpenCode 2 copy is skipped), m2 and m5; the Anthropic row is not hosted.
        XCTAssertEqual(today.value, "$2.25 \u{00B7} 3.2K tokens")
        XCTAssertEqual(section.rows.last?.value, "$4.25 \u{00B7} 6.2K tokens")
        XCTAssertNil(OpenCodeGoUsage.localSpend(directory: dir.appendingPathComponent("none"), now: now))
        XCTAssertEqual(OpenCodeGoUsage.dataDirectory(env: ["OPENCODE_DATA_DIR": "/tmp/oc"]).path, "/tmp/oc")
        XCTAssertEqual(OpenCodeGoUsage.dataDirectory(env: ["XDG_DATA_HOME": "/tmp/x"]).path, "/tmp/x/opencode")
    }

    // MARK: Devin

    func testDevinWeeklyResetWithoutPercentIsExhaustedAndHiddenDailyFallsBack() throws {
        let exhausted = try DevinUsage.map(json(#"{"userStatus":{"planStatus":{"planInfo":{"planName":"Pro","hideDailyQuota":true},"dailyQuotaRemainingPercent":80,"weeklyQuotaResetAtUnix":"1789286400","overageBalanceMicros":"0"}}}"#))
        XCTAssertEqual(exhausted.windows.map(\.id), ["weekly"])
        XCTAssertEqual(exhausted.windows[0].usedPercent, 100)
        XCTAssertEqual(exhausted.cost?.balance, 0)
        let fallback = try DevinUsage.map(json(#"{"userStatus":{"planStatus":{"planInfo":{"planName":"Pro","hideDailyQuota":true},"dailyQuotaRemainingPercent":80,"dailyQuotaResetAtUnix":"1788940800"}}}"#))
        XCTAssertEqual(fallback.windows.map(\.id), ["weekly"])
        XCTAssertEqual(fallback.windows[0].usedPercent, 20)
    }

    // MARK: Gemini CLI

    func testGeminiProjectDiscoveryAndConsumerShutdown() throws {
        let projects = try json("""
        {"projects":[{"projectId":"my-app","labels":{}},
                     {"projectId":"gen-lang-client-0123456789","labels":{}},
                     {"projectId":"other","labels":{"generative-language":"enabled"}}]}
        """)
        XCTAssertEqual(GeminiCLIUsage.pickProject(projects), "gen-lang-client-0123456789")
        XCTAssertEqual(GeminiCLIUsage.pickProject(try json(#"{"projects":[{"projectId":"other","labels":{"generative-language":"x"}}]}"#)), "other")
        XCTAssertNil(GeminiCLIUsage.pickProject(try json(#"{"projects":[{"projectId":"my-app"}]}"#)))
        let shutdown = try json(#"{"ineligibleTiers":[{"reasonCode":"UNSUPPORTED_CLIENT"}]}"#)
        XCTAssertTrue(GeminiCLIUsage.consumerShutdown(shutdown, claims: nil))
        XCTAssertFalse(GeminiCLIUsage.consumerShutdown(shutdown, claims: try json(#"{"hd":"corp.com"}"#)))
        XCTAssertFalse(GeminiCLIUsage.consumerShutdown(try json(#"{"paidTier":{"name":"Google AI Pro"},"ineligibleTiers":[{"reasonCode":"UNSUPPORTED_CLIENT"}]}"#), claims: nil))
        XCTAssertFalse(GeminiCLIUsage.consumerShutdown(try json(#"{"currentTier":{"id":"standard-tier"},"ineligibleTiers":[{"reasonCode":"UNSUPPORTED_CLIENT"}]}"#), claims: nil))
    }

    // MARK: Antigravity CLI

    func testAntigravityUntouchedFiveHourPoolReadsNotStarted() throws {
        let summary = try json("""
        {"groups":[{"buckets":[
          {"bucketId":"gemini-5h","remainingFraction":1,"resetTime":"2026-07-02T16:00:00Z"},
          {"bucketId":"gemini-weekly","remainingFraction":0.9},
          {"bucketId":"3p-5h","remainingFraction":0.4}]}]}
        """)
        let usage = try AntigravityCLIUsage.map(assist: json("{}"), summary: summary, models: nil, claims: nil)
        XCTAssertEqual(usage.windows.map(\.detail), ["Not started", nil, nil])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [0, 10, 60])
    }

    func testAntigravityUnmeasuredSummaryFallsBackToModelQuotas() throws {
        let unmeasured = try json(#"{"groups":[{"buckets":[{"bucketId":"gemini-5h"},{"bucketId":"future-bucket","remainingFraction":0.2}]}]}"#)
        XCTAssertTrue(AntigravityCLIUsage.hasSummary(unmeasured))
        XCTAssertFalse(AntigravityCLIUsage.hasMeasured(unmeasured))
        let models = try json(#"{"models":{"a":{"displayName":"Gemini 3 Pro","quotaInfo":{"remainingFraction":0.8}}}}"#)
        let usage = try AntigravityCLIUsage.map(assist: json("{}"), summary: unmeasured, models: models, claims: nil)
        XCTAssertEqual(usage.windows.map(\.id), ["session"])
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 20, accuracy: 1e-9)
        // With no models either, the unmeasured summary stays an empty (not failed) answer.
        XCTAssertTrue(try AntigravityCLIUsage.map(assist: json("{}"), summary: unmeasured, models: nil, claims: nil).windows.isEmpty)
        XCTAssertThrowsError(try AntigravityCLIUsage.map(assist: json("{}"), summary: nil, models: nil, claims: nil))
    }

    // MARK: OpenRouter

    func testOpenRouterCreditsAndKeyRowsAndActivity() throws {
        let credits = try json(#"{"data":{"total_credits":100,"total_usage":40}}"#)
        let key = try json(#"{"data":{"limit":10,"limit_remaining":2.5,"limit_reset":"daily","usage":55,"usage_daily":7.5,"is_free_tier":false}}"#)
        let usage = try OpenRouterUsage.map(credits: credits, key: key)
        XCTAssertEqual(usage.sections.map(\.title), ["Spend", "Credits", "API key"])
        let all = rows(usage)
        XCTAssertEqual(all["Used"], "$40.00")
        XCTAssertEqual(all["Total added"], "$100.00")
        XCTAssertEqual(all["API key limit"], "$10.00 (spending cap, not balance)")
        XCTAssertEqual(all["API key remaining"], "$2.50")
        XCTAssertEqual(all["API key used"], "$55.00")
        XCTAssertEqual(all["Reset window"], "daily")
        let uncapped = try OpenRouterUsage.map(credits: nil, key: json(#"{"data":{"limit":null,"usage_monthly":3}}"#))
        XCTAssertEqual(rows(uncapped)["API key limit"], "No limit configured")

        let now = iso("2026-10-10T12:00:00Z")
        let activity = try XCTUnwrap(OpenRouterUsage.activitySection(rows: [
            try json(#"{"date":"2026-10-09","model_permaslug":"openai/gpt-5","endpoint_id":"e1","prompt_tokens":1000,"completion_tokens":500,"reasoning_tokens":100,"requests":4,"usage":1.5,"byok_usage_inference":0.5}"#),
            try json(#"{"date":"2026-10-09","model_permaslug":"openai/gpt-5","endpoint_id":"e1","prompt_tokens":1000,"completion_tokens":500,"reasoning_tokens":100,"requests":4,"usage":1.5,"byok_usage_inference":0.5}"#),
            try json(#"{"date":"2026-10-01 00:00:00","model":"anthropic/claude","prompt_tokens":2000,"completion_tokens":0,"requests":2,"usage":1}"#),
            try json(#"{"date":"2026-08-01","model":"old","prompt_tokens":99999,"completion_tokens":0,"requests":9,"usage":9}"#),
            try json(#"{"date":"2026-10-10","model":"today","prompt_tokens":99999,"completion_tokens":0,"requests":9,"usage":9}"#),
        ], now: now))
        XCTAssertEqual(activity.section.rows, [UsageRow("Tokens", "3.5K"), UsageRow("Requests", "6"), UsageRow("Models", "2"), UsageRow("Spend", "$3.00")])
        // 30 completed UTC days Sep 10 to Oct 9; Oct 9 spend $2 (the duplicate row is dropped), Oct 1 spend $1.
        let chart = try XCTUnwrap(activity.chart)
        XCTAssertEqual(chart.points.count, 30)
        XCTAssertEqual(chart.points.first?.label, "Sep 10")
        XCTAssertEqual(chart.points.last?.label, "Oct 9")
        XCTAssertEqual(chart.points.last?.value, 2)
        XCTAssertEqual(chart.points.first { $0.label == "Oct 1" }?.value, 1)
        XCTAssertEqual(chart.total, 3)
    }

    // MARK: Z.ai

    func testZaiQuotaRateModelUsageAndBalanceRows() throws {
        // 2026-10-12 is a Monday. 07:00 UTC is peak, 11:00 UTC is off-peak until Tuesday, Friday 11:00 waits for Monday.
        let monday = iso("2026-10-12T07:00:00Z")
        XCTAssertEqual(ZaiUsage.quotaRate(monday), UsageRow("Quota rate", "Peak (off-peak in 3h 0m)"))
        XCTAssertEqual(ZaiUsage.quotaRate(iso("2026-10-12T11:00:00Z")), UsageRow("Quota rate", "Off-peak (peak in 19h 0m)"))
        XCTAssertEqual(ZaiUsage.quotaRate(iso("2026-10-16T11:00:00Z")).value, "Off-peak (peak in 2d 19h)")
        let credit = try ZaiUsage.map(json("""
        {"code":200,"success":true,"data":{"level":"lite","limits":[
        {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,"currentValue":100,"remaining":1900,"percentage":5}]}}
        """), now: monday)
        XCTAssertEqual(rows(credit)["Quota rate"], "Peak (off-peak in 3h 0m)")
        let tokens = try ZaiUsage.map(json("""
        {"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":5}]}}
        """), now: monday)
        XCTAssertNil(rows(tokens)["Quota rate"])

        let model = try json("""
        {"success":true,"code":200,"data":{"x_time":["a","b"],"modelDataList":[
         {"modelName":"glm-5","tokensUsage":[1500000,500000]},{"modelName":"glm-4.5","tokensUsage":[10,20]},{"modelName":"idle","tokensUsage":[0,0]}]}}
        """)
        let section = try XCTUnwrap(ZaiUsage.modelUsage(model, title: "Daily tokens"))
        XCTAssertEqual(section.title, "Daily tokens")
        XCTAssertEqual(section.rows, [UsageRow("glm-5", "2M"), UsageRow("glm-4.5", "30")])
        XCTAssertNil(ZaiUsage.modelUsage(try json(#"{"success":false}"#), title: "x"))
        let range = ZaiUsage.timeRange(days: 1, now: iso("2026-10-12T07:30:00Z"))
        XCTAssertTrue(range.start.hasSuffix("00%3A00%3A00"))
        XCTAssertTrue(range.end.hasSuffix("59%3A59"))

        var cn = ProviderUsage()
        ZaiUsage.addBalance(try json(#"{"success":true,"data":{"availableBalance":50,"totalSpendAmount":12,"rechargeAmount":60,"giveAmount":5}}"#), to: &cn)
        XCTAssertEqual(cn.cost?.currency, "CNY")
        XCTAssertEqual(cn.cost?.balance, 50)
        XCTAssertEqual(rows(cn)["Recharged"], "CN\u{00A5}60.00")
        XCTAssertEqual(rows(cn)["Granted"], "CN\u{00A5}5.00")
    }
}
