import Foundation
import XCTest
@testable import AIManagerCore

final class ProvidersPluginsATests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }
    private func date(_ text: String) -> Date { Fmt.iso(text)! }

    func testCatalogListsAllPluginsAProviders() {
        let ids = Set(ProviderCatalog.pluginsA.map(\.id.rawValue))
        XCTAssertEqual(ids.count, 21)
        XCTAssertTrue(ids.isSuperset(of: ["abacus", "aerostack", "aiand", "aixy", "atlascloud", "bifrost", "chutes",
                                          "clawrouter", "clinepass", "cosmic", "deepgram", "deepinfra", "devpass",
                                          "elevenlabs", "exa", "fireworks", "gitkraken", "helmcode", "huggingface",
                                          "hyper", "langdock"]))
    }

    func testAbacus() throws {
        let points = try json(#"{"success":true,"result":{"totalComputePoints":1000,"computePointsLeft":750}}"#)
        let billing = try json(#"{"success":true,"result":{"nextBillingDate":"2026-07-01T00:00:00Z","currentTier":"Pro"}}"#)
        let usage = try AbacusUsage.map(points, billing: billing)
        XCTAssertEqual(usage.windows.first?.usedPercent, 25)
        XCTAssertEqual(usage.windows.first?.detail, "250 / 1,000 credits")
        XCTAssertEqual(usage.windows.first?.resetsAt, date("2026-07-01T00:00:00Z"))
        XCTAssertGreaterThan(usage.windows.first?.windowMinutes ?? 0, 28 * 1440)
        XCTAssertEqual(usage.plan, "Pro")
        XCTAssertEqual(try AbacusUsage.map(points).windows.first?.windowMinutes, 43_200)
        XCTAssertThrowsError(try AbacusUsage.map(try json(#"{"success":false,"error":"Session expired"}"#))) {
            XCTAssertTrue(($0 as? ProviderError)?.needsSignIn == true)
        }
    }

    func testAerostack() throws {
        let usage = try AerostackUsage.map(try json(
            #"{"usage":{"ai_tokens":{"used":250,"limit":1000}},"period":"2026-06","tier":"Pro"}"#))
        XCTAssertEqual(usage.windows.first?.usedPercent, 25)
        XCTAssertEqual(usage.plan, "Pro")
        XCTAssertEqual(usage.sections.first?.rows.map(\.label), ["Tokens used", "Allowance", "Remaining", "Period"])
        XCTAssertThrowsError(try AerostackUsage.map(try json(#"{"usage":{}}"#)))
    }

    func testAiand() throws {
        let page = try json(#"""
        {"data":[{"cost":"0.5","currency":"usd"},{"cost":"0.25","currency":"USD"},{"cost":"9","currency":"EUR"}],
         "has_more":false}
        """#)
        let usage = try AiandUsage.map([page])
        XCTAssertEqual(usage.cost?.used ?? 0, 0.75, accuracy: 1e-9)
        XCTAssertEqual(usage.cost?.currency, "USD")
        XCTAssertEqual(usage.cost?.period, "Last 30 days")
        let partial = try json(#"{"data":[{"cost":"1","currency":"USD"}],"has_more":true}"#)
        XCTAssertEqual(try AiandUsage.map([partial]).cost?.period, "Last 30 days (partial)")
    }

    func testAixy() throws {
        let usage = try AixyUsage.map(try json(#"""
        {"object":"key.usage","currency":"USD","as_of":"2026-06-10T00:00:00Z",
         "key":{"id":"k1","name":"CI key","project_id":"p1","project_name":"Proj"},
         "budgets":[
          {"id":"b2","scope":"organization","interval":"daily","enforcement":"monitor","shared":true,"limit_usd":10,
           "spend_status":"available","spend_usd":2,"remaining_usd":8,"availability":{"status":"not_enforced"}},
          {"id":"b1","scope":"api_key","interval":"monthly","enforcement":"hard","shared":false,"limit_usd":100,
           "availability":{"status":"available","spent_usd":20,"reserved_usd":5,"remaining_usd":75},
           "spend_status":"available","starts_at":"2026-06-01T00:00:00Z","resets_at":"2026-07-01T00:00:00Z"}],
         "usage":{"window":"7d","requests":10,"total_tokens":1000,"attributed_requests":8,"partial_requests":1,"spend_usd":3.5}}
        """#))
        XCTAssertEqual(usage.windows.map(\.id), ["aixy-b1", "aixy-b2"])
        XCTAssertEqual(usage.windows[0].usedPercent, 25)
        XCTAssertEqual(usage.windows[0].windowMinutes, 30 * 1440)
        XCTAssertEqual(usage.windows[0].title, "Key · Monthly · Personal · Hard")
        XCTAssertEqual(usage.windows[1].usedPercent, 20)
        XCTAssertEqual(usage.cost?.used, 3.5)
    }

    func testAtlascloud() throws {
        let usage = try AtlascloudUsage.map(try json(
            #"{"object":"balance","scope":"account","available":{"currency":"usd","value":"12.34"}}"#))
        XCTAssertEqual(usage.cost?.balance, 12.34)
        XCTAssertThrowsError(try AtlascloudUsage.map(try json(#"{"object":"balance"}"#)))
    }

    func testBifrost() throws {
        let now = date("2026-06-01T10:30:00Z")
        let usage = try BifrostUsage.map(try json(#"""
        {"virtual_key_name":"team-key","is_active":true,
         "budgets":[{"id":"b1","source_name":"Main","max_limit":100,"current_usage":25,"reset_duration":"1M",
                     "last_reset":"2026-06-01T00:00:00Z",
                     "per_model_usage":[{"model":"gpt-4o","total_cost":10,"total_tokens":1500}]}],
         "rate_limits":[{"source_name":"rl","token_max_limit":1000,"token_current_usage":100,
                         "token_reset_duration":"1h","token_last_reset":"2026-06-01T10:00:00Z"}]}
        """#), now: now)
        XCTAssertEqual(usage.windows.map(\.id), ["bifrost-budget-b1", "bifrost-tokens-0"])
        XCTAssertEqual(usage.windows[0].usedPercent, 25)
        XCTAssertNil(usage.windows[0].windowMinutes)
        XCTAssertEqual(usage.windows[1].usedPercent, 10)
        XCTAssertEqual(usage.windows[1].windowMinutes, 60)
        XCTAssertEqual(usage.windows[1].resetsAt, date("2026-06-01T11:00:00Z"))
        XCTAssertEqual(usage.cost?.used, 25)
        XCTAssertEqual(usage.cost?.limit, 100)
        XCTAssertEqual(usage.cost?.period, "Monthly")
        XCTAssertEqual(usage.email, "team-key")
        XCTAssertEqual(usage.sections.first?.rows.first?.label, "gpt-4o")
    }

    func testChutes() throws {
        let usage = try ChutesUsage.map(try json(#"""
        {"subscription":{"active":true,"plan_name":"Pro","current_period_end":"2026-07-01T00:00:00Z"},
         "monthly":{"used":250,"limit":1000,"resets_at":"2026-07-01T00:00:00Z","unit":"credits"},
         "rolling_window":{"requests":40,"limit":100,"window_minutes":240,"reset_at":"2026-06-13T18:00:00Z",
                           "unit":"requests"}}
        """#))
        XCTAssertEqual(usage.windows.map(\.id), ["rolling", "monthly"])
        XCTAssertEqual(usage.windows[0].usedPercent, 40)
        XCTAssertEqual(usage.windows[0].windowMinutes, 240)
        XCTAssertEqual(usage.windows[0].detail, "40/100 requests")
        XCTAssertEqual(usage.windows[0].resetsAt, date("2026-06-13T18:00:00Z"))
        XCTAssertEqual(usage.windows[1].usedPercent, 25)
        XCTAssertEqual(usage.windows[1].resetsAt, date("2026-07-01T00:00:00Z"))
        XCTAssertEqual(usage.plan, "Pro")

        let partial = try json(#"{"subscription":{"active":true,"plan_name":"Pro"},"monthly":{"used":250,"limit":1000}}"#)
        XCTAssertFalse(ChutesUsage.hasBothWindows(partial))
        let quotas = try json(#"{"rolling_window":{"requests":40,"limit":100,"window_minutes":240,"unit":"requests"}}"#)
        let filled = try ChutesUsage.map(partial, quotas: quotas)
        XCTAssertEqual(filled.windows.map(\.usedPercent), [40, 25])

        let free = try ChutesUsage.map(try json(#"{"subscription":{"active":false,"status":"free"}}"#),
                                       quotas: try json(#"[{"chute_id":"0","quota":100,"used":10}]"#))
        XCTAssertEqual(free.windows.first?.usedPercent, 10)
        XCTAssertEqual(free.plan, "No active subscription")
    }

    func testClawrouter() throws {
        let usage = try ClawrouterUsage.map(try json(#"""
        {"budget":{"configured":true,"ledger":"monthly","limitMicros":10000000,"spentMicros":2500000,
                   "remainingMicros":7500000,"windowKey":"monthly:2026-06"},
         "usage":{"summary":{"requestCount":10,"successCount":9,"errorCount":1,"inputTokens":100,"outputTokens":50,
                             "totalTokens":150,"actualCostMicros":2500000},
                  "providers":[{"provider":"openai","requestCount":4,"successCount":4,"errorCount":0,"totalTokens":50,
                                "actualCostMicros":500000},
                               {"provider":"anthropic","requestCount":6,"successCount":5,"errorCount":1,"totalTokens":100,
                                "actualCostMicros":2000000}]}}
        """#))
        XCTAssertEqual(usage.windows.first?.usedPercent, 25)
        XCTAssertEqual(usage.windows.first?.resetsAt, date("2026-07-01T00:00:00Z"))
        XCTAssertEqual(usage.cost?.used, 2.5)
        XCTAssertEqual(usage.cost?.limit, 10)
        XCTAssertEqual(usage.plan, "Managed monthly budget")
        XCTAssertEqual(usage.sections.last?.rows.first?.label, "anthropic")
        XCTAssertEqual(usage.organization, "2 routed providers")
    }

    func testClinepass() throws {
        let usage = try ClinepassUsage.map(try json(#"""
        {"success":true,"data":{"limits":[
          {"type":"monthly","percentUsed":70},
          {"type":"five_hour","percentUsed":12.5,"resetsAt":"2026-06-13T18:00:00Z"},
          {"type":"weekly","percentUsed":40,"resetsAt":null},
          {"type":"other","percentUsed":99}]}}
        """#))
        XCTAssertEqual(usage.windows.map(\.id), ["five_hour", "weekly", "monthly"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [12.5, 40, 70])
        XCTAssertEqual(usage.windows.map(\.windowMinutes), [300, 10_080, 43_200])
        XCTAssertEqual(usage.windows[0].resetsAt, date("2026-06-13T18:00:00Z"))
        XCTAssertNil(usage.windows[1].resetsAt)
    }

    func testCosmic() throws {
        let usage = try CosmicUsage.map(try json(#"""
        {"usage":{"ai":{"input_tokens":500000,"output_tokens":100}},
         "plan_info":{"ai_tokens":{"max_input":"1M","max_output":1000}}}
        """#))
        XCTAssertEqual(usage.windows.map(\.id), ["input", "output"])
        XCTAssertEqual(usage.windows[0].usedPercent, 50)
        XCTAssertEqual(usage.windows[1].usedPercent, 10)
        XCTAssertEqual(usage.sections.first?.rows.map(\.label), ["Used", "Allowance", "Remaining"])
        XCTAssertThrowsError(try CosmicUsage.map(try json("{}")))
    }

    func testDeepgram() throws {
        let breakdown = try json(#"""
        {"start":"2026-06-01","end":"2026-06-30","results":[
          {"hours":1.5,"total_hours":2,"requests":10,"tokens_in":100,"tokens_out":50},
          {"hours":0.5,"total_hours":1,"requests":5,"tts_characters":2000}]}
        """#)
        let usage = try DeepgramUsage.map([breakdown], projects: ["Main"])
        let rows = Dictionary(uniqueKeysWithValues: (usage.sections.first?.rows ?? []).map { ($0.label, $0.value) })
        XCTAssertEqual(rows["Requests"], "15")
        XCTAssertEqual(rows["Audio"], "2 hours (3 billable)")
        XCTAssertEqual(rows["Tokens"], "150")
        XCTAssertEqual(rows["TTS characters"], "2,000")
        XCTAssertEqual(rows["Period"], "2026-06-01 to 2026-06-30")
        XCTAssertEqual(usage.organization, "Main")
    }

    func testDeepinfra() throws {
        let usage = try DeepinfraUsage.map(
            checklist: try json(#"{"recent":3.5,"stripe_balance":-10,"limit":50,"suspended":false}"#),
            usage: try json(#"{"months":[{"period":"2026-06","total_cost":1250}]}"#))
        XCTAssertEqual(usage.cost?.used, 3.5)
        XCTAssertEqual(usage.cost?.limit, 50)
        XCTAssertEqual(usage.cost?.balance, 6.5)
        XCTAssertEqual(usage.sections.first?.rows.map(\.value), ["$6.50", "$12.50"])
    }

    func testDevpass() throws {
        let usage = try DevpassUsage.map(try json(#"""
        {"data":{"devPlan":"pro","usage":"1.5","limit":null,"devPlanCreditsUsed":"5","devPlanCreditsLimit":"20",
                 "devPlanCreditsRemaining":"15","devPlanPremiumCreditsUsed":"1","devPlanPremiumWeeklyLimit":"4",
                 "devPlanPremiumWeekResetsAt":"2026-06-15T00:00:00Z"}}
        """#))
        XCTAssertEqual(usage.windows.map(\.id), ["credits", "weekly"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [25, 25])
        XCTAssertEqual(usage.windows[1].windowMinutes, 10_080)
        XCTAssertEqual(usage.windows[1].resetsAt, date("2026-06-15T00:00:00Z"))
        XCTAssertEqual(usage.plan, "DevPass Pro")
        let payg = try DevpassUsage.map(try json(#"{"data":{"devPlan":"none","usage":"2"}}"#))
        XCTAssertEqual(payg.plan, "Pay as you go")
        XCTAssertTrue(payg.windows.isEmpty)
    }

    func testElevenlabs() throws {
        let usage = try ElevenlabsUsage.map(try json(#"""
        {"character_count":2500,"character_limit":10000,"voice_slots_used":3,"voice_limit":10,
         "professional_voice_slots_used":0,"professional_voice_limit":1,"tier":"pro_plus","status":"past_due",
         "next_character_count_reset_unix":1781000000}
        """#))
        XCTAssertEqual(usage.windows.map(\.id), ["credits", "voice-slots", "professional-voices"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [25, 30, 0])
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1_781_000_000))
        XCTAssertEqual(usage.windows[0].detail, "2,500 / 10,000 credits")
        XCTAssertEqual(usage.plan, "Pro Plus · past_due")
    }

    func testExa() throws {
        let usage = try ExaUsage.map(try json(
            #"{"total_cost_usd":12.5,"period":{"start":"2026-06-01T00:00:00.000Z","end":"2026-06-10T00:00:00.000Z"}}"#))
        XCTAssertEqual(usage.cost?.used, 12.5)
        XCTAssertEqual(usage.sections.first?.rows.first?.value, "$12.50")
        XCTAssertThrowsError(try ExaUsage.map(try json(#"{"total_cost_usd":-1}"#)))
    }

    func testFireworks() throws {
        let summary = try json(#"""
        {"lineItems":[{"totalCost":{"units":"12","nanos":500000000,"currencyCode":"USD"}},
                      {"totalCost":{"units":"1","nanos":0,"currencyCode":"EUR"}},
                      {"totalCost":{"units":"3","nanos":250000000,"currencyCode":"USD"}}]}
        """#)
        let usage = try FireworksUsage.map(summary)
        XCTAssertEqual(usage.cost?.used ?? 0, 15.75, accuracy: 1e-9)
        XCTAssertEqual(usage.cost?.currency, "USD")
        let slugs = FireworksUsage.slugs(try json(#"{"accounts":[{"name":"accounts/my-team"},{"id":"bad slug"}]}"#))
        XCTAssertEqual(slugs, ["my-team"])
        XCTAssertEqual(try FireworksUsage.choose(slugs), "my-team")
        XCTAssertThrowsError(try FireworksUsage.choose(["a", "b"]))
        XCTAssertThrowsError(try FireworksUsage.choose([]))
    }

    func testGitkraken() throws {
        let usage = try GitkrakenUsage.map(try json(#"""
        {"data":{"used":30,"limit":100,"resetsOn":"2026-06-15T00:00:00Z","sharedUsed":100,
                 "organization":{"used":500,"limit":1000}}}
        """#))
        XCTAssertEqual(usage.windows.map(\.id), ["personal", "shared"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [30, 50])
        XCTAssertEqual(usage.windows[0].windowMinutes, 10_080)
        XCTAssertEqual(usage.windows[0].resetsAt, date("2026-06-15T00:00:00Z"))
        XCTAssertEqual(usage.sections.first?.rows.map(\.label),
                       ["Personal", "Shared pool", "Your shared usage", "Rest of organization"])
        let unlimited = try GitkrakenUsage.map(try json(#"{"data":{"used":3,"limit":-1,"resetsOn":"2026-06-15T00:00:00Z"}}"#))
        XCTAssertTrue(unlimited.windows.isEmpty)
    }

    func testHelmcode() throws {
        let quota = try json(#"""
        {"periodStart":"2026-06-01T00:00:00Z","models":[
          {"model":"qwen","cap":1000,"tokensUsed":250,"creditTokens":0,"periodEnd":"2026-07-01T00:00:00Z"},
          {"model":"glm","cap":2000,"tokensUsed":1500,"windowHours":5}]}
        """#)
        let billing = try json(#"{"subscription":{"premium":true}}"#)
        let credits = try json(#"{"balanceMicros":5000000,"currency":"eur"}"#)
        let usage = try HelmcodeUsage.map(quota, billing: billing, credits: credits, organization: "Helmcode Cloud")
        XCTAssertEqual(usage.windows.map(\.title), ["glm", "qwen"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [75, 25])
        XCTAssertEqual(usage.windows[0].windowMinutes, 300)
        XCTAssertEqual(usage.windows[1].resetsAt, date("2026-07-01T00:00:00Z"))
        XCTAssertEqual(usage.cost?.balance, 5)
        XCTAssertEqual(usage.cost?.currency, "EUR")
        let free = try HelmcodeUsage.map(quota, organization: "Helmcode Cloud")
        XCTAssertEqual(free.windows.map(\.title), ["qwen"])
    }

    func testHuggingface() throws {
        let usage = try HuggingfaceUsage.map(
            try json(#"""
            {"usage":{"inferenceProviders":{"usedNanoUsd":5000000000,"includedNanoUsd":2000000000,
                                            "limitNanoUsd":10000000000,"numRequests":42}}}
            """#),
            zeroGPU: try json(#"{"base":1800,"current":900,"resetsAt":1781000000}"#),
            profile: try json(#"{"isPro":true,"email":"a@example.com"}"#))
        XCTAssertEqual(usage.cost?.used, 3)
        XCTAssertEqual(usage.cost?.limit, 10)
        XCTAssertEqual(usage.windows.map(\.id), ["inference", "zerogpu"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [30, 50])
        XCTAssertEqual(usage.windows[1].resetsAt, Date(timeIntervalSince1970: 1_781_000_000))
        XCTAssertEqual(usage.plan, "PRO")
        XCTAssertEqual(usage.email, "a@example.com")
        XCTAssertEqual(usage.sections.last?.rows.first?.value, "15 min")
    }

    func testHyper() throws {
        let usage = try HyperUsage.map(try json(#"{"balance":12.5}"#))
        XCTAssertEqual(usage.cost?.balance, 12.5)
        XCTAssertEqual(usage.sections.first?.rows.first?.value, "12.5 HC")
        XCTAssertThrowsError(try HyperUsage.map(try json(#"{"balance":-1}"#)))
    }

    func testLangdock() throws {
        let usage = try LangdockUsage.map(try json(#"""
        [{"result":{"data":{"json":{"hasIncludedUsageLimits":true,"planUsage":{
           "sessionUsageLimitsEnabled":true,"sessionUsagePercent":12.5,"sessionResetsAt":"2026-06-13T18:00:00Z",
           "weeklyUsagePercent":130,"weeklyResetsAt":"2026-06-15T00:00:00Z"}}}}}]
        """#))
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [12.5, 130])
        XCTAssertEqual(usage.windows.map(\.windowMinutes), [300, 10_080])
        XCTAssertEqual(usage.windows[0].resetsAt, date("2026-06-13T18:00:00Z"))
        XCTAssertThrowsError(try LangdockUsage.map(try json(
            #"[{"error":{"json":{"data":{"code":"UNAUTHORIZED"}}}}]"#))) {
            XCTAssertTrue(($0 as? ProviderError)?.needsSignIn == true)
        }
    }
}
