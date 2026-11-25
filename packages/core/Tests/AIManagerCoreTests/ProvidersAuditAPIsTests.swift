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


/// Fixtures follow CodexBar's Alibaba Coding Plan tests.
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

    func testCodingPlanStatusCodeErrors() throws {
        assertSignIn(try AlibabaUsage.map(json(#"{"statusCode":403,"message":"Forbidden"}"#)))
        assertSignIn(try AlibabaUsage.map(json(#"{"status_code":500,"message":"Invalid API key"}"#)))
        XCTAssertThrowsError(try AlibabaUsage.map(json(#"{"statusCode":500,"message":"boom"}"#))) {
            XCTAssertEqual($0 as? ProviderError, .http(500, "Alibaba returned an error: boom"))
        }
        XCTAssertTrue(AlibabaUsage.retryOnChina(ProviderError.http(404, "")))
        XCTAssertFalse(AlibabaUsage.retryOnChina(ProviderError.network("down")))
    }
}


/// Parity with CodexBar for Xiaomi MiMo and Groq. Fixtures come from CodexBar's tests.
final class ProvidersAuditAPIsCTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }

    // MARK: MiMo

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

    // MARK: Groq

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
}


/// Parity tests against CodexBar for Bedrock, Azure OpenAI, Wayfinder and IBM Bob.
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
        let result = try BedrockUsage.map([page], budget: 200, now: Date(timeIntervalSince1970: 1_775_345_600),
                                          activity: activity, daily: true)
        XCTAssertEqual(result.cost?.used, 14.5)
        XCTAssertEqual(result.cost?.limit, 200)
        XCTAssertEqual(result.windows.first?.usedPercent ?? 0, 7.25, accuracy: 1e-9)
        XCTAssertEqual(result.windows.first?.title, "Monthly budget")
        XCTAssertNotNil(result.windows.first?.resetsAt)
        let claude = try XCTUnwrap(result.sections.first { $0.title == "Claude activity (14d)" })
        XCTAssertEqual(claude.rows.map(\.value), ["2.0M", "1.5M", "500.0K", "42"])
        XCTAssertNil(result.sections.first { $0.title == "Daily cost" })
        // Month to date (Apr 1 to Apr 4), zero-filled.
        let daily = try XCTUnwrap(result.charts.first)
        XCTAssertEqual(daily.unit, "USD")
        XCTAssertEqual(daily.points.map(\.label), ["Apr 1", "Apr 2", "Apr 3", "Apr 4"])
        XCTAssertEqual(daily.points.map(\.value), [10, 4.5, 0, 0])
        // The monthly shape keeps no per-day chart and no activity without CloudWatch.
        let monthly = try BedrockUsage.map([page], budget: nil)
        XCTAssertTrue(monthly.charts.isEmpty)
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
