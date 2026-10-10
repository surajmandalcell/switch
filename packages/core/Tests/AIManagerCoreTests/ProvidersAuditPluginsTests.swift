import Foundation
import XCTest
@testable import AIManagerCore

/// One fixture test per plugin provider. Each asserts the values CodexBar's plugin returns that the first port dropped
/// (extra windows, detail rows, identity, renewal and expiry dates), plus the plugin's own fixture values.
final class ProvidersAuditPluginsTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }
    private func utc(_ text: String) -> Date { Fmt.iso(text)! }

    private func section(_ usage: ProviderUsage, _ title: String) throws -> UsageSection {
        try XCTUnwrap(usage.sections.first { $0.title == title }, "missing section \(title)")
    }

    /// Row label to value of one section.
    private func rows(_ usage: ProviderUsage, _ title: String) throws -> [String: String] {
        Dictionary(try section(usage, title).rows.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: A

    func testAbacus() throws {
        let usage = try AbacusUsage.map(
            json(#"{"success":true,"result":{"totalComputePoints":1000,"computePointsLeft":750}}"#),
            billing: json(#"{"success":true,"result":{"nextBillingDate":"2026-07-01T00:00:00Z","currentTier":"Pro"}}"#))
        XCTAssertEqual(usage.windows[0].usedPercent, 25)
        XCTAssertEqual(usage.windows[0].detail, "250 / 1,000 credits")
        XCTAssertEqual(usage.windows[0].windowMinutes, 30 * 1440)
        XCTAssertEqual(usage.windows[0].resetsAt, utc("2026-07-01T00:00:00Z"))
        XCTAssertEqual(usage.plan, "Pro")
    }

    func testAerostack() throws {
        let usage = try AerostackUsage.map(json(
            #"{"usage":{"ai_tokens":{"used":1200,"limit":1000}},"period":"2026-06","tier":" Pro "}"#))
        XCTAssertEqual(try section(usage, "Monthly AI tokens").rows.map(\.label),
                       ["Tokens used", "Allowance", "Remaining", "Above allowance", "Period"])
        let values = try rows(usage, "Monthly AI tokens")
        XCTAssertEqual(values["Tokens used"], "1,200")
        XCTAssertEqual(values["Remaining"], "0")
        XCTAssertEqual(values["Above allowance"], "200")
        XCTAssertEqual(values["Period"], "2026-06")
        XCTAssertEqual(usage.windows[0].usedPercent, 100)
        XCTAssertEqual(usage.plan, "Pro")
    }

    func testAiand() throws {
        let page = try json(#"{"data":[{"cost":"0.5","currency":"usd"},{"cost":"0.25","currency":"USD"}],"has_more":false}"#)
        let usage = try AiandUsage.map([page])
        XCTAssertEqual(usage.cost?.used ?? 0, 0.75, accuracy: 1e-9)
        XCTAssertEqual(usage.cost?.currency, "USD")
        XCTAssertEqual(usage.cost?.period, "Last 30 days")
    }

    func testAixy() throws {
        let usage = try AixyUsage.map(json(#"""
        {"object":"key.usage","currency":"USD","as_of":"2026-06-10T00:00:00Z",
         "key":{"id":"k1","name":"CI key","project_id":"p1","project_name":"Proj"},
         "budgets":[
          {"id":"b2","scope":"organization","interval":"daily","enforcement":"monitor","shared":true,"limit_usd":10,
           "spend_status":"available","spend_usd":2,"remaining_usd":8,"availability":{"status":"not_enforced"}},
          {"id":"b3","scope":"project","interval":"weekly","enforcement":"hard","shared":false,"limit_usd":50,
           "spend_status":"unavailable","availability":{"status":"unavailable"}},
          {"id":"b1","scope":"api_key","interval":"monthly","enforcement":"hard","shared":false,"limit_usd":100,
           "availability":{"status":"available","spent_usd":20,"reserved_usd":5,"remaining_usd":75},
           "spend_status":"available","starts_at":"2026-06-01T00:00:00Z","resets_at":"2026-07-01T00:00:00Z"}],
         "usage":{"window":"7d","requests":10,"total_tokens":1000,"attributed_requests":8,"partial_requests":1,"spend_usd":3.5}}
        """#))
        // The two lead windows are the first known budgets; the unavailable one follows.
        XCTAssertEqual(usage.windows.map(\.id), ["aixy-b1", "aixy-b2", "aixy-b3"])
        XCTAssertNil(usage.windows[2].usedPercent)
        XCTAssertEqual(usage.windows[2].detail, "Unavailable")
        XCTAssertEqual(try rows(usage, "Aixy key")["Observed"], "2026-06-10T00:00:00.000Z")
        XCTAssertEqual(try rows(usage, "Aixy key")["Project"], "Proj")
        // Applicable budgets are listed hard first, then known, then by fill.
        let budgets = try section(usage, "Applicable budgets").rows
        XCTAssertEqual(budgets.map(\.label), ["Key · Monthly · Personal · Hard", "Project · Weekly · Personal · Hard",
                                              "Organization · Daily · Shared · Monitor"])
        XCTAssertEqual(budgets[0].value, "$75.00 / $100.00 remaining · $20.00 spent · $5.00 reserved")
        XCTAssertEqual(budgets[0].progress, 0.25)
        XCTAssertEqual(budgets[1].value, "Unavailable")
        XCTAssertEqual(budgets[2].value, "$8.00 / $10.00 remaining · $2.00 spent")
        XCTAssertEqual(try rows(usage, "Last 7 days · this key")["Cost coverage"], "8 / 10 requests · 1 partial")
        XCTAssertEqual(usage.cost?.used, 3.5)
        XCTAssertEqual(usage.plan, "API key")
    }

    func testAtlascloud() throws {
        let usage = try AtlascloudUsage.map(json(
            #"{"object":"balance","scope":"account","available":{"currency":"usd","value":"12.34"}}"#))
        XCTAssertEqual(usage.cost?.balance, 12.34)
        XCTAssertEqual(try rows(usage, "Account balance")["Available balance"], "$12.34")
    }

    func testBifrost() throws {
        let now = utc("2026-06-01T10:30:00Z")
        let usage = try BifrostUsage.map(json(#"""
        {"virtual_key_name":"team-key","is_active":false,
         "budgets":[
          {"id":"b1","source_name":"Main","max_limit":100,"current_usage":25,"reset_duration":"1h",
           "last_reset":"2026-06-01T10:00:00Z",
           "per_model_usage":[
            {"model":"anthropic.claude-3-5-sonnet-20241022-v2:0","provider":"bedrock","total_cost":10,"total_tokens":1500},
            {"model":"gpt-4o","provider":"openai","total_cost":5,"total_tokens":2500000},
            {"model":"idle","total_cost":0,"total_tokens":0}]},
          {"id":"b2","source_name":"Backup","max_limit":50,"current_usage":5,"reset_duration":"1M"}]}
        """#), now: now)
        // The inactive marker follows the two lead budget windows.
        XCTAssertEqual(usage.windows.map(\.id), ["bifrost-budget-b1", "bifrost-budget-b2", "bifrost-key-inactive"])
        let models = try section(usage, "Models").rows
        XCTAssertEqual(models.map(\.label), ["bedrock · claude-3-5-sonnet", "openai · gpt-4o"])
        XCTAssertEqual(models[0].value, "$10.00 · 1.5K tokens")
        XCTAssertEqual(models[1].value, "$5.00 · 2.5M tokens")
        let budgets = try section(usage, "Budgets").rows
        XCTAssertEqual(budgets.map(\.label), ["Main", "Backup"])
        XCTAssertEqual(budgets[0].value, "$25.00 / $100.00 · Hourly")
        XCTAssertEqual(budgets[1].value, "$5.00 / $50.00 · Monthly")
        XCTAssertEqual(usage.email, "team-key")
        XCTAssertEqual(usage.organization, "Main")
    }

    // MARK: C

    func testChutes() throws {
        let usage = try ChutesUsage.map(json(#"""
        {"subscription":{"active":true,"plan_name":"Pro","current_period_end":"2026-07-01T00:00:00Z"},
         "monthly":{"used":250,"limit":1000,"unit":"credits"}}
        """#))
        XCTAssertEqual(usage.plan, "Pro")
        XCTAssertEqual(usage.windows[0].resetsAt, utc("2026-07-01T00:00:00Z"))
        XCTAssertEqual(try rows(usage, "Subscription"), ["Renews": "2026-07-01"])
        let empty = try ChutesUsage.map(json(#"{"unrelated":true}"#))
        XCTAssertEqual(empty.plan, "No usage data")
        XCTAssertTrue(empty.windows.isEmpty)
    }

    func testClawrouter() throws {
        let usage = try ClawrouterUsage.map(json(#"""
        {"budget":{"configured":true,"ledger":"monthly","limitMicros":10000000,"spentMicros":2500000,
                   "remainingMicros":7500000,"windowKey":"monthly:2026-06"},
         "usage":{"summary":{"requestCount":10,"successCount":9,"errorCount":1,"inputTokens":100,"outputTokens":50,
                             "totalTokens":150,"actualCostMicros":2500000},
                  "providers":[{"provider":"openai","requestCount":4,"successCount":4,"errorCount":0,"totalTokens":50,
                                "actualCostMicros":500000},
                               {"provider":"anthropic","requestCount":6,"successCount":5,"errorCount":1,"totalTokens":100,
                                "actualCostMicros":2000000}]}}
        """#))
        let values = try rows(usage, "Usage")
        XCTAssertEqual(values["Requests"], "10 · 9 succeeded · 1 failed")
        XCTAssertEqual(values["Tokens"], "150 · 100 input · 50 output")
        XCTAssertEqual(values["Actual cost"], "$2.500000")
        XCTAssertEqual(values["Budget ledger"], "monthly")
        XCTAssertEqual(values["Monthly budget"], "$2.500000 / $10.00 · $7.500000 remaining")
        let providers = try section(usage, "Routed providers").rows
        XCTAssertEqual(providers[0].label, "anthropic")
        XCTAssertEqual(providers[0].value, "6 requests · $2.000000 · 100 tokens")
    }

    func testClinepass() throws {
        let usage = try ClinepassUsage.map(json(#"""
        {"success":true,"data":{"limits":[{"type":"five_hour","percentUsed":10},{"type":"weekly","percentUsed":20},
        {"type":"monthly","percentUsed":30}]}}
        """#))
        XCTAssertEqual(usage.windows.map(\.windowMinutes), [300, 10_080, 43_200])
        XCTAssertEqual(usage.plan, "API key")
    }

    func testCosmic() throws {
        let usage = try CosmicUsage.map(json(#"""
        {"usage":{"ai":{"input_tokens":1500000,"output_tokens":100}},
         "plan_info":{"ai_tokens":{"max_input":"1M","max_output":"unlimited"}}}
        """#))
        // Input is over its allowance; output has no number, so it has a section but no window.
        XCTAssertEqual(usage.windows.map(\.id), ["input"])
        XCTAssertEqual(usage.windows[0].usedPercent, 100)
        XCTAssertEqual(try section(usage, "Input tokens").rows.map(\.label), ["Used", "Allowance", "Remaining", "Above allowance"])
        XCTAssertEqual(try rows(usage, "Input tokens")["Above allowance"], "500,000")
        XCTAssertEqual(try rows(usage, "Output tokens")["Allowance"], "Unlimited")
    }

    // MARK: D

    func testDeepgram() throws {
        let breakdown = try json(#"{"start":"2026-06-01","end":"2026-06-30","results":[{"hours":1.5,"total_hours":2,"requests":10}]}"#)
        let one = try DeepgramUsage.map([breakdown], projects: ["Main"])
        XCTAssertEqual(one.plan, "Project: Main")
        XCTAssertEqual(one.organization, "Main")
        XCTAssertEqual(try rows(one, "Usage summary")["Period"], "2026-06-01 to 2026-06-30")
        let two = try DeepgramUsage.map([breakdown, breakdown], projects: ["A", "B"])
        XCTAssertEqual(two.plan, "2 projects")
        XCTAssertEqual(try rows(two, "Usage summary")["Requests"], "20")
    }

    func testDeepinfra() throws {
        let credit = try DeepinfraUsage.map(
            checklist: json(#"{"recent":3.5,"stripe_balance":-10,"limit":50,"suspended":false}"#),
            usage: json(#"{"months":[{"period":"2026-06","total_cost":1250}]}"#))
        XCTAssertEqual(credit.windows[0].usedPercent, 0)
        XCTAssertEqual(credit.windows[0].detail, "$6.50 available · $12.50 spent this month")
        let owed = try DeepinfraUsage.map(
            checklist: json(#"{"recent":1,"stripe_balance":5,"suspended":true,"suspend_reason":"Card declined"}"#),
            usage: json(#"{"months":[]}"#))
        XCTAssertEqual(owed.windows[0].usedPercent, 100)
        XCTAssertEqual(owed.windows[0].detail, "Suspended: Card declined · $6.00 owed · $1.00 spent this month")
    }

    func testDevpass() throws {
        let usage = try DevpassUsage.map(json(#"""
        {"data":{"devPlan":"max","usage":"1.5","limit":"10","devPlanCreditsUsed":"5","devPlanCreditsLimit":"20",
                 "devPlanCreditsRemaining":"15","devPlanPremiumCreditsUsed":"1","devPlanPremiumWeeklyLimit":"4",
                 "devPlanPremiumWeekResetsAt":"2026-06-15T00:00:00Z"}}
        """#))
        XCTAssertEqual(usage.plan, "DevPass Max")
        XCTAssertEqual(try rows(usage, "DevPass credits"),
                       ["Cycle used": "$5.00 / $20.00", "Cycle remaining": "$15.00", "Premium weekly": "$1.00 / $4.00"])
        XCTAssertEqual(try rows(usage, "API key (all time)"), ["All-time key usage": "$1.50", "Key spending limit": "$10.00"])
        XCTAssertEqual(usage.windows[1].resetsAt, utc("2026-06-15T00:00:00Z"))
    }

    // MARK: E

    func testElevenlabs() throws {
        let usage = try ElevenlabsUsage.map(json(#"""
        {"character_count":2500,"character_limit":10000,"voice_slots_used":3,"voice_limit":10,
         "professional_voice_slots_used":1,"professional_voice_limit":2,"tier":"pro_plus","status":"active",
         "next_character_count_reset_unix":1781000000}
        """#))
        XCTAssertEqual(usage.windows.map(\.id), ["credits", "voice-slots", "professional-voices"])
        XCTAssertEqual(usage.windows[1].detail, "3 / 10")
        XCTAssertEqual(usage.windows[2].detail, "1 / 2")
        XCTAssertEqual(usage.plan, "Pro Plus")
    }

    func testExa() throws {
        let usage = try ExaUsage.map(json(
            #"{"total_cost_usd":12.5,"period":{"start":"2026-06-01T00:00:00.000Z","end":"2026-06-10T00:00:00.000Z"}}"#))
        XCTAssertEqual(usage.plan, "Service key")
        XCTAssertEqual(try rows(usage, "API key this month (UTC)"), ["Spend": "$12.50"])
    }

    // MARK: F

    func testFireworks() throws {
        let usage = try FireworksUsage.map(json(#"""
        {"lineItems":[{"totalCost":{"units":"12","nanos":500000000,"currencyCode":"USD"}},
                      {"totalCost":{"units":"1","nanos":0,"currencyCode":"EUR"}}]}
        """#))
        XCTAssertEqual(usage.cost?.used ?? 0, 12.5, accuracy: 1e-9)
        XCTAssertEqual(usage.cost?.period, "Last 30 days")
    }

    // MARK: G

    func testGitkraken() throws {
        let unlimited = try GitkrakenUsage.map(json(
            #"{"data":{"used":10,"limit":-1,"resetsOn":"2026-07-01T00:00:00Z"}}"#))
        XCTAssertTrue(unlimited.windows.isEmpty)
        let values = try rows(unlimited, "Weekly usage")
        XCTAssertEqual(values["Personal"], "10 credits used · Unlimited")
        XCTAssertEqual(values["Reset"], "2026-07-01T00:00:00.000Z")
        let limited = try GitkrakenUsage.map(json(
            #"{"data":{"used":10,"limit":100,"resetsOn":"2026-07-01T00:00:00Z"}}"#))
        XCTAssertNil(try rows(limited, "Weekly usage")["Reset"])
    }

    // MARK: H

    func testHelmcode() throws {
        let quota = try json(#"{"periodStart":"2026-06-01T00:00:00Z","models":[{"model":"qwen","cap":1000,"tokensUsed":250,"creditTokens":100}]}"#)
        let usage = try HelmcodeUsage.map(quota, organization: "NaN Builders")
        XCTAssertEqual(usage.plan, "Dashboard session")
        XCTAssertEqual(usage.organization, "NaN Builders")
        XCTAssertEqual(usage.windows[0].detail, "250 / 1,000 tokens · 100 credit-funded")
        // periodEnd is missing, so the reset is the first of the month after periodStart.
        XCTAssertEqual(usage.windows[0].resetsAt, utc("2026-07-01T00:00:00Z"))
    }

    func testHuggingface() throws {
        let html = """
        <div class="x" data-props="{&quot;entity&quot;:{&quot;type&quot;:&quot;user&quot;,&quot;currentBalanceUsd&quot;:12.5}}"></div>
        """
        XCTAssertEqual(HuggingfaceUsage.walletBalance(html: html), 12.5)
        let legacy = #"<div data-props='{"invoiceCreditsCents":250}'></div>"#
        XCTAssertEqual(HuggingfaceUsage.walletBalance(html: legacy), 2.5)
        // Two wallets are ambiguous.
        XCTAssertNil(HuggingfaceUsage.walletBalance(html: html + html))
        let usage = try HuggingfaceUsage.map(
            json(#"{"usage":{"inferenceProviders":{"usedNanoUsd":5000000000,"includedNanoUsd":2000000000}}}"#),
            profile: json(#"{"name":"ada","isPro":false}"#), balance: 12.5)
        XCTAssertEqual(usage.cost?.balance, 12.5)
        XCTAssertEqual(try rows(usage, "Credits"), ["Prepaid balance": "$12.50"])
        XCTAssertEqual(try rows(usage, "Account"), ["Username": "ada"])
        XCTAssertEqual(usage.plan, "Free")
    }

    func testHyper() throws {
        let usage = try HyperUsage.map(json(#"{"balance":1234.567}"#))
        XCTAssertEqual(usage.cost?.balance, 1234.567)
        XCTAssertEqual(usage.cost?.currency, "HC")
        XCTAssertEqual(try rows(usage, "Hypercredits"), ["Balance": "1,234.57 HC"])
    }

    // MARK: L

    func testLangdock() throws {
        let usage = try LangdockUsage.map(json(#"""
        [{"result":{"data":{"json":{"hasIncludedUsageLimits":true,"planUsage":{
           "sessionUsageLimitsEnabled":false,"weeklyUsagePercent":40,"weeklyResetsAt":"2026-06-15T00:00:00Z"}}}}}]
        """#))
        // Session limits are off, so only the weekly window shows.
        XCTAssertEqual(usage.windows.map(\.id), ["weekly"])
        XCTAssertEqual(usage.windows[0].windowMinutes, 10_080)
        let none = try LangdockUsage.map(json(
            #"[{"result":{"data":{"json":{"hasIncludedUsageLimits":false}}}}]"#))
        XCTAssertEqual(try rows(none, "Usage"), ["Included limits": "No included usage limits available"])
    }

    func testLinkup() throws {
        let usage = try LinkupUsage.map(json(#"{"balance":4.25}"#))
        XCTAssertEqual(usage.cost?.balance, 4.25)
        XCTAssertEqual(usage.plan, "API")
        XCTAssertEqual(try rows(usage, "Account balance"), ["Credit balance": "$4.25"])
    }

    func testLiteLLM() throws {
        let key = try json(#"{"info":{"user_id":"u1","expires":"2026-12-31T00:00:00Z"}}"#)
        let user = try json(#"{"user_info":{"user_id":"u1","user_email":"ada@example.com","spend":5,"max_budget":50}}"#)
        let page = try json(#"""
        {"results":[
          {"date":"2026-09-20","breakdown":{"models":{
            "gpt-4o":{"metrics":{"prompt_tokens":100,"completion_tokens":50,"total_tokens":150,"api_requests":3}},
            "small":{"metrics":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2,"api_requests":1}}}}},
          {"date":"2026-09-21","breakdown":{"models":{
            "gpt-4o":{"metrics":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15,"api_requests":1}}}}}],
         "metadata":{"page":1,"total_pages":1,"has_more":false}}
        """#)
        let activity = LiteLLMUsage.modelActivity([page])
        let usage = try LiteLLMUsage.map(key: key, user: user, team: nil, activity: activity)
        let model = try section(usage, "Model activity · 30d UTC").rows
        XCTAssertEqual(model.map(\.label), ["gpt-4o", "small"])
        XCTAssertEqual(model[0].value, "165 tokens · 4 requests · Input 110 · Output 55")
        XCTAssertEqual(try rows(usage, "Subscription"), ["Expires": "2026-12-31"])
        XCTAssertEqual(usage.email, "ada@example.com")
        XCTAssertNil(LiteLLMUsage.modelActivity([]))
    }

    func testLithosAI() throws {
        let usage = try LithosAIUsage.map(
            me: json(#"{"user":{"email":"ada@example.com"},"activeOrganization":{"id":"o1","name":"Lab"}}"#),
            billing: json(#"{"balanceNanos":5000000,"hasCard":false,"onHold":true}"#), spend: nil, today: "2026-09-21")
        XCTAssertEqual(usage.plan, "Browser session")
        let values = try rows(usage, "Billing")
        XCTAssertEqual(values["Balance"], "Less than $0.01")
        XCTAssertEqual(values["Payment card"], "Not added")
        XCTAssertEqual(values["Account status"], "On hold")
        XCTAssertEqual(values["Spend"], "Unavailable")
    }

    func testLlmman() throws {
        let node = try json(#"{"memory":10000000000,"loaded":{"a":4000000000},"stored":{"a":4000000000,"b":500}}"#)
        let usage = try LlmmanUsage.map(node, version: "0.5.1", hasKey: true)
        XCTAssertEqual(usage.plan, "API key")
        XCTAssertEqual(try rows(usage, "Daemon"), ["Loaded": "1 · 4.0 GB", "Stored": "2 · 4.0 GB", "Version": "0.5.1"])
        XCTAssertEqual(try section(usage, "Loaded models").rows[0].progress, 0.4)
        XCTAssertEqual(usage.windows[0].detail, "4.0 GB of 10.0 GB")
    }

    func testLlmproxy() throws {
        let now = utc("2026-06-01T00:00:00Z")
        let usage = try LlmproxyUsage.map(json(#"""
        {"summary":{"total_requests":30,"total_tokens":900,"approx_cost":1.5},
         "providers":{"a":{"credential_count":2,"active_count":1,"total_requests":20,"approx_cost":1,
                           "tokens":{"input_cached":1,"input_uncached":2,"output":3},
                           "quota_groups":{"g":{"remaining_percent":40,"reset_time":"2026-06-02T00:00:00Z"}}},
                      "b":{"credential_count":1,"active_count":1,"total_requests":10}}}
        """#), now: now)
        XCTAssertEqual(usage.plan, "quota-stats")
        XCTAssertEqual(usage.organization, "2/3 active keys")
        XCTAssertEqual(usage.windows[0].usedPercent, 60)
        XCTAssertEqual(usage.windows[0].resetsAt, utc("2026-06-02T00:00:00Z"))
        XCTAssertEqual(try rows(usage, "Totals"), ["Requests": "30", "Tokens": "900"])
        XCTAssertEqual(try section(usage, "Providers").rows[0].value, "20 req · 6 tok · $1.00")
        XCTAssertEqual(usage.cost?.used, 1.5)
    }

    func testLongcat() throws {
        let account = try LongCatUsage.unwrap(json(#"{"code":0,"data":{"nickName":"Ada"}}"#))
        let tokenUsage = try LongCatUsage.unwrap(json(#"{"code":0,"data":{"usage":{"totalToken":1000,"availableToken":600}}}"#))
        let usage = try LongCatUsage.map(account: account, summary: nil, tokenUsage: tokenUsage, fuel: nil)
        XCTAssertEqual(usage.windows[0].usedPercent, 40)
        XCTAssertEqual(usage.windows[0].detail, "400 / 1,000 tokens")
        XCTAssertEqual(usage.organization, "Ada")
    }

    // MARK: M

    func testManus() throws {
        let usage = try ManusUsage.map(json(#"""
        {"data":{"totalCredits":1500,"freeCredits":300,"periodicCredits":600,"proMonthlyCredits":800,
         "refreshCredits":200,"maxRefreshCredits":300,"refreshInterval":"DAILY"}}
        """#))
        XCTAssertEqual(usage.plan, "Balance: 1,500 credits")
        XCTAssertEqual(usage.windows[1].title, "Daily")
        XCTAssertEqual(usage.windows[1].detail, "Daily: 200 / 300")
        XCTAssertEqual(try rows(usage, "Balance"), ["Total credits": "1,500", "Free credits": "300"])
    }

    func testMoonshot() throws {
        let usd = try MoonshotUsage.map(json(
            #"{"code":0,"scode":"0x0","status":true,"data":{"available_balance":49.58,"voucher_balance":46.58,"cash_balance":3}}"#))
        XCTAssertEqual(usd.plan, "Balance: $49.58")
        let cny = try MoonshotUsage.map(json(
            #"{"code":0,"scode":"0x0","status":true,"data":{"available_balance":10,"voucher_balance":0,"cash_balance":-2}}"#),
            currency: "CNY")
        XCTAssertEqual(cny.plan, "Balance: \(Fmt.money(10, currency: "CNY")) · \(Fmt.money(2, currency: "CNY")) in deficit")
    }

    func testMuse() throws {
        let now = utc("2026-06-01T00:00:00Z")
        let quota = try json(#"""
        {"tier":"Power","weekly_weighted_used":"50","weekly_weighted_limit":"100","weekly_resets_at":1782000000,
         "window_duration_secs":18000,"window_weighted_used":"10","window_weighted_limit":"100","window_resets_at":1781000000}
        """#)
        let parsed = try XCTUnwrap(MuseUsage.webQuota(quota, now: now))
        XCTAssertEqual(parsed.primary.usedPercent, 10)
        XCTAssertEqual(parsed.primary.windowMinutes, 300)
        XCTAssertEqual(parsed.primary.resetsAt, Date(timeIntervalSince1970: 1_781_000_000))
        XCTAssertEqual(parsed.secondary.usedPercent, 50)
        XCTAssertEqual(parsed.secondary.windowMinutes, 10_080)
        // A weekly quota whose reset has passed is stale.
        XCTAssertNil(MuseUsage.webQuota(quota, now: utc("2030-01-01T00:00:00Z")))

        let idle = try json(#"{"is_subs_active":true,"subs_tier_name":"Power","user_email":"ada@example.com"}"#)
        let web = MuseUsage.Web(teams: [("7", "Core")], note: nil, quota: ("Core", parsed.primary, parsed.secondary))
        let usage = try MuseUsage.map(idle, web: web)
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(try rows(usage, "Browser team quota (dev.meta.ai)"),
                       ["Team": "Core", "5 hours": "10%", "Weekly": "50%"])
        XCTAssertEqual(try rows(usage, "Browser teams"), ["Core": "7"])
        let noTeam = try MuseUsage.map(idle, web: MuseUsage.Web(teams: [("7", "Core")], note: "Choose a browser team in Muse Code settings"))
        XCTAssertEqual(try rows(noTeam, "Browser teams")["Status"], "Choose a browser team in Muse Code settings")
        XCTAssertEqual(try rows(noTeam, "Muse Code subscription")["Quota"], "Not included in this login response")

        let live = try MuseUsage.map(json(#"""
        {"is_subs_active":true,"subs_tier_name":"Power","subs_usage":{"window":{"used_percent":96,"window_duration_mins":300},
         "weekly":{"used_percent":40}}}
        """#))
        XCTAssertEqual(try rows(live, "Muse Code subscription"), ["Plan": "Power", "5 hours": "96%", "Weekly": "40%"])
    }

    // MARK: N

    func testNeuralwatt() throws {
        let usage = try NeuralwattUsage.map(json(#"""
        {"balance":{"credits_remaining_usd":7.5,"total_credits_usd":10,"credits_used_usd":2.5},
         "subscription":{"plan":"pro_max","kwh_included":100,"kwh_used":25,"auto_renew":true,
           "current_period_start":"2026-09-01T00:00:00Z","current_period_end":"2026-10-01T00:00:00Z"},
         "key":{"allowance":{"limit_usd":20,"spent_usd":5,"period":"monthly"}}}
        """#))
        XCTAssertEqual(usage.windows[1].title, "Key Monthly")
        XCTAssertEqual(try rows(usage, "Subscription"), ["Renews": "2026-10-01"])
        let manual = try NeuralwattUsage.map(json(#"""
        {"balance":{"credits_remaining_usd":7.5},
         "subscription":{"kwh_included":100,"kwh_used":25,"auto_renew":false,"current_period_end":"2026-10-01T00:00:00Z"}}
        """#))
        XCTAssertTrue(manual.sections.isEmpty)
    }

    func testNotion() throws {
        let identity = NotionUsage.Identity(email: "ada@example.com", userID: "u1", workspaceID: "s2",
                                            workspaceName: "Acme", tier: "business")
        let usage = try NotionUsage.map(
            json(#"{"window":{"used":20,"limit":100,"window":"5h"}}"#), identity: identity)
        XCTAssertEqual(try rows(usage, "Account"), ["User ID": "u1"])
        XCTAssertEqual(usage.plan, "Business")
        XCTAssertEqual(usage.organization, "Acme")
        let spaces = try json(#"""
        {"u1":{"notion_user":{"u1":{"value":{"value":{"id":"u1","email":"ada@example.com"}}}},
               "space":{"s1":{"value":{"value":{"id":"s1","name":"Acme","subscription_tier":"business"}}}}}}
        """#)
        XCTAssertEqual(try NotionUsage.identity(spaces: spaces, preferred: nil).userID, "u1")
    }

    func testNous() throws {
        let usage = try NousUsage.map(json(#"""
        {"user":{"email":"ada@example.com"},"organisation":{"name":"Acme"},
         "subscription":{"plan":"Plus","monthly_credits":20,"credits_remaining":5,"rollover_credits":2,
                         "current_period_end":"2026-10-15T12:00:00Z"},
         "paid_service_access":{"purchased_credits_remaining":3,"total_usable_credits":8}}
        """#))
        let subscription = try section(usage, "Subscription").rows
        XCTAssertEqual(subscription.map(\.label), ["Subscription credits", "Rollover credits", "Renews"])
        XCTAssertEqual(subscription[0].value, "$5.00 of $20.00 left")
        XCTAssertEqual(subscription[1].value, "$2.00")
        XCTAssertEqual(subscription[2].value, "Oct 15")
        XCTAssertEqual(try rows(usage, "Credits"), ["Top-up credits": "$3.00", "Total usable": "$8.00"])
    }

    // MARK: O

    func testOpenai() throws {
        let now = utc("2026-09-21T12:00:00Z")
        let day = 1_789_948_800 // 2026-09-21T00:00:00Z
        let costs = try [
            json(#"{"start_time":\#(day),"end_time":\#(day + 86400),"results":[{"amount":{"value":1.5},"line_item":"gpt"},{"amount":{"value":0.5},"line_item":"search"}]}"#),
            json(#"{"start_time":\#(day - 86400),"end_time":\#(day),"results":[{"amount":{"value":2},"line_item":"gpt"}]}"#),
        ]
        let completions = try [json(#"""
        {"start_time":\#(day),"end_time":\#(day + 86400),"results":[
         {"model":"gpt-5","num_model_requests":10,"input_tokens":1000,"input_cached_tokens":400,"output_tokens":500}]}
        """#)]
        let usage = try OpenAIUsage.map(costs: costs, completions: completions, now: now, projectID: "proj_1")
        XCTAssertEqual(usage.plan, "Admin API: proj_1")
        XCTAssertEqual(usage.organization, "Project: proj_1")
        XCTAssertEqual(try rows(usage, "Last 30 days")["Cached input tokens"], "400")
        let top = try section(usage, "Top models").rows
        XCTAssertEqual(top[0].value, "1,500 tokens · 10 requests")
        let latest = try section(usage, "Latest days").rows
        XCTAssertEqual(latest.map(\.label), ["2026-09-21", "2026-09-20"])
        XCTAssertEqual(latest[0].value, "$2.00 · 10 requests · 1,500 tokens · gpt $1.50")
        XCTAssertEqual(try section(usage, "Cost by line item").rows.map(\.value), ["$3.50", "$0.50"])
        // A one-day history reads as today.
        let today = try OpenAIUsage.map(costs: costs, completions: completions, days: 1, now: now)
        XCTAssertEqual(today.cost?.period, "Today")
        XCTAssertEqual(today.cost?.used, 2)
        XCTAssertEqual(OpenAIUsage.historyDays("400"), 365)
        XCTAssertEqual(OpenAIUsage.historyDays("x"), 30)
        XCTAssertEqual(OpenAIUsage.ranges(days: 40, now: now).map(\.limit), [31, 9])
    }

    // MARK: P

    func testPerplexity() throws {
        let now = utc("2026-09-21T00:00:00Z")
        let expiry = Int(utc("2026-10-15T12:00:00Z").timeIntervalSince1970)
        let usage = try PerplexityUsage.map(json("""
        {"balance_cents":100,"renewal_date_ts":1791000000,"current_period_purchased_cents":0,"total_usage_cents":50,
         "credit_grants":[{"type":"recurring","amount_cents":4000},
                          {"type":"promotional","amount_cents":200,"expires_at_ts":\(expiry)}]}
        """), now: now)
        let bonus = try XCTUnwrap(usage.windows.first { $0.id == "bonus" })
        XCTAssertEqual(bonus.detail, "0 / 200 bonus · exp. Oct 15")
        XCTAssertEqual(usage.plan, "Pro")
    }

    func testPoe() throws {
        let now = utc("2026-09-21T12:00:00Z")
        let t = Int(now.timeIntervalSince1970 * 1_000_000)
        let history = try [
            json(#"{"creation_time":\#(t - 3_600_000_000),"cost_points":100,"cost_usd":0.5,"bot_name":"GPT-5","usage_type":"chat"}"#),
            json(#"{"creation_time":\#(t - 86_400_000_000 * 3),"cost_points":300,"bot_name":"Claude","usage_type":"api"}"#),
        ]
        let usage = try PoeUsage.map(balance: json(#"{"current_point_balance":2500}"#), history: history, now: now)
        XCTAssertEqual(usage.plan, "Balance: 2,500 points")
        let values = try rows(usage, "Points")
        XCTAssertEqual(values["Today (UTC)"], "100 points · 1 requests · $0.50")
        XCTAssertEqual(values["Usage mix"], "api: 300 points · chat: 100 points")
        XCTAssertEqual(values["Recent activity"], "09-21 11:00 · GPT-5 · 100 points")
        XCTAssertEqual(values["09-18 12:00"], "Claude · 300 points")
        XCTAssertEqual(try section(usage, "Daily points").rows.map(\.label), ["2026-09-21", "2026-09-18"])
    }

    // MARK: Q

    func testQoder() throws {
        let usage = try QoderUsage.map(json(#"""
        {"totalQuota":{"quotaSummary":{"usedValue":1.5,"limitValue":10,"remainingValue":8.5}},
         "nextResetAt":"2026-10-01T00:00:00Z"}
        """#))
        XCTAssertEqual(usage.windows[0].usedPercent, 15)
        XCTAssertEqual(usage.windows[0].detail, "1.5 / 10 credits")
        XCTAssertEqual(usage.windows[0].resetsAt, utc("2026-10-01T00:00:00Z"))
    }

    // MARK: R

    func testRaycast() throws {
        let usage = try RaycastUsage.map(json(#"""
        {"remaining_balance_credits":0,"total_balance_credits":0,"next_credits_at":"2026-10-01T12:00:00Z",
         "funding_subscription":{"tier":"pro_plus"}}
        """#))
        XCTAssertEqual(usage.plan, "Pro+")
        XCTAssertEqual(try section(usage, "Credits").rows.map(\.label), ["Left", "Total", "Renews"])
        let meter = try RaycastUsage.map(json(#"{"remaining_balance_credits":"75.5","total_balance_credits":100}"#))
        XCTAssertEqual(meter.windows[0].usedPercent, 24.5)
        XCTAssertEqual(meter.windows[0].detail, "75.5 / 100 credits left")
    }

    func testReplicate() throws {
        let usage = try ReplicateUsage.map(
            invoices: json(#"{"invoices":[{"type":"monthly-usage","total_cost_before_adjustments":"4.25"}]}"#),
            credit: json(#"{"unused_credit":"10"}"#), account: .init(username: "ada", isOrganization: false))
        XCTAssertEqual(try rows(usage, "Account"), ["Username": "ada"])
        XCTAssertEqual(try rows(usage, "Billing"), ["Spent this month": "$4.25", "Credit balance": "$10.00"])
        XCTAssertNil(usage.organization)
    }

    // MARK: S

    func testSailResearch() throws {
        let usage = try SailResearchUsage.map(json(#"""
        {"object":"usage.summary","available":true,"has_metronome_customer":true,"balance_unavailable":true,
        "period_spend":1234,"effective_range":"7d"}
        """#))
        XCTAssertEqual(usage.plan, "API key")
        XCTAssertEqual(try rows(usage, "Organization billing"),
                       ["Credit balance": "Unavailable", "Last 7 days spend": "$12.34"])
    }

    func testSakana() throws {
        let page = """
        <div data-slot="card"><div data-slot="card-title"><span>Standard</span><span class="price">$20/mo</span></div></div>
        <p class="t">5-hour</p><div><p class="u">12.5% used</p></div>
        """
        let payg = """
        <h2 class="a">Credit balance</h2><div><p class="text-2xl tabular-nums">$12.50</p></div>
        <h2>Usage</h2><span class="m">Total<!-- -->: <!-- -->$3.25</span>
        <button aria-label="Usage date range" type="button"><!-- -->Sep 1  -  <!-- -->Sep 21</button>
        """
        let usage = try SakanaUsage.map(html: page, paygHTML: payg)
        let extra = try section(usage, "Extra usage").rows
        XCTAssertEqual(extra[1], UsageRow("Usage", "$3.25 · Sep 1 - Sep 21"))
    }

    func testSofya() throws {
        let usage = try SofyaUsage.map(json(#"{"credits":1,"plan_credits":0.5}"#))
        XCTAssertEqual(usage.plan, "API")
        XCTAssertTrue(usage.windows.isEmpty)
        let paid = try SofyaUsage.map(json(#"{"credits":1,"is_free_tier":false}"#))
        XCTAssertEqual(paid.plan, "Pay as you go")
    }

    func testSub2Api() throws {
        let usage = try Sub2ApiUsage.map(json(#"""
        {"planName":"Claude Team","balance":8,"unit":"USD",
         "subscription":{"daily_usage_usd":2,"daily_limit_usd":10,"expires_at":"2026-12-01T00:00:00Z"}}
        """#))
        XCTAssertEqual(usage.organization, "Claude Team")
        XCTAssertEqual(try rows(usage, "Subscription"), ["Expires": "2026-12-01"])
        let root = try Sub2ApiUsage.map(json(#"{"planName":"Pro","expires_at":"2027-01-01T00:00:00Z","balance":1}"#))
        XCTAssertEqual(try rows(root, "Subscription"), ["Expires": "2027-01-01"])
    }

    func testSynthetic() throws {
        let usage = try SyntheticUsage.map(json(#"""
        {"rollingFiveHourLimit":{"limit":100,"used":10,"window":"5h","tickPercent":0.05},
         "weeklyTokenLimit":{"percentRemaining":98,"maxCredits":"$36.00","remainingCredits":"$35.30",
                             "nextRegenCredits":"$0.50","nextRegenAt":"2026-04-17T05:19:30.000Z"}}
        """#))
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(usage.windows[0].windowMinutes, 300)
        XCTAssertEqual(usage.windows[0].detail, "10 / 100 · 5 hours window · Next regen 5%")
        XCTAssertEqual(try rows(usage, "Weekly credits"), ["Next regen": "$0.50"])
        XCTAssertEqual(usage.cost?.limit, 36)
    }

    // MARK: T

    func testT3Chat() throws {
        let line = #"{"json":{"usageFourHourPercentage":12,"usageMonthPercentage":30,"usageBand":"high","usageFourHourNextResetAt":1790000000,"subscription":{"productName":"pro-plus","currentPeriodEnd":1791000000}}}"#
        let usage = try T3ChatUsage.map(jsonLines: line)
        XCTAssertEqual(usage.windows.map(\.id), ["base", "overage"])
        XCTAssertEqual(usage.windows[0].detail, "Base - high")
        XCTAssertEqual(usage.windows[0].windowMinutes, 240)
        XCTAssertEqual(usage.windows[1].resetsAt, Date(timeIntervalSince1970: 1_791_000_000))
        XCTAssertEqual(usage.plan, "Pro Plus")
    }

    func testTavily() throws {
        let usage = try TavilyUsage.map(json(#"""
        {"account":{"plan_usage":120,"plan_limit":1000,"paygo_usage":5,"paygo_limit":50},"key":{"usage":30,"limit":null}}
        """#))
        XCTAssertEqual(usage.plan, "API key")
        XCTAssertEqual(try rows(usage, "API key"), ["Used": "30 credits", "Limit": "Unlimited"])
        XCTAssertEqual(try rows(usage, "Pay as you go")["Remaining"], "45 credits")
    }

    func testTinyApi() throws {
        let usage = try TinyApiUsage.map(json(#"{"success":true,"data":{"totalAvailable":42.5}}"#))
        XCTAssertEqual(usage.plan, "Browser session")
        XCTAssertEqual(try rows(usage, "Credits"), ["Available credits": "42.5 credits"])
    }

    func testTypeSafe() throws {
        let credits = (1...30).map { #"{"amount":10,"remaining":\#($0),"expiresAt":"2026-10-15T12:00:00Z"}"# }.joined(separator: ",")
        let line = #"1:{"ok":true,"data":{"billing":{"spent":4.5,"balance":20,"cycleLabel":"Oct","plan":"free_plan","credits":["#
            + credits + "]}}}"
        let usage = try TypeSafeUsage.map(rsc: line)
        let list = try section(usage, "Billing").rows
        XCTAssertEqual(list[0], UsageRow("Spent (Oct)", "$4.50"))
        XCTAssertEqual(list[1], UsageRow("Credit", "1 of 10, expires Oct 15"))
        XCTAssertEqual(list.last, UsageRow("Additional credits", "9"))
        XCTAssertEqual(list.count, 23)
        XCTAssertEqual(usage.plan, "Free")
    }

    // MARK: V

    func testV0() throws {
        let usage = try V0Usage.map(
            billing: json(#"{"billingType":"token","data":{"balance":{"total":1000,"remaining":750},"onDemand":{"balance":5}}}"#),
            rateLimit: json(#"{"limit":100}"#), scope: "proj")
        XCTAssertEqual(usage.plan, "API key")
        XCTAssertEqual(try section(usage, "v0 API").rows.map(\.label),
                       ["Billing remaining", "On-demand balance", "Rate-limit remaining", "Billing type", "Scope"])
        let values = try rows(usage, "v0 API")
        XCTAssertEqual(values["Billing remaining"], "750 · of 1,000")
        XCTAssertEqual(values["Rate-limit remaining"], "Unavailable · limit 100")
    }

    func testVenice() throws {
        let usage = try VeniceUsage.map(json(
            #"{"canConsume":true,"consumptionCurrency":"DIEM","balances":{"diem":90.5,"usd":2},"diemEpochAllocation":100}"#))
        XCTAssertEqual(usage.windows[0].detail, "DIEM 90.50 / 100.00 epoch allocation")
        XCTAssertEqual(try rows(usage, "Balances"), ["DIEM": "90.5", "USD": "$2.00"])
    }

    func testVercel() throws {
        let usage = try VercelUsage.map(json(#"{"balance":"12.50","total_used":"7.25"}"#))
        XCTAssertEqual(usage.plan, "API")
        XCTAssertEqual(try rows(usage, "Team credits"), ["Available balance": "$12.50", "Lifetime spend": "$7.25"])
    }

    // MARK: W

    func testWorkbuddy() throws {
        let listings = try [
            json(#"{"Accounts":[{"CapacityUnit":"credits","CycleEndTime":"2026-10-31 23:59:59"},{"CapacityUnit":"tokens","CycleEndTime":"2026-09-30 23:59:59"}]}"#),
            json(#"{"Accounts":[{"CapacityUnit":"credits","CycleEndTime":"2026-11-30 23:59:59"},{"CapacityUnit":"credits","CycleEndTime":"2020-01-01 00:00:00"}]}"#),
        ]
        // The cycle ends at 23:59:59 China time; the dashboard resets one second later, at midnight CST.
        XCTAssertEqual(WorkBuddyUsage.nextReset(listings, now: utc("2026-10-10T00:00:00Z")), utc("2026-10-31T16:00:00Z"))
        XCTAssertNil(WorkBuddyUsage.nextReset([], now: utc("2026-10-10T00:00:00Z")))
        XCTAssertEqual(WorkBuddyUsage.paidPackageCodes.count, 9)
        XCTAssertEqual(WorkBuddyUsage.freePackageCodes.count, 11)
    }

    // MARK: X

    func testXApi() throws {
        let usage = try XApiUsage.map(json(#"{"credits":{"balance":10.5},"freeCredits":{"balance":2}}"#))
        XCTAssertEqual(usage.plan, "Browser session")
        XCTAssertEqual(try rows(usage, "Credits"),
                       ["Balance": "$12.50", "Purchased credits": "$10.50", "Free credits": "$2.00"])
    }

    func testXaiConsole() throws {
        let history = try json("""
        {"timeSeries":[{"dataPoints":[{"timestamp":"2027-01-13T00:00:00Z","values":[0.75]},{"timestamp":"2027-01-14T00:00:00Z","values":[0.5]}]},
        {"dataPoints":[{"timestamp":"2027-01-13T00:00:00Z","values":[0.5]}]}],"limitReached":true}
        """)
        let usage = try XaiConsoleUsage.map(balance: json(#"{"total":{"val":"-1000"}}"#), history: history)
        XCTAssertEqual(usage.plan, "Management API")
        XCTAssertEqual(try section(usage, "Daily spend").rows, [UsageRow("2027-01-14", "$0.50"), UsageRow("2027-01-13", "$1.25")])
        XCTAssertEqual(try rows(usage, "Billing summary")["Last 30 days (partial)"], "$1.75")
    }

    func testXKiro() throws {
        let usage = try XKiroUsage.map(json(#"""
        {"object":"usage","plan":"team","free_tokens":{"used_today":10,"limit_per_day":null,"remaining":5}}
        """#))
        XCTAssertEqual(usage.plan, "team")
        XCTAssertEqual(try rows(usage, "Free tokens"),
                       ["Tokens used today": "10", "Daily allowance": "No cap reported", "Tokens remaining": "5",
                        "Daily reset": "00:00 UTC"])
        XCTAssertTrue(usage.windows.isEmpty)
    }

    // MARK: Z

    func testZed() throws {
        let capped = try ZedUsage.map(json(#"""
        {"plan":"zed_pro","current_usage":{"token_spend":{"spend_in_cents":250,"limit_in_cents":1000},
        "edit_predictions":{"used":12,"limit":{"limited":100}}}}
        """#))
        XCTAssertEqual(try rows(capped, "Zed"),
                       ["Token spend": "$2.50", "Spend limit": "$10.00", "Remaining budget": "$7.50"])
        let open = try ZedUsage.map(json(
            #"{"plan":"zed_free","current_usage":{"token_spend":{"spend_in_cents":0},"edit_predictions":{"used":3,"limit":"unlimited"}}}"#))
        XCTAssertEqual(try rows(open, "Zed")["Spend limit"], "Not reported")
    }

    func testZenMux() throws {
        let subscription = try json("""
        {"success":true,"data":{"plan":{"tier":"ultra","expires_at":"2026-04-12T08:26:56Z"},"account_status":"warning",
        "quota_5_hour":{"usage_percentage":0.1,"max_flows":800,"used_flows":80,"remaining_flows":720},
        "quota_7_day":{"usage_percentage":0.2,"max_flows":6000,"used_flows":1200,"remaining_flows":4800}}}
        """)
        let usage = try ZenMuxUsage.map(subscription)
        XCTAssertEqual(usage.plan, "Ultra plan · Warning")
        XCTAssertEqual(try rows(usage, "Subscription"), ["Expires": "2026-04-12"])
        let healthy = try ZenMuxUsage.map(json("""
            {"success":true,"data":{"plan":{"tier":"pro"},"account_status":"healthy",
            "quota_5_hour":{"usage_percentage":0,"max_flows":1,"used_flows":0,"remaining_flows":1},
            "quota_7_day":{"usage_percentage":0,"max_flows":1,"used_flows":0,"remaining_flows":1}}}
            """))
        XCTAssertEqual(healthy.plan, "Pro plan")
        XCTAssertTrue(healthy.sections.isEmpty)
    }

    func testZoomMate() throws {
        let now = utc("2026-09-21T12:00:00Z")
        let status = try json(#"""
        {"data":{"credit_status":{"budget_cap":100,"used_credit":25,"cycle_start_date":1788912000000,"cycle_end_date":1791590400000}}}
        """#)
        let today = ISO8601DateFormatter().string(from: now)
        let history = try [
            json(#"{"cost":1.25,"time":"\#(today)"}"#),
            json(#"{"cost":2,"time":"\#(today)","is_deleted":true}"#),
            json(#"{"cost":3,"time":"\#(ISO8601DateFormatter().string(from: now.addingTimeInterval(-3 * 86400)))"}"#),
        ]
        let usage = try ZoomMateUsage.map(status, history: history, now: now)
        let values = try rows(usage, "Credit history")
        XCTAssertEqual(values["Today"], "1.25")
        XCTAssertEqual(values["30d credits"], "4.25")
        // 2026-09-21 is before the cycle starts (2026-09-08 + ...); pace compares 25% used against the elapsed share.
        XCTAssertNotNil(values["Pace"])
        XCTAssertEqual(usage.windows[0].usedPercent, 25)
        let unlimited = try ZoomMateUsage.map(json(#"{"data":{"credit_status":{"is_unlimited":true}}}"#), history: history, now: now)
        XCTAssertEqual(try rows(unlimited, "Credit history")["30d credits"], "4.25")
        XCTAssertNil(try rows(unlimited, "Credit history")["Pace"])
    }
}
