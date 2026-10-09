import Foundation
import XCTest
@testable import AIManagerCore

final class ProvidersPluginsBTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }
    private let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21T14:13:20Z

    func testCatalogRegistersEveryPluginsBProvider() {
        let ids = ProviderCatalog.pluginsB.map(\.id.rawValue)
        XCTAssertEqual(ids.count, 20)
        XCTAssertEqual(Set(ids).count, 20)
        XCTAssertFalse(ids.contains("museai"))
    }

    func testLinkup() throws {
        let usage = try LinkupUsage.map(json(#"{"balance": 12.5}"#))
        XCTAssertEqual(usage.cost?.balance, 12.5)
        XCTAssertEqual(usage.sections.first?.rows.first?.value, "$12.50")
        XCTAssertThrowsError(try LinkupUsage.map(json(#"{"credits": 1}"#)))
    }

    func testLiteLLMPersonalAndTeamBudgets() throws {
        let key = try json(#"{"info":{"user_id":"u1","team_id":"t1","spend":3}}"#)
        let user = try json("""
        {"user_info":{"user_id":"u1","user_email":"ada@example.com","spend":25,"max_budget":100,
         "budget_reset_at":"2026-10-01T00:00:00Z"},
         "teams":[{"team_id":"t0","spend":1,"max_budget":2},
                  {"team_id":"t1","team_alias":"Core","spend":40,"max_budget":50}]}
        """)
        let usage = try LiteLLMUsage.map(key: key, user: user, team: nil)
        XCTAssertEqual(usage.windows.map(\.id), ["personal", "team"])
        XCTAssertEqual(usage.windows[0].usedPercent, 25)
        XCTAssertEqual(usage.windows[1].usedPercent, 80)
        XCTAssertEqual(usage.windows[1].detail, "Core: $40.00 / $50.00")
        XCTAssertEqual(usage.cost?.used, 25)
        XCTAssertEqual(usage.cost?.limit, 100)
        XCTAssertEqual(usage.email, "ada@example.com")
        XCTAssertEqual(usage.organization, "Core")
    }

    func testLiteLLMSpendReportFallback() throws {
        let rows = try json(#"[{"total_cost":1.25},{"total_cost":2}]"#)
        let usage = try LiteLLMUsage.mapSpendReport(rows, scope: "Key", start: "2026-09-01", end: "2026-09-21")
        XCTAssertEqual(usage.cost?.used, 3.25)
        XCTAssertTrue(usage.windows.isEmpty)
    }

    func testLithosAI() throws {
        let me = try json(#"{"user":{"email":"ada@example.com"},"activeOrganization":{"id":"o1","name":"Lab"}}"#)
        let billing = try json(#"{"balanceNanos":12500000000,"hasCard":true,"onHold":false}"#)
        let spend = try json(#"{"days":[{"day":"2026-09-20","nanos":1000000000},{"day":"2026-09-21","nanos":500000000}]}"#)
        let usage = try LithosAIUsage.map(me: me, billing: billing, spend: spend, today: "2026-09-21")
        XCTAssertEqual(usage.cost?.balance, 12.5)
        XCTAssertEqual(usage.email, "ada@example.com")
        XCTAssertEqual(usage.organization, "Lab")
        let rows = Dictionary(uniqueKeysWithValues: usage.sections[0].rows.map { ($0.label, $0.value) })
        XCTAssertEqual(rows["Today (UTC)"], "$0.50")
        XCTAssertEqual(rows["This month (UTC)"], "$1.50")
        XCTAssertEqual(rows["Payment card"], "Added")
    }

    func testLlmmanMemory() throws {
        let node = try json("""
        {"memory":16000000000,"loaded":{"qwen:7b":4000000000,"llama:8b":2000000000},"stored":{"qwen:7b":4000000000,"x":1000000}}
        """)
        let usage = try LlmmanUsage.map(node, version: "0.5.1")
        XCTAssertEqual(usage.windows.first?.usedPercent, 37.5)
        XCTAssertEqual(usage.windows.first?.detail, "6.0 GB of 16.0 GB")
        XCTAssertEqual(usage.sections[0].rows.map(\.value), ["2 · 6.0 GB", "2 · 4.0 GB", "0.5.1"])
        XCTAssertEqual(usage.sections[1].rows.first?.label, "qwen:7b")
        XCTAssertEqual(usage.sections[1].rows.first?.progress, 0.25)
    }

    func testLlmproxyQuotaStats() throws {
        let stats = try json("""
        {"summary":{"total_requests":30,"total_tokens":1500,"approx_cost":0.75},
         "providers":{"openai":{"credential_count":2,"active_count":1,"total_requests":20,
           "tokens":{"input_cached":100,"input_uncached":400,"output":500},"approx_cost":0.5,
           "quota_groups":{"a":{"remaining_percent":30,"reset_time":"2026-09-22T00:00:00Z"},
                           "b":{"remaining_percent":60}}},
          "gemini":{"credential_count":1,"active_count":1,"total_requests":10,"tokens":{"output":50}}}}
        """)
        let usage = try LlmproxyUsage.map(stats, now: now)
        XCTAssertEqual(usage.windows.first?.id, "quota")
        XCTAssertEqual(usage.windows.first?.usedPercent, 70)
        XCTAssertEqual(usage.windows.first?.resetsAt, Fmt.iso("2026-09-22T00:00:00Z"))
        XCTAssertEqual(usage.cost?.used, 0.75)
        XCTAssertEqual(usage.organization, "2/3 active keys")
        XCTAssertEqual(usage.sections[1].rows.first?.label, "openai")
        XCTAssertEqual(usage.sections[1].rows.first?.value, "20 req · 1,000 tok · $0.50")
    }

    func testLongCatActivePackAndFuel() throws {
        let account = try LongCatUsage.unwrap(json(#"{"code":0,"data":{"name":"Acme"}}"#))
        let summary = try LongCatUsage.unwrap(json(
            #"{"code":200,"data":{"currentLot":{"status":"ACTIVE","totalToken":1000,"consumedToken":250}}}"#))
        let fuel = try LongCatUsage.unwrap(json(
            #"{"code":0,"data":{"totalQuota":400,"list":[{"availableToken":100,"expireTime":1790500000}]}}"#))
        let usage = try LongCatUsage.map(account: account, summary: summary, tokenUsage: nil, fuel: fuel)
        XCTAssertEqual(usage.windows.map(\.id), ["quota", "fuel"])
        XCTAssertEqual(usage.windows[0].usedPercent, 25)
        XCTAssertEqual(usage.windows[1].usedPercent, 75)
        XCTAssertEqual(usage.windows[1].resetsAt, Date(timeIntervalSince1970: 1_790_500_000))
        XCTAssertEqual(usage.organization, "Acme")
        XCTAssertThrowsError(try LongCatUsage.unwrap(json(#"{"code":401}"#)))
    }

    func testManusCredits() throws {
        let usage = try ManusUsage.map(json("""
        {"data":{"totalCredits":1500,"freeCredits":300,"periodicCredits":600,"proMonthlyCredits":800,
         "refreshCredits":200,"maxRefreshCredits":300,"nextRefreshTime":"2026-09-22T00:00:00Z"}}
        """))
        XCTAssertEqual(usage.windows.map(\.id), ["monthly", "daily"])
        XCTAssertEqual(usage.windows[0].usedPercent, 25)
        XCTAssertEqual(try XCTUnwrap(usage.windows[1].usedPercent), 100.0 / 3, accuracy: 0.01)
        XCTAssertEqual(usage.windows[1].resetsAt, Fmt.iso("2026-09-22T00:00:00Z"))
        XCTAssertThrowsError(try ManusUsage.map(json(#"{"data":{"other":1}}"#)))
    }

    func testMoonshotBalance() throws {
        let usage = try MoonshotUsage.map(json("""
        {"code":0,"scode":"0x0","status":true,"data":{"available_balance":49.58,"voucher_balance":46.58,"cash_balance":3}}
        """))
        XCTAssertEqual(usage.cost?.balance, 49.58)
        XCTAssertEqual(usage.cost?.currency, "USD")
        let china = try MoonshotUsage.map(json("""
        {"code":0,"scode":"0x0","status":true,"data":{"available_balance":10,"voucher_balance":0,"cash_balance":-2}}
        """), currency: "CNY")
        XCTAssertEqual(china.cost?.currency, "CNY")
        XCTAssertTrue(china.sections[0].rows.contains { $0.label == "In deficit" })
    }

    func testMuseWindowsAndTokenSources() throws {
        let usage = try MuseUsage.map(json("""
        {"api_key":"LLM|fixture","payment_method":"Visa-0000","require_payment":false,"is_subs_active":true,
         "user_email":"ada@example.com","subs_tier_name":"Muse Code Power Usage",
         "subs_usage":{"window":{"used_percent":96,"window_duration_mins":300,"resets_at":1788599502},
                       "weekly":{"used_percent":40,"resets_at":1788739200}}}
        """))
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(usage.windows[0].usedPercent, 96)
        XCTAssertEqual(usage.windows[0].windowMinutes, 300)
        XCTAssertEqual(usage.windows[1].resetsAt, Date(timeIntervalSince1970: 1_788_739_200))
        XCTAssertEqual(usage.plan, "Muse Code Power Usage")
        XCTAssertEqual(usage.email, "ada@example.com")
        let file = Data(#"{"providers":{"meta":{"access_token":"dca:abc"}}}"#.utf8)
        let credential = ProviderCredential(files: [".config/muse/auth.json": file])
        XCTAssertEqual(MuseUsage.token(credential), "dca:abc")
        XCTAssertEqual(MuseUsage.token(ProviderCredential(fields: ["token": "dca:pasted"], files: credential.files)), "dca:pasted")
        let idle = try MuseUsage.map(json(#"{"is_subs_active":true,"subs_tier_name":"Free","subs_usage":null}"#))
        XCTAssertTrue(idle.windows.isEmpty)
        XCTAssertThrowsError(try MuseUsage.map(json(#"{"is_subs_active":false}"#)))
    }

    func testNeuralwatt() throws {
        let usage = try NeuralwattUsage.map(json("""
        {"balance":{"credits_remaining_usd":7.5,"total_credits_usd":10,"credits_used_usd":2.5,"accounting_method":"energy"},
         "subscription":{"plan":"pro_max","kwh_included":100,"kwh_used":25,
           "current_period_start":"2026-09-01T00:00:00Z","current_period_end":"2026-10-01T00:00:00Z"},
         "key":{"allowance":{"limit_usd":20,"spent_usd":5,"blocked":false,"period":"monthly"}}}
        """))
        XCTAssertEqual(usage.windows.map(\.id), ["subscription", "key"])
        XCTAssertEqual(usage.windows[0].usedPercent, 25)
        XCTAssertEqual(usage.windows[0].windowMinutes, 30 * 24 * 60)
        XCTAssertEqual(usage.windows[1].usedPercent, 25)
        XCTAssertEqual(usage.cost?.balance, 7.5)
        XCTAssertEqual(usage.plan, "Pro Max plan")
    }

    func testNotionWindowsAndIdentity() throws {
        let usage = try NotionUsage.map(json("""
        {"status":"active","resetsInSeconds":3600,
         "window":{"used":20,"limit":100,"window":"5h"},
         "billingPeriodWindow":{"used":150,"limit":100,"periodEndMs":1791000000000}}
        """), identity: .init(email: "ada@example.com", workspaceName: "Acme", tier: "business"), now: now)
        XCTAssertEqual(usage.windows.map(\.id), ["rolling", "monthly"])
        XCTAssertEqual(usage.windows[0].windowMinutes, 300)
        XCTAssertEqual(usage.windows[0].resetsAt, now.addingTimeInterval(3600))
        XCTAssertEqual(usage.windows[1].usedPercent, 100)
        XCTAssertEqual(usage.windows[1].resetsAt, Date(timeIntervalSince1970: 1_791_000_000))
        XCTAssertEqual(usage.plan, "Business")
        let spaces = try json("""
        {"u1":{"notion_user":{"u1":{"value":{"value":{"id":"u1","email":"ada@example.com"}}}},
               "space":{"s1":{"value":{"value":{"id":"s1","name":"Personal","subscription_tier":"free"}}},
                        "s2":{"value":{"value":{"id":"s2","name":"Acme","subscription_tier":"business"}}}}}}
        """)
        let identity = try NotionUsage.identity(spaces: spaces, preferred: nil)
        XCTAssertEqual(identity.workspaceID, "s2")
        XCTAssertEqual(identity.email, "ada@example.com")
        XCTAssertEqual(NotionUsage.dashed("0123456789abcdef0123456789abcdef"), "01234567-89ab-cdef-0123-456789abcdef")
    }

    func testNousSubscriptionCredits() throws {
        let usage = try NousUsage.map(json("""
        {"user":{"email":"ada@example.com"},"organisation":{"name":"Acme"},
         "subscription":{"plan":"Plus","monthly_credits":20,"credits_remaining":5,"current_period_end":"2026-10-01T00:00:00Z"},
         "paid_service_access":{"purchased_credits_remaining":3,"total_usable_credits":8}}
        """))
        XCTAssertEqual(usage.windows.first?.id, "monthly")
        XCTAssertEqual(usage.windows.first?.usedPercent, 75)
        XCTAssertEqual(usage.windows.first?.resetsAt, Fmt.iso("2026-10-01T00:00:00Z"))
        XCTAssertEqual(usage.cost?.balance, 8)
        XCTAssertEqual(usage.plan, "Plus")
        XCTAssertEqual(usage.email, "ada@example.com")
        let auth = Data(#"{"providers":{"nous":{"access_token":"tok","portal_base_url":"https://portal.nousresearch.com"}}}"#.utf8)
        XCTAssertEqual(NousUsage.token(ProviderCredential(files: [".hermes/auth.json": auth]))?.token, "tok")
    }

    func testOpenAIAdminCostsAndCreditFallback() throws {
        let day = 1_789_948_800 // 2026-09-21T00:00:00Z
        let costs = try [json("""
        {"start_time":\(day),"end_time":\(day + 86400),"results":[{"amount":{"value":1.5,"currency":"usd"},"line_item":"gpt"},
         {"amount":{"value":0.5,"currency":"usd"}}]}
        """), json("""
        {"start_time":\(day - 86400),"end_time":\(day),"results":[{"amount":{"value":2,"currency":"usd"}}]}
        """)]
        let completions = try [json("""
        {"start_time":\(day),"end_time":\(day + 86400),"results":[
         {"model":"gpt-5","num_model_requests":10,"input_tokens":1000,"output_tokens":500},
         {"model":"gpt-mini","num_model_requests":5,"input_tokens":100,"output_tokens":50}]}
        """)]
        let usage = try OpenAIUsage.map(costs: costs, completions: completions, now: now)
        XCTAssertEqual(usage.cost?.used, 4)
        let rows = Dictionary(uniqueKeysWithValues: usage.sections[0].rows.map { ($0.label, $0.value) })
        XCTAssertEqual(rows["Today (UTC)"], "$2.00")
        XCTAssertEqual(rows["Requests"], "15")
        XCTAssertEqual(usage.sections[1].rows.first?.label, "gpt-5")
        let credits = try OpenAIUsage.mapCredits(json(#"{"total_granted":20,"total_used":5,"total_available":15}"#), now: now)
        XCTAssertEqual(credits.windows.first?.usedPercent, 25)
        XCTAssertEqual(credits.cost?.balance, 15)
    }

    func testOpenRouterCreditsAndKeySpend() throws {
        let credits = try json(#"{"data":{"total_credits":100,"total_usage":40}}"#)
        let key = try json("""
        {"data":{"limit":10,"limit_remaining":2.5,"limit_reset":"daily","usage":55,
         "usage_daily":7.5,"usage_weekly":20,"usage_monthly":40,"is_free_tier":false}}
        """)
        let usage = try OpenRouterUsage.map(credits: credits, key: key)
        XCTAssertEqual(usage.windows.map(\.id), ["key", "credits"])
        XCTAssertEqual(usage.windows[0].usedPercent, 75)
        XCTAssertEqual(usage.windows[0].windowMinutes, 1440)
        XCTAssertEqual(usage.windows[1].usedPercent, 40)
        XCTAssertEqual(usage.cost?.balance, 60)
        XCTAssertEqual(usage.cost?.used, 40)
        XCTAssertEqual(usage.plan, "Pay as you go")
        let spend = Dictionary(uniqueKeysWithValues: usage.sections[0].rows.map { ($0.label, $0.value) })
        XCTAssertEqual(spend["Today"], "$7.50")
        XCTAssertEqual(spend["This week"], "$20.00")
        XCTAssertEqual(spend["This month"], "$40.00")
        // Either payload alone is enough.
        XCTAssertEqual(try OpenRouterUsage.map(credits: credits, key: nil).cost?.balance, 60)
        XCTAssertThrowsError(try OpenRouterUsage.map(credits: nil, key: nil))
    }

    func testPerplexityCreditPools() throws {
        let usage = try PerplexityUsage.map(json("""
        {"balance_cents":1500,"renewal_date_ts":1791000000,"current_period_purchased_cents":500,"total_usage_cents":1200,
         "credit_grants":[{"type":"recurring","amount_cents":1000},
                          {"type":"purchased","amount_cents":500},
                          {"type":"promotional","amount_cents":300,"expires_at_ts":1795000000}]}
        """), now: now)
        XCTAssertEqual(usage.windows.map(\.id), ["credits", "bonus", "purchased"])
        XCTAssertEqual(usage.windows[0].usedPercent, 100)
        XCTAssertEqual(usage.windows[1].usedPercent, 0)
        XCTAssertEqual(try XCTUnwrap(usage.windows[2].usedPercent), 40, accuracy: 0.01)
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1_791_000_000))
        XCTAssertEqual(usage.plan, "Pro")
        XCTAssertEqual(PerplexityUsage.cookies("abc").count, 4)
        XCTAssertEqual(PerplexityUsage.cookies("Cookie: a=b; c=d"), ["a=b; c=d"])
    }

    func testPoeBalanceAndHistory() throws {
        let t = Int(now.timeIntervalSince1970 * 1_000_000) // microseconds
        let history = try [
            json(#"{"creation_time":\#(t - 3_600_000_000),"cost_points":100,"cost_usd":0.003,"bot_name":"GPT-5"}"#),
            json(#"{"creation_time":\#(t - 3 * 86_400_000_000),"cost_points":300,"bot_name":"Claude"}"#),
            json(#"{"creation_time":\#(t - 40 * 86_400_000_000),"cost_points":999,"bot_name":"Old"}"#),
        ]
        let usage = try PoeUsage.map(balance: json(#"{"current_point_balance":123456}"#), history: history, now: now)
        let rows = Dictionary(uniqueKeysWithValues: usage.sections[0].rows.map { ($0.label, $0.value) })
        XCTAssertEqual(rows["Current balance"], "123,456 points")
        XCTAssertEqual(rows["Last 24 hours"], "100 points · 1 requests · $0.00")
        XCTAssertEqual(rows["Last 30 days"], "400 points · 2 requests · $0.00")
        XCTAssertEqual(rows["Top model"], "Claude · 300 points")
    }

    func testQoderCredits() throws {
        let usage = try QoderUsage.map(json("""
        {"totalQuota":{"quotaSummary":{"usedValue":250,"limitValue":1000,"remainingValue":750,"usagePercentage":25,"unit":"credits"}},
         "nextResetAt":1791000000}
        """))
        XCTAssertEqual(usage.windows.first?.usedPercent, 25)
        XCTAssertEqual(usage.windows.first?.detail, "250 / 1,000 credits")
        XCTAssertEqual(usage.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_791_000_000))
        let shared = try QoderUsage.map(json("""
        {"total_quota":{"quota_summary":{"used_value":100,"limit_value":200}},
         "shared_quota":{"quota_summary":{"used_value":100,"limit_value":800}}}
        """))
        XCTAssertEqual(shared.windows.first?.usedPercent, 20)
    }

    func testQwenCloudTeamCredits() throws {
        let start = (now.timeIntervalSince1970 - 86400) * 1000
        let end = (now.timeIntervalSince1970 + 86400) * 1000
        let summary = try json("""
        {"Data":{"ProductCode":"sfm_tokenplanteams_dp_intl","StartTime":\(Int(start)),"EndTime":\(Int(end)),
         "SubscriptionGroupList":[{"SpecType":"standard","SubscriptionAssignedNumber":3,"SubscriptionTotalNumber":5,
          "NextCycleFlushTime":1791000000000,
          "EquityList":[{"EquityCode":"credit_value","TotalValue":"1000","SurplusValue":"400"}]}]}}
        """)
        let usage = try QwenCloudTeamUsage.map(summary, now: now)
        XCTAssertEqual(usage.windows.first?.usedPercent, 60)
        XCTAssertEqual(usage.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_791_000_000))
        XCTAssertEqual(usage.plan, "Standard Team")
        XCTAssertEqual(usage.sections[0].rows.last?.value, "3 / 5")
        XCTAssertTrue(try QwenCloudTeamUsage.map(json(#"{"Data":null}"#), now: now).isEmpty)
    }

    func testRaycastCredits() throws {
        let usage = try RaycastUsage.map(json("""
        {"remaining_balance_credits":"75","total_balance_credits":100,"next_credits_at":"2026-10-01T00:00:00Z",
         "funding_subscription":{"tier":"pro_plus"}}
        """))
        XCTAssertEqual(usage.windows.first?.usedPercent, 25)
        XCTAssertEqual(usage.windows.first?.detail, "75 / 100 credits left")
        XCTAssertEqual(usage.windows.first?.resetsAt, Fmt.iso("2026-10-01T00:00:00Z"))
        XCTAssertEqual(usage.plan, "Pro+")
    }

    func testReplicateInvoiceAndAccount() throws {
        let html = """
        <html><script id="react-component-props-1" type="application/json">
        {"props":{"nested":[{"account":{"kind":"organization","username":"acme"}}]}}</script></html>
        """
        let account = try XCTUnwrap(ReplicateUsage.account(html: html))
        XCTAssertEqual(account, .init(username: "acme", isOrganization: true))
        let invoices = try json("""
        {"invoices":[{"type":"monthly-usage","ended_before":"2026-08-01T00:00:00Z","total_cost_before_adjustments":"9.99"},
                     {"type":"monthly-usage","ended_before":"2026-10-01T00:00:00Z","total_cost_before_adjustments":"12.34"}]}
        """)
        let usage = try ReplicateUsage.map(invoices: invoices, credit: json(#"{"unused_credit":"5.50"}"#),
                                           account: account, now: now)
        XCTAssertEqual(usage.cost?.used, 12.34)
        XCTAssertEqual(usage.cost?.balance, 5.5)
        XCTAssertEqual(usage.organization, "acme")
        XCTAssertTrue(ReplicateUsage.signedOut("<title>Sign in | Replicate</title>"))
    }
}
