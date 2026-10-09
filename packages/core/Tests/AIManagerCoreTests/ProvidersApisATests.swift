import XCTest
@testable import AIManagerCore

final class ProvidersApisATests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }

    func testCatalogListsGroup() {
        XCTAssertEqual(ProviderCatalog.apisA.map(\.id.rawValue),
                       ["minimax", "alibaba", "alibabatokenplan", "qwencloud", "deepseek", "doubao", "mimo", "stepfun"])
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

    func testAlibabaTokenPlanTeamAndPersonal() throws {
        let team = try AlibabaTokenPlanUsage.mapTeam(json(
            #"{"Success":true,"Data":{"TotalCount":1,"TotalValue":1000,"TotalSurplusValue":875,"NearestExpireDate":1701000000000},"Code":"200"}"#))
        XCTAssertEqual(team.plan, "TOKEN PLAN")
        XCTAssertEqual(team.windows.first?.usedPercent ?? -1, 12.5, accuracy: 0.001)
        XCTAssertEqual(team.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_701_000_000))

        // The usage payload is a JSON string nested inside the envelope.
        let inner = #"{\"per5HourPercentage\":0.25,\"per5HourResetTime\":1787000400000,\"per1WeekPercentage\":0.70,\"per1WeekResetTime\":1787001180000}"#
        let personal = try AlibabaTokenPlanUsage.mapPersonal(
            usage: json(#"{"data":{"DataV2":{"data":"\#(inner)"}}}"#),
            subscription: json(#"{"data":{"specCode":"pro"}}"#),
            quotaConfig: json(#"{"data":{"pro":{"five_hour":1000,"weekly":4000}}}"#))
        XCTAssertEqual(personal.plan, "Pro")
        XCTAssertEqual(personal.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(personal.windows[0].usedPercent ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(personal.windows[1].usedPercent ?? -1, 70, accuracy: 0.001)
        XCTAssertEqual(personal.windows[0].detail, "250 / 1,000 credits")
    }

    func testQwenCloudIndividualAndTeam() throws {
        let individual = try QwenCloudUsage.mapIndividual(
            usage: json(#"{"data":{"per5HourPercentage":0.03,"per5HourResetTime":1700003600000,"per1WeekPercentage":0.01,"per1WeekResetTime":1700086400000}}"#),
            subscription: json(#"{"data":{"specCode":"standard","status":"VALID"}}"#),
            quotaConfig: json(#"{"data":{"standard":{"five_hour":5000,"weekly":50000}}}"#))
        XCTAssertEqual(individual.plan, "Standard")
        XCTAssertEqual(individual.windows[0].usedPercent ?? -1, 3, accuracy: 0.001)
        XCTAssertEqual(individual.windows[0].detail, "150 / 5,000 credits")
        XCTAssertEqual(individual.windows[1].usedPercent ?? -1, 1, accuracy: 0.001)

        let team = try QwenCloudUsage.mapTeam(json("""
        {"code":"200","successResponse":true,"data":{"Success":true,"Data":{"StartTime":1700000000000,"EndTime":1800000000000,
         "ProductCode":"sfm_tokenplanteams_dp_intl","SubscriptionGroupList":[{"SpecType":"standard","NextCycleFlushTime":1701000000000,
         "SubscriptionAssignedNumber":2,"SubscriptionTotalNumber":5,
         "EquityList":[{"EquityCode":"credit_value","TotalValue":"2000","SurplusValue":1500}]}]}}}
        """), now: Date(timeIntervalSince1970: 1_700_500_000))
        XCTAssertEqual(team.plan, "Standard Team")
        XCTAssertEqual(team.windows.first?.usedPercent ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(team.sections.first?.rows.first?.value, "2 / 5 assigned")
    }

    func testDeepSeekStringBalances() throws {
        let key = try DeepSeekUsage.map(json(
            #"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"50.00","granted_balance":"10.00","topped_up_balance":"40.00"}]}"#))
        XCTAssertEqual(key.cost?.balance, 50)
        XCTAssertEqual(key.cost?.currency, "USD")
        XCTAssertEqual(key.sections.first?.rows.map(\.label), ["Paid", "Granted"])

        let summary = try DeepSeekUsage.mapSummary(json(
            #"{"code":0,"data":{"biz_code":0,"biz_data":{"normal_wallets":[{"balance":"7.97","currency":"USD"}],"bonus_wallets":[{"balance":0.50,"currency":"USD"}]}}}"#))
        XCTAssertEqual(summary.cost?.balance ?? -1, 8.47, accuracy: 0.0001)
        XCTAssertThrowsError(try DeepSeekUsage.mapSummary(json(#"{"code":40003,"data":{}}"#)))
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

    func testMiMoBalanceAndTokenPlan() throws {
        XCTAssertThrowsError(try MiMoUsage.cookie("userId=1"))
        XCTAssertEqual(try MiMoUsage.cookie("a=b; userId=7; api-platform_serviceToken=tok; other=x"),
                       "api-platform_serviceToken=tok; userId=7")
        let usage = try MiMoUsage.map(
            balance: json(#"{"code":0,"message":"","data":{"balance":"50.00","currency":"USD","giftBalance":"20.00","cashBalance":"30.00"}}"#),
            detail: json(#"{"code":0,"data":{"planCode":"standard","currentPeriodEnd":"2026-05-04 23:59:59","expired":false}}"#),
            usage: json(#"{"code":0,"data":{"monthUsage":{"percent":0.0505,"items":[{"name":"month_total_token","used":10100158,"limit":200000000,"percent":0.0505}]}}}"#))
        XCTAssertEqual(usage.cost?.balance, 50)
        XCTAssertEqual(usage.plan, "Standard")
        XCTAssertEqual(usage.windows.first?.usedPercent ?? -1, 5.05, accuracy: 0.001)
        XCTAssertEqual(usage.windows.first?.windowMinutes, 43200)
        XCTAssertEqual(usage.windows.first?.resetsAt, Fmt.iso("2026-05-04 23:59:59"))
    }

    func testStepFunWindowsCreditsAndToken() throws {
        let windows = try StepFunUsage.map(json(
            #"{"status":1,"desc":"","five_hour_usage_left_rate":1,"five_hour_usage_reset_time":"1777528800","weekly_usage_left_rate":0.99781543,"weekly_usage_reset_time":"1777899600"}"#),
                                           plan: "Plus")
        XCTAssertEqual(windows.plan, "Plus")
        XCTAssertEqual(windows.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(windows.windows[0].usedPercent ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(windows.windows[1].usedPercent ?? -1, 0.218457, accuracy: 0.0001)
        XCTAssertEqual(windows.windows[0].resetsAt, Date(timeIntervalSince1970: 1_777_528_800))

        let credit = try StepFunUsage.map(json("""
        {"status":1,"five_hour_usage_left_rate":0,"five_hour_usage_reset_time":"0","weekly_usage_left_rate":0,"weekly_usage_reset_time":"0",
         "plan_family":2,"plan_credit_rate_limit":{"subscription_credit_left_rate":0.9641096,"subscription_credit_reset_time":"1786288293",
         "topup_credit_left_rate":0,"credit_buckets":[{"type":1,"credit_total":"400000000","credit_residual":"385643853"}]}}
        """))
        XCTAssertEqual(credit.windows.map(\.id), ["credits"])
        XCTAssertEqual(credit.windows[0].usedPercent ?? -1, 3.5890, accuracy: 0.001)

        XCTAssertEqual(StepFunUsage.normalize("a=b; Oasis-Token=abc...def; Oasis-Webid=x"), "abc...def")
        XCTAssertEqual(StepFunUsage.webID("h.eyJkZXZpY2VfaWQiOiJkZXYxMjMifQ.s...h.e30.s"), "dev123")
    }
}
