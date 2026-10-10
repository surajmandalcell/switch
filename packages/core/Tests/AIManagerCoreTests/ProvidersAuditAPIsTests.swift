import Foundation
import XCTest
@testable import AIManagerCore


/// Parity with CodexBar for MiniMax, DeepSeek and Doubao. Fixtures are CodexBar's own test JSON.
final class ProvidersAuditAPIsATests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }
    private func rows(_ usage: ProviderUsage, _ title: String) -> [String: String] {
        let section = usage.sections.first { $0.title == title }
        return Dictionary(uniqueKeysWithValues: (section?.rows ?? []).map { ($0.label, $0.value) })
    }

    // MARK: MiniMax

    private let percentBased = """
    {"model_remains":[{"start_time":1780279200000,"end_time":1780297200000,"remains_time":16659830,
     "current_interval_total_count":0,"current_interval_usage_count":0,"model_name":"general",
     "current_weekly_total_count":0,"current_weekly_usage_count":0,"weekly_start_time":1780243200000,
     "weekly_end_time":1780848000000,"weekly_remains_time":567459830,"current_interval_status":1,
     "current_interval_remaining_percent":96,"current_weekly_status":1,"current_weekly_remaining_percent":99}],
     "base_resp":{"status_code":0,"status_msg":"success"}}
    """

    func testMiniMaxPercentLanesCarryCountsAndWindowLengths() throws {
        let now = Date(timeIntervalSince1970: 1_780_282_340)
        let usage = try MiniMaxUsage.map(json(percentBased), now: now)
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(usage.windows[0].detail, "4 / 100")
        XCTAssertEqual(usage.windows[0].windowMinutes, 300)
        XCTAssertEqual(usage.windows[1].detail, "1 / 100")
        XCTAssertEqual(usage.windows[1].windowMinutes, 10080)
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1_780_297_200))
        let quota = rows(usage, "Quota services")
        XCTAssertEqual(quota["General \u{00B7} 5 hours"], "4 / 100 \u{00B7} 4% used \u{00B7} Resets in 4 hours")
        XCTAssertEqual(quota["General \u{00B7} Weekly"], "1 / 100 \u{00B7} 1% used \u{00B7} Resets in 6 days")
    }

    func testMiniMaxPointsPlanAndStringStatus() throws {
        let usage = try MiniMaxUsage.map(json("""
        {"base_resp":{"status_code":"0"},"data":{"current_subscribe_title":"Token Plan \u{00B7} TokenPlanPlus-\u{5E74}\u{5EA6}\u{4F1A}\u{5458}",
         "points_balance":"14000","model_remains":[{"model_name":"general","current_interval_total_count":0,
         "current_interval_usage_count":0,"current_interval_remaining_percent":"96","start_time":1780279200000,
         "end_time":1780297200000,"current_weekly_total_count":0,"current_weekly_usage_count":0,
         "current_weekly_remaining_percent":"99","weekly_start_time":1780243200000,"weekly_end_time":1780848000000}]}}
        """), now: Date(timeIntervalSince1970: 1_780_282_340))
        XCTAssertEqual(usage.plan, "Token Plan \u{00B7} TokenPlanPlus-\u{5E74}\u{5EA6}\u{4F1A}\u{5458}")
        XCTAssertEqual(rows(usage, "Services")["Points"], "14,000")
        XCTAssertEqual(usage.windows.count, 2)
    }

    func testMiniMaxVideoFirstStillLeadsWithGeneralAndKeepsVideoLane() throws {
        let usage = try MiniMaxUsage.map(json("""
        {"base_resp":{"status_code":"0"},"model_remains":[
         {"model_name":"video","current_interval_total_count":100,"current_interval_usage_count":70,
          "current_interval_remaining_percent":30,"start_time":1780243200000,"end_time":1780329600000},
         {"model_name":"general","current_interval_total_count":0,"current_interval_usage_count":0,
          "current_interval_remaining_percent":96,"start_time":1780279200000,"end_time":1780297200000,
          "current_weekly_total_count":0,"current_weekly_usage_count":0,"current_weekly_remaining_percent":99,
          "weekly_start_time":1780243200000,"weekly_end_time":1780848000000}]}
        """), now: Date(timeIntervalSince1970: 1_780_282_340))
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 4, accuracy: 0.001)
        XCTAssertEqual(rows(usage, "Services")["video"], "70% used")
        // Ordered like CodexBar: text lanes first, then the video lane.
        XCTAssertEqual(usage.sections.first { $0.title == "Quota services" }?.rows.map(\.label),
                       ["General \u{00B7} 5 hours", "General \u{00B7} Weekly", "Video"])
        XCTAssertEqual(rows(usage, "Quota services")["Video"]?.hasPrefix("70 / 100 \u{00B7} 70% used"), true)
    }

    func testMiniMaxPlusPlanHidesUnavailableVideoAndInfersPlan() throws {
        let usage = try MiniMaxUsage.map(json("""
        {"base_resp":{"status_code":0,"status_msg":"success"},"model_remains":[
         {"start_time":1780279200000,"end_time":1780297200000,"remains_time":16659830,"current_interval_total_count":0,
          "current_interval_usage_count":0,"model_name":"general","current_weekly_total_count":0,
          "current_weekly_usage_count":0,"weekly_start_time":1780243200000,"weekly_end_time":1780848000000,
          "weekly_remains_time":567459830,"current_interval_status":1,"current_interval_remaining_percent":96,
          "current_weekly_status":1,"current_weekly_remaining_percent":99},
         {"start_time":1780243200000,"end_time":1780329600000,"remains_time":49059830,"current_interval_total_count":0,
          "current_interval_usage_count":0,"model_name":"video","current_weekly_total_count":0,
          "current_weekly_usage_count":0,"weekly_start_time":1780243200000,"weekly_end_time":1780848000000,
          "weekly_remains_time":567459830,"current_interval_status":3,"current_interval_remaining_percent":100,
          "current_weekly_status":3,"current_weekly_remaining_percent":100}]}
        """), now: Date(timeIntervalSince1970: 1_780_282_340))
        XCTAssertEqual(usage.plan, "Plus")
        XCTAssertEqual(usage.windows.count, 2)
        XCTAssertNil(rows(usage, "Services")["video"])
        XCTAssertNil(rows(usage, "Quota services")["Video"])
    }

    func testMiniMaxBoostedIntervalAndUnlimitedWeekly() throws {
        let usage = try MiniMaxUsage.map(json("""
        {"model_remains":[
         {"start_time":1780347600000,"end_time":1780365600000,"remains_time":4650822,"current_interval_total_count":0,
          "current_interval_usage_count":0,"model_name":"general","current_weekly_total_count":0,
          "current_weekly_usage_count":0,"weekly_start_time":1780243200000,"weekly_end_time":1780848000000,
          "weekly_remains_time":487050822,"current_interval_status":1,"current_interval_remaining_percent":99,
          "current_weekly_status":3,"current_weekly_remaining_percent":100,"interval_boost_permill":2000,
          "weekly_boost_permill":2000},
         {"start_time":1780329600000,"end_time":1780416000000,"remains_time":55050822,"current_interval_total_count":0,
          "current_interval_usage_count":0,"model_name":"video","current_weekly_total_count":0,
          "current_weekly_usage_count":0,"weekly_start_time":1780243200000,"weekly_end_time":1780848000000,
          "weekly_remains_time":487050822,"current_interval_status":3,"current_interval_remaining_percent":100,
          "current_weekly_status":3,"current_weekly_remaining_percent":100}],
         "base_resp":{"status_code":0,"status_msg":"success"}}
        """), now: Date(timeIntervalSince1970: 1_780_347_620))
        XCTAssertEqual(usage.windows.map(\.id), ["session"])
        XCTAssertEqual(usage.windows[0].detail, "2 / 200")
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(rows(usage, "Services")["Weekly"], "Unlimited")
        XCTAssertEqual(rows(usage, "Quota services")["General \u{00B7} Weekly"], "Unlimited")
    }

    func testMiniMaxBoostedWeeklyWithPermilleSpelling() throws {
        let usage = try MiniMaxUsage.map(json("""
        {"model_remains":[{"start_time":1782043200000,"end_time":1782057600000,"remains_time":7003536,
         "current_interval_total_count":0,"current_interval_usage_count":0,"model_name":"general",
         "current_weekly_total_count":0,"current_weekly_usage_count":0,"weekly_start_time":1781452800000,
         "weekly_end_time":1782057600000,"weekly_remains_time":7003536,"current_interval_status":1,
         "current_interval_remaining_percent":100,"current_weekly_status":1,"current_weekly_remaining_percent":70,
         "weekly_boost_permille":1500},
         {"model_name":"video","current_interval_status":3,"current_interval_remaining_percent":100,
          "current_weekly_status":3,"current_weekly_remaining_percent":100}],
         "base_resp":{"status_code":0}}
        """), now: Date(timeIntervalSince1970: 1_782_050_596))
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(usage.windows[1].detail, "45 / 150")
        XCTAssertEqual(usage.windows[1].usedPercent ?? -1, 30, accuracy: 0.001)
    }

    func testMiniMaxCountsAndWeeklyForLegacyTextModels() throws {
        let start = 1_700_000_000_000, end = start + 5 * 3_600_000
        let weekStart = start - 2 * 86_400_000, weekEnd = weekStart + 7 * 86_400_000
        let usage = try MiniMaxUsage.map(json("""
        {"base_resp":{"status_code":0},"current_subscribe_title":"Max","model_remains":[{"model_name":"MiniMax-M1",
         "current_interval_total_count":1000,"current_interval_usage_count":250,"start_time":\(start),"end_time":\(end),
         "current_weekly_total_count":6000,"current_weekly_usage_count":5376,"weekly_start_time":\(weekStart),
         "weekly_end_time":\(weekEnd)}]}
        """), now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(usage.plan, "Max")
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 75, accuracy: 0.001)
        XCTAssertEqual(usage.windows[0].detail, "750 / 1,000")
        XCTAssertEqual(usage.windows[1].detail, "624 / 6,000")
        XCTAssertEqual(rows(usage, "Quota services")["Text Generation \u{00B7} Weekly"]?.contains("10.4% used"), true)

        let noWeekly = try MiniMaxUsage.map(json("""
        {"base_resp":{"status_code":0},"model_remains":[{"model_name":"MiniMax-M1","current_interval_total_count":1000,
         "current_interval_usage_count":250,"start_time":\(start),"end_time":\(end),
         "current_weekly_total_count":0,"current_weekly_usage_count":0}]}
        """), now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(noWeekly.windows.map(\.id), ["session"])
    }

    func testMiniMaxDataWrapperStringCountsAndNamedPlanFields() throws {
        let usage = try MiniMaxUsage.map(json("""
        {"base_resp":{"status_code":"0"},"data":{"current_subscribe_title":"Max","model_remains":[
         {"current_interval_total_count":"15000","current_interval_usage_count":"14989",
          "start_time":1700000000000,"end_time":1700018000000,"remains_time":8941292}]}}
        """), now: Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(usage.plan, "Max")
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 11.0 / 15000 * 100, accuracy: 0.001)
        for (field, value) in [("plan_name", "MiniMax Star"), ("current_plan_title", "Coding Plan Pro"),
                               ("combo_title", "Combo Star")] {
            let plan = try MiniMaxUsage.map(json(#"{"base_resp":{"status_code":0},"\#(field)":"\#(value)","model_remains":[{"model_name":"abab6.5"}]}"#))
            XCTAssertEqual(plan.plan, value)
        }
        let card = try MiniMaxUsage.map(json(#"{"base_resp":{"status_code":0},"current_combo_card":{"title":"Card Title"},"model_remains":[{"model_name":"abab6.5"}]}"#))
        XCTAssertEqual(card.plan, "Card Title")
    }

    func testMiniMaxErrorsInDataWrapperAndStringCodes() throws {
        for body in [#"{"base_resp":{"status_code":"1004","status_msg":"login required"}}"#,
                     #"{"data":{"base_resp":{"status_code":1004,"status_msg":"unauthorized"}}}"#,
                     #"{"base_resp":{"status_code":1004,"status_msg":"cookie is missing, log in again"}}"#] {
            XCTAssertThrowsError(try MiniMaxUsage.map(json(body))) { XCTAssertTrue(($0 as? ProviderError)?.needsSignIn == true) }
        }
    }

    func testMiniMaxLegacyMultiServicePayload() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 25, hour: 11))!
        let usage = try MiniMaxUsage.map(json("""
        {"data":{"services":[
         {"service_type":"Text Generation","window_type":"5 hours","time_range":"10:00-15:00(UTC+8)","usage":2,"limit":10},
         {"service_type":"Image","window_type":"Today","time_range":"2026/03/25 00:00 - 2026/03/26 00:00",
          "usage":"5","limit":"50","percent":"10"}]}}
        """), now: now)
        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 20, accuracy: 0.001)
        XCTAssertEqual(usage.windows[0].resetsAt, calendar.date(from: DateComponents(year: 2026, month: 3, day: 25, hour: 15)))
        XCTAssertEqual(rows(usage, "Services")["Image"], "10% used")
        XCTAssertEqual(rows(usage, "Quota services")["Image"]?.hasPrefix("5 / 50 \u{00B7} 10% used \u{00B7} Resets in"), true)
    }

    func testMiniMaxCodingPlanPageText() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let page = try MiniMaxUsage.mapHTML("""
        <div>Coding Plan</div><div>Max</div><div>Available usage: 1,000 prompts / 5 hours</div>
        <div>Current Usage</div><div>0% Used</div><div>Resets in 4 min</div>
        """, now: now)
        XCTAssertFalse(page.quotas)
        XCTAssertEqual(page.usage.plan, "Max")
        XCTAssertEqual(page.usage.windows[0].detail, "1000 prompts / 5 hours")
        XCTAssertEqual(page.usage.windows[0].windowMinutes, 300)
        XCTAssertEqual(page.usage.windows[0].usedPercent, 0)
        XCTAssertEqual(page.usage.windows[0].resetsAt, now.addingTimeInterval(240))

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let morning = utc.date(from: DateComponents(year: 2025, month: 1, day: 1, hour: 10))!
        let used = try MiniMaxUsage.mapHTML("""
        <div>Coding Plan Pro</div><div>Available usage: 1,500 prompts / 1.5 hours</div><div>Used 75%</div>
        <div>Resets at 23:30 (UTC)</div>
        """, now: morning)
        XCTAssertEqual(used.usage.plan, "Pro")
        XCTAssertEqual(used.usage.windows[0].windowMinutes, 90)
        XCTAssertEqual(used.usage.windows[0].usedPercent, 75)
        XCTAssertEqual(used.usage.windows[0].resetsAt, utc.date(from: DateComponents(year: 2025, month: 1, day: 1, hour: 23, minute: 30)))
        XCTAssertThrowsError(try MiniMaxUsage.mapHTML("<html>nothing</html>"))
    }

    func testMiniMaxNextDataPageCarriesQuotaLanes() throws {
        let page = try MiniMaxUsage.mapHTML("""
        <html><script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"data":{
        "base_resp":{"status_code":0},"currentSubscribeTitle":"Max","modelRemains":[{"current_interval_total_count":1000,
        "current_interval_usage_count":250,"start_time":1700000000000,"end_time":1700018000000,"remains_time":240000}]}}}}</script></html>
        """, now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(page.quotas)
        XCTAssertEqual(page.usage.plan, "Max")
        XCTAssertEqual(page.usage.windows[0].usedPercent ?? -1, 75, accuracy: 0.001)
        XCTAssertEqual(page.usage.windows[0].windowMinutes, 300)
    }

    func testMiniMaxSignedOutIgnoresScriptsButSeesVisibleCopy() {
        XCTAssertFalse(MiniMaxUsage.looksSignedOut(#"<html><script id="__NEXT_DATA__">{"t":"Sign in"}</script><main>Coding Plan</main></html>"#))
        XCTAssertTrue(MiniMaxUsage.looksSignedOut("<html><button>Sign in</button></html>"))
    }

    func testMiniMaxCookieSessionFromCurlAndHeader() {
        let curl = """
        curl 'https://platform.minimax.io/v1/api/openplatform/coding_plan/remains?GroupId=123456' \
          -H 'authorization: Bearer token123' \
          -H 'Cookie: foo=bar; session=abc123'
        """
        XCTAssertEqual(MiniMaxUsage.web(curl), .init(cookie: "foo=bar; session=abc123", bearer: "token123", groupID: "123456"))
        let combo = "curl 'https://www.minimaxi.com/x' -b 'foo=bar; minimax_group_id_v2=2013894056999916075' -H 'x-group-id: 2013894056999916075'"
        XCTAssertEqual(MiniMaxUsage.web(combo)?.cookie, "foo=bar; minimax_group_id_v2=2013894056999916075")
        XCTAssertEqual(MiniMaxUsage.web(combo)?.groupID, "2013894056999916075")
        XCTAssertEqual(MiniMaxUsage.web("Cookie: HERTZ-SESSION=abc")?.cookie, "HERTZ-SESSION=abc")
        XCTAssertEqual(MiniMaxUsage.web("a=b; web-base=1")?.cookie, "a=b; web-base=1")
    }

    func testMiniMaxSubscriptionMetadata() throws {
        let sub = try MiniMaxUsage.mapSubscription(json("""
        {"base_resp":{"status_code":0,"status_msg":"success"},"data":{"current_subscribe":{
         "current_subscribe_title":"TokenPlanMax-\u{5E74}\u{5EA6}\u{4F1A}\u{5458}","current_subscribe_end_time":"05/19/2027",
         "renewal_date":"05/18/2027","current_subscribe_end_time_ts":1810656000000,"renewal_trigger_time_ts":1810569600000},
         "packages":[{"resource_package_name":"TokenPlanMax","display_name":"Token Plan \u{00B7} TokenPlanMax-\u{5E74}\u{5EA6}\u{4F1A}\u{5458}"}]}}
        """))
        XCTAssertEqual(sub.plan, "TokenPlanMax-\u{5E74}\u{5EA6}\u{4F1A}\u{5458}")
        XCTAssertEqual(sub.expires, Date(timeIntervalSince1970: 1_810_656_000))
        XCTAssertEqual(sub.renews, Date(timeIntervalSince1970: 1_810_569_600))
        let section = MiniMaxUsage.subscriptionSection(sub)
        XCTAssertEqual(section.rows.map(\.value), ["2027-05-19", "2027-05-18"])

        let current = try MiniMaxUsage.mapSubscription(json("""
        {"base_resp":{"status_code":0},"data":{"current_subscribe":{"current_subscribe_title":"TokenPlanUltra-x"},
         "packages":[{"resource_package_name":"TokenPlanPlus"},{"resource_package_name":"TokenPlanMax"}]}}
        """))
        XCTAssertEqual(current.plan, "TokenPlanUltra-x")
        XCTAssertThrowsError(try MiniMaxUsage.mapSubscription(json(#"{"base_resp":{"status_code":1004,"status_msg":"cookie is missing"}}"#)))
    }

    func testMiniMaxBillingHistoryAggregatesAndFiltersFailures() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Fmt.iso("2026-05-17T12:00:00Z")!
        let body = try json("""
        {"base_resp":{"status_code":0},"total_cnt":4,"charge_records":[
         {"consume_token":1000,"consume_cash_after_voucher":1.25,"ymd":"2026-05-17","method":"chat","model":"MiniMax-M1"},
         {"consume_token":"2000","consume_cash":"2.50","ymd":"2026-05-16","method":"chat","model":"MiniMax-M2"},
         {"consume_input_token":1200,"consume_output_token":1800,"ymd":"2026-04-18","method":"audio","model":"speech-2.8"},
         {"consume_token":4000,"ymd":"2026-04-17","method":"old","model":"ignored"},
         {"consume_token":9000,"ymd":"2026-05-17","method":"chat","model":"MiniMax-M1","result":"FAILED"},
         {"consume_token":9000,"ymd":"2026-05-17","method":"chat","model":"MiniMax-M1","status":0}]}
        """)
        let billing = MiniMaxUsage.mapBilling(records: body["charge_records"].array, now: now, calendar: calendar)
        XCTAssertEqual(billing.todayTokens, 1000)
        XCTAssertEqual(billing.last30Tokens, 6000)
        XCTAssertEqual(billing.todayCash, 1.25)
        XCTAssertEqual(billing.last30Cash, 3.75)
        XCTAssertEqual(billing.topMethods.first?.name, "audio")
        XCTAssertEqual(billing.topModels.first?.name, "speech-2.8")
        let section = MiniMaxUsage.billingSection(billing)
        XCTAssertEqual(section.title, "Billing history")
        XCTAssertEqual(section.rows.map(\.label), ["Today tokens", "30d tokens", "Today cash", "Models", "Top model", "Top method", "30d cash"])
        XCTAssertEqual(section.rows.map(\.value), ["1,000", "6,000", "1.25", "3", "speech-2.8", "audio", "3.75"])
    }

    // MARK: DeepSeek

    func testDeepSeekKeyBalanceEmptyAndUnavailableStates() throws {
        let empty = try DeepSeekUsage.map(json(#"{"is_available":false,"balance_infos":[]}"#))
        XCTAssertEqual(empty.cost?.balance, 0)
        XCTAssertEqual(empty.sections.first?.rows.map(\.value), ["Add credits"])
        let blocked = try DeepSeekUsage.map(json(
            #"{"is_available":false,"balance_infos":[{"currency":"USD","total_balance":"0.00","granted_balance":"0.00","topped_up_balance":"0.00"},{"currency":"CNY","total_balance":"12.00","granted_balance":"2.00","topped_up_balance":"10.00"}]}"#))
        XCTAssertEqual(blocked.cost?.currency, "CNY")
        XCTAssertEqual(rows(blocked, "")["Status"] ?? blocked.sections[0].rows.last?.value, "Balance unavailable for API calls")
    }

    func testDeepSeekPlatformPrefersFundedCurrencyAndRejectsExpiredSession() throws {
        let usage = try DeepSeekUsage.mapSummary(json("""
        {"code":0,"data":{"biz_code":0,"biz_data":{"normal_wallets":[{"balance":"0","currency":"USD"},{"balance":"70.5","currency":"CNY"}],
         "bonus_wallets":[{"balance":0.5,"currency":"CNY"}]}}}
        """))
        XCTAssertEqual(usage.cost?.currency, "CNY")
        XCTAssertEqual(usage.cost?.balance ?? -1, 71, accuracy: 0.0001)
        XCTAssertEqual(usage.sections[0].rows.map(\.label), ["Paid", "Granted"])
        XCTAssertThrowsError(try DeepSeekUsage.mapSummary(json(#"{"code":0,"data":{"biz_code":40002,"biz_data":null}}"#))) {
            XCTAssertTrue(($0 as? ProviderError)?.needsSignIn == true)
        }
    }

    private let fixtureNow = Date(timeIntervalSince1970: 1_779_796_800) // 2026-05-26 12:00:00 UTC
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testDeepSeekByAPIKeyDetailedUsage() throws {
        for stringKey in [true, false] {
            let day = Int(fixtureNow.timeIntervalSince1970)
            let key = stringKey ? "\"key-1\"" : "{\"name\":\"main\",\"tracking_id\":\"key-1\"}"
            let summary = try DeepSeekUsage.mapByAPIKey(
                amount: json("""
                {"code":0,"data":{"biz_data":{"series":[{"api_key":\(key),"model":"deepseek-chat","buckets":[{"time":\(day),
                 "usage":{"PROMPT_CACHE_HIT_TOKEN":"100","PROMPT_CACHE_MISS_TOKEN":50,"RESPONSE_TOKEN":25,"REQUEST":2}}]}]}}}
                """),
                cost: json("""
                {"code":0,"data":{"biz_data":{"data":[{"currency":"CNY","series":[{"api_key":\(key),"model":"deepseek-chat",
                 "buckets":[{"time":\(day),"cost":"0.12"}]}]}]}}}
                """), now: fixtureNow, calendar: utc)
            XCTAssertEqual(summary.todayTokens, 175)
            XCTAssertEqual(summary.todayCost, 0.12)
            XCTAssertEqual(summary.periodRequests, 2)
            XCTAssertEqual(summary.apiKeyCount, 1)
            XCTAssertEqual(summary.topModel, "deepseek-chat")
            XCTAssertTrue(summary.last30Days)

            let sections = DeepSeekUsage.sections(summary)
            XCTAssertEqual(sections[0].title, "Usage")
            XCTAssertEqual(sections[0].rows.map(\.label), ["Today", "Last 30 days", "Requests", "API keys", "Top model"])
            XCTAssertEqual(sections[0].rows[0].value, "\u{00A5}0.1200 \u{00B7} 175 tokens")
            XCTAssertEqual(sections[0].rows[2].value, "2")
            XCTAssertEqual(sections[1].rows.map(\.label), ["deepseek-chat"])
            XCTAssertEqual(sections[1].rows[0].value, "\u{00A5}0.1200")
        }
    }

    func testDeepSeekByAPIKeyKeepsOneCurrencyAndRejectsBadPayloads() throws {
        let day = Int(fixtureNow.timeIntervalSince1970)
        let summary = try DeepSeekUsage.mapByAPIKey(
            amount: json(#"{"code":0,"data":{"biz_code":0,"biz_data":{"series":[]}}}"#),
            cost: json("""
            {"code":0,"data":{"biz_code":0,"biz_data":{"data":[
             {"currency":"CNY","series":[{"buckets":[{"time":\(day),"cost":"7"}]}]},
             {"currency":"USD","series":[{"buckets":[{"time":\(day),"cost":"1"}]}]}]}}}
            """), now: fixtureNow, calendar: utc)
        XCTAssertEqual(summary.currency, "USD")
        XCTAssertEqual(summary.todayCost, 1)
        XCTAssertEqual(DeepSeekUsage.sections(summary)[0].rows[0].value.hasPrefix("$1.0000"), true)

        XCTAssertThrowsError(try DeepSeekUsage.mapByAPIKey(amount: json(#"{"code":0,"data":{"biz_code":40002,"biz_data":null}}"#),
                                                           cost: json(#"{"code":0,"data":{"biz_code":40002}}"#),
                                                           now: fixtureNow, calendar: utc)) {
            XCTAssertTrue(($0 as? ProviderError)?.needsSignIn == true)
        }
        XCTAssertThrowsError(try DeepSeekUsage.mapByAPIKey(amount: json(#"{"code":0,"data":{"biz_code":0}}"#),
                                                           cost: json(#"{"code":0,"data":{"biz_code":0}}"#),
                                                           now: fixtureNow, calendar: utc))
    }

    func testDeepSeekMonthlyFallbackTotals() throws {
        let amount = try json("""
        {"code":0,"msg":"","data":{"biz_code":0,"biz_msg":"","biz_data":{
         "total":[{"model":"deepseek-v4-flash","usage":[{"type":"PROMPT_CACHE_HIT_TOKEN","amount":"100686720"},
           {"type":"PROMPT_CACHE_MISS_TOKEN","amount":"1305432"},{"type":"RESPONSE_TOKEN","amount":"656338"},{"type":"REQUEST","amount":"1212"}]},
          {"model":"deepseek-chat","usage":[{"type":"PROMPT_CACHE_HIT_TOKEN","amount":"200"},{"type":"RESPONSE_TOKEN","amount":"100"}]}],
         "days":[{"date":"2026-05-26","data":[{"model":"deepseek-v4-flash","usage":[
           {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"100686720"},{"type":"PROMPT_CACHE_MISS_TOKEN","amount":"1305432"},
           {"type":"RESPONSE_TOKEN","amount":"656338"},{"type":"REQUEST","amount":"1212"}]}]},
          {"date":"2026-05-02","data":[{"model":"deepseek-chat","usage":[{"type":"RESPONSE_TOKEN","amount":"10"},{"type":"BOGUS","amount":"99"}]}]},
          {"date":"2026-04-30","data":[{"model":"deepseek-chat","usage":[{"type":"RESPONSE_TOKEN","amount":"5000"}]}]}]}}}
        """)
        let cost = try json("""
        {"code":0,"msg":"","data":{"biz_code":0,"biz_msg":"","biz_data":[{
         "total":[{"model":"deepseek-v4-flash","usage":[{"type":"PROMPT_CACHE_HIT_TOKEN","amount":"2.0137344000000000"},
           {"type":"PROMPT_CACHE_MISS_TOKEN","amount":"1.3054320000000000"},{"type":"RESPONSE_TOKEN","amount":"1.3126760000000000"},
           {"type":"REQUEST","amount":"0"}]},
          {"model":"deepseek-chat","usage":[{"type":"RESPONSE_TOKEN","amount":"oops"}]}],
         "days":[{"date":"2026-05-26","data":[{"model":"deepseek-v4-flash","usage":[
           {"type":"PROMPT_CACHE_HIT_TOKEN","amount":"2.0137344000000000"},{"type":"PROMPT_CACHE_MISS_TOKEN","amount":"1.3054320000000000"},
           {"type":"RESPONSE_TOKEN","amount":"1.3126760000000000"},{"type":"REQUEST","amount":"0"}]}]}],
         "currency":"CNY"}]}}
        """)
        let summary = try DeepSeekUsage.mapMonthly(amount: amount, cost: cost, now: fixtureNow, calendar: utc)
        XCTAssertEqual(summary.todayTokens, 102_648_490)
        XCTAssertEqual(summary.todayRequests, 1212)
        XCTAssertEqual(summary.todayCost ?? 0, 4.6318424, accuracy: 0.0001)
        // Month so far: today plus 2026-05-02; April is out.
        XCTAssertEqual(summary.periodTokens, 102_648_500)
        XCTAssertEqual(summary.periodRequests, 1212)
        XCTAssertEqual(summary.topModel, "deepseek-v4-flash")
        XCTAssertFalse(summary.last30Days)
        // deepseek-chat has an unreadable cost, so only the complete model total is kept.
        XCTAssertEqual(summary.modelCosts.map(\.model), ["deepseek-v4-flash"])
        XCTAssertEqual(summary.modelCosts[0].cost, 4.6318424, accuracy: 0.0001)
        let rows = DeepSeekUsage.sections(summary)[0].rows
        XCTAssertEqual(rows[1].label, "This month")
        XCTAssertEqual(rows[0].value, "\u{00A5}4.6318 \u{00B7} 102,648,490 tokens")
    }

    func testDeepSeekMissingCostShowsDash() {
        let summary = DeepSeekUsage.Summary()
        XCTAssertEqual(DeepSeekUsage.sections(summary)[0].rows[0].value, "\u{2014} \u{00B7} 0 tokens")
    }

    // MARK: Doubao

    func testDoubaoWindowsOrderedAndTimestampedWhateverTheResponseOrder() throws {
        let usage = try DoubaoUsage.map(coding: json("""
        {"Result":{"Status":"Running","UpdateTimestamp":1782226444,"QuotaUsage":[
         {"Level":"Monthly","Percent":7.5,"ResetTimestamp":1782403199},{"Level":"5H","Percent":0.116,"ResetTimestamp":1782226478},
         {"Level":"week","Percent":3.18,"ResetTimestamp":1782662400}]}}
        """), agent: nil)
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly", "monthly"])
        XCTAssertEqual(usage.windows.map(\.windowMinutes), [300, 10080, 43200])
        XCTAssertEqual(usage.fetchedAt, Date(timeIntervalSince1970: 1_782_226_444))
        XCTAssertEqual(usage.plan, "Running")
    }

    func testDoubaoAgentPlanOnlyAccountAndDailyWindowSkipped() throws {
        let usage = try DoubaoUsage.map(coding: json(#"{"Result":{"Status":"Reclaimed"}}"#), agent: json("""
        {"Result":{"PlanType":"medium","AFPFiveHour":{"Quota":10000,"Used":0,"ResetTime":-1},
         "AFPWeekly":{"Quota":35000,"Used":8750,"ResetTime":1785686400000},
         "AFPMonthly":{"Quota":100000,"Used":25000,"ResetTime":1787846399000},
         "AFPDaily":{"Quota":50000,"Used":0,"ResetTime":1785340800000}}}
        """))
        XCTAssertEqual(usage.windows.map(\.id), ["agent-session", "agent-weekly", "agent-monthly"])
        XCTAssertEqual(usage.windows.map { $0.usedPercent ?? -1 }, [0, 25, 25])
        XCTAssertEqual(usage.windows[1].resetsAt, Date(timeIntervalSince1970: 1_785_686_400))
        XCTAssertNil(usage.windows[0].resetsAt)
    }

    func testDoubaoProbeRequestLimitHeaders() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ok = DoubaoUsage.probe(status: 200, headers: ["x-ratelimit-limit-requests": "100",
                                                          "x-ratelimit-remaining-requests": "40",
                                                          "x-ratelimit-reset-requests": "1m30s"], now: now)
        XCTAssertTrue(ok.reliable)
        let usage = DoubaoUsage.map(probe: ok, now: now)
        XCTAssertEqual(usage.windows.map(\.id), ["requests"])
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 60, accuracy: 0.001)
        XCTAssertEqual(usage.windows[0].detail, "60/100 requests")
        XCTAssertEqual(usage.windows[0].resetsAt, now.addingTimeInterval(90))

        // A throttled call with only the limit header proves the bucket is empty.
        let throttled = DoubaoUsage.map(probe: DoubaoUsage.probe(status: 429, headers: ["x-ratelimit-limit-requests": "100"], now: now), now: now)
        XCTAssertEqual(throttled.windows[0].usedPercent, 100)
        // A bare 429 and a header-less 200 show an active key without invented limits.
        for probe in [DoubaoUsage.probe(status: 429, headers: [:]), DoubaoUsage.probe(status: 200, headers: [:])] {
            let unknown = DoubaoUsage.map(probe: probe, now: now)
            XCTAssertTrue(unknown.windows.isEmpty)
            XCTAssertEqual(unknown.sections.first?.rows.first?.label, "API key")
        }
        // Zero remaining on a 200 needs a second look.
        XCTAssertTrue(DoubaoUsage.probe(status: 200, headers: ["x-ratelimit-limit-requests": "5", "x-ratelimit-remaining-requests": "0"]).ambiguousZero)
        XCTAssertFalse(DoubaoUsage.probe(status: 429, headers: ["x-ratelimit-limit-requests": "5", "x-ratelimit-remaining-requests": "0"]).ambiguousZero)
    }

    func testDoubaoResetDateFormats() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(DoubaoUsage.resetDate("2026-06-17T00:00:00Z", now: now), Fmt.iso("2026-06-17T00:00:00Z"))
        XCTAssertEqual(DoubaoUsage.resetDate("1d2h3m4s", now: now), now.addingTimeInterval(86400 + 7200 + 180 + 4))
        XCTAssertEqual(DoubaoUsage.resetDate("30", now: now), now.addingTimeInterval(30))
        XCTAssertNil(DoubaoUsage.resetDate("soon", now: now))
    }
}


/// Fixtures follow CodexBar's Alibaba Coding Plan, Alibaba Token Plan and QwenCloud tests.
final class ProvidersAuditAPIsBTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func assertSignIn(_ body: @autoclosure () throws -> Any, _ line: UInt = #line) {
        XCTAssertThrowsError(try body(), line: line) { XCTAssertTrue(($0 as? ProviderError)?.needsSignIn == true, line: line) }
    }

    // MARK: Alibaba Coding Plan

    func testCodingPlanWindowsResetsAndDetail() throws {
        let usage = try AlibabaUsage.map(json("""
        {"data":{"codingPlanInstanceInfos":[{"planName":"Alibaba Coding Plan Pro"}],
         "codingPlanQuotaInfo":{"per5HourUsedQuota":52,"per5HourTotalQuota":1000,"per5HourQuotaNextRefreshTime":1700000300000,
         "perWeekUsedQuota":800,"perWeekTotalQuota":5000,"perWeekQuotaNextRefreshTime":1700100000000,
         "perBillMonthUsedQuota":1200,"perBillMonthTotalQuota":20000,"perBillMonthQuotaNextRefreshTime":1701000000000}},
         "status_code":0}
        """), now: now)
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly", "monthly"])
        XCTAssertEqual(usage.windows.map(\.windowMinutes), [300, 10080, 43200])
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1_700_000_300))
        XCTAssertEqual(usage.windows[1].resetsAt, Date(timeIntervalSince1970: 1_700_100_000))
        XCTAssertEqual(usage.windows[2].resetsAt, Date(timeIntervalSince1970: 1_701_000_000))
        XCTAssertEqual(usage.windows[0].detail, "52 / 1,000 requests")
        XCTAssertEqual(usage.plan, "Alibaba Coding Plan Pro")
    }

    func testCodingPlanStaleSessionResetShiftsFiveHours() throws {
        let usage = try AlibabaUsage.map(json("""
        {"codingPlanQuotaInfo":{"per5HourUsedQuota":70,"per5HourTotalQuota":1200,"per5HourQuotaNextRefreshTime":1699999900000,
         "perWeekUsedQuota":80,"perWeekTotalQuota":9000,"perWeekQuotaNextRefreshTime":1700010000000}}
        """), now: now)
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1_699_999_900 + 18000))
        XCTAssertEqual(usage.windows[1].resetsAt, Date(timeIntervalSince1970: 1_700_010_000))
    }

    func testCodingPlanMultiInstanceUsesActiveInstance() throws {
        let usage = try AlibabaUsage.map(json("""
        {"data":{"codingPlanInstanceInfos":[
          {"planName":"Expired Starter","status":"EXPIRED","endTime":"2025-04-01 17:00",
           "codingPlanQuotaInfo":{"per5HourUsedQuota":7,"per5HourTotalQuota":100,"per5HourQuotaNextRefreshTime":1700000100000}},
          {"planName":"Active Pro","status":"VALID",
           "codingPlanQuotaInfo":{"per5HourUsedQuota":52,"per5HourTotalQuota":1000,"per5HourQuotaNextRefreshTime":1700000300000}}]},
         "status_code":0}
        """), now: now)
        XCTAssertEqual(usage.plan, "Active Pro")
        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 5.2, accuracy: 0.001)
    }

    func testCodingPlanActiveInstanceDoesNotBorrowQuota() throws {
        let usage = try AlibabaUsage.map(json("""
        {"data":{"codingPlanInstanceInfos":[
          {"planName":"Expired Starter","status":"EXPIRED","endTime":"2025-04-01 17:00",
           "codingPlanQuotaInfo":{"per5HourUsedQuota":7,"per5HourTotalQuota":100}},
          {"planName":"Active Pro","status":"VALID"}]},"status_code":0}
        """), now: now)
        XCTAssertEqual(usage.plan, "Active Pro")
        XCTAssertTrue(usage.windows.isEmpty)
    }

    func testCodingPlanWrappedJSONStringPayload() throws {
        let inner = #"{\"data\":{\"codingPlanInstanceInfos\":[{\"planName\":\"Coding Plan Lite\",\"status\":\"VALID\",\"codingPlanQuotaInfo\":{\"per5HourUsedQuota\":0,\"per5HourTotalQuota\":1000,\"per5HourQuotaNextRefreshTime\":1700000300000}}]},\"statusCode\":200}"#
        let usage = try AlibabaUsage.map(json(#"{"successResponse":{"body":"\#(inner)"}}"#), now: now)
        XCTAssertEqual(usage.plan, "Coding Plan Lite")
        XCTAssertEqual(usage.windows.first?.usedPercent, 0)
        XCTAssertEqual(usage.windows.first?.detail, "0 / 1,000 requests")
    }

    func testCodingPlanQuotaLookupKeepsDictionaryPrecedenceAcrossArrays() throws {
        let usage = try AlibabaUsage.map(json("""
        {"codingPlanQuotaInfo":[{"codingPlanQuotaInfo":{"per5HourUsedQuota":90,"per5HourTotalQuota":100},
          "per5HourUsedQuota":20,"per5HourTotalQuota":100}]}
        """), now: now)
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 20, accuracy: 0.001)
    }

    func testCodingPlanPlanLookupPrefersCurrentExactKeys() throws {
        let usage = try AlibabaUsage.map(json("""
        {"packageName":"Current plan","PLANNAME":"Wrong case","data":{"planName":"Nested plan"},
         "codingPlanQuotaInfo":{"per5HourUsedQuota":20,"per5HourTotalQuota":100}}
        """), now: now)
        XCTAssertEqual(usage.plan, "Current plan")
    }

    func testCodingPlanActivePlanWithoutCountersStaysVisible() throws {
        for body in [
            #"{"data":{"codingPlanInstanceInfos":[{"planName":"Coding Plan Lite","status":"VALID","planUsage":"0%","endTime":"2026-04-01 17:00"}]},"status_code":0}"#,
            #"{"data":{"codingPlanInstanceInfos":[{"planName":"Coding Plan Lite","status":"VALID","endTime":"2026-04-01 17:00"}]},"status_code":0}"#,
            // A future end time alone counts as proof (also covers "yyyy-MM-dd HH:mm" dates).
            #"{"data":{"codingPlanInstanceInfos":[{"planName":"Coding Plan Lite","endTime":"2030-04-01 17:00"}]},"status_code":0}"#,
        ] {
            let usage = try AlibabaUsage.map(json(body), now: now)
            XCTAssertEqual(usage.plan, "Coding Plan Lite")
            XCTAssertTrue(usage.windows.isEmpty)
        }
        let multi = try AlibabaUsage.map(json("""
        {"data":{"codingPlanInstanceInfos":[{"planName":"Expired Starter","status":"EXPIRED","endTime":"2025-04-01 17:00"},
          {"planName":"Active Pro","status":"VALID","planUsage":"42%"}]},"status_code":0}
        """), now: now)
        XCTAssertEqual(multi.plan, "Active Pro")
    }

    func testCodingPlanWithoutActiveProofFailsInsteadOfFakeUsage() {
        let bodies = [
            #"{"data":{"codingPlanInstanceInfos":[{"planName":"Alibaba Coding Plan Pro"}]},"status_code":0}"#,
            #"{"data":{"codingPlanInstanceInfos":[{"planName":"Alibaba Coding Plan Pro","planUsage":"18%"}]},"status_code":0}"#,
            #"{"data":{"codingPlanInstanceInfos":[{"planName":"Coding Plan Lite","status":"EXPIRED"}]},"status_code":0}"#,
            #"{"data":{"status":"VALID","codingPlanInstanceInfos":[{"planName":"Expired Starter","status":"EXPIRED"},{"planName":"No Proof Pro"}]},"status_code":0}"#,
        ]
        for body in bodies {
            XCTAssertThrowsError(try AlibabaUsage.map(json(body), now: now)) {
                guard case .parse = $0 as? ProviderError else { return XCTFail("expected parse error, got \($0)") }
                // Parse failures are the ones that retry on the China console.
                XCTAssertTrue(AlibabaUsage.retryOnChina($0))
            }
        }
    }

    func testCodingPlanConsoleLoginPayload() throws {
        let body = try json(#"{"code":"ConsoleNeedLogin","message":"You need to log in.","requestId":"abc","successResponse":false}"#)
        assertSignIn(try AlibabaUsage.map(body))
        // An API key cannot fix a console login answer, so it asks for a Cookie header and does not retry.
        XCTAssertThrowsError(try AlibabaUsage.map(body, apiKey: true)) {
            guard case .unsupported(let text) = $0 as? ProviderError else { return XCTFail("expected unsupported") }
            XCTAssertTrue(text.contains("Cookie"))
            XCTAssertFalse(AlibabaUsage.retryOnChina($0))
        }
    }

    func testCodingPlanStatusCodeErrors() throws {
        assertSignIn(try AlibabaUsage.map(json(#"{"statusCode":403,"message":"Forbidden"}"#)))
        assertSignIn(try AlibabaUsage.map(json(#"{"status_code":500,"message":"Invalid API key"}"#)))
        XCTAssertThrowsError(try AlibabaUsage.map(json(#"{"statusCode":500,"message":"boom"}"#))) {
            XCTAssertEqual($0 as? ProviderError, .http(500, "Alibaba returned an error: boom"))
        }
        XCTAssertTrue(AlibabaUsage.retryOnChina(ProviderError.http(404, "")))
        XCTAssertFalse(AlibabaUsage.retryOnChina(ProviderError.network("down")))
    }

    func testConsoleSecTokenScrape() {
        let html = """
        <script>window.ALIYUN_CONSOLE_CONFIG = { LANG: "zh", SEC_TOKEN: "NwsiCAv9SDsHsNab4Jexample", ACCOUNT_NAME: "someone" };</script>
        """
        XCTAssertEqual(OneConsole.scrapeToken(html, csrf: false), "NwsiCAv9SDsHsNab4Jexample")
        XCTAssertEqual(OneConsole.scrapeToken(#"{"secToken":"abc123"}"#, csrf: true), "abc123")
        XCTAssertEqual(OneConsole.scrapeToken("var x = { sec_token: 'def456' };", csrf: false), "def456")
        XCTAssertEqual(OneConsole.scrapeToken("var c = { csrfToken: 'ghi789' };", csrf: true), "ghi789")
        XCTAssertNil(OneConsole.scrapeToken("var c = { csrfToken: 'ghi789' };", csrf: false))
        XCTAssertNil(OneConsole.scrapeToken("<html><body>no token here</body></html>", csrf: true))
    }

    // MARK: Alibaba Token Plan

    private let personalUsage = """
    {"code":"200","data":{"DataV2":{"data":{"success":true,"data":{"per5HourPercentage":0.0009973083333333333,
     "per5HourResetTime":1784813220000,"per1WeekPercentage":0.0003014725,"per1WeekResetTime":1785234900000}},
     "success":true,"httpStatus":200}},"successResponse":true}
    """
    private let personalSubscription = """
    {"code":"200","data":{"DataV2":{"data":{"success":true,"data":{"instanceCode":"sfm_tokenplansolo_public_cn-redacted",
     "specCode":"pro","status":"VALID","remainingDays":29,"autoRenewFlag":false,"startTime":1784622404000,"endTime":1787328000000}},
     "success":true,"httpStatus":200}},"successResponse":true}
    """
    private let personalQuota = """
    {"code":"200","data":{"DataV2":{"data":{"success":true,"data":{"lite":{"five_hour":700,"weekly":2500},
     "standard":{"five_hour":3000,"weekly":10000},"pro":{"five_hour":12000,"weekly":40000}}},"success":true,"httpStatus":200}},
     "successResponse":true}
    """

    func testTokenPlanPersonalRealFixtures() throws {
        let usage = try AlibabaTokenPlanUsage.mapPersonal(usage: json(personalUsage), subscription: json(personalSubscription),
                                                          quotaConfig: json(personalQuota), now: now)
        XCTAssertEqual(usage.plan, "Pro")
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 0.09973083333333333, accuracy: 1e-9)
        XCTAssertEqual(usage.windows[0].windowMinutes, 300)
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1_784_813_220))
        XCTAssertEqual(usage.windows[0].detail, "11.97 / 12,000 credits")
        XCTAssertEqual(usage.windows[1].usedPercent ?? -1, 0.03014725, accuracy: 1e-9)
        XCTAssertEqual(usage.windows[1].windowMinutes, 10080)
        XCTAssertEqual(usage.windows[1].resetsAt, Date(timeIntervalSince1970: 1_785_234_900))
        XCTAssertEqual(usage.windows[1].detail, "12.06 / 40,000 credits")
    }

    func testTokenPlanPersonalWeeklyOnlyAndDefaultPlan() throws {
        let usage = try AlibabaTokenPlanUsage.mapPersonal(usage: json("""
        {"data":{"DataV2":{"data":{"success":true,"data":{"per1WeekPercentage":0.10007527475,"per1WeekResetTime":1785234900000}}}},
         "successResponse":true}
        """), subscription: nil, quotaConfig: nil, now: now)
        XCTAssertEqual(usage.windows.map(\.id), ["weekly"])
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 10.007527475, accuracy: 1e-9)
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1_785_234_900))
        XCTAssertNil(usage.windows[0].detail)
        XCTAssertEqual(usage.plan, "Personal")
    }

    func testTokenPlanPersonalMonthlyTiersAndAliases() throws {
        // Plan code is trimmed and lowercased, a blank alias is skipped, ratios clamp to 0...1.
        let usage = try AlibabaTokenPlanUsage.mapPersonal(
            usage: json(#"{"per5HourPercentage":2,"per1WeekPercentage":-1,"per1MonthPercentage":0.5,"per1MonthResetTime":1700100000000}"#),
            subscription: json(#"{"specCode":" ","spec_code":"  PRO  ","planName":"max"}"#),
            quotaConfig: json(#"{"pro":{"fiveHour":80,"weekly":160,"monthly":800},"max":{"fiveHour":800}}"#), now: now)
        XCTAssertEqual(usage.plan, "Pro")
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly", "monthly"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [100, 0, 50])
        XCTAssertEqual(usage.windows.map(\.detail), ["80 / 80 credits", "0 / 160 credits", "400 / 800 credits"])
        XCTAssertEqual(usage.windows[2].windowMinutes, 43200)
        XCTAssertEqual(usage.windows[2].resetsAt, Date(timeIntervalSince1970: 1_700_100_000))

        let custom = try AlibabaTokenPlanUsage.mapPersonal(usage: json(#"{"per5HourPercentage":0.25}"#),
                                                           subscription: json(#"{"specCode":"custom"}"#),
                                                           quotaConfig: json(#"{"custom":{"five_hour":100}}"#), now: now)
        XCTAssertEqual(custom.plan, "custom")
        XCTAssertEqual(custom.windows[0].detail, "25 / 100 credits")
    }

    func testTokenPlanPersonalErrors() throws {
        assertSignIn(try AlibabaTokenPlanUsage.mapPersonal(usage: json("""
        {"data":{"success":false,"errorCode":"BailianGateway.Login.NotLogined","errorMsg":"BailianGateway.Login.NotLogined"},"httpStatusCode":"200"}
        """), subscription: nil, quotaConfig: nil))
        // An empty Success answer is transient and is retried by the fetch.
        XCTAssertThrowsError(try AlibabaTokenPlanUsage.mapPersonal(
            usage: json(#"{"code":"200","data":{"success":true},"successResponse":true}"#), subscription: nil, quotaConfig: nil)) {
            XCTAssertEqual($0 as? ProviderError, .unavailable(AlibabaTokenPlanUsage.pending))
        }
    }

    func testTokenPlanTeamSummaryShapes() throws {
        let plain = try AlibabaTokenPlanUsage.mapTeam(json(
            #"{"Success":true,"Data":{"TotalCount":1,"TotalValue":1000,"TotalSurplusValue":875,"NearestExpireDate":1701000000000},"Code":"200"}"#))
        XCTAssertEqual(plain.plan, "TOKEN PLAN")
        XCTAssertEqual(plain.windows[0].usedPercent ?? -1, 12.5, accuracy: 0.001)
        XCTAssertEqual(plain.windows[0].resetsAt, Date(timeIntervalSince1970: 1_701_000_000))
        XCTAssertEqual(plain.windows[0].detail, "125 / 1,000 credits")

        let body = #"{"success":true,"data":{"totalCount":1,"totalSurplusValue":750,"totalValue":1000}}"#
        let nested = try AlibabaTokenPlanUsage.mapTeam(JSON(["successResponse": ["body": body]]))
        XCTAssertEqual(nested.windows[0].usedPercent ?? -1, 25, accuracy: 0.001)

        // Empty subscription summary stays visible without a window.
        let empty = try AlibabaTokenPlanUsage.mapTeam(json(#"{"Success":true,"Data":{"TotalCount":0}}"#))
        XCTAssertTrue(empty.windows.isEmpty)
        XCTAssertNil(empty.plan)

        // Balance alone does not make a window.
        let balance = try AlibabaTokenPlanUsage.mapTeam(json(#"{"Success":true,"Data":{"balance":700}}"#))
        XCTAssertTrue(balance.windows.isEmpty)

        let named = try AlibabaTokenPlanUsage.mapTeam(json(#"{"Success":true,"Data":{"TotalCount":1,"SpecType":"standard","TotalValue":10,"TotalSurplusValue":5}}"#))
        XCTAssertEqual(named.plan, "standard")
    }

    func testTokenPlanTeamTraversalPrecedence() throws {
        let usage = try AlibabaTokenPlanUsage.mapTeam(json("""
        {"envelope":[{"Data":{"totalQuota":100,"usedQuota":"invalid","usedCredits":20,
          "metadata":[{"packageName":"Current plan","PLANNAME":"Wrong case","data":{"planName":"Nested plan"}}]}}]}
        """))
        XCTAssertEqual(usage.plan, "Current plan")
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 20, accuracy: 0.001)
        let reset = try AlibabaTokenPlanUsage.mapTeam(json(
            #"{"Data":{"totalQuota":100,"metadata":[{"resetTime":100,"data":{"resetTime":1700000000}}]}}"#))
        XCTAssertEqual(reset.windows.isEmpty, true)
        let withUse = try AlibabaTokenPlanUsage.mapTeam(json(
            #"{"Data":{"totalQuota":100,"usedQuota":1,"metadata":[{"resetTime":100,"data":{"resetTime":1700000000}}]}}"#))
        XCTAssertEqual(withUse.windows[0].resetsAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testTokenPlanErrorPayloads() throws {
        assertSignIn(try AlibabaTokenPlanUsage.mapTeam(json(#"{"code":"ConsoleNeedLogin","message":"You need to log in.","successResponse":false}"#)))
        assertSignIn(try AlibabaTokenPlanUsage.mapTeam(json(
            #"{"code":"PostonlyOrTokenError","message":"Your request has expired. Please refresh the page.","successResponse":false}"#)))
        assertSignIn(try AlibabaTokenPlanUsage.mapTeam(json(#"{"statusCode":403,"message":"Forbidden"}"#)))
        assertSignIn(try AlibabaTokenPlanUsage.mapTeam(json(#"{"successResponse":false,"statusCode":403,"message":"Forbidden"}"#)))
        let failed = JSON(["successResponse": ["body": #"{"success":false,"message":"Subscription lookup failed"}"#]])
        XCTAssertThrowsError(try AlibabaTokenPlanUsage.mapTeam(failed)) {
            XCTAssertEqual($0 as? ProviderError, .unavailable("Subscription lookup failed"))
        }
        // The outer envelope claims success while the nested frame carries the real gateway error.
        let workspace = try json("""
        {"code":"200","data":{"success":false,"httpStatus":200,"errorCode":"BailianGateway.Workspace.NotAuthorised",
         "errorMsg":"BailianGateway.Workspace.NotAuthorised"},"httpStatusCode":"200","successResponse":true}
        """)
        XCTAssertThrowsError(try AlibabaTokenPlanUsage.mapTeam(workspace)) {
            XCTAssertEqual($0 as? ProviderError, .unavailable("BailianGateway.Workspace.NotAuthorised"))
        }
        let gateway = try json("""
        {"code":"200","data":{"success":false,"errorCode":"BailianGateway.Quota.ServiceUnavailable","errorMsg":"quota service unavailable"},
         "successResponse":true}
        """)
        XCTAssertThrowsError(try AlibabaTokenPlanUsage.mapTeam(gateway)) {
            XCTAssertEqual($0 as? ProviderError, .unavailable("quota service unavailable"))
        }
    }

    // MARK: QwenCloud

    func testQwenIndividualCurrentShapeWithNestedJSONString() throws {
        let inner = #"{\"code\":0,\"data\":{\"per5HourPercentage\":0.03,\"per5HourResetTime\":1700003600000,\"per1WeekPercentage\":0.01,\"per1WeekResetTime\":1700086400000},\"success\":true}"#
        let usage = try QwenCloudUsage.mapIndividual(usage: json(#"{"data":{"DataV2":{"data":"\#(inner)"}},"httpStatusCode":200}"#),
                                                     subscription: nil, quotaConfig: nil, now: now)
        XCTAssertNil(usage.plan)
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1_700_003_600))
        XCTAssertEqual(usage.windows[1].usedPercent ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(usage.windows[1].resetsAt, Date(timeIntervalSince1970: 1_700_086_400))
    }

    func testQwenIndividualMonthlyTiersShareParserWithAlibaba() throws {
        let usage = try QwenCloudUsage.mapIndividual(
            usage: json(#"{"per5HourPercentage":0.25,"per1WeekPercentage":0.5,"per1MonthPercentage":0.1,"per5HourResetTime":1700003600000}"#),
            subscription: json(#"{"planName":"  LITE "}"#),
            quotaConfig: json(#"{"lite":{"five_hour":100,"weekly":200,"monthly":1000}}"#), now: now)
        XCTAssertEqual(usage.plan, "Lite")
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly", "monthly"])
        XCTAssertEqual(usage.windows.map(\.detail), ["25 / 100 credits", "100 / 200 credits", "100 / 1,000 credits"])
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1_700_003_600))
    }

    func testQwenIndividualFallsBackToSummaryShapes() throws {
        let nested = try QwenCloudUsage.mapIndividual(usage: json("""
        {"code":"200","successResponse":true,"data":{"TotalCount":1,"Data":[{"InstanceCode":"qwen-token-plan","Status":"NORMAL","EndTime":1.701e12,
         "EquityList":[{"Type":"CREDITS","CycleTotalValue":"1000","CycleSurplusValue":"875"}]}]}}
        """), subscription: nil, quotaConfig: nil, now: now)
        XCTAssertEqual(nested.plan, "TOKEN PLAN")
        XCTAssertEqual(nested.windows[0].usedPercent ?? -1, 12.5, accuracy: 0.001)
        XCTAssertEqual(nested.windows[0].resetsAt, Date(timeIntervalSince1970: 1_701_000_000))

        let flat = try QwenCloudUsage.mapIndividual(usage: json(#"{"Success":true,"Data":{"TotalCount":1,"TotalValue":2000,"TotalSurplusValue":1500}}"#),
                                                    subscription: nil, quotaConfig: nil, now: now)
        XCTAssertEqual(flat.windows[0].usedPercent ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(flat.windows[0].detail, "500 / 2,000 credits")

        // Authenticated account with no subscription: HTTP 200, TotalCount 0, no false 100% bar.
        let none = try QwenCloudUsage.mapIndividual(usage: json("""
        {"requestId":"x","code":"200","message":null,"data":{"RequestId":"x","Message":"Successful!","Data":{"Uid":7,
         "TotalSurplusValue":"0","TotalCount":0,"TotalValue":"0","ProductCode":"sfm_tokenplansolo_public_intl"},"Code":"Success","Success":true},
         "httpStatusCode":"200","successResponse":true}
        """), subscription: nil, quotaConfig: nil, now: now)
        XCTAssertTrue(none.windows.isEmpty)
    }

    func testQwenIndividualErrors() throws {
        assertSignIn(try QwenCloudUsage.mapIndividual(usage: json(#"{"code":"ConsoleNeedLogin","message":"You need to log in.","successResponse":false}"#),
                                                      subscription: nil, quotaConfig: nil))
        assertSignIn(try QwenCloudUsage.mapIndividual(usage: json(#"{"statusCode":403,"message":"Forbidden"}"#),
                                                      subscription: nil, quotaConfig: nil))
    }

    func testQwenTeamCreditPoolSeatsAndRows() throws {
        let team = try QwenCloudUsage.mapTeam(json("""
        {"successResponse":true,"data":{"Success":true,"Data":{
          "StartTime":1784894400000,"EndTime":1790251200000,"ProductCode":"sfm_tokenplanteams_dp_intl",
          "SubscriptionGroupList":[{"SpecType":"standard","SubscriptionAssignedNumber":1,"SubscriptionTotalNumber":1,
            "NextCycleFlushTime":1790251200000,"EquityList":[{"EquityCode":"credit_value","TotalValue":"25000","SurplusValue":"6373.93922996"}]}]}}}
        """), now: Date(timeIntervalSince1970: 1_789_500_000))
        XCTAssertEqual(team.plan, "Standard Team")
        XCTAssertEqual(team.windows.count, 1)
        XCTAssertEqual(team.windows[0].usedPercent ?? -1, 74.504243, accuracy: 0.0001)
        XCTAssertEqual(team.windows[0].resetsAt, Date(timeIntervalSince1970: 1_790_251_200))
        XCTAssertEqual(team.sections.first?.title, "Team Token Plan")
        XCTAssertEqual(team.sections.first?.rows.map(\.label), ["Seats", "Credits", "Remaining"])
        XCTAssertEqual(team.sections.first?.rows.map(\.value), ["1 / 1 assigned", "18,626.06 / 25,000 credits used", "6,373.94 credits"])
    }

    func testQwenTeamRejectsUnsafeShapesAndNamesUnknownSpec() throws {
        func team(spec: String, equity: String, groups: String = "1") throws -> JSON {
            try json("""
            {"code":"200","data":{"Success":true,"Data":{"StartTime":1700000000000,"EndTime":1800000000000,
             "ProductCode":"sfm_tokenplanteams_dp_intl","SubscriptionGroupList":[{"SpecType":"\(spec)",\(equity)}]}}}
            """)
        }
        let ok = #""EquityList":[{"EquityCode":"credit_value","TotalValue":100,"SurplusValue":40}]"#
        let usage = try QwenCloudUsage.mapTeam(team(spec: "Weird Spec!", equity: ok), now: now)
        XCTAssertEqual(usage.plan, "Team Token Plan")
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 60, accuracy: 0.001)
        // Remaining above total, or two credit equities, is a diagnostic and not an invented value.
        XCTAssertThrowsError(try QwenCloudUsage.mapTeam(team(
            spec: "standard", equity: #""EquityList":[{"EquityCode":"credit_value","TotalValue":100,"SurplusValue":140}]"#), now: now))
        XCTAssertThrowsError(try QwenCloudUsage.mapTeam(team(
            spec: "standard", equity: #""EquityList":[{"EquityCode":"credit_value","TotalValue":1,"SurplusValue":1},{"EquityCode":"credit_value","TotalValue":1,"SurplusValue":1}]"#), now: now))
        // Seats with assigned above total are hidden.
        let seats = try QwenCloudUsage.mapTeam(team(spec: "pro", equity: ok + #","SubscriptionAssignedNumber":6,"SubscriptionTotalNumber":5"#), now: now)
        XCTAssertEqual(seats.sections.first?.rows.map(\.label), ["Credits", "Remaining"])
        assertSignIn(try QwenCloudUsage.mapTeam(json(#"{"code":"NO_LOGIN"}"#)))
    }
}


/// Parity with CodexBar for Xiaomi MiMo, StepFun, Mistral, and Groq. Fixtures come from CodexBar's tests.
final class ProvidersAuditAPIsCTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }

    // MARK: MiMo

    func testMiMoBalanceSectionAndPastedCookieLabel() throws {
        XCTAssertEqual(try MiMoUsage.cookie("Cookie: api-platform_serviceToken=tok; userId=7; api-platform_ph=p; api-platform_slh=s; x=y"),
                       "api-platform_ph=p; api-platform_serviceToken=tok; api-platform_slh=s; userId=7")
        let usage = try MiMoUsage.map(
            balance: json(#"{"code":0,"message":"","data":{"balance":"50.00","currency":"USD","giftBalance":"20.00","cashBalance":"30.00"}}"#),
            detail: nil, usage: nil)
        XCTAssertEqual(usage.cost?.balance, 50)
        XCTAssertEqual(usage.sections.first?.title, "Credits")
        XCTAssertEqual(usage.sections.first?.rows.map(\.value), ["$30.00", "$20.00"])
        XCTAssertTrue(usage.windows.isEmpty)
        XCTAssertThrowsError(try MiMoUsage.map(balance: json(#"{"code":401,"message":"no"}"#), detail: nil, usage: nil)) {
            XCTAssertTrue(($0 as? ProviderError)?.needsSignIn ?? false)
        }
    }

    private func localCache(updated: String?, today: Double = 0, sessions: Int = 42) throws -> JSON {
        let updatedField = updated.map { #""updated_at":"\#($0)","# } ?? ""
        return try json("""
        {\(updatedField)"sessions_scanned":\(sessions),"windows":{
          "today":{"input":\(today),"output":0,"cache_read":0},
          "week":{"input":0,"output":0,"cache_read":0},
          "all_time":{"input":1000,"output":500,"cache_read":0}}}
        """)
    }

    func testMiMoLocalFallbackBuckets() throws {
        let cache = try json("""
        {"updated_at":"2026-06-03T05:04:03.123456+00:00","sessions_scanned":1296,"windows":{
          "today":{"input":1500,"output":500,"cache_read":0,"cache_create":250,"messages":3},
          "week":{"input":30000,"output":10000,"cache_read":60000,"cache_create":10000,"messages":25},
          "all_time":{"input":3600000,"output":1100000,"cache_read":16100000,"cache_create":2000000,"messages":1315}}}
        """)
        let usage = try XCTUnwrap(MiMoUsage.mapLocal(cache, now: XCTUnwrap(Fmt.iso("2026-06-03T06:00:00Z"))))
        let plan = try XCTUnwrap(usage.plan)
        XCTAssertTrue(plan.hasPrefix("Local \u{B7} 2.2k today"), plan)
        XCTAssertTrue(plan.contains("110.0k week"))
        XCTAssertTrue(plan.contains("22.8M total"))
        XCTAssertTrue(plan.hasSuffix("1296 sessions"))
        XCTAssertTrue(usage.windows.isEmpty, "local accounting is never a quota percentage")
        XCTAssertNil(usage.cost)
        XCTAssertEqual(usage.sections.first?.rows.map(\.value), ["2,250 tokens", "110,000 tokens", "22,800,000 tokens", "1,296"])
        XCTAssertEqual(usage.fetchedAt, Fmt.iso("2026-06-03T05:04:03.123Z"))
    }

    func testMiMoLocalFallbackStaleAndIdle() throws {
        let now = try XCTUnwrap(Fmt.iso("2026-07-07T10:00:00Z"))
        let base = "Local \u{B7} 1.5k total \u{B7} 42 sessions"
        for (stamp, expected) in [("2026-06-03T10:00:00.000000+00:00", base + " \u{B7} stale 34d"),
                                  ("2026-07-06T22:00:00.000000+00:00", base),
                                  ("2026-07-06T21:59:59.000000+00:00", base + " \u{B7} stale 12h"),
                                  ("2026-07-07T10:01:00.000000+00:00", base)] {
            XCTAssertEqual(MiMoUsage.mapLocal(try localCache(updated: stamp), now: now)?.plan, expected, stamp)
        }
        let modified = now.addingTimeInterval(-2 * 86400)
        for stamp in [nil, "not-a-timestamp"] {
            let usage = MiMoUsage.mapLocal(try localCache(updated: stamp), modified: modified, now: now)
            XCTAssertEqual(usage?.plan, base + " \u{B7} stale 2d")
            XCTAssertEqual(usage?.fetchedAt, modified)
        }
    }

    func testMiMoLocalFallbackRejectsOverflowAndBadFiles() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (input, expected) in [(Double(Int.max), 2), (Double.greatestFiniteMagnitude, 2), (12.9, 14)] {
            let usage = MiMoUsage.mapLocal(try json("""
            {"sessions_scanned":1,"windows":{"today":{"input":\(input),"output":2},"week":{"input":\(input),"output":2},"all_time":{"input":\(input),"output":2}}}
            """), modified: now, now: now)
            XCTAssertEqual(usage?.plan, "Local \u{B7} \(expected) today \u{B7} \(expected) week \u{B7} \(expected) total \u{B7} 1 sessions", "\(input)")
        }
        XCTAssertNil(MiMoUsage.mapLocal(try json("{}")))
        XCTAssertNil(MiMoUsage.local(path: "/nonexistent/path/that/should/never/exist.json"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mimo-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("bad.json")
        try Data("{not json".utf8).write(to: bad)
        XCTAssertNil(MiMoUsage.local(path: bad.path))
        let good = dir.appendingPathComponent("good.json")
        try Data(#"{"sessions_scanned":3,"windows":{"today":{"input":5},"week":{"input":5},"all_time":{"input":9}}}"#.utf8).write(to: good)
        XCTAssertTrue(MiMoUsage.local(path: good.path)?.plan?.contains("3 sessions") ?? false)
    }

    func testMiMoSpecHasLocalPathFieldAndOptionalCookie() {
        XCTAssertEqual(ProviderCatalog.mimo.fields.map(\.key), ["cookie", "localUsagePath"])
        XCTAssertTrue(ProviderCatalog.mimo.fields.allSatisfy(\.optional))
    }

    // MARK: StepFun

    func testStepFunCreditLabelsAndResets() throws {
        let monthly = try StepFunUsage.map(json(#"{"status":1,"plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.25,"subscription_credit_reset_time":"1790812800"}}"#))
        XCTAssertEqual(monthly.windows.map(\.title), ["Credit"])
        XCTAssertEqual(monthly.windows[0].usedPercent ?? -1, 75, accuracy: 1e-9)
        XCTAssertEqual(monthly.windows[0].windowMinutes, 43200)
        XCTAssertEqual(monthly.windows[0].resetsAt, Date(timeIntervalSince1970: 1_790_812_800))

        let topup = try StepFunUsage.map(json(#"{"status":1,"plan_family":2,"plan_credit_rate_limit":{"topup_credit_left_rate":0.6}}"#))
        XCTAssertEqual(topup.windows[0].usedPercent ?? -1, 40, accuracy: 1e-9)
        XCTAssertNil(topup.windows[0].windowMinutes)
        XCTAssertNil(topup.windows[0].resetsAt)

        let coding = try StepFunUsage.map(json(#"{"status":1,"five_hour_usage_left_rate":0.7,"five_hour_usage_reset_time":"1790812800","weekly_usage_left_rate":0.8,"weekly_usage_reset_time":"1790899200"}"#), plan: "Plus")
        XCTAssertEqual(coding.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(coding.windows.map(\.windowMinutes), [300, 10080])
        XCTAssertEqual(coding.windows.map { $0.usedPercent ?? -1 }[0], 30, accuracy: 1e-9)
        XCTAssertEqual(coding.windows.map { $0.usedPercent ?? -1 }[1], 20, accuracy: 1e-9)
        XCTAssertEqual(coding.plan, "Plus")
    }

    func testStepFunCreditBucketsWeightAndFallback() throws {
        let mixed = try StepFunUsage.map(json("""
        {"status":1,"plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.8,"topup_credit_left_rate":0.5,
         "credit_buckets":[{"credit_total":"100","credit_residual":"80"},{"credit_total":"300","credit_residual":"150"}]}}
        """))
        XCTAssertEqual(mixed.windows[0].usedPercent ?? -1, 42.5, accuracy: 1e-9)
        XCTAssertNil(mixed.windows[0].windowMinutes)
        let incomplete = try StepFunUsage.map(json("""
        {"status":1,"plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.6,"topup_credit_left_rate":0.4,
         "credit_buckets":[{"credit_total":"100"}]}}
        """))
        XCTAssertEqual(incomplete.windows[0].usedPercent ?? -1, 40, accuracy: 1e-9)
        // A live rolling window wins over a credit-family id.
        let live = try StepFunUsage.map(json(#"{"status":1,"plan_family":2,"five_hour_usage_left_rate":0.5,"five_hour_usage_reset_time":"1790812800","weekly_usage_left_rate":1,"weekly_usage_reset_time":"1790899200"}"#))
        XCTAssertEqual(live.windows.map(\.id), ["session", "weekly"])
    }

    func testStepFunErrorsTokenQuotesAndRefreshPair() throws {
        XCTAssertThrowsError(try StepFunUsage.map(json(#"{"status":0,"message":"auth failed: oasis-token is embezzled"}"#))) {
            XCTAssertTrue(($0 as? ProviderError)?.needsSignIn ?? false)
        }
        XCTAssertEqual(StepFunUsage.normalize("\"some-token\""), "some-token")
        XCTAssertEqual(StepFunUsage.normalize("'some-token'"), "some-token")
        XCTAssertEqual(StepFunUsage.normalize("a=b; Oasis-Token=abc...def; Oasis-Webid=x"), "abc...def")
        // The refresh reply has the same shape as a sign-in reply.
        XCTAssertEqual(try StepFunUsage.pair(json(#"{"accessToken":{"raw":"acc"},"refreshToken":{"raw":"ref"}}"#)), "acc...ref")
        XCTAssertEqual(try StepFunUsage.pair(json(#"{"accessToken":{"raw":"acc"}}"#)), "acc")
        XCTAssertThrowsError(try StepFunUsage.pair(json("{}")))
    }

    // MARK: Mistral

    private let november = #"""
    {"completion":{"models":{"mistral-large-latest::mistral-large-2411":{"input":[{"usage_type":"usage","event_type":"api_tokens","billing_metric":"mistral-large-2411","billing_display_name":"mistral-large-latest","billing_group":"input","timestamp":"2025-11-14","value":11121,"value_paid":11121}],"output":[{"usage_type":"usage","event_type":"api_tokens","billing_metric":"mistral-large-2411","billing_display_name":"mistral-large-latest","billing_group":"output","timestamp":"2025-11-14","value":1115,"value_paid":1115}]},"mistral-small-latest::mistral-small-2506":{"input":[{"usage_type":"usage","event_type":"api_tokens","billing_metric":"mistral-small-2506","billing_display_name":"mistral-small-latest","billing_group":"input","timestamp":"2025-11-14","value":20,"value_paid":20},{"usage_type":"usage","event_type":"api_tokens","billing_metric":"mistral-small-2506","billing_display_name":"mistral-small-latest","billing_group":"input","timestamp":"2025-11-24","value":100,"value_paid":100}],"output":[{"usage_type":"usage","event_type":"api_tokens","billing_metric":"mistral-small-2506","billing_display_name":"mistral-small-latest","billing_group":"output","timestamp":"2025-11-14","value":500,"value_paid":500},{"usage_type":"usage","event_type":"api_tokens","billing_metric":"mistral-small-2506","billing_display_name":"mistral-small-latest","billing_group":"output","timestamp":"2025-11-24","value":2482,"value_paid":2482}]}}},"ocr":{"models":{}},"connectors":{"models":{}},"libraries_api":{"pages":{"models":{}},"tokens":{"models":{}}},"fine_tuning":{"training":{},"storage":{}},"audio":{"models":{}},"vibe_usage":0.0,"date":"2025-11-01T00:00:00Z","previous_month":"2025-10","next_month":"2025-12","start_date":"2025-11-01T00:00:00Z","end_date":"2025-11-30T23:59:59.999Z","currency":"EUR","currency_symbol":"€","prices":[{"event_type":"api_tokens","billing_metric":"mistral-large-2411","billing_group":"input","price":"0.0000017000"},{"event_type":"api_tokens","billing_metric":"mistral-large-2411","billing_group":"output","price":"0.0000051000"},{"event_type":"api_tokens","billing_metric":"mistral-small-2506","billing_group":"input","price":"8.50E-8"},{"event_type":"api_tokens","billing_metric":"mistral-small-2506","billing_group":"output","price":"2.550E-7"}]}
    """#

    func testMistralMonthTotalsDailyAndModelBreakdown() throws {
        let usage = try MistralUsage.map(usage: json(november), credits: nil, subscriptionHTML: nil)
        let expected = 0.0189057 + 0.0056865 + 0.0000102 + 0.00076041
        XCTAssertEqual(usage.cost?.used ?? 0, expected, accuracy: 1e-4)
        XCTAssertEqual(usage.cost?.currency, "EUR")
        XCTAssertEqual(usage.cost?.period, "Month to date")
        let month = usage.sections[0]
        XCTAssertEqual(month.title, "This month")
        XCTAssertEqual(month.rows.map(\.label), ["Input tokens", "Output tokens", "Period"])
        XCTAssertEqual(month.rows.map(\.value), ["11,241", "4,097", "2025-11-01 to 2025-11-30"])
        // Models, ranked by tokens, use the billing display name.
        let models = try XCTUnwrap(usage.sections.first { $0.title == "Models" })
        XCTAssertEqual(models.rows.map(\.label), ["mistral-large-latest", "mistral-small-latest"])
        XCTAssertEqual(models.rows[0].value, "\u{20AC}0.0246 \u{B7} 12,236 tokens")
        XCTAssertEqual(models.rows[1].value, "\u{20AC}0.0008 \u{B7} 3,102 tokens")
        // Daily rows, newest day first.
        let daily = try XCTUnwrap(usage.sections.first { $0.title == "Daily" })
        XCTAssertEqual(daily.rows.map(\.label), ["2025-11-24", "2025-11-14"])
        XCTAssertEqual(daily.rows[1].value, "\u{20AC}0.0247 \u{B7} 12,756 tokens")
        XCTAssertEqual(daily.rows[0].value, "\u{20AC}0.0006 \u{B7} 2,582 tokens")
    }

    func testMistralPricesByZoneAndTierAndLegacy() throws {
        func entry(_ group: String, _ value: Int) -> String {
            #"{"usage_type":"vibe","event_type":"api_tokens","billing_metric":"mistral-medium-3-5","billing_display_name":"mistral-vibe-cli-latest","billing_group":"\#(group)","timestamp":"2026-09-16","value":\#(value),"value_paid":\#(value),"api_zone":"global","service_tier":"standard"}"#
        }
        func price(_ event: String, _ group: String, _ zone: String, _ tier: String, _ price: String) -> String {
            #"{"event_type":"\#(event)","billing_metric":"mistral-medium-3-5","billing_group":"\#(group)","api_zone":"\#(zone)","service_tier":"\#(tier)","price":"\#(price)"}"#
        }
        var prices = [price("api_tokens", "input", "global", "standard", "0.0000012750"),
                      price("api_tokens", "input", "eu", "priority", "0.0000023588"),
                      price("api_audio_seconds", "input", "global", "standard", "0.0001416667"),
                      price("api_tokens", "cached", "global", "standard", "1.275E-7"),
                      price("api_tokens", "cached", "eu", "priority", "2.359E-7"),
                      price("api_tokens", "output", "global", "standard", "0.0000063750"),
                      price("api_tokens", "output", "eu", "priority", "0.0000117938")]
        for reversed in [false, true] {
            if reversed { prices.reverse() }
            let body = try json("""
            {"vibe_code":{"completion":{"models":{"mistral-vibe-cli-latest::mistral-medium-3-5":{"input":[\(entry("input", 4_375_190))],"cached":[\(entry("cached", 21_628_160))],"output":[\(entry("output", 458_774))]}}}},
             "start_date":"2026-09-01T00:00:00Z","end_date":"2026-09-30T23:59:59Z","currency":"EUR","prices":[\(prices.joined(separator: ","))]}
            """)
            let usage = try MistralUsage.map(usage: body, credits: nil, subscriptionHTML: nil)
            let expected = 4_375_190 * 0.000001275 + 21_628_160 * 1.275e-7 + 458_774 * 0.000006375
            XCTAssertEqual(usage.cost?.used ?? 0, expected, accuracy: 1e-9)
            XCTAssertEqual(usage.sections[0].rows.map(\.value).prefix(3), ["4,375,190", "458,774", "21,628,160"])
            // The daily bucket carries the same cost as the month.
            XCTAssertEqual(usage.sections.first { $0.title == "Daily" }?.rows.count, 1)
        }
        // A legacy price row without zone or tier prices qualified usage; a mismatched zone or tier gets none.
        for (qualifier, cost) in [("", 10.0), (#","api_zone":"eu","service_tier":"standard""#, 0), (#","api_zone":"global","service_tier":"priority""#, 0)] {
            let body = try json("""
            {"completion":{"models":{"fixture":{"input":[{"event_type":"api_tokens","billing_metric":"fixture","billing_group":"input","timestamp":"2026-09-16","value":100,"value_paid":40,"api_zone":"global","service_tier":"standard"}]}}},
             "prices":[{"event_type":"api_tokens","billing_metric":"fixture","billing_group":"input","price":"0.25"\(qualifier)}]}
            """)
            let usage = try MistralUsage.map(usage: body, credits: nil, subscriptionHTML: nil)
            XCTAssertEqual(usage.cost?.used, cost, qualifier)
            XCTAssertEqual(usage.sections[0].rows.first?.value, "100")
        }
    }

    func testMistralDailyLibraryTokensRefundClampAndBadPrice() throws {
        let body = try json("""
        {"libraries_api":{"tokens":{"models":{"lib::x":{"input":[{"event_type":"e","billing_metric":"m","billing_group":"g","timestamp":"2026-07-04T00:00:00Z","value":7,"value_paid":7}]}}}},
         "completion":{"models":{"small":{"input":[{"event_type":"e","billing_metric":"t","billing_group":"input","timestamp":"2026-07-04","value":2}]}}},
         "currency":"USD","prices":[{"event_type":"e","billing_metric":"t","billing_group":"input","price":"Infinity"},{"event_type":"e","billing_metric":"m","billing_group":"g","price":"1"}]}
        """)
        let usage = try MistralUsage.map(usage: body, credits: nil, subscriptionHTML: nil)
        // Library tokens count in the daily bucket only; an infinite price is ignored.
        XCTAssertEqual(usage.sections[0].rows.map(\.value), ["2"])
        XCTAssertEqual(usage.sections.first { $0.title == "Daily" }?.rows.first?.value, "$7.00 \u{B7} 9 tokens")
        XCTAssertEqual(usage.cost?.used, 7)
        let refund = try MistralUsage.map(usage: json(#"{"completion":{"models":{"m":{"input":[{"event_type":"e","billing_metric":"m","billing_group":"g","value":-5,"value_paid":-5}]}}},"prices":[{"event_type":"e","billing_metric":"m","billing_group":"g","price":"1"}]}"#), credits: nil, subscriptionHTML: nil)
        XCTAssertEqual(refund.cost?.used, 0)
    }

    private func flightPush(_ chunk: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [1, chunk])
        return "<script>self.__next_f.push(\(String(decoding: data, as: UTF8.self)))</script>"
    }

    private let fullRecord = #"7:["$","$L1",null,{"budget":{"api_budget":{"usage_percentage":2.0,"initial_budget":25.5,"currency":"eur","reset_at":"2026-10-01T00:00:00.000Z","payg_enabled":false},"vibe_budget":{"usage_percentage":0.0,"initial_budget":255.0,"currency":"eur","reset_at":"2026-10-01T00:00:00.000Z","payg_enabled":false}}}]"# + "\n"

    func testMistralSubscriptionBudgetsShowRemainingAndSplitPushes() throws {
        let reset = Fmt.iso("2026-10-01T00:00:00.000Z")
        let split = fullRecord.index(fullRecord.startIndex, offsetBy: fullRecord.count / 2)
        for html in [try flightPush(fullRecord), try flightPush(String(fullRecord[..<split])) + flightPush(String(fullRecord[split...]))] {
            let usage = try MistralUsage.map(usage: json(november), credits: nil, subscriptionHTML: html)
            XCTAssertEqual(usage.windows.map(\.id), ["api", "vibe"])
            XCTAssertEqual(usage.windows.map(\.title), ["Included API", "Monthly Plan"])
            XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 2, accuracy: 1e-9)
            XCTAssertEqual(usage.windows[0].detail, "\u{20AC}0.51 / \u{20AC}25.50 \u{B7} \u{20AC}24.99 left")
            XCTAssertEqual(usage.windows[1].detail, "\u{20AC}0.00 / \u{20AC}255.00 \u{B7} \u{20AC}255.00 left")
            XCTAssertEqual(usage.windows.map(\.resetsAt), [reset, reset])
        }
        let apiOnly = #"7:["$",null,null,{"budget":{"api_budget":{"usage_percentage":1.1,"initial_budget":25.5,"currency":"eur","reset_at":"2026-10-01T00:00:00.000Z","payg_enabled":true}}}]"# + "\n"
        let usage = try MistralUsage.map(usage: json(november), credits: nil, subscriptionHTML: flightPush(apiOnly))
        XCTAssertEqual(usage.windows.map(\.id), ["api"])
    }

    func testMistralVibeConsoleFallbackAndPartialBudgets() throws {
        let vibe = try json(#"[{"result":{"data":{"json":{"usage_percentage":37,"quota_changed_this_month":false,"payg_enabled":false,"reset_at":"2026-07-01T00:00:00Z"}}}}]"#)
        let noPage = try MistralUsage.map(usage: json(november), credits: nil, subscriptionHTML: nil, vibeUsage: vibe)
        XCTAssertEqual(noPage.windows.map(\.id), ["vibe"])
        XCTAssertEqual(noPage.windows[0].title, "Monthly Plan")
        XCTAssertEqual(noPage.windows[0].usedPercent ?? -1, 37, accuracy: 1e-9)
        XCTAssertEqual(noPage.windows[0].resetsAt, Fmt.iso("2026-07-01T00:00:00Z"))
        XCTAssertNil(noPage.windows[0].detail)
        // The invalid vibe allowance is dropped without losing the API allowance; the console reply fills the plan.
        let partial = #"7:{"budget":{"api_budget":{"usage_percentage":20,"initial_budget":50,"currency":"EUR"},"vibe_budget":{"usage_percentage":"invalid","initial_budget":100,"currency":"EUR"}}}"# + "\n"
        let html = try flightPush(partial)
        XCTAssertNil(MistralUsage.budgets(html: html)["vibe_budget"])
        let both = try MistralUsage.map(usage: json(november), credits: nil, subscriptionHTML: html, vibeUsage: vibe)
        XCTAssertEqual(both.windows.map(\.id), ["api", "vibe"])
        XCTAssertEqual(both.windows.map { $0.usedPercent ?? -1 }, [20, 37])
        // A page allowance wins over the console reply.
        let page = try MistralUsage.map(usage: json(november), credits: nil, subscriptionHTML: flightPush(fullRecord), vibeUsage: vibe)
        XCTAssertEqual(page.windows[1].usedPercent ?? -1, 0, accuracy: 1e-9)
        for bad in [#"[{"result":{"data":{"json":{"usage_percentage":150}}}}]"#, "[]"] {
            let usage = try MistralUsage.map(usage: json(november), credits: nil, subscriptionHTML: nil, vibeUsage: json(bad))
            XCTAssertTrue(usage.windows.isEmpty)
        }
    }

    func testMistralCreditsBalance() throws {
        let credits = try json(#"{"wallet_amount":40,"credit_notes_amount":0,"ongoing_usage_balance":5,"currency":"EUR"}"#)
        let usage = try MistralUsage.map(usage: json(november), credits: credits, subscriptionHTML: nil)
        XCTAssertEqual(usage.cost?.balance, 35)
        let over = try MistralUsage.map(usage: json(november), credits: json(#"{"wallet_amount":1,"ongoing_usage_balance":5,"currency":"EUR"}"#), subscriptionHTML: nil)
        XCTAssertEqual(over.cost?.balance, 0)
        XCTAssertThrowsError(try MistralUsage.map(usage: json("{}"), credits: nil, subscriptionHTML: nil))
    }

    // MARK: Groq

    func testGroqConsoleAggregatesDailyModelsAndCachedInput() throws {
        let activity = try json("""
        {"object":"list","data":[
          {"organization_name":"Personal","model":"llama-3.1-8b-instant","timestamp":1783900800,"num_requests":3,"n_context_tokens_total":100,"n_non_cached_context_tokens_total":80,"n_generated_tokens_total":40,"cost":0.01},
          {"organization_name":"Personal","model":"openai/gpt-oss-120b","timestamp":1783901000,"num_requests":2,"n_context_tokens_total":50,"n_non_cached_context_tokens_total":50,"n_generated_tokens_total":10,"cost":0.02},
          {"organization_name":"Personal","model":"llama-3.1-8b-instant","timestamp":1783987200,"num_requests":1,"n_context_tokens_total":10,"n_non_cached_context_tokens_total":10,"n_generated_tokens_total":5,"cost":0.005}]}
        """)
        let usage = try GroqUsage.map(activity, now: Date(timeIntervalSince1970: 1_783_987_200))
        XCTAssertEqual(usage.plan, "Console")
        XCTAssertEqual(usage.organization, "Personal")
        XCTAssertEqual(usage.cost?.used ?? 0, 0.035, accuracy: 1e-9)
        XCTAssertEqual(usage.cost?.period, "Last 30 days")
        let sections = Dictionary(uniqueKeysWithValues: usage.sections.map { ($0.title ?? "", $0.rows) })
        XCTAssertEqual(sections["Today"]?.map(\.value), ["$0.00", "1", "15"])
        XCTAssertEqual(sections["Last 30 days"]?.map(\.label), ["Requests", "Tokens", "Cached input"])
        XCTAssertEqual(sections["Last 30 days"]?.map(\.value), ["6", "215", "20"])
        XCTAssertEqual(sections["Models"]?.map(\.label), ["llama-3.1-8b-instant", "openai/gpt-oss-120b"])
        XCTAssertEqual(sections["Models"]?.map(\.value), ["155 tokens \u{B7} 4 requests", "60 tokens \u{B7} 2 requests"])
        XCTAssertEqual(sections["Daily"]?.map(\.label), ["2026-07-14", "2026-07-13"])
        XCTAssertEqual(sections["Daily"]?.map(\.value), ["$0.00 \u{B7} 1 requests \u{B7} 15 tokens", "$0.03 \u{B7} 5 requests \u{B7} 200 tokens"])
    }

    func testGroqConsoleOmitsCachedRowWhenNoneAndSessionClaims() throws {
        let usage = try GroqUsage.map(json(#"{"data":[{"model":"a","timestamp":1783900800,"num_requests":1,"n_context_tokens_total":10,"n_generated_tokens_total":1,"cost":0}]}"#), now: Date(timeIntervalSince1970: 1_783_900_800))
        XCTAssertEqual(usage.sections.first { $0.title == "Last 30 days" }?.rows.map(\.label), ["Requests", "Tokens"])
        XCTAssertThrowsError(try GroqUsage.map(json("{}")))
        func jwt(_ claims: String) -> String {
            let payload = Data(claims.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "h.\(payload).s"
        }
        XCTAssertEqual(GroqUsage.organizationID(jwt: jwt(#"{"https://groq.com/organization":{"id":"org_abc123"}}"#)), "org_abc123")
        XCTAssertEqual(GroqUsage.organizationID(jwt: jwt(#"{"https://stytch.com/organization":{"slug":"org_slug9"}}"#)), "org_slug9")
        XCTAssertNil(GroqUsage.organizationID(jwt: "not-a-jwt"))
        XCTAssertNil(GroqUsage.organizationID(jwt: "only.two"))
    }

    func testGroqPrometheusScalarAndWindows() throws {
        XCTAssertEqual(try GroqUsage.scalar(json(#"{"status":"success","data":{"result":[{"value":[1710000000,"2.5"]},{"value":[1710000000,"1.5"]}]}}"#)), 4)
        for zero in [#"{"status":"success","data":{"result":[]}}"#, #"{"status":"success","data":{"result":[{"value":[1,0]}]}}"#, #"{"status":"success","data":{"result":[{"value":[1,"0"]}]}}"#] {
            XCTAssertEqual(try GroqUsage.scalar(json(zero)), 0)
        }
        for bad in [#"{"status":"success"}"#, #"{"status":"success","data":{"result":[{}]}}"#, #"{"status":"success","data":{"result":[{"value":[]}]}}"#,
                    #"{"status":"success","data":{"result":[{"value":["2.5"]}]}}"#, #"{"status":"success","data":{"result":[{"value":[1,"2.5",3]}]}}"#,
                    #"{"status":"success","data":{"result":[{"value":[1,"NaN"]}]}}"#, #"{"status":"success","data":{"result":[{"value":[1,"-1"]}]}}"#,
                    #"{"status":"success","data":{"result":[{"value":[1,"invalid"]}]}}"#, #"{"status":"success","data":{"result":[{"value":[1,true]}]}}"#,
                    #"{"status":"success","data":{"result":[{"value":[1,"1e308"]},{"value":[1,"1e308"]}]}}"#] {
            XCTAssertThrowsError(try GroqUsage.scalar(json(bad)), bad)
        }
        XCTAssertThrowsError(try GroqUsage.scalar(json(#"{"status":"error","error":"query unavailable","data":{"result":false}}"#))) {
            XCTAssertEqual(($0 as? ProviderError)?.errorDescription, "Groq metrics error: query unavailable")
        }

        let usage = try GroqUsage.mapMetrics(requests: 2, input: 100, output: 50, cache: 3, now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(usage.plan, "Prometheus metrics")
        XCTAssertEqual(usage.windows.map(\.title), ["Requests", "Tokens", "Cache hits"])
        XCTAssertEqual(usage.windows.map(\.detail), ["120 req/min", "9000 tok/min", "180 cache/min"])
        XCTAssertEqual(usage.windows.map(\.windowMinutes), [5, 5, 5])
        XCTAssertTrue(usage.windows.allSatisfy { $0.usedPercent == nil }, "a rate is not a quota")
        let noCache = try GroqUsage.mapMetrics(requests: 0.1, input: 0, output: 0, cache: 0)
        XCTAssertEqual(noCache.windows.map(\.detail), ["6.00 req/min", "0.00 tok/min"])
        for (rate, label) in [(0.0, "0.00 req/min"), (0.1, "6.00 req/min"), (0.25, "15.0 req/min"), (2.0, "120 req/min")] {
            XCTAssertEqual(try GroqUsage.mapMetrics(requests: rate, input: 0, output: 0, cache: 0).windows[0].detail, label)
        }
        XCTAssertThrowsError(try GroqUsage.mapMetrics(requests: 1e308, input: 0, output: 0, cache: 0))
        XCTAssertThrowsError(try GroqUsage.mapMetrics(requests: 0, input: 1.6e306, output: 1.6e306, cache: 0))
    }

    func testGroqSpecFieldsAndCookieLabel() {
        XCTAssertEqual(ProviderCatalog.groq.fields.map(\.key), ["cookie", "apiKey"])
        XCTAssertTrue(ProviderCatalog.groq.fields.allSatisfy(\.optional))
        XCTAssertEqual(ProviderCatalog.groq.fields[1].env, ["GROQ_API_KEY"])
        XCTAssertEqual(PastedCookie.clean("Cookie: stytch_session=abc; x=y"), "stytch_session=abc; x=y")
        XCTAssertEqual(Fmt.cookie("stytch_session", in: PastedCookie.clean("\"Cookie: stytch_session=abc\"")), "abc")
    }
}


/// Parity tests against CodexBar for Bedrock, Azure OpenAI, Command Code, Wayfinder and IBM Bob.
/// Fixtures are CodexBar's test JSON; keys and cookies are synthetic.
final class ProvidersAuditAPIsDTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }

    // MARK: Bedrock

    func testBedrockDailyCostActivityAndBudget() throws {
        let page = try json("""
        {"ResultsByTime":[
         {"TimePeriod":{"Start":"2026-04-01","End":"2026-04-02"},"Groups":[
          {"Keys":["Claude Opus (Bedrock Edition)"],"Metrics":{"UnblendedCost":{"Amount":"10.00","Unit":"USD"}}},
          {"Keys":["Amazon EC2"],"Metrics":{"UnblendedCost":{"Amount":"5.00","Unit":"USD"}}}]},
         {"TimePeriod":{"Start":"2026-04-02","End":"2026-04-03"},"Groups":[
          {"Keys":["Claude Sonnet (Bedrock Edition)"],"Metrics":{"UnblendedCost":{"Amount":"4.50","Unit":"USD"}}}]},
         {"TimePeriod":{"Start":"2026-04-03","End":"2026-04-04"},"Groups":[
          {"Keys":["Amazon Bedrock"],"Metrics":{"UnblendedCost":{"Amount":"0","Unit":"USD"}}}]}]}
        """)
        let activity = BedrockActivity(inputTokens: 1_500_000, outputTokens: 500_000, requests: 42)
        let result = try BedrockUsage.map([page], budget: 200, now: Date(timeIntervalSince1970: 1_775_000_000),
                                          activity: activity, daily: true)
        XCTAssertEqual(result.cost?.used, 14.5)
        XCTAssertEqual(result.cost?.limit, 200)
        XCTAssertEqual(result.windows.first?.usedPercent ?? 0, 7.25, accuracy: 1e-9)
        XCTAssertEqual(result.windows.first?.title, "Monthly budget")
        XCTAssertNotNil(result.windows.first?.resetsAt)
        let claude = try XCTUnwrap(result.sections.first { $0.title == "Claude activity (14d)" })
        XCTAssertEqual(claude.rows.map(\.value), ["2.0M", "1.5M", "500.0K", "42"])
        let daily = try XCTUnwrap(result.sections.first { $0.title == "Daily cost" })
        XCTAssertEqual(daily.rows.map(\.label), ["2026-04-02", "2026-04-01"])
        XCTAssertEqual(daily.rows.map(\.value), ["$4.50", "$10.00"])
        // The monthly shape keeps no per-day list and no activity without CloudWatch.
        let monthly = try BedrockUsage.map([page], budget: nil)
        XCTAssertNil(monthly.sections.first { $0.title == "Daily cost" })
        XCTAssertNil(monthly.sections.first { $0.title == "Claude activity (14d)" })
        XCTAssertNil(monthly.windows.first)
    }

    func testBedrockCloudWatchActivityTotals() throws {
        let first = try json("""
        {"NextToken":"page-2","MetricDataResults":[
         {"Id":"inputTokens","StatusCode":"Complete","Values":[1000,2500]},
         {"Id":"outputTokens","StatusCode":"Complete","Values":[400,600]},
         {"Id":"requests","StatusCode":"Complete","Values":[7,8]}]}
        """)
        let second = try json(#"{"MetricDataResults":[{"Id":"inputTokens","StatusCode":"Complete","Values":[3]}]}"#)
        XCTAssertEqual(try BedrockUsage.activity([first]), BedrockActivity(inputTokens: 3500, outputTokens: 1000, requests: 15))
        XCTAssertEqual(try BedrockUsage.activity([first, second]).inputTokens, 3503)
        XCTAssertEqual(try BedrockUsage.activity([]), BedrockActivity(inputTokens: 0, outputTokens: 0, requests: 0))
        XCTAssertThrowsError(try BedrockUsage.activity([json(#"{"Messages":[{"Code":"MaxQueryLimit","Value":"x"}]}"#)]))
        XCTAssertThrowsError(try BedrockUsage.activity([json(#"{"MetricDataResults":[{"Id":"requests","StatusCode":"PartialData","Values":[1]}]}"#)]))
        XCTAssertThrowsError(try BedrockUsage.activity([json(#"{"MetricDataResults":[{"Id":"other","StatusCode":"Complete","Values":[1]}]}"#)]))
        XCTAssertThrowsError(try BedrockUsage.activity([json(#"{"MetricDataResults":[{"Id":"requests","StatusCode":"Complete","Values":["x"]}]}"#)]))
        XCTAssertThrowsError(try BedrockUsage.activity([json(#"{"MetricDataResults":[{"Id":"requests","StatusCode":"Complete","Values":[-1]}]}"#)]))
        for literal in ["9.223372036854776e18", "1e40"] {
            let huge = try json(#"{"MetricDataResults":[{"Id":"inputTokens","StatusCode":"Complete","Values":[\#(literal)]}]}"#)
            XCTAssertThrowsError(try BedrockUsage.activity([huge]))
        }
        XCTAssertEqual(BedrockUsage.compact(999), "999")
        XCTAssertEqual(BedrockUsage.compact(2_500), "2.5K")
    }

    func testBedrockCloudWatchPartitionHosts() {
        let cases = [
            ("us-east-1", "monitoring.us-east-1.amazonaws.com"),
            ("us-gov-west-1", "monitoring.us-gov-west-1.amazonaws.com"),
            ("cn-north-1", "monitoring.cn-north-1.amazonaws.com.cn"),
            ("eusc-de-east-1", "monitoring.eusc-de-east-1.amazonaws.eu"),
            ("us-iso-east-1", "monitoring.us-iso-east-1.c2s.ic.gov"),
            ("us-isob-east-1", "monitoring.us-isob-east-1.sc2s.sgov.gov"),
            ("eu-isoe-west-1", "monitoring.eu-isoe-west-1.cloud.adc-e.uk"),
            ("us-isof-south-1", "monitoring.us-isof-south-1.csp.hci.ic.gov"),
        ]
        for (region, host) in cases { XCTAssertEqual(BedrockUsage.monitoringHost(region), host) }
        for bad in ["", "us-east", "evil.example/x", "US-EAST-1", "us-east-1.evil.com"] {
            XCTAssertNil(BedrockUsage.monitoringHost(bad), bad)
        }
    }

    func testBedrockSpecHasRegionField() {
        let region = ProviderCatalog.bedrock.fields.first { $0.key == "region" }
        XCTAssertEqual(region?.optional, true)
        XCTAssertEqual(region?.env, ["AWS_REGION", "AWS_DEFAULT_REGION"])
    }

    // MARK: Azure OpenAI

    func testAzureDeploymentNameAndModel() throws {
        let list = try json(#"{"data":[{"id":"gpt4o-prod","model":"gpt-4o","status":"succeeded"},{"id":"mini","model":"gpt-4o-mini"}]}"#)
        let found = try AzureOpenAIUsage.map(list, models: false, host: "res.openai.azure.com", deployment: "GPT4O-PROD")
        XCTAssertEqual(found.sections.first?.title, "Deployment")
        XCTAssertEqual(found.sections.first?.rows.first?.value, "Deployment: GPT4O-PROD · Model: gpt-4o")
        XCTAssertEqual(found.plan, "Deployment: GPT4O-PROD")
        XCTAssertEqual(found.organization, "res.openai.azure.com")
        XCTAssertEqual(found.sections[1].rows.first?.value, "2")

        let missing = try AzureOpenAIUsage.map(list, models: false, host: "res.openai.azure.com", deployment: "gone")
        XCTAssertEqual(missing.sections.first?.rows.first?.value, "Deployment: gone (not found)")

        // A model list cannot prove or disprove the deployment.
        let models = try json(#"{"data":[{"id":"gpt-4o"}]}"#)
        let fallback = try AzureOpenAIUsage.map(models, models: true, host: nil, deployment: "chat-prod")
        XCTAssertEqual(fallback.sections.first?.rows.first?.value, "Deployment: chat-prod")

        // Without a deployment the result keeps its old shape.
        let plain = try AzureOpenAIUsage.map(list, models: false, host: nil)
        XCTAssertNil(plain.plan)
        XCTAssertEqual(plain.sections.count, 1)
    }

    func testAzureSpecFieldsAndEndpoint() throws {
        let deployment = ProviderCatalog.azureopenai.fields.first { $0.key == "deployment" }
        XCTAssertEqual(deployment?.optional, true)
        XCTAssertEqual(deployment?.env, ["AZURE_OPENAI_DEPLOYMENT_NAME"])
        XCTAssertEqual(try AzureOpenAIUsage.endpoint("my-resource.openai.azure.com"), "https://my-resource.openai.azure.com")
        XCTAssertThrowsError(try AzureOpenAIUsage.endpoint("http://127.0.0.1:31337"))
    }

    // MARK: Command Code (CodexBar fixtures)

    private let creditsJSON = """
    {"credits":{"belowThreshold":false,"creditThreshold":0,"monthlyCredits":8.7784,\
    "purchasedCredits":0,"premiumMonthlyCredits":0,"opensourceMonthlyCredits":8.7784}}
    """
    private let goSubscription = """
    {"success":true,"data":{"id":"sub_1","status":"active","orgId":null,"quantity":1,"cancelAtPeriodEnd":false,\
    "currentPeriodStart":"2026-05-06T07:28:50.000Z","currentPeriodEnd":"2026-06-06T07:28:50.000Z",\
    "endedAt":null,"planId":"individual-go"}}
    """

    func testCommandCodeRootWindowLimitsFixture() throws {
        let credits = try json("""
        {"credits":{"monthlyCredits":8.5,"purchasedCredits":0,"premiumMonthlyCredits":0,"opensourceMonthlyCredits":0},
         "windowLimits":{"fiveHour":{"cap":3,"used":0.75,"resetAt":1780000000000},"weekly":{"cap":15,"used":1.5,"resetAt":1780100000000}}}
        """)
        let result = try CommandCodeUsage.map(credits: credits, subscription: nil)
        XCTAssertEqual(result.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(result.windows[0].usedPercent, 25)
        XCTAssertEqual(result.windows[0].windowMinutes, 300)
        XCTAssertEqual(result.windows[0].resetsAt, Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(result.windows[1].usedPercent, 10)
        XCTAssertEqual(result.windows[1].windowMinutes, 10_080)
        XCTAssertEqual(result.windows[1].resetsAt, Date(timeIntervalSince1970: 1_780_100_000))
    }

    func testCommandCodeNestedWindowLimitsFixtureWithStringNumbers() throws {
        let credits = try json("""
        {"credits":{"monthlyCredits":7.25,"purchasedCredits":2,"premiumMonthlyCredits":0,"opensourceMonthlyCredits":0,
         "windowLimits":{"fiveHour":{"cap":"4","used":"1","resetAt":"1780200000"},"weekly":{"cap":20,"used":4,"resetAt":1780300000000}}}}
        """)
        let result = try CommandCodeUsage.map(credits: credits, subscription: nil)
        XCTAssertEqual(result.windows[0].usedPercent, 25)
        XCTAssertEqual(result.windows[0].resetsAt, Date(timeIntervalSince1970: 1_780_200_000))
        XCTAssertEqual(result.windows[1].usedPercent, 20)
        XCTAssertEqual(result.windows[1].resetsAt, Date(timeIntervalSince1970: 1_780_300_000))
        XCTAssertEqual(result.cost?.balance, 2)
    }

    func testCommandCodeWindowWithoutUsedReadsZero() throws {
        let credits = try json(#"{"credits":{"monthlyCredits":1},"windowLimits":{"fiveHour":{"cap":10,"resetAt":0}}}"#)
        let result = try CommandCodeUsage.map(credits: credits, subscription: nil)
        XCTAssertEqual(result.windows.first?.usedPercent, 0)
        XCTAssertNil(result.windows.first?.resetsAt)
    }

    func testCommandCodeGoPlanMonthlyBarRowsAndStatus() throws {
        let result = try CommandCodeUsage.map(credits: json(creditsJSON), subscription: json(goSubscription))
        let monthly = try XCTUnwrap(result.windows.first { $0.id == "credits" })
        XCTAssertEqual(monthly.usedPercent ?? 0, 12.216, accuracy: 0.001)
        XCTAssertEqual(monthly.windowMinutes, 43_200)
        XCTAssertEqual(monthly.resetsAt, Fmt.iso("2026-06-06T07:28:50.000Z"))
        XCTAssertEqual(result.plan, "Go")
        XCTAssertEqual(result.cost?.limit, 10)
        XCTAssertEqual(result.cost?.used ?? 0, 1.2216, accuracy: 0.0001)
        let rows = try XCTUnwrap(result.sections.first?.rows)
        XCTAssertEqual(rows.first { $0.label == "Monthly credits left" }?.value, "$8.78")
        XCTAssertEqual(rows.first { $0.label == "Open-source monthly" }?.value, "$8.78")
        XCTAssertNil(rows.first { $0.label == "Premium monthly" })
        XCTAssertEqual(rows.first { $0.label == "Subscription" }?.value, "Active")
    }

    func testCommandCodeProV1PlanIsEightyDollars() throws {
        let sub = goSubscription.replacingOccurrences(of: "individual-go", with: "individual-pro-v1")
        let result = try CommandCodeUsage.map(credits: json(creditsJSON), subscription: json(sub))
        XCTAssertEqual(result.cost?.limit, 80)
        XCTAssertEqual(result.plan, "Pro")
        let plans = CommandCodeUsage.plans
        XCTAssertEqual(plans["individual-go"]?.usd, 10)
        XCTAssertEqual(plans["individual-goat"]?.usd, 70)
        XCTAssertEqual(plans["individual-pro"]?.usd, 30)
        XCTAssertEqual(plans["individual-max"]?.usd, 150)
        XCTAssertEqual(plans["individual-ultra"]?.usd, 300)
    }

    func testCommandCodeGrantedCreditsSizeTheBarOverThePlan() throws {
        let credits = try json(#"{"credits":{"monthlyCredits":9,"purchasedCredits":0,"monthlyCreditsGranted":12}}"#)
        let result = try CommandCodeUsage.map(credits: credits, subscription: json(goSubscription))
        XCTAssertEqual(result.windows.first { $0.id == "credits" }?.usedPercent ?? 0, 25, accuracy: 1e-9)
        for bad in ["0", "-5"] {
            let unusable = try json(#"{"credits":{"monthlyCredits":0,"purchasedCredits":5,"monthlyCreditsGranted":\#(bad)}}"#)
            let free = try CommandCodeUsage.map(credits: unusable, subscription: json(#"{"success":true,"data":null}"#))
            XCTAssertEqual(free.windows.first { $0.id == "credits" }?.usedPercent, 0, bad)
        }
    }

    func testCommandCodeFreeTierAndFailedLookups() throws {
        let free = #"{"success":true,"data":null}"#
        // Verified free tier with a spendable balance keeps an untouched monthly bar.
        let spendable = try CommandCodeUsage.map(credits: json(creditsJSON), subscription: json(free))
        XCTAssertEqual(spendable.windows.first { $0.id == "credits" }?.usedPercent, 0)
        XCTAssertNil(spendable.plan)
        // Free tier with nothing to spend has no monthly bar.
        let empty = try json(#"{"credits":{"monthlyCredits":0,"purchasedCredits":0}}"#)
        XCTAssertTrue(try CommandCodeUsage.map(credits: empty, subscription: json(free)).windows.isEmpty)
        // A failed lookup, a failure envelope, or no success flag must not borrow the free-tier reading.
        for subscription in [nil, try json(#"{"success":false,"error":"temporarily unavailable"}"#), try json(#"{"data":null}"#)] {
            let result = try CommandCodeUsage.map(credits: json(creditsJSON), subscription: subscription)
            XCTAssertNil(result.windows.first { $0.id == "credits" })
            XCTAssertEqual(result.sections.first?.rows.first?.value, "$8.78")
        }
        // An active plan this build cannot size shows its id and no invented 0% bar.
        let unknown = goSubscription.replacingOccurrences(of: "individual-go", with: "individual-future")
        let future = try CommandCodeUsage.map(credits: json(creditsJSON), subscription: json(unknown))
        XCTAssertEqual(future.plan, "individual-future")
        XCTAssertNil(future.windows.first { $0.id == "credits" })
        XCTAssertThrowsError(try CommandCodeUsage.map(credits: json(#"{"credits":{}}"#), subscription: nil))
    }

    func testCommandCodePlanMemorySizesBarAfterFailedLookup() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let periodEnd = Date(timeIntervalSince1970: 4_000_000_000)
        let memory = CommandCodePlanMemory()
        let fp = CommandCodePlanMemory.fingerprint("session=first")
        XCTAssertEqual(fp.count, 64)
        XCTAssertNotEqual(fp, CommandCodePlanMemory.fingerprint("session=second"))
        let active = try json(#"{"success":true,"data":{"status":"active","planId":"individual-go","currentPeriodEnd":"2096-10-02T07:06:40.000Z"}}"#)
        CommandCodeUsage.remember(active, fingerprint: fp, memory: memory, now: now)
        let entry = try XCTUnwrap(memory.entry(fp, now: now))
        XCTAssertEqual(entry.planID, "individual-go")
        XCTAssertEqual(entry.periodEnd, Fmt.iso("2096-10-02T07:06:40.000Z"))

        // $10 plan with $4 left reads 60 percent used, and the reset comes from the remembered period.
        let spent = try json(#"{"credits":{"monthlyCredits":4,"purchasedCredits":0}}"#)
        let repaired = try CommandCodeUsage.map(credits: spent, subscription: nil, remembered: entry, now: now)
        let monthly = try XCTUnwrap(repaired.windows.first { $0.id == "credits" })
        XCTAssertEqual(monthly.usedPercent ?? 0, 60, accuracy: 1e-9)
        XCTAssertEqual(monthly.resetsAt, entry.periodEnd)
        XCTAssertEqual(repaired.plan, "Go")
        // The remembered status is never repeated.
        XCTAssertNil(repaired.sections.first?.rows.first { $0.label == "Subscription" })

        // Other credentials, an ended period, and an old confirmation get nothing.
        XCTAssertNil(memory.entry(CommandCodePlanMemory.fingerprint("session=second"), now: now))
        XCTAssertNil(memory.entry(fp, now: periodEnd.addingTimeInterval(1)))
        XCTAssertNil(memory.entry(fp, now: now.addingTimeInterval(CommandCodePlanMemory.maxAge)))
        XCTAssertNotNil(memory.entry(fp, now: now.addingTimeInterval(CommandCodePlanMemory.maxAge - 1)))

        // A failed lookup keeps the memory; a verified free tier, an unsizable plan, or an undated plan forgets it.
        CommandCodeUsage.remember(nil, fingerprint: fp, memory: memory, now: now)
        CommandCodeUsage.remember(try json(#"{"success":false}"#), fingerprint: fp, memory: memory, now: now)
        XCTAssertNotNil(memory.entry(fp, now: now))
        CommandCodeUsage.remember(try json(#"{"success":true,"data":null}"#), fingerprint: fp, memory: memory, now: now)
        XCTAssertNil(memory.entry(fp, now: now))
        CommandCodeUsage.remember(active, fingerprint: fp, memory: memory, now: now)
        CommandCodeUsage.remember(try json(#"{"success":true,"data":{"status":"active","planId":"individual-unreleased","currentPeriodEnd":"2096-10-02T07:06:40.000Z"}}"#),
                                  fingerprint: fp, memory: memory, now: now)
        XCTAssertNil(memory.entry(fp, now: now))
        CommandCodeUsage.remember(active, fingerprint: fp, memory: memory, now: now)
        CommandCodeUsage.remember(try json(#"{"success":true,"data":{"status":"active","planId":"individual-go"}}"#),
                                  fingerprint: fp, memory: memory, now: now)
        XCTAssertNil(memory.entry(fp, now: now))
    }

    func testCommandCodePlanMemoryIsBounded() {
        let memory = CommandCodePlanMemory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let end = Date(timeIntervalSince1970: 4_000_000_000)
        for index in 0..<5 {
            memory.store(planID: "individual-go", periodEnd: end, fingerprint: "account-\(index)",
                         now: now.addingTimeInterval(Double(index)))
        }
        let latest = now.addingTimeInterval(5)
        XCTAssertNil(memory.entry("account-0", now: latest))
        for index in 1..<5 { XCTAssertNotNil(memory.entry("account-\(index)", now: latest)) }
    }

    func testCommandCodeCookieNames() throws {
        XCTAssertEqual(try CommandCodeUsage.sessionCookie("bare-value"), "__Secure-commandcode_prod_.session_token=bare-value")
        XCTAssertEqual(try CommandCodeUsage.sessionCookie("_ga=GA1.2.123; __Secure-better-auth.session_token=abc123; foo=bar"),
                       "__Secure-better-auth.session_token=abc123")
        XCTAssertEqual(try CommandCodeUsage.sessionCookie("_ga=1; __Secure-commandcode_prod_.session_token=abc123"),
                       "__Secure-commandcode_prod_.session_token=abc123")
        XCTAssertEqual(try CommandCodeUsage.sessionCookie("better-auth.session_token=plain-token"), "better-auth.session_token=plain-token")
        XCTAssertThrowsError(try CommandCodeUsage.sessionCookie("_ga=1; foo=bar"))
    }

    // MARK: Wayfinder

    func testWayfinderStatusModelsOrganizationAndMarkers() throws {
        let healthy = WayfinderUsage.map(
            health: try json(#"{"status":"ok","offline":false,"missing_keys":[]}"#),
            models: try json(#"{"models":[{"name":"local"}],"dry_run":false}"#),
            savings: nil, metrics: nil)
        XCTAssertEqual(healthy.plan, "Local gateway")
        XCTAssertEqual(healthy.organization, "1 model · local gateway")
        XCTAssertEqual(healthy.sections.first?.rows.map(\.label), ["Status", "Models", "Gateway"])
        XCTAssertEqual(healthy.sections.first?.rows.last?.value, "ok · 1 model")

        let offline = WayfinderUsage.map(
            health: try json(#"{"status":"ok","offline":true}"#),
            models: try json(#"{"models":[{"name":"a"},{"name":"b"}],"dry_run":true}"#),
            savings: nil, metrics: nil)
        XCTAssertEqual(offline.plan, "Offline mode")
        XCTAssertEqual(offline.organization, "2 models · local gateway")
        XCTAssertEqual(offline.sections.first?.rows.last?.value, "ok · 2 models · offline · dry run")

        let dry = WayfinderUsage.map(
            health: try json(#"{"status":"ok"}"#), models: try json(#"{"models":[],"dry_run":true}"#), savings: nil, metrics: nil)
        XCTAssertEqual(dry.plan, "Dry run")
    }

    func testWayfinderSavingsRoutesAndLatency() throws {
        let metrics = """
        # TYPE wayfinder_router_decision_latency_seconds histogram
        wayfinder_router_decision_latency_seconds_bucket{le="0.001"} 99
        wayfinder_router_decision_latency_seconds_sum 0.0123
        wayfinder_router_decision_latency_seconds_count 10
        """
        let priced = WayfinderUsage.map(
            health: try json(#"{"status":"ok"}"#),
            models: try json(#"{"models":[{"name":"m"}]}"#),
            savings: try json(#"{"priced":true,"requests":14,"saved":4.123,"saved_pct":38.25,"by_route":{"local":{"requests":10},"cloud":{"requests":4}}}"#),
            metrics: metrics)
        XCTAssertEqual(priced.sections[0].rows[2].label, "Avg decision")
        XCTAssertEqual(priced.sections[0].rows[2].value, "1.23 ms")
        let routes = try XCTUnwrap(priced.sections.first { $0.title == "Routes (30d)" })
        XCTAssertEqual(routes.rows.map(\.label), ["Saved (30d)", "local", "cloud"])
        XCTAssertEqual(routes.rows[0].value, "$4.12, 38.25% vs highest-cost route")
        XCTAssertEqual(routes.rows[1].value, "10")

        // Unpriced savings show a percentage only, never dollars; tiny priced savings read <$0.01.
        let unpriced = WayfinderUsage.map(
            health: try json(#"{"status":"ok"}"#), models: try json(#"{"models":[]}"#),
            savings: try json(#"{"priced":false,"requests":3,"saved":0.4,"saved_pct":20,"by_route":{}}"#), metrics: nil)
        XCTAssertEqual(unpriced.sections[1].rows.first?.value, "20% vs highest-cost route")
        let tiny = WayfinderUsage.map(
            health: try json(#"{"status":"ok"}"#), models: try json(#"{"models":[]}"#),
            savings: try json(#"{"priced":true,"requests":3,"saved":0.004,"saved_pct":1,"by_route":{}}"#), metrics: nil)
        XCTAssertEqual(tiny.sections[1].rows.first?.value, "<$0.01, 1% vs highest-cost route")
        // No routed traffic means no savings row.
        let idle = WayfinderUsage.map(
            health: try json(#"{"status":"ok"}"#), models: try json(#"{"models":[]}"#),
            savings: try json(#"{"priced":true,"requests":0,"saved":0,"saved_pct":0,"by_route":{}}"#), metrics: nil)
        XCTAssertEqual(idle.sections.count, 1)
    }

    func testWayfinderDashboardDefault() {
        XCTAssertEqual(ProviderCatalog.wayfinder.dashboard?.absoluteString, "http://127.0.0.1:8088/router")
    }

    // MARK: IBM Bob (CodexBar fixtures)

    private let twoInstanceProfile = """
    {"instances":[
     {"instance_id":"instance-one","name":"Personal","user_id":"user-one","plan_name":"Pro+","refresh_at":"2026-09-01T00:00:00Z",
      "region_domain":"us-east.bob.ibm.com","teams":[{"id":"team-one","name":"Solo","budget_limit":40}]},
     {"instance_id":"instance-two","name":"Work","user_id":"user-two","plan_name":"Enterprise","refresh_at":"2026-09-05T00:00:00.000Z",
      "region_domain":"api.eu-de.bob.ibm.com","teams":[{"id":"team-two","name":"Platform","budget_limit":160}]}]}
    """

    func testIBMBobAggregatesTeamsPlansAndReset() throws {
        let result = try IBMBobUsage.map(profile: json(twoInstanceProfile), teams: [
            "instance-one/team-one": try json(#"{"usage":10}"#),
            "instance-two/team-two": try json(#"{"usage":25}"#),
        ])
        let window = try XCTUnwrap(result.windows.first)
        XCTAssertEqual(window.usedPercent ?? 0, 17.5, accuracy: 1e-9)
        XCTAssertEqual(window.windowMinutes, 43_200)
        XCTAssertEqual(window.detail, "35 / 200 Bobcoins")
        XCTAssertEqual(window.resetsAt, Fmt.iso("2026-09-01T00:00:00Z"))
        XCTAssertEqual(result.plan, "Pro+, Enterprise")
        let rows = try XCTUnwrap(result.sections.first?.rows)
        XCTAssertEqual(rows.map(\.label), ["Personal - Solo", "Work - Platform"])
        XCTAssertEqual(rows[0].value, "10 / 40 Bobcoins · Pro+")
        XCTAssertEqual(rows[0].progress, 0.25)
        XCTAssertEqual(rows[1].value, "25 / 160 Bobcoins · Enterprise")
    }

    func testIBMBobLiveProfileUnlimitedTeamAndFallbackNames() throws {
        let live = try json("""
        {"instances":[{"instance_id":"instance-one","instance_name":"Personal","user_id":"user-one","plan_name":"Pro+","refresh_at":1788220800,
          "region_domain":"us-east.bob.ibm.com","teams":[{"id":"team-one","name":"Solo","budget_limit":40,"usage":10}]}]}
        """)
        let team = try json(#"{"usage":12.5,"budget_limit":80}"#)
        let result = try IBMBobUsage.map(profile: live, teams: ["instance-one/team-one": team])
        XCTAssertEqual(result.windows.first?.usedPercent ?? 0, 15.625, accuracy: 1e-9)
        XCTAssertEqual(result.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_788_220_800))
        XCTAssertEqual(result.sections.first?.rows.first?.value, "12.5 / 80 Bobcoins · Pro+")

        // A team without a budget is usage-only, and unnamed teams fall back to their ids.
        let bare = try json(#"{"instances":[{"instance_id":"instance-one","user_id":"u","teams":[{"id":"team-one"}]}]}"#)
        let unlimited = try IBMBobUsage.map(profile: bare, teams: ["instance-one/team-one": try json(#"{"usage":4}"#)])
        XCTAssertNil(unlimited.windows.first?.usedPercent)
        XCTAssertEqual(unlimited.windows.first?.detail, "4 Bobcoins used")
        XCTAssertEqual(unlimited.sections.first?.rows.first?.label, "instance-one - team-one")
        XCTAssertEqual(unlimited.sections.first?.rows.first?.value, "4 Bobcoins used")
        XCTAssertNil(unlimited.plan)
        XCTAssertThrowsError(try IBMBobUsage.map(profile: json(#"{"instances":[]}"#), teams: [:]))
    }

    func testIBMBobKeyAndRegionHandling() throws {
        XCTAssertEqual(try IBMBobUsage.clean("  \"bob-key\"  "), "bob-key")
        XCTAssertEqual(try IBMBobUsage.clean("'bob-key'"), "bob-key")
        XCTAssertThrowsError(try IBMBobUsage.clean("   "))
        XCTAssertTrue(IBMBobUsage.isJWT("header.eyJzdWIiOiJ1c2VyIn0.signature"))
        XCTAssertFalse(IBMBobUsage.isJWT("fixture-key"))
        XCTAssertEqual(try IBMBobUsage.host("api.eu-de.bob.ibm.com"), "api.eu-de.bob.ibm.com")
        XCTAssertEqual(try IBMBobUsage.host(nil), "api.us-east.bob.ibm.com")
        for bad in ["evil.example", "bob.ibm.com.evil.example", "x@evil.example", "evil.example/x.bob.ibm.com",
                    "evil.example?next=.bob.ibm.com", "evil.example#.bob.ibm.com", "us-east.bob.ibm.com:443"] {
            XCTAssertThrowsError(try IBMBobUsage.host(bad), bad)
        }
    }
}
