import Foundation
import XCTest
@testable import AIManagerCore

/// Every provider mapper that turns a Double into an Int gets huge, negative huge, NaN and infinite
/// numbers in every numeric field. `Int(Double)` traps on these, so a pass means the process survived.
final class ProviderHugeNumberTests: XCTestCase {
    /// `@` is a JSON number; `%` is a number written inside a JSON string.
    private static let bad: [(json: String, text: String)] = [
        ("1e300", "1e300"), ("-1e300", "-1e300"), (#""NaN""#, "nan"), (#""Infinity""#, "inf"),
        ("1e300", String(repeating: "9", count: 400)),
    ]

    private static let now = Date(timeIntervalSince1970: 1_780_279_200)

    private static let mappers: [(name: String, template: String, run: (JSON) throws -> Any)] = [
        ("MiniMax remains", #"""
        {"model_remains":[
          {"model_name":"general","start_time":@,"end_time":@,"remains_time":@,"current_interval_remaining_percent":@,
           "interval_boost_permill":@,"weekly_start_time":@,"weekly_end_time":@,"weekly_remains_time":@,
           "current_weekly_remaining_percent":@,"current_interval_status":1,"current_weekly_status":1},
          {"model_name":"speech-hd","current_interval_total_count":@,"current_interval_usage_count":@,"start_time":@,"end_time":@}],
         "base_resp":{"status_code":0}}
        """#, { try MiniMaxUsage.map($0, now: now) }),
        ("MiniMax legacy", #"""
        {"data":{"services":[{"service_type":"Text Generation","window_type":"5 hours","time_range":"10:00-15:00","usage":@,"limit":@,"percent":@},
                             {"service_type":"Image","window_type":"Weekly","time_range":"x","usage":@,"limit":@}]}}
        """#, { try MiniMaxUsage.map($0, now: now) }),
        ("Alibaba", #"""
        {"data":{"codingPlanInstanceInfos":[{"planName":"P"}],"codingPlanQuotaInfo":{"per5HourUsedQuota":@,"per5HourTotalQuota":@,
         "per5HourQuotaNextRefreshTime":@,"perWeekUsedQuota":@,"perWeekTotalQuota":@,"perWeekQuotaNextRefreshTime":@}},"status_code":@}
        """#, { try AlibabaUsage.map($0, now: now) }),
        ("Bifrost", #"""
        {"virtual_key_name":"k","is_active":true,"budgets":[{"id":"b1","source_name":"Main","max_limit":@,"current_usage":@,
         "reset_duration":"%h","last_reset":"2026-06-01T10:00:00Z",
         "per_model_usage":[{"model":"m","provider":"p","total_cost":@,"total_tokens":@}]}]}
        """#, { try BifrostUsage.map($0, now: now) }),
        ("LiteLLM", #"""
        {"results":[{"date":"2026-09-20","breakdown":{"models":{"m":{"metrics":{"prompt_tokens":@,"completion_tokens":@,"total_tokens":@,"api_requests":@}}}}}]}
        """#, { LiteLLMUsage.modelActivity([$0]) as Any }),
        ("ZoomMate", #"""
        {"data":{"credit_status":{"budget_cap":@,"used_credit":@,"cycle_start_date":1780000000000,"cycle_end_date":1790000000000}}}
        """#, { try ZoomMateUsage.map($0, history: [], now: now) }),
        ("Raycast", #"{"remaining_balance_credits":@,"total_balance_credits":@}"#, { try RaycastUsage.map($0) }),
        ("Llmman", #"{"memory":@,"loaded":{"a":@},"stored":{"a":@,"b":@}}"#, { try LlmmanUsage.map($0, version: "1", hasKey: true) }),
        ("Muse", #"""
        {"weekly_weighted_used":"50","weekly_weighted_limit":"100","weekly_resets_at":1790000000,
         "window_duration_secs":@,"window_weighted_used":"10","window_weighted_limit":"100","window_resets_at":1781000000}
        """#, { MuseUsage.webQuota($0, now: now) as Any }),
        ("Cursor", #"""
        {"billingCycleStart":@,"billingCycleEnd":@,"enabled":true,
         "planUsage":{"limit":@,"remaining":@,"totalSpend":@,"totalPercentUsed":@,"autoPercentUsed":@,"apiPercentUsed":@},
         "spendLimitUsage":{"limitType":"individual","individualLimit":@,"individualRemaining":@,"individualUsed":@}}
        """#, { try CursorUsage.map(usage: $0, plan: nil, credits: nil, membership: "pro", email: nil) }),
        ("Cursor events", #"""
        {"usageEventsDisplay":[{"timestamp":"1780000000000","tokenUsage":{"inputTokens":@,"outputTokens":@,"cacheWriteTokens":@,"cacheReadTokens":@,"totalCents":@}}]}
        """#, { CursorUsage.parseEvents($0) }),
        ("Synthetic", #"""
        {"rollingFiveHourLimit":{"limit":@,"used":@,"window":"%h","windowMinutes":@},
         "weeklyTokenLimit":{"percentRemaining":@,"windowDays":@}}
        """#, { try SyntheticUsage.map($0) }),
        ("Abacus", #"{"success":true,"result":{"totalComputePoints":@,"computePointsLeft":@}}"#, { try AbacusUsage.map($0) }),
        ("Neuralwatt", #"""
        {"balance":{"credits_remaining_usd":@,"total_credits_usd":@,"credits_used_usd":@},
         "subscription":{"plan":"pro","kwh_included":@,"kwh_used":@,"current_period_start":@,"current_period_end":@}}
        """#, { try NeuralwattUsage.map($0) }),
        ("Aixy", #"""
        {"object":"key.usage","currency":"USD","budgets":[{"id":"b","scope":"project","interval":"weekly","enforcement":"hard",
         "limit_usd":@,"spend_usd":@,"remaining_usd":@,"starts_at":@,"resets_at":@}]}
        """#, { try AixyUsage.map($0) }),
        ("Factory legacy", #"""
        {"usage":{"startDate":@,"endDate":@,"standard":{"userTokens":@,"totalAllowance":@,"usedRatio":@}}}
        """#, { try FactoryUsage.map(me: JSON(nil), billing: nil, legacy: $0, now: now) }),
        ("Ollama", #"""
        {"included":{"session":{"remaining_percent":@},"weekly":{"remaining_percent":@},"allowance_usd":@,"balance_usd":@,
         "period":{"from":@,"until":@}},"purchased":{"balance_usd":@}}
        """#, { try OllamaUsage.map(balance: $0, usage: nil, account: nil) }),
        ("Openrouter activity", #"""
        [{"date":"2026-05-31","model":"m","prompt_tokens":@,"completion_tokens":@,"requests":@,"usage":@}]
        """#, { OpenRouterUsage.activitySection(rows: $0.array, now: now) as Any }),
        ("Codex wham extras", #"""
        {"rate_limit_reset_credits":{"available_count":@,"credits":[{"expires_at":@}]},
         "spend_control":{"individual_limit":{"limit":@,"used":@,"remaining_percent":@,"resets_at":@}},
         "additional_rate_limits":[{"metered_feature":"spark","rate_limit":{"primary_window":{"used_percent":@,
           "limit_window_seconds":@,"reset_at":@,"reset_after_seconds":@}}}],"credits":{"balance":@}}
        """#, { CodexWhamExtras.parse(usage: HTTPResponse(status: 200, data: try JSONSerialization.data(withJSONObject: $0.raw ?? [:]),
                                                           headers: [:]), resetCredits: nil, now: now) as Any }),
        ("z.ai model usage", #"""
        {"success":true,"data":{"modelDataList":[{"modelName":"m","tokensUsage":[@,@]}]}}
        """#, { ZaiUsage.modelUsage($0, title: "t") as Any }),
    ]

    func testAmpHugeRenewalAndRatesNeverTrap() throws {
        for value in ["1e300", String(repeating: "9", count: 400), "0"] {
            let text = """
            Amp Standard Tier: agent usage $1 of $20 remaining (5%) - resets upon renewal in \(value) days
            Amp Free: $1/$\(value) remaining (replenishes +$\(value)/hour)
            """
            _ = try? AmpUsage.map(displayText: text, now: Self.now)
        }
    }

    func testEpochRejectsValuesThatAreNoRealDate() {
        XCTAssertEqual(Fmt.epoch(1_700_000_000), Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(Fmt.epoch(1_700_000_000_000), Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(Fmt.epoch(253_402_300_799_000), Date(timeIntervalSince1970: 253_402_300_799))
        for value in [1e300, 253_402_300_800_000, 1.7e18, Double.infinity, Double.nan, 0, -5] {
            XCTAssertNil(Fmt.epoch(value), "\(value)")
        }
        XCTAssertNil(JSON("1e300").date)
    }

    func testClampedIntMapsNaNAndOverflowIntoTheRange() {
        XCTAssertEqual(Fmt.clampedInt(.nan, 0...10), 0)
        XCTAssertEqual(Fmt.clampedInt(.infinity, 0...10), 10)
        XCTAssertEqual(Fmt.clampedInt(-.infinity, 0...10), 0)
        XCTAssertEqual(Fmt.clampedInt(1e300, 0...1_000_000_000_000_000), 1_000_000_000_000_000)
        XCTAssertEqual(Fmt.clampedInt(7.9, 0...10), 7)
        XCTAssertEqual(Fmt.clampedInt(1e300, Int.min...Int.max), Int.max)
    }

    func testUsagePaceTextNeverTraps() {
        for value in [1e300, -1e300, Double.nan, Double.infinity] {
            _ = UsagePace.tooltip(.healthy(projectedFraction: value))
            _ = UsagePace.tooltip(.closeToLimit(label: "x", projectedFraction: value))
            _ = UsagePace.tooltip(.runningOut(eta: value, projectedFraction: value))
            _ = UsagePace.label(.runningOut(eta: value, projectedFraction: nil))
            _ = UsagePace.duration(value)
        }
    }

    func testHugeNaNAndInfiniteNumbersNeverTrap() throws {
        var runs = 0
        for mapper in Self.mappers {
            for value in Self.bad {
                let text = mapper.template.replacingOccurrences(of: "@", with: value.json)
                    .replacingOccurrences(of: "%", with: value.text)
                let json = try XCTUnwrap(try? JSON(data: Data(text.utf8)), "\(mapper.name): \(text)")
                _ = try? mapper.run(json)
                runs += 1
            }
        }
        XCTAssertEqual(runs, Self.mappers.count * Self.bad.count)
    }

    func testMuseHugeWindowHasNoMinutes() throws {
        let quota = try JSON(data: Data(#"""
        {"weekly_weighted_used":"50","weekly_weighted_limit":"100","weekly_resets_at":1790000000,
         "window_duration_secs":1e300,"window_weighted_used":"10","window_weighted_limit":"100","window_resets_at":1781000000}
        """#.utf8))
        XCTAssertNil(try XCTUnwrap(MuseUsage.webQuota(quota, now: Self.now)).primary.windowMinutes)
    }
}
