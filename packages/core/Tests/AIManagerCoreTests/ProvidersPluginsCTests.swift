import Foundation
import XCTest
@testable import AIManagerCore

final class ProvidersPluginsCTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }
    private func utc(_ text: String) -> Date { Fmt.iso(text)! }

    func testCatalogListsEveryProvider() {
        let ids = Set(ProviderCatalog.pluginsC.map(\.id.rawValue))
        XCTAssertEqual(ids, ["sailresearch", "sakana", "sofya", "sub2api", "synthetic", "t3chat", "tavily", "tinyapi",
                             "typesafe", "v0", "venice", "vercel", "workbuddy", "xai", "xapi", "xkiro", "zai", "zed",
                             "zenmux", "zoommate"])
        XCTAssertEqual(ProviderCatalog.pluginsC.count, 20)
    }

    func testTavily() throws {
        let usage = try TavilyUsage.map(json("""
        {"account":{"current_plan":"Researcher","plan_usage":120,"plan_limit":1000},"key":{"usage":30,"limit":100}}
        """))
        XCTAssertEqual(usage.windows.map(\.id), ["plan", "key"])
        XCTAssertEqual(usage.windows[0].usedPercent, 12)
        XCTAssertEqual(usage.windows[1].usedPercent, 30)
        XCTAssertEqual(usage.plan, "Researcher")
        XCTAssertThrowsError(try TavilyUsage.map(json(#"{"account":{}}"#)))
    }

    func testTinyApi() throws {
        let usage = try TinyApiUsage.map(json(#"{"success":true,"data":{"totalAvailable":42.5}}"#))
        XCTAssertEqual(usage.sections.first?.rows.first?.value, "42.5 credits")
        XCTAssertThrowsError(try TinyApiUsage.map(json(#"{"success":false}"#)))
    }

    func testVercel() throws {
        let usage = try VercelUsage.map(json(#"{"balance":"12.50","total_used":"7.25"}"#))
        XCTAssertEqual(usage.cost?.balance, 12.5)
        XCTAssertEqual(usage.cost?.used, 7.25)
    }

    func testVenice() throws {
        let diem = try VeniceUsage.map(json("""
        {"canConsume":true,"consumptionCurrency":"DIEM","balances":{"diem":90.50,"usd":null},"diemEpochAllocation":100.0}
        """))
        XCTAssertEqual(diem.windows[0].usedPercent ?? 0, 9.5, accuracy: 0.0001)
        let usd = try VeniceUsage.map(json(#"{"canConsume":true,"consumptionCurrency":"USD","balances":{"diem":0,"usd":"5.5"}}"#))
        XCTAssertEqual(usd.windows[0].usedPercent, 0)
        XCTAssertEqual(usd.cost?.balance, 5.5)
        let blocked = try VeniceUsage.map(json(#"{"canConsume":false,"balances":{"diem":1}}"#))
        XCTAssertEqual(blocked.windows[0].usedPercent, 100)
    }

    func testXApi() throws {
        XCTAssertEqual(try XApiUsage.accountID(json(#"{"account":{"id":1234567}}"#)), "1234567")
        XCTAssertThrowsError(try XApiUsage.accountID(json(#"{"account":{"id":"../x"}}"#)))
        let usage = try XApiUsage.map(json(#"{"credits":{"balance":10.5},"freeCredits":{"balance":2}}"#))
        XCTAssertEqual(usage.cost?.balance, 12.5)
    }

    func testZenMux() throws {
        let subscription = try json("""
        {"success":true,"data":{"plan":{"tier":"ultra","expires_at":"2026-04-12T08:26:56Z"},"account_status":"healthy",
        "quota_5_hour":{"usage_percentage":0.0715,"resets_at":"2026-03-24T08:35:09Z","max_flows":800,"used_flows":57.2,"remaining_flows":742.8},
        "quota_7_day":{"usage_percentage":0.0673,"max_flows":6182,"used_flows":416.11,"remaining_flows":5765.89}}}
        """)
        let payg = try json(#"{"success":true,"data":{"currency":"usd","total_credits":-12.34}}"#)
        let usage = try ZenMuxUsage.map(subscription, payg: payg)
        XCTAssertEqual(usage.windows[0].usedPercent ?? 0, 7.15, accuracy: 0.000001)
        XCTAssertEqual(usage.windows[0].windowMinutes, 300)
        XCTAssertEqual(usage.windows[0].detail, "57.2 / 800 flows")
        XCTAssertEqual(usage.windows[0].resetsAt, utc("2026-03-24T08:35:09Z"))
        XCTAssertEqual(usage.windows[1].usedPercent ?? 0, 6.73, accuracy: 0.000001)
        XCTAssertEqual(usage.windows[1].windowMinutes, 10080)
        XCTAssertEqual(usage.plan, "Ultra plan")
        XCTAssertEqual(usage.cost?.balance, -12.34)
    }

    func testXaiConsole() throws {
        let history = try json("""
        {"timeSeries":[{"dataPoints":[{"timestamp":"2027-01-13T00:00:00Z","values":[0.75973725]},{"timestamp":"2027-01-14T00:00:00Z","values":[0.5]}]},
        {"dataPoints":[{"timestamp":"2027-01-13T00:00:00Z","values":[0.5]}]}],"limitReached":false}
        """)
        let usage = try XaiConsoleUsage.map(balance: json(#"{"total":{"val":"-1000"}}"#), history: history)
        XCTAssertEqual(usage.cost?.balance, 10)
        XCTAssertEqual(usage.cost?.used ?? 0, 1.75973725, accuracy: 0.000001)
        XCTAssertEqual(usage.sections[0].rows.last?.value, "$1.76")
        let owing = try XaiConsoleUsage.map(balance: json(#"{"total":{"val":"2500"}}"#), history: nil)
        XCTAssertEqual(owing.cost?.balance, -25)
        XCTAssertNil(owing.cost?.used)
        XCTAssertThrowsError(try XaiConsoleUsage.map(balance: json(#"{"total":{"val":"n/a"}}"#), history: nil))
    }

    func testSailResearch() throws {
        let usage = try SailResearchUsage.map(json("""
        {"object":"usage.summary","available":true,"has_metronome_customer":true,"balance_unavailable":false,
        "balance":2500,"period_spend":1234,"effective_range":"30d"}
        """))
        XCTAssertEqual(usage.cost?.balance, 25)
        XCTAssertEqual(usage.cost?.used ?? 0, 12.34, accuracy: 0.0001)
        XCTAssertEqual(usage.cost?.period, "Last 30 days")
    }

    func testSakana() throws {
        let page = """
        <div data-slot="card"><div data-slot="card-title"><span>Standard</span><span class="price">$20/mo</span></div></div>
        <p class="t">5-hour</p><div><p class="u">12.5% used</p><p class="r">Resets on October 14, 2026 at 3:00 PM</p></div>
        <p class="t">Weekly</p><div><p class="u">40% used</p><p class="r">Resets on October 19, 2026 at 12:00 AM</p></div>
        """
        let payg = """
        <h2 class="a">Credit balance</h2><div><p class="text-2xl tabular-nums">$12.50</p></div>
        <h2>Usage</h2><span class="m">Total<!-- -->: <!-- -->$3.25</span>
        """
        let usage = try SakanaUsage.map(html: page, paygHTML: payg)
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(usage.windows[0].usedPercent, 12.5)
        XCTAssertEqual(usage.windows[0].windowMinutes, 300)
        XCTAssertEqual(usage.windows[0].resetsAt, utc("2026-10-14T15:00:00Z"))
        XCTAssertEqual(usage.windows[1].usedPercent, 40)
        XCTAssertEqual(usage.windows[1].resetsAt, utc("2026-10-19T00:00:00Z"))
        XCTAssertEqual(usage.plan, "Standard $20/mo")
        XCTAssertEqual(usage.cost?.balance, 12.5)
        XCTAssertEqual(usage.cost?.used, 3.25)
        XCTAssertThrowsError(try SakanaUsage.map(html: "<html>Sign in</html>"))
    }

    func testSofya() throws {
        let usage = try SofyaUsage.map(json("""
        {"credits":12.5,"plan_credits":10,"purchased_credits":2.5,"is_free_tier":true,"credits_reset_at":"2026-11-01T00:00:00Z"}
        """))
        XCTAssertEqual(usage.plan, "Free tier")
        XCTAssertEqual(usage.windows[0].resetsAt, utc("2026-11-01T00:00:00Z"))
        XCTAssertEqual(usage.sections[0].rows.map(\.label), ["Available credits", "Plan credits", "Purchased credits"])
        XCTAssertEqual(usage.sections[0].rows[0].value, "12.5")
        XCTAssertThrowsError(try SofyaUsage.map(json("{}")))
    }

    func testSub2Api() throws {
        let usage = try Sub2ApiUsage.map(json("""
        {"mode":"unrestricted","isValid":true,"planName":"Claude Team","remaining":8,"unit":"USD","balance":8,
        "subscription":{"daily_usage_usd":2,"weekly_usage_usd":10,"monthly_usage_usd":30,"daily_limit_usd":10,"weekly_limit_usd":40,"monthly_limit_usd":100},
        "rate_limits":[{"window":"5h","limit":50,"used":5,"remaining":45,"reset_at":"2026-08-15T00:00:00Z"}],
        "usage":{"today":{"requests":4,"total_tokens":1200,"actual_cost":0.5}}}
        """))
        XCTAssertEqual(usage.windows.map(\.id), ["daily", "weekly", "monthly", "rate-5h"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [20, 25, 30, 10])
        XCTAssertEqual(usage.windows[0].windowMinutes, 1440)
        XCTAssertEqual(usage.windows[3].windowMinutes, 300)
        XCTAssertEqual(usage.windows[3].resetsAt, utc("2026-08-15T00:00:00Z"))
        XCTAssertEqual(usage.plan, "Claude Team")
        XCTAssertEqual(usage.cost?.balance, 8)
        XCTAssertThrowsError(try Sub2ApiUsage.map(json(#"{"isValid":false}"#)))
        XCTAssertEqual(try Sub2ApiUsage.endpoint("https://gw.example.com/", timeZone: "UTC"), "https://gw.example.com/v1/usage?days=30&timezone=UTC")
        XCTAssertEqual(try Sub2ApiUsage.endpoint("https://gw.example.com/v1/usage", timeZone: "UTC"), "https://gw.example.com/v1/usage?days=30&timezone=UTC")
        XCTAssertThrowsError(try Sub2ApiUsage.endpoint("http://gw.example.com", timeZone: "UTC"))
    }

    func testSyntheticGenericQuotas() throws {
        let usage = try SyntheticUsage.map(json("""
        {"plan":"Starter","quotas":[{"name":"Monthly","limit":1000,"used":250,"reset_at":"2025-01-01T00:00:00Z"},
        {"name":"Daily","max":200,"remaining":50,"window_minutes":1440}]}
        """))
        XCTAssertEqual(usage.windows[0].usedPercent, 25)
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1_735_689_600))
        XCTAssertEqual(usage.windows[1].usedPercent, 75)
        XCTAssertEqual(usage.windows[1].windowMinutes, 1440)
        XCTAssertEqual(usage.plan, "Starter")
    }

    func testSyntheticNamedSlotsAndCredits() throws {
        let usage = try SyntheticUsage.map(json("""
        {"weeklyTokenLimit":{"nextRegenAt":"2026-04-17T05:19:30.000Z","percentRemaining":98.0,"maxCredits":"$36.00","remainingCredits":"$35.30"},
        "search":{"hourly":{"limit":250,"requests":2,"renewsAt":"2026-04-17T04:30:01.494Z"}}}
        """))
        XCTAssertEqual(usage.windows.map(\.id), ["weekly", "search"])
        XCTAssertEqual(usage.windows[0].usedPercent ?? 0, 2, accuracy: 0.0001)
        XCTAssertEqual(usage.windows[1].usedPercent ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(usage.cost?.limit, 36)
        XCTAssertEqual(usage.cost?.used ?? 0, 0.7, accuracy: 0.0001)
        XCTAssertThrowsError(try SyntheticUsage.map(json("{}")))
    }

    func testT3Chat() throws {
        let lines = """
        {"json":[0,0,[]]}
        {"json":[2,0,[[{"subTier":"pro","subscription":{"productId":"pro","productName":"pro","status":"active","currentPeriodStart":1778084609000,"currentPeriodEnd":1780763009000,"canceledAt":null},"lifetimeBalance":0,"usageBand":"max","usageFourHourPercentage":12.5,"usageMonthPercentage":34.25,"usageFourHourNextResetAt":1779366216920}]]]}
        """
        let usage = try T3ChatUsage.map(jsonLines: lines)
        XCTAssertEqual(usage.windows.map(\.id), ["base", "overage"])
        XCTAssertEqual(usage.windows[0].usedPercent, 12.5)
        XCTAssertEqual(usage.windows[0].windowMinutes, 240)
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1_779_366_216.92))
        XCTAssertEqual(usage.windows[0].detail, "Base - max")
        XCTAssertEqual(usage.windows[1].usedPercent, 34.25)
        XCTAssertEqual(usage.windows[1].resetsAt, Date(timeIntervalSince1970: 1_780_763_009))
        XCTAssertEqual(usage.plan, "Pro")
        XCTAssertThrowsError(try T3ChatUsage.map(jsonLines: "{}"))
    }

    func testTypeSafe() throws {
        let rsc = """
        0:["$@1"]
        1:{"ok":true,"data":{"billing":{"plan":"free_plan","spent":0.01,"freeCreditsRemaining":4.98,"balance":4.98,"purchased":0,"resetsInDays":12,"cycleLabel":"September 2026","credits":[{"id":"c1","amount":5,"remaining":4.98,"expiresAt":"2026-10-19T00:00:00Z"}]}}}
        """
        let usage = try TypeSafeUsage.map(rsc: rsc)
        XCTAssertEqual(usage.cost?.used, 0.01)
        XCTAssertEqual(usage.cost?.balance, 4.98)
        XCTAssertEqual(usage.cost?.period, "September 2026")
        XCTAssertEqual(usage.plan, "Free")
        XCTAssertEqual(usage.sections[0].rows[0].label, "Spent (September 2026)")
        XCTAssertEqual(usage.sections[0].rows.count, 2)
        XCTAssertThrowsError(try TypeSafeUsage.map(rsc: #"1:{"ok":false}"#))

        let id = String(repeating: "ab", count: 21)
        XCTAssertEqual(TypeSafeUsage.actionID(#"createServerReference)("\#(id)",x,void 0,"getBillingOverviewResult")"#), id)
        let html = #"<script src="/_next/static/a.js"></script><script src="https://evil.example/b.js"></script><script src="/x.css"></script>"#
        XCTAssertEqual(TypeSafeUsage.chunkURLs(html), ["https://console.typesafe.ai/_next/static/a.js"])
    }

    func testV0() throws {
        let usage = try V0Usage.map(
            billing: json(#"{"billingType":"token","data":{"balance":{"total":1000,"remaining":750},"billingCycle":{"end":1790000000},"onDemand":{"balance":5}}}"#),
            rateLimit: json(#"{"limit":100,"remaining":40,"reset":1790000100}"#), scope: "proj")
        XCTAssertEqual(usage.windows.map(\.id), ["billing", "rate-limit"])
        XCTAssertEqual(usage.windows[0].usedPercent, 25)
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(usage.windows[1].usedPercent, 60)
        let legacy = try V0Usage.map(billing: json(#"{"billingType":"legacy","data":{"limit":200,"remaining":150}}"#),
                                     rateLimit: json(#"{"limit":10}"#))
        XCTAssertEqual(legacy.windows.map(\.id), ["billing"])
        XCTAssertEqual(legacy.windows[0].usedPercent, 25)
    }

    func testWorkBuddy() throws {
        let usage = try WorkBuddyUsage.map(json("""
        {"code":0,"msg":"OK","data":{"SubscriptionPackageName":"Free","Packages":[
        {"CycleTotalCapacity":"500","CycleRemainCapacity":"450","CycleFrozenCapacity":"20","CapacityUnit":"credits"},
        {"CycleTotalCapacity":"9","CycleRemainCapacity":"9","CapacityUnit":"tokens"}]}}
        """))
        XCTAssertEqual(usage.windows[0].usedPercent, 10)
        XCTAssertEqual(usage.windows[0].detail, "450 / 500 credits left")
        XCTAssertEqual(usage.plan, "Free")
        XCTAssertEqual(usage.sections[0].rows, [UsageRow("Reserved", "20")])
        let empty = try WorkBuddyUsage.map(json(#"{"code":0,"data":{"Packages":[{"CycleTotalCapacity":"0","CycleRemainCapacity":"0","CapacityUnit":"credits"}]}}"#))
        XCTAssertTrue(empty.windows.isEmpty)
        XCTAssertEqual(empty.sections[0].rows.map(\.label), ["Left", "Total"])
        XCTAssertThrowsError(try WorkBuddyUsage.map(json(#"{"code":401}"#)))
    }

    func testXKiro() throws {
        let now = utc("2026-10-10T12:00:00Z")
        let usage = try XKiroUsage.map(json("""
        {"object":"usage","plan":null,"user":{"email":"dev@example.com"},"windows":[],
        "free_tokens":{"used_today":124035,"limit_per_day":5000000,"remaining":4875965}}
        """), now: now)
        XCTAssertEqual(usage.windows[0].usedPercent ?? 0, 2.4807, accuracy: 0.0001)
        XCTAssertEqual(usage.windows[0].windowMinutes, 1440)
        XCTAssertEqual(usage.windows[0].resetsAt, utc("2026-10-11T00:00:00Z"))
        XCTAssertEqual(usage.plan, "Pay as you go")
        XCTAssertEqual(usage.email, "dev@example.com")
        XCTAssertThrowsError(try XKiroUsage.map(json(#"{"object":"other"}"#)))
    }

    func testZai() throws {
        let reset = 1_785_816_000.0
        let now = Date(timeIntervalSince1970: reset - 3600)
        let usage = try ZaiUsage.map(json("""
        {"code":200,"msg":"success","success":true,"data":{"planName":"Pro","limits":[
        {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":9,"nextResetTime":1786291200000},
        {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25,"nextResetTime":1785816000000},
        {"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":224,"remaining":776,"percentage":22,
        "usageDetails":[{"modelCode":"search-prime","usage":210}]}]}}
        """), now: now)
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly", "mcp"])
        XCTAssertEqual(usage.windows[0].usedPercent, 25)
        XCTAssertEqual(usage.windows[0].windowMinutes, 300)
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: reset))
        XCTAssertEqual(usage.windows[1].usedPercent, 9)
        XCTAssertEqual(usage.windows[1].windowMinutes, 10080)
        XCTAssertEqual(usage.windows[2].usedPercent ?? 0, 22.4, accuracy: 0.0001)
        XCTAssertEqual(usage.windows[2].windowMinutes, 43200)
        XCTAssertEqual(usage.windows[2].detail, "224 / 1,000 calls")
        XCTAssertEqual(usage.sections[0].rows, [UsageRow("search-prime", "210")])
        XCTAssertEqual(usage.plan, "Pro")

        // Credit plans: a reset past five hours on the five-hour window is dropped.
        let credit = try ZaiUsage.map(json("""
        {"code":200,"success":true,"data":{"level":"lite","limits":[
        {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,"currentValue":100,"remaining":1900,"percentage":5,"nextResetTime":1786073946574}]}}
        """), now: now)
        XCTAssertEqual(credit.windows[0].usedPercent, 5)
        XCTAssertNil(credit.windows[0].resetsAt)
        XCTAssertEqual(credit.plan, "lite")

        XCTAssertThrowsError(try ZaiUsage.map(json(#"{"success":false,"code":500,"msg":"No active Coding Plan"}"#))) {
            XCTAssertEqual(($0 as? ProviderError), .unsupported("No active GLM Coding Plan on this account."))
        }
    }

    func testZaiRegionAndBalance() throws {
        XCTAssertTrue(ZaiUsage.isChina("CN"))
        XCTAssertTrue(ZaiUsage.isChina("bigmodel-cn"))
        XCTAssertFalse(ZaiUsage.isChina(nil))
        XCTAssertFalse(ZaiUsage.isChina("global"))
        var usage = ProviderUsage()
        ZaiUsage.addBalance(try json(#"{"success":true,"data":{"availableBalance":"88.5","totalSpendAmount":11.5}}"#), to: &usage)
        XCTAssertEqual(usage.cost?.balance, 88.5)
        XCTAssertEqual(usage.cost?.currency, "CNY")
        XCTAssertEqual(usage.cost?.used, 11.5)
    }

    func testZed() throws {
        let usage = try ZedUsage.map(json("""
        {"plan":"zed_pro","current_usage":{"token_spend":{"spend_in_cents":250,"limit_in_cents":1000},
        "edit_predictions":{"used":12,"limit":100}}}
        """))
        XCTAssertEqual(usage.windows[0].usedPercent, 12)
        XCTAssertEqual(usage.cost?.used, 2.5)
        XCTAssertEqual(usage.cost?.limit, 10)
        XCTAssertEqual(usage.plan, "Zed Pro")
        let unlimited = try ZedUsage.map(json(#"{"plan":"zed_free","current_usage":{"edit_predictions":{"used":3,"limit":"unlimited"}}}"#))
        XCTAssertTrue(unlimited.windows.isEmpty)
        XCTAssertEqual(unlimited.sections[0].rows.first?.value, "Unlimited")
        XCTAssertNil(unlimited.cost)
    }

    func testZoomMate() throws {
        let usage = try ZoomMateUsage.map(json(#"{"data":{"credit_status":{"budget_cap":100,"used_credit":25,"remaining_credit":75,"cycle_end_date":1790000000000}}}"#))
        XCTAssertEqual(usage.windows[0].usedPercent, 25)
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1_790_000_000))
        let unlimited = try ZoomMateUsage.map(json(#"{"data":{"credit_status":{"is_unlimited":true}}}"#))
        XCTAssertTrue(unlimited.windows.isEmpty)
        XCTAssertEqual(ZoomMateUsage.bearer("abc"), "Bearer abc")
        XCTAssertEqual(ZoomMateUsage.bearer("Bearer abc"), "Bearer abc")
        XCTAssertThrowsError(try ZoomMateUsage.map(json("{}")))
    }
}
