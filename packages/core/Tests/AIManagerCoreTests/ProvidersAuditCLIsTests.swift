import Foundation
import XCTest
@testable import AIManagerCore

/// Parity audit for Factory, Kiro, Kimi, Kilo, Augment, Amp, Codebuff, Pi, Vertex AI, Windsurf,
/// JetBrains AI and Warp. Each test asserts a value CodexBar shows that Switch used to drop.
final class ProvidersAuditCLIsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }
    private func rows(_ usage: ProviderUsage, _ title: String?) -> [String: String] {
        Dictionary(uniqueKeysWithValues: usage.sections.filter { $0.title == title }.flatMap(\.rows).map { ($0.label, $0.value) })
    }

    // MARK: Factory

    func testFactoryLegacyPoolsKeepTokensPeriodAndEmail() throws {
        let me = try json(#"{"userProfile":{"id":"u1","email":"dev@example.com"},"organization":{"name":"Acme","subscription":{"factoryTier":"team"}}}"#)
        let legacy = try json("""
        {"usage":{"startDate":1788000000000,"endDate":1790592000000,
         "standard":{"userTokens":50000000,"orgTotalTokensUsed":70000000,"totalAllowance":100000000,"usedRatio":0.5,"orgOverageUsed":5,"orgOverageLimit":10},
         "premium":{"userTokens":25,"totalAllowance":50,"usedRatio":0.5}}}
        """)
        let usage = try FactoryUsage.map(me: me, billing: nil, legacy: legacy, now: now)
        XCTAssertEqual(usage.windows.map(\.title), ["Standard", "Premium"])
        XCTAssertEqual(usage.windows[0].windowMinutes, 43_200)
        XCTAssertEqual(usage.windows[0].detail, "50,000,000 / 100,000,000 tokens")
        XCTAssertEqual(usage.windows[1].detail, "25 / 50 tokens")
        XCTAssertEqual(usage.email, "dev@example.com")
        XCTAssertEqual(rows(usage, "Standard tokens")["Org tokens used"], "70,000,000")
        XCTAssertEqual(rows(usage, "Standard tokens")["Org overage"], "5 / 10")
        XCTAssertEqual(rows(usage, "Billing period").keys.sorted(), ["Ends", "Starts"])
    }

    func testFactoryCoreWindowsAppearForAnEndedWindowWithoutPercent() throws {
        let me = try json(#"{"organization":{"name":"Acme"}}"#)
        let idle = #"{"fiveHour":{"usedPercent":0},"weekly":{"usedPercent":0},"monthly":{"usedPercent":0}}"#
        let ended = #"{"fiveHour":{"usedPercent":0,"windowEnd":"2020-01-01T00:00:00Z"},"weekly":{"usedPercent":0},"monthly":{"usedPercent":0}}"#
        let hidden = try FactoryUsage.map(me: me, billing: json(#"{"usesTokenRateLimitsBilling":true,"limits":{"standard":\#(idle),"core":\#(idle)}}"#), legacy: nil, now: now)
        XCTAssertEqual(hidden.windows.count, 3)
        let shown = try FactoryUsage.map(me: me, billing: json(#"{"usesTokenRateLimitsBilling":true,"limits":{"standard":\#(idle),"core":\#(ended)}}"#), legacy: nil, now: now)
        XCTAssertEqual(shown.windows.count, 6)
    }

    // MARK: Kiro

    func testKiroBonusCreditsLeavePlanShareAndShowRows() throws {
        let reply = try json("""
        {"nextDateReset":1.7882208E9,"overageConfiguration":{"overageStatus":"DISABLED"},
         "subscriptionInfo":{"subscriptionTitle":"KIRO PRO"},
         "usageBreakdownList":[{"resourceType":"CREDIT","currency":"USD","currentUsageWithPrecision":40,"usageLimitWithPrecision":50,
          "bonuses":[{"usageLimitWithPrecision":100,"currentUsageWithPrecision":25,"expiresAt":1.790E9,"status":"ACTIVE"}]}]}
        """)
        let usage = try KiroUsage.map(reply)
        XCTAssertEqual(usage.windows.map(\.id), ["monthly", "bonus"])
        XCTAssertEqual(usage.windows[0].usedPercent ?? 0, 30, accuracy: 1e-9)
        XCTAssertEqual(usage.windows[1].usedPercent ?? 0, 25, accuracy: 1e-9)
        XCTAssertEqual(usage.windows[1].resetsAt, Date(timeIntervalSince1970: 1_790_000_000))
        let usageRows = rows(usage, "Usage")
        XCTAssertEqual(usageRows["Credits left"], "35")
        XCTAssertEqual(usageRows["Credits used"], "15")
        XCTAssertEqual(usageRows["Credits total"], "50")
        XCTAssertTrue(usageRows["Bonus credits left"]?.hasPrefix("75 of 100") == true)
        XCTAssertEqual(usageRows["Overages"], "Disabled")
        XCTAssertEqual(usage.plan, "KIRO PRO")
    }

    func testKiroFreeTrialIsBonusAndOverageRows() throws {
        let trial = try json("""
        {"nextDateReset":1.7882208E9,"usageBreakdownList":[{"resourceType":"CREDIT","currentUsageWithPrecision":0,"usageLimitWithPrecision":50,
         "freeTrialInfo":{"freeTrialStatus":"ACTIVE","usageLimit":500,"currentUsage":100,"freeTrialExpiry":1.790E9}}]}
        """)
        XCTAssertEqual(try KiroUsage.map(trial).windows.last?.usedPercent ?? 0, 20, accuracy: 1e-9)
        let over = try json("""
        {"nextDateReset":1.7882208E9,"overageConfiguration":{"overageStatus":"ENABLED"},
         "usageBreakdownList":[{"resourceType":"CREDIT","currency":"USD","currentUsageWithPrecision":13603.49,"usageLimitWithPrecision":10000,
          "currentOveragesWithPrecision":3603.49,"overageCapWithPrecision":10000,"overageCharges":144.14,"overageRate":0.04}]}
        """)
        let usage = try KiroUsage.map(over)
        let usageRows = rows(usage, "Usage")
        XCTAssertEqual(usageRows["Overages"], "Enabled")
        XCTAssertEqual(usageRows["Overage usage"], "3,603.49 credits of 10,000")
        XCTAssertEqual(usageRows["Overage credits left"], "6,396.51")
        XCTAssertEqual(usageRows["Overage cost"], "$144.14")
        XCTAssertEqual(usage.cost?.currency, "USD")
    }

    // MARK: Kimi

    func testKimiMoreExhaustedCountsBeatRatioAndNegativeRatioDoesNot() throws {
        let same = try json("""
        {"usage":{"limit":"100","used":"40","resetTime":"2026-09-20T00:00:00Z"},
         "usages":{"limit_7d":{"used_ratio":0.1,"reset_time":"2026-09-20T00:00:01Z"},"limit_month_total":{"used_ratio":0.5}}}
        """)
        let merged = try KimiUsage.map(same)
        XCTAssertEqual(merged.windows[0].usedPercent ?? 0, 40, accuracy: 1e-9)
        XCTAssertEqual(merged.windows[0].detail, "40 / 100 requests")
        XCTAssertEqual(merged.windows[1].windowMinutes, 43_200)
        XCTAssertEqual(merged.windows[1].title, "Total usage")
        let other = try json(#"{"usage":{"limit":"100","used":"40","resetTime":"2026-09-21T00:00:00Z"},"usages":{"limit_7d":{"used_ratio":0.1,"reset_time":"2026-09-20T00:00:00Z"}}}"#)
        XCTAssertEqual(try KimiUsage.map(other).windows[0].usedPercent ?? 0, 10, accuracy: 1e-9)
        let negative = try json(#"{"usage":{"limit":"100","used":"25"},"usages":{"limit_7d":{"used_ratio":-0.5}}}"#)
        XCTAssertEqual(try KimiUsage.map(negative).windows[0].usedPercent ?? 0, 25, accuracy: 1e-9)
    }

    func testKimiRateLimitDescriptionAndUnreliableCounters() throws {
        let rate = try json(#"{"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"25","remaining":"75"}}]}"#)
        let usage = try KimiUsage.map(rate)
        XCTAssertEqual(usage.windows.map(\.id), ["session"])
        XCTAssertEqual(usage.windows[0].detail, "Rate: 25/100 per 5 hours")
        XCTAssertEqual(usage.windows[0].windowMinutes, 300)
        let broken = try KimiUsage.map(json(#"{"usage":{"limit":"100"}}"#))
        XCTAssertEqual(broken.windows[0].usedPercent, 0)
        XCTAssertNil(broken.windows[0].windowMinutes)
    }

    // MARK: Kilo

    func testKiloPassTopLevelTopUpMethodAndBalance() throws {
        let batch = try json("""
        [{"result":{"data":{"json":{"creditBlocks":[{"balance_mUsd":19000000,"amount_mUsd":19000000}],"totalBalance_mUsd":19000000}}}},
         {"result":{"data":{"json":{"tier":"tier_49","currentPeriodUsageUsd":5,"currentPeriodBaseCreditsUsd":49,"nextBillingAt":"2026-03-28T04:00:00.000Z"}}}},
         {"result":{"data":{"json":{"enabled":true,"paymentMethod":"Visa"}}}}]
        """)
        let usage = try KiloUsage.map(batch)
        XCTAssertEqual(usage.windows.map(\.id), ["credits", "pass"])
        XCTAssertEqual(usage.windows[1].usedPercent ?? 0, 5.0 / 49 * 100, accuracy: 1e-9)
        XCTAssertEqual(usage.plan, "Pro")
        XCTAssertEqual(usage.sections[0].rows[0].value, "Visa")
        XCTAssertEqual(usage.cost?.balance, 19)
    }

    func testKiloPlainCreditFieldsAndStatusTopUp() throws {
        let batch = try json("""
        [{"result":{"data":{"used":2,"total":10,"remaining":8}}},{"result":{"data":{"subscription":null}}},
         {"result":{"data":{"status":"disabled"}}}]
        """)
        let usage = try KiloUsage.map(batch)
        XCTAssertEqual(usage.windows[0].usedPercent ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(usage.cost?.balance, 8)
        XCTAssertEqual(usage.sections[0].rows[0].value, "Off")
        XCTAssertNil(usage.plan)
    }

    // MARK: Augment

    func testAugmentRemainingStatusAndCycleRows() throws {
        let credits = try json(#"{"usageUnitsRemaining":15,"usageUnitsConsumedThisBillingCycle":10,"usageUnitsAvailable":100,"usageBalanceStatus":"active"}"#)
        let subscription = try json(#"{"planName":"Max Plan","billingPeriodEnd":"2026-06-09T00:00:00Z"}"#)
        let usage = try AugmentUsage.map(credits: credits, subscription: subscription)
        let all = rows(usage, nil)
        XCTAssertEqual(all["Credits remaining"], "15")
        XCTAssertEqual(all["Balance status"], "Active")
        XCTAssertNotNil(all["Billing cycle ends"])
    }

    // MARK: Amp

    func testAmpMonthlyAllowancesAndOrbPeriod() throws {
        let text = """
        Signed in as fixture@example.test (example)
        Amp Standard Tier: agent usage $18.57 of $20 remaining (93%), orb usage 732.8h of 750h a1.small orb hours remaining (98%) - period 2026-09-13 to 2026-10-13, resets upon renewal in 27 days
        Individual credits: $17.23 remaining
        """
        let usage = try AmpUsage.map(displayText: text, now: now)
        XCTAssertEqual(rows(usage, "Monthly allowances")["Agent"], "$18.57")
        XCTAssertEqual(rows(usage, "Monthly allowances")["Orb"], "732h a1.small-equivalent")
        XCTAssertEqual(usage.windows[1].windowMinutes, 43_200)
        XCTAssertEqual(usage.cost?.balance, 17.23)
        let small = try AmpUsage.map(displayText: "Amp Standard Tier: agent usage $1 of $20 remaining, orb usage 0.5h of 750h a1.small orb hours remaining - period 2026-09-13 to 2026-10-13, resets upon renewal in 27 days", now: now)
        XCTAssertEqual(rows(small, "Monthly allowances")["Orb"], "< 1h a1.small-equivalent")
    }

    func testAmpLegacySubscriptionGetsCalendarMonthWindow() throws {
        let legacy = try AmpUsage.map(displayText: "Subscription Gigawatt: 73% other usage and 91% orb usage remaining - resets upon renewal in 1 month", now: now)
        let minutes = try XCTUnwrap(legacy.windows[0].windowMinutes)
        XCTAssertTrue((28 * 1440...31 * 1440).contains(minutes))
        XCTAssertEqual(legacy.windows[1].windowMinutes, minutes)
    }

    // MARK: Codebuff

    func testCodebuffBalanceStatusAndBillingRows() throws {
        let usage = try json(#"{"usage":1250,"quota":5000,"remainingBalance":3750,"autoTopupEnabled":false}"#)
        let subscription = try json(#"{"hasSubscription":true,"subscription":{"status":"active","tier":"pro","billingPeriodEnd":"2026-05-15T00:00:00Z"}}"#)
        let mapped = try CodebuffUsage.map(usage: usage, subscription: subscription)
        let all = rows(mapped, nil)
        XCTAssertEqual(all["Auto top-up"], "Off")
        XCTAssertEqual(all["Credits remaining"], "3,750")
        XCTAssertEqual(all["Subscription"], "Active")
        XCTAssertNotNil(all["Billing period ends"])
    }

    // MARK: Pi

    func testPiSessionRootsCoverOMPDefaultAndProfile() {
        let home = URL(fileURLWithPath: "/tmp/pi-home")
        let paths = PiUsage.sessionDirectories(environment: [:], home: home).map(\.path)
        XCTAssertEqual(paths, ["/tmp/pi-home/.pi/agent/sessions", "/tmp/pi-home/.omp/agent/sessions", "/tmp/pi-home/.local/share/omp/sessions"])
        let profile = PiUsage.sessionDirectories(environment: ["OMP_PROFILE": "work", "XDG_DATA_HOME": "/tmp/xdg"], home: home).map(\.path)
        XCTAssertTrue(profile.contains("/tmp/pi-home/.omp/profiles/work/sessions"))
        XCTAssertTrue(profile.contains("/tmp/pi-home/.omp/profiles/work/agent/sessions"))
        XCTAssertTrue(profile.contains("/tmp/xdg/omp/profiles/work/sessions"))
        XCTAssertFalse(profile.contains("/tmp/pi-home/.omp/agent/sessions"))
        let bad = PiUsage.sessionDirectories(environment: ["OMP_PROFILE": "../x"], home: home).map(\.path)
        XCTAssertTrue(bad.contains("/tmp/pi-home/.omp/agent/sessions"))
    }

    func testPiScanReadsEveryRootAndSplitsByModel() throws {
        let base = URL(fileURLWithPath: "/tmp/pi-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let stamp = ISO8601DateFormatter().string(from: Date())
        func write(_ root: String, _ id: String, _ model: String) throws {
            let dir = base.appending(path: root)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let line = #"{"type":"message","id":"\#(id)","timestamp":"\#(stamp)","message":{"role":"assistant","model":"\#(model)","usage":{"input":1,"output":1,"totalTokens":2,"cost":{"total":0.25}}}}"#
            try Data(line.utf8).write(to: dir.appending(path: "s.jsonl"))
        }
        try write("a", "m1", "claude-x")
        try write("b", "m2", "gpt-y")
        let usage = try PiUsage.scan(now: Date(), directories: [base.appending(path: "a"), base.appending(path: "b"), base.appending(path: "none")])
        XCTAssertEqual(usage.sections[1].rows.first { $0.label == "Messages" }?.value, "2")
        XCTAssertNotNil(usage.sections[1].rows.first { $0.label == "Model claude-x" })
        XCTAssertEqual(usage.sections[1].rows.first { $0.label == "Model gpt-y" }?.value, "2 tokens · 1 message · $0.25")
    }

    // MARK: Vertex AI

    func testVertexProjectFromActiveGcloudConfigAndPeakQuotaRow() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "gcloud-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appending(path: "configurations"), withIntermediateDirectories: true)
        try "work\n".write(to: dir.appending(path: "active_config"), atomically: true, encoding: .utf8)
        try "[compute]\nproject = wrong\n[core]\naccount = a@b.c\nproject = my-proj\n".write(
            to: dir.appending(path: "configurations/config_work"), atomically: true, encoding: .utf8)
        XCTAssertEqual(VertexAIUsage.configProject(env: ["CLOUDSDK_CONFIG": dir.path], home: dir), "my-proj")
        XCTAssertNil(VertexAIUsage.configProject(env: ["CLOUDSDK_CONFIG": dir.path, "CLOUDSDK_ACTIVE_CONFIG_NAME": "missing"], home: dir))

        let usage = [try json(#"{"metric":{"labels":{"quota_metric":"aiplatform.googleapis.com/online_prediction_requests","limit_name":"L"}},"resource":{"labels":{"location":"us-central1"}},"points":[{"value":{"int64Value":"60"}}]}"#)]
        let limit = [try json(#"{"metric":{"labels":{"quota_metric":"aiplatform.googleapis.com/online_prediction_requests","limit_name":"L"}},"resource":{"labels":{"location":"us-central1"}},"points":[{"value":{"int64Value":"100"}}]}"#)]
        let mapped = VertexAIUsage.map(usage: usage, limit: limit, project: "p", email: "e@x.com")
        XCTAssertEqual(rows(mapped, nil)["Peak quota"], "online_prediction_requests (us-central1)")
        XCTAssertEqual(mapped.plan, "gcloud")
    }

    // MARK: Windsurf

    func testWindsurfLocalCacheQuotaPercentsPlanAndFlexCredits() throws {
        let plan = try json("""
        {"planName":"Pro","endTimestamp":1774029950000,
         "quotaUsage":{"dailyRemainingPercent":80,"weeklyRemainingPercent":50,"dailyResetAtUnix":1774080000,"weeklyResetAtUnix":1774166400},
         "usage":{"flexCredits":500,"usedFlexCredits":120,"remainingFlexCredits":380}}
        """)
        let usage = try WindsurfLocal.map(plan)
        XCTAssertEqual(usage.windows.map(\.id), ["daily", "weekly"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [20, 50])
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1_774_080_000))
        XCTAssertEqual(usage.windows[1].windowMinutes, 10_080)
        XCTAssertEqual(usage.plan, "Pro")
        XCTAssertEqual(rows(usage, nil)["Flex credits"], "380 of 500 left")
        XCTAssertNotNil(rows(usage, nil)["Plan ends"])
    }

    func testWindsurfLocalCacheFallsBackToMessageAndFlowCounters() throws {
        let plan = try json(#"{"planName":"Free","usage":{"messages":100,"usedMessages":30,"flowActions":200,"remainingFlowActions":150}}"#)
        let usage = try WindsurfLocal.map(plan)
        XCTAssertEqual(usage.windows.map(\.title), ["Messages", "Flow actions"])
        XCTAssertEqual(usage.windows[0].usedPercent, 30)
        XCTAssertEqual(usage.windows[0].detail, "30 / 100 messages")
        XCTAssertEqual(usage.windows[1].usedPercent, 25)
        XCTAssertThrowsError(try WindsurfLocal.map(json("{}")))
    }

    func testWindsurfSessionIsOptionalAndMissingDatabaseIsReported() {
        XCTAssertTrue(ProviderCatalog.windsurf.fields.allSatisfy(\.optional))
        XCTAssertThrowsError(try WindsurfLocal.read(database: URL(fileURLWithPath: "/tmp/no-windsurf-\(UUID().uuidString).vscdb"))) {
            XCTAssertTrue(($0 as? ProviderError)?.needsSignIn == true)
        }
    }

    // MARK: JetBrains AI

    private let quotaLine = "2026-10-05 15:27:49,811 [   8326]   INFO - #c.i.m.l.c.q.QuotaManager2Impl - New quota state is: "
        + "Available(current=346495.294, maximum=6489986.397, until=2028-09-22T21:00:00Z, "
        + "tariffQuota=QuotaDetails(current=346495.294, maximum=1000000, available=653504.706), "
        + "topUpQuota=QuotaDetails(current=0, maximum=5489986.397, available=5489986.397))"
    private let refillLine = "2026-10-05 15:21:27,386 [2707002]   INFO - #c.i.m.l.c.q.QuotaManager2Impl - New quota refill state is: "
        + "Known(next=2026-10-11T17:00:30.231Z, tariff=QuotaRefillInfoTariff(amount=1000000, duration=30d))"

    func testJetBrainsLogQuotaAndRefillMapToMonthlyCredits() throws {
        let entry = try XCTUnwrap(JetBrainsUsage.latestEntry(inLog: refillLine + "\n" + quotaLine + "\n"))
        let usage = try JetBrainsUsage.map(quota: entry.quota, refill: entry.refill, ide: "IntelliJIdea2026.1")
        XCTAssertEqual(usage.windows[0].usedPercent ?? 0, 34.6495294, accuracy: 1e-6)
        XCTAssertEqual(usage.windows[0].windowMinutes, 43_200)
        XCTAssertEqual(usage.windows[0].resetsAt, Fmt.iso("2026-10-11T17:00:30.231Z"))
        XCTAssertEqual(usage.windows[0].detail, "3.46 / 10 credits")
        XCTAssertEqual(usage.sections[0].rows[0].value, "54.9")
        XCTAssertEqual(rows(usage, "Monthly credits")["Monthly credits left"], "6.54")
        XCTAssertEqual(rows(usage, "Monthly credits")["Monthly refill"], "10 credits")
        XCTAssertNotNil(rows(usage, "Monthly credits")["Subscription ends"])
        // A newer quota line that cannot be read must not fall back to an older account's quota.
        let broken = quotaLine.replacingOccurrences(of: "maximum=1000000", with: "maximum=1e999")
        XCTAssertNil(JetBrainsUsage.latestEntry(inLog: quotaLine + "\n" + broken + "\n"))
    }

    func testJetBrainsNewerLogBeatsStaleXMLButOlderLogDoesNot() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "jb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let options = home.appending(path: "Library/Application Support/JetBrains/IntelliJIdea2026.1/options")
        let logs = home.appending(path: "Library/Logs/JetBrains/IntelliJIdea2026.1")
        try FileManager.default.createDirectory(at: options, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let xmlFile = options.appending(path: "AIAssistantQuotaManager2.xml")
        try """
        <application><component name="AIAssistantQuotaManager2">
        <option name="quotaInfo" value="{&quot;type&quot;:&quot;Available&quot;,&quot;tariffQuota&quot;:{&quot;current&quot;:&quot;250000&quot;,&quot;maximum&quot;:&quot;1000000&quot;,&quot;available&quot;:&quot;750000&quot;}}" />
        </component></application>
        """.write(to: xmlFile, atomically: true, encoding: .utf8)
        try (refillLine + "\n" + quotaLine + "\n").write(to: logs.appending(path: "idea.log"), atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: xmlFile.path)
        XCTAssertEqual(try JetBrainsUsage.read(home: home).windows[0].usedPercent ?? 0, 34.6495294, accuracy: 1e-6)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_900_000_000)], ofItemAtPath: xmlFile.path)
        XCTAssertEqual(try JetBrainsUsage.read(home: home).windows[0].usedPercent ?? 0, 25, accuracy: 1e-9)

        // No quota XML at all: the log still names the quota.
        try FileManager.default.removeItem(at: xmlFile)
        let logOnly = try JetBrainsUsage.read(home: home)
        XCTAssertEqual(logOnly.organization, "IntelliJIdea2026.1")
        XCTAssertEqual(logOnly.windows[0].usedPercent ?? 0, 34.6495294, accuracy: 1e-6)
    }

    // MARK: Warp

    func testWarpUnlimitedShowsNoResetAndAddOnKeepsExpiry() throws {
        let unlimited = try json(#"{"data":{"user":{"__typename":"UserOutput","user":{"requestLimitInfo":{"isUnlimited":true,"nextRefreshTime":"2026-02-28T19:16:33Z","requestLimit":0,"requestsUsedSinceLastRefresh":9}}}}}"#)
        let usage = try WarpUsage.map(unlimited)
        XCTAssertEqual(usage.windows[0].detail, "Unlimited")
        XCTAssertEqual(usage.windows[0].usedPercent, 0)
        XCTAssertNil(usage.windows[0].resetsAt)
        let capped = try json(#"{"data":{"user":{"__typename":"UserOutput","user":{"requestLimitInfo":{"isUnlimited":false,"requestLimit":1500,"requestsUsedSinceLastRefresh":300},"bonusGrants":[{"requestCreditsGranted":100,"requestCreditsRemaining":0}]}}}}"#)
        let exhausted = try WarpUsage.map(capped)
        XCTAssertEqual(exhausted.windows[0].detail, "300 / 1,500 credits")
        XCTAssertEqual(exhausted.windows[1].usedPercent, 100)
    }
}
