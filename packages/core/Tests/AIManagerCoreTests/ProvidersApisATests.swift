import XCTest
@testable import AIManagerCore

final class ProvidersApisATests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }

    func testCatalogListsGroup() {
        XCTAssertEqual(ProviderCatalog.apisA.map(\.id.rawValue),
                       ["minimax", "alibaba", "deepseek", "doubao", "mimo"])
    }

    func testMiniMaxTreatsUsageCountAsRemaining() throws {
        let body = try json("""
        {"model_remains":[
          {"start_time":1780279200000,"end_time":1780297200000,"remains_time":16659830,"current_interval_total_count":0,
           "current_interval_usage_count":0,"model_name":"general","current_weekly_total_count":0,"current_weekly_usage_count":0,
           "weekly_start_time":1780243200000,"weekly_end_time":1780848000000,"weekly_remains_time":567459830,
           "current_interval_status":1,"current_interval_remaining_percent":96,"current_weekly_status":1,
           "current_weekly_remaining_percent":99},
          {"model_name":"speech-hd","current_interval_total_count":100,"current_interval_usage_count":40,
           "start_time":1780279200000,"end_time":1780365600000}],
         "base_resp":{"status_code":0,"status_msg":"success"}}
        """)
        let usage = try MiniMaxUsage.map(body, now: Date(timeIntervalSince1970: 1_780_279_200))
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 4, accuracy: 0.001)
        XCTAssertEqual(usage.windows[0].windowMinutes, 300)
        XCTAssertEqual(usage.windows[1].usedPercent ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(usage.sections.first?.rows.first?.label, "speech-hd")
        XCTAssertEqual(usage.sections.first?.rows.first?.value, "60% used")
    }

    func testMiniMaxAuthErrorFromBaseResp() throws {
        XCTAssertThrowsError(try MiniMaxUsage.map(json(#"{"base_resp":{"status_code":1004,"status_msg":"login fail"}}"#))) {
            XCTAssertTrue(($0 as? ProviderError)?.needsSignIn == true)
        }
    }

    func testAlibabaCodingPlanQuota() throws {
        let body = try json("""
        {"data":{"codingPlanInstanceInfos":[{"planName":"Alibaba Coding Plan Pro"}],
         "codingPlanQuotaInfo":{"per5HourUsedQuota":52,"per5HourTotalQuota":1000,"per5HourQuotaNextRefreshTime":1700000300000,
         "perWeekUsedQuota":800,"perWeekTotalQuota":5000,"perWeekQuotaNextRefreshTime":1700100000000,
         "perBillMonthUsedQuota":1200,"perBillMonthTotalQuota":20000,"perBillMonthQuotaNextRefreshTime":1701000000000}},
         "status_code":0}
        """)
        let usage = try AlibabaUsage.map(body, now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(usage.plan, "Alibaba Coding Plan Pro")
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly", "monthly"])
        XCTAssertEqual(usage.windows[0].usedPercent ?? -1, 5.2, accuracy: 0.001)
        XCTAssertEqual(usage.windows[1].usedPercent ?? -1, 16, accuracy: 0.001)
        XCTAssertEqual(usage.windows[2].usedPercent ?? -1, 6, accuracy: 0.001)
        XCTAssertEqual(usage.windows[0].windowMinutes, 300)
    }

    func testDeepSeekStringBalances() throws {
        let key = try DeepSeekUsage.map(json(
            #"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"50.00","granted_balance":"10.00","topped_up_balance":"40.00"}]}"#))
        XCTAssertEqual(key.cost?.balance, 50)
        XCTAssertEqual(key.cost?.currency, "USD")
        XCTAssertEqual(key.sections.first?.rows.map(\.label), ["Paid", "Granted"])
    }

    func testDoubaoSigningVectorAndMapping() throws {
        let date = Date(timeIntervalSince1970: 1_781_654_400) // 2026-06-17T00:00:00Z
        let headers = DoubaoUsage.sign(accessKeyID: "AKLTTEST", secret: "SKTEST", region: "cn-beijing",
                                       query: [("Version", "2024-01-01"), ("Action", "GetCodingPlanUsage")], date: date)
        XCTAssertEqual(headers["X-Date"], "20260617T000000Z")
        XCTAssertEqual(headers["X-Content-Sha256"], "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(headers["Authorization"],
                       "HMAC-SHA256 Credential=AKLTTEST/20260617/cn-beijing/ark/request, "
                       + "SignedHeaders=content-type;host;x-content-sha256;x-date, "
                       + "Signature=e37e98715e94c75ebb7b6e161defd0b5ea028a63439bb9d6905566ae4c82af30")

        let usage = try DoubaoUsage.map(coding: json("""
        {"ResponseMetadata":{"Action":"GetCodingPlanUsage"},"Result":{"Status":"Running","UpdateTimestamp":1782226444,
         "QuotaUsage":[{"Level":"session","Percent":0.116,"ResetTimestamp":1782226478},
                       {"Level":"weekly","Percent":3.182143,"ResetTimestamp":1782662400},
                       {"Level":"monthly","Percent":7.5730535,"ResetTimestamp":1782403199}]}}
        """), agent: json(#"{"Result":{"PlanType":"medium","AFPFiveHour":{"Quota":10000,"Used":0,"ResetTime":-1},"AFPWeekly":{"Quota":35000,"Used":8750,"ResetTime":1785686400000}}}"#))
        XCTAssertEqual(usage.plan, "Running")
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly", "monthly", "agent-session", "agent-weekly"])
        XCTAssertEqual(usage.windows[1].usedPercent ?? -1, 3.182143, accuracy: 0.0001)
        XCTAssertEqual(usage.windows[1].resetsAt, Date(timeIntervalSince1970: 1_782_662_400))
        XCTAssertEqual(usage.windows[4].usedPercent ?? -1, 25, accuracy: 0.001)
        XCTAssertNil(usage.windows[3].resetsAt)
    }
}
