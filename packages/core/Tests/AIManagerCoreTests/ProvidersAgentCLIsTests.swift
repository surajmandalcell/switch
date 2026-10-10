import Foundation
import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import AIManagerCore

final class ProvidersAgentCLIsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }
    private func iso(_ text: String) -> Date { Fmt.iso(text)! }
    private func credential(_ spec: ProviderSpec, _ text: String, at index: Int = 0) -> ProviderCredential {
        ProviderCredential(files: [spec.files[index].id: Data(text.utf8)])
    }

    func testCatalogIdsAreUniqueAndGrokKeepsEngineId() {
        let ids = ProviderCatalog.agentCLIs.map(\.id.rawValue)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.contains("grok-build"))
        XCTAssertEqual(ProviderCatalog.agentGrok.files, [LiveFile(".grok/auth.json", homeEnv: "GROK_HOME")])
        XCTAssertNil(ProviderCatalog.agentGrok.login)
    }

    // MARK: Grok

    func testGrokWeeklyPoolPayAsYouGoAndTeam() throws {
        let billing = try json("""
        {"config":{"creditUsagePercent":99.0,
          "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-06-30T21:36:52.140114+00:00","end":"2026-07-07T21:36:52.140114+00:00"},
          "onDemandCap":{"val":2500},"onDemandUsed":{"val":500},"isUnifiedBillingUser":true,"prepaidBalance":{"val":1446}}}
        """)
        let usage = try GrokBuildUsage.map(billing: billing, plan: "SuperGrok Heavy", email: "u@example.com")
        XCTAssertEqual(usage.windows.first?.title, "Weekly")
        XCTAssertEqual(usage.windows.first?.usedPercent, 99)
        XCTAssertEqual(usage.windows.first?.windowMinutes, 10080)
        XCTAssertNotNil(usage.windows.first?.resetsAt)
        XCTAssertEqual(usage.sections[0].rows[0].value, "2,500 credit cap")
        XCTAssertEqual(usage.cost?.balance ?? 0, 14.46, accuracy: 1e-9)
        XCTAssertEqual(usage.plan, "SuperGrok Heavy")
        // Proto3 JSON drops zeros: no percent means 0, and a missing cap means Disabled.
        let idle = try GrokBuildUsage.map(billing: json(#"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-01T00:00:00Z","end":"2026-07-08T00:00:00Z"}}}"#))
        XCTAssertEqual(idle.windows.first?.usedPercent, 0)
        XCTAssertEqual(idle.sections[0].rows[0].value, "Disabled")
        XCTAssertTrue(GrokBuildUsage.isTeamResponse(status: 412, body: #"{"error":"user has no personal team"}"#))
        XCTAssertFalse(GrokBuildUsage.isTeamResponse(status: 412, body: #"{"error":"other"}"#))
        XCTAssertTrue(GrokBuildUsage.teamOnly(plan: nil, email: nil).windows.isEmpty)
    }

    func testGrokNeverRefreshesAnExpiredToken() async throws {
        let file = """
        {"https://auth.x.ai::b1a00492":{"key":"tok","refresh_token":"r","expires_at":"2020-01-01T00:00:00Z","user_id":"user-uuid","email":"u@example.com"}}
        """
        let live = ProviderCredential(files: [ProviderCatalog.agentGrok.files[0].id: Data(file.utf8)], isLive: true)
        do {
            _ = try await ProviderCatalog.agentGrok.fetch(live)
            XCTFail("expected unauthorized")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .unauthorized("Open Grok to refresh this sign-in."))
        }
        let identity = ProviderCatalog.agentGrok.identify?(live)
        XCTAssertEqual(identity, CredentialIdentity(key: "user-uuid", email: "u@example.com"))
    }

    // MARK: Factory

    func testFactoryBillingAndLegacy() throws {
        let me = try json(#"{"organization":{"id":"org_1","name":"Acme","subscription":{"factoryTier":"team","orbSubscription":{"plan":{"name":"Team","id":"plan_1"},"status":"active"}}}}"#)
        let pool = #"{"fiveHour":{"usedPercent":12,"secondsRemaining":3600},"weekly":{"usedPercent":34,"secondsRemaining":7200},"monthly":{"usedPercent":56,"secondsRemaining":10800}}"#
        let billing = try json(#"{"usesTokenRateLimitsBilling":true,"extraUsageBalanceCents":2500,"overagePreference":"core","limits":{"standard":\#(pool),"core":\#(pool)}}"#)
        let usage = try FactoryUsage.map(me: me, billing: billing, legacy: nil, now: now)
        XCTAssertEqual(usage.windows.count, 6)
        XCTAssertEqual(usage.windows[0].usedPercent, 12)
        XCTAssertEqual(usage.windows[0].windowMinutes, 300)
        XCTAssertEqual(usage.windows[0].resetsAt, now.addingTimeInterval(3600))
        XCTAssertEqual(usage.cost?.balance, 25)
        XCTAssertEqual(usage.plan, "Factory Team - Team - Fallback: core")
        XCTAssertEqual(usage.organization, "Acme")
        let legacy = try json(#"{"usage":{"standard":{"userTokens":100,"totalAllowance":1000,"usedRatio":0.10}},"userId":"user-1"}"#)
        let old = try FactoryUsage.map(me: me, billing: nil, legacy: legacy, now: now)
        XCTAssertEqual(old.windows.map(\.title), ["Standard"])
        XCTAssertEqual(old.windows[0].usedPercent ?? 0, 10, accuracy: 1e-9)
    }

    // MARK: Kiro

    func testKiroUsageLimitsAndEndpoint() throws {
        let reply = try json("""
        {"nextDateReset":1.7882208E9,"overageConfiguration":{"overageStatus":"ENABLED"},
         "subscriptionInfo":{"subscriptionTitle":"KIRO POWER"},
         "usageBreakdownList":[{"currentOverages":3603,"currentOveragesWithPrecision":3603.49,"currentUsage":13603,
          "currentUsageWithPrecision":13603.49,"overageCap":10000,"overageCapWithPrecision":10000.0,"overageCharges":144.14,
          "overageRate":0.04,"resourceType":"CREDIT","usageLimit":10000,"usageLimitWithPrecision":10000.0}]}
        """)
        let usage = try KiroUsage.map(reply)
        XCTAssertEqual(usage.windows[0].usedPercent ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1_788_220_800))
        XCTAssertEqual(usage.windows[1].title, "Overage")
        XCTAssertEqual(usage.windows[1].usedPercent ?? 0, 36.0349, accuracy: 1e-6)
        XCTAssertEqual(usage.cost?.limit ?? 0, 400, accuracy: 1e-9)
        XCTAssertEqual(usage.plan, "KIRO POWER")
        XCTAssertEqual(KiroUsage.endpoint("arn:aws:codewhisperer:us-east-1:123456789012:profile/ABC"),
                       "https://codewhisperer.us-east-1.amazonaws.com/")
        XCTAssertEqual(KiroUsage.endpoint("arn:aws:codewhisperer:eu-central-1:1:profile/A"), "https://q.eu-central-1.amazonaws.com/")
        XCTAssertNil(KiroUsage.endpoint("arn:aws:codewhisperer:ap-south-1:1:profile/A"))
        XCTAssertNil(KiroUsage.endpoint("not an arn"))
    }

    func testKiroIdentityAndTokenRows() throws {
        let rows = #"{"api.codewhisperer.profile":"{\"arn\":\"arn:aws:codewhisperer:us-east-1:1:profile/A\"}"}"#
        let spec = ProviderCatalog.agentKiro
        let identity = spec.identify?(credential(spec, rows, at: 1))
        XCTAssertEqual(identity?.key, "arn:aws:codewhisperer:us-east-1:1:profile/A")
        let tokens = try json(#"{"kirocli:odic:token":"{\"access_token\":\"abc\"}"}"#)
        XCTAssertEqual(KiroUsage.accessToken(tokens), "abc")
    }

    // MARK: Kimi

    func testKimiRatioPoolsAndLegacyCounts() throws {
        let pools = try json("""
        {"usages":{"limit_5h":{"used_ratio":0,"reset_time":"2026-09-16T20:15:44Z"},"limit_7d":{"used_ratio":0.125,"reset_time":"2026-09-20T00:00:00Z"},
         "limit_month_total":{"used_ratio":0.0056,"reset_time":"2026-10-17T00:00:00Z"}},"user":{"membership":{"level":"LEVEL_ADVANCED"}}}
        """)
        let usage = try KimiUsage.map(pools)
        XCTAssertEqual(usage.windows.map(\.id), ["weekly", "session", "monthly"])
        XCTAssertEqual(usage.windows[0].usedPercent, 12.5)
        XCTAssertEqual(usage.windows[2].usedPercent ?? 0, 0.56, accuracy: 1e-9)
        XCTAssertEqual(usage.plan, "Allegro")
        let legacy = try json("""
        {"usage":{"limit":"2048","used":"214","remaining":"1834","resetTime":"2026-01-09T15:23:13.716839300Z"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"200","used":"139","remaining":"61","resetTime":"2026-01-06T13:33:02.717479433Z"}}]}
        """)
        let old = try KimiUsage.map(legacy)
        XCTAssertEqual(old.windows[0].usedPercent ?? 0, 214.0 / 2048 * 100, accuracy: 1e-9)
        XCTAssertEqual(old.windows[1].usedPercent ?? 0, 69.5, accuracy: 1e-9)
        XCTAssertEqual(old.windows[1].windowMinutes, 300)
        XCTAssertThrowsError(try KimiUsage.map(json("{}")))
    }

    func testKimiIdentityFromTokenClaims() {
        let payload = Data(#"{"sub":"user-9"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let spec = ProviderCatalog.agentKimi
        let identity = spec.identify?(credential(spec, #"{"access_token":"h.\#(payload).s","refresh_token":"r"}"#))
        XCTAssertEqual(identity?.key, "user-9")
        XCTAssertNil(spec.identify?(credential(spec, #"{"access_token":"opaque"}"#)))
    }

    // MARK: Kilo

    func testKiloCreditsPassAndIdentity() throws {
        let batch = try json("""
        [{"result":{"data":{"creditBlocks":[{"id":"cb-1","balance_mUsd":19000000,"amount_mUsd":19000000,"is_free":false}],"totalBalance_mUsd":19000000}}},
         {"result":{"data":{"subscription":{"tier":"tier_19","currentPeriodUsageUsd":0,"currentPeriodBaseCreditsUsd":19.0,"currentPeriodBonusCreditsUsd":9.5,"nextBillingAt":"2026-03-28T04:00:00.000Z"}}}},
         {"result":{"data":{"enabled":false,"amountCents":5000,"paymentMethod":null}}}]
        """)
        let usage = try KiloUsage.map(batch)
        XCTAssertEqual(usage.windows.map(\.title), ["Credits", "Kilo Pass"])
        XCTAssertEqual(usage.windows[0].usedPercent, 0)
        XCTAssertEqual(usage.windows[1].detail, "$0.00 / $19.00 (+ $9.50 bonus)")
        XCTAssertEqual(usage.windows[1].resetsAt, iso("2026-03-28T04:00:00.000Z"))
        XCTAssertEqual(usage.plan, "Starter")
        XCTAssertEqual(usage.sections[0].rows[0].value, "Off")
        let denied = try json(#"[{"error":{"json":{"message":"UNAUTHORIZED"}}},{"result":{"data":{}}},{"result":{"data":{}}}]"#)
        XCTAssertThrowsError(try KiloUsage.map(denied))
        let spec = ProviderCatalog.agentKilo
        XCTAssertEqual(spec.identify?(credential(spec, #"{"type":"oauth","access":"a","accountId":"acct1"}"#))?.key, "acct1")
        let apiKey = spec.identify?(credential(spec, #"{"type":"api","key":"k-1"}"#))?.key
        XCTAssertEqual(apiKey, AgentCLIsKit.fingerprint("k-1"))
        XCTAssertEqual(apiKey?.count, 12)
    }

    // MARK: Augment

    func testAugmentCredits() throws {
        let credits = try json(#"{"usageUnitsRemaining":15,"usageUnitsConsumedThisBillingCycle":10,"usageUnitsAvailable":100,"usageBalanceStatus":"active"}"#)
        let subscription = try json(#"{"planName":"Max Plan","billingPeriodEnd":"2026-06-09T00:00:00Z","email":"a@example.com"}"#)
        let usage = try AugmentUsage.map(credits: credits, subscription: subscription)
        XCTAssertEqual(usage.windows[0].usedPercent, 10)
        XCTAssertEqual(usage.windows[0].detail, "10 / 100 credits")
        XCTAssertEqual(usage.plan, "Max Plan")
        XCTAssertEqual(usage.email, "a@example.com")
        let noTotal = try AugmentUsage.map(credits: json(#"{"usageUnitsRemaining":15,"usageUnitsConsumedThisBillingCycle":10}"#), subscription: nil)
        XCTAssertEqual(noTotal.windows[0].usedPercent, 40)
    }

    // MARK: Amp

    func testAmpTierText() throws {
        let text = """
        Signed in as fixture@example.test (example)
        Amp Free: 61% remaining today (resets daily) - https://ampcode.com/settings#amp-free
        Amp Standard Tier: agent usage $18.57 of $20 remaining (93%), orb usage 732.8h of 750h a1.small orb hours remaining (98%) - period 2026-09-13 to 2026-10-13, resets upon renewal in 27 days
        Individual credits: $17.23 remaining (set up auto-reload to avoid running out) - https://ampcode.com/settings
        Workspace meow: $5.33 remaining (set up auto-reload to avoid running out) - https://ampcode.com/workspaces/meow
        """
        let usage = try AmpUsage.map(displayText: text, now: now)
        XCTAssertEqual(usage.windows.map(\.id), ["agent", "orb", "free"])
        XCTAssertEqual(usage.windows[0].usedPercent ?? 0, 7.15, accuracy: 1e-9)
        XCTAssertEqual(usage.windows[0].resetsAt, iso("2026-10-13"))
        XCTAssertEqual(usage.windows[1].usedPercent ?? 0, 17.2 / 750 * 100, accuracy: 1e-9)
        XCTAssertEqual(usage.windows[2].usedPercent, 39)
        XCTAssertEqual(usage.cost?.balance, 17.23)
        XCTAssertEqual(usage.sections[0].rows[0].label, "Workspace meow")
        XCTAssertEqual(usage.plan, "Standard")
        XCTAssertEqual(usage.email, "fixture@example.test")
        XCTAssertEqual(usage.organization, "example")
    }

    func testAmpSubscriptionAndDollarFreeForms() throws {
        let legacy = try AmpUsage.map(displayText: """
        Signed in as fixture@example.test (example)
        Subscription Gigawatt: 73% other usage and 91% orb usage remaining - resets upon renewal in 1 month
        """, now: now)
        XCTAssertEqual(legacy.windows.map(\.usedPercent), [27, 9])
        XCTAssertEqual(legacy.plan, "Gigawatt")
        let free = try AmpUsage.map(displayText: "Amp Free: $8/$10 remaining (replenishes +$0.5/hour)", now: now)
        XCTAssertEqual(free.windows[0].usedPercent, 20)
        XCTAssertEqual(free.windows[0].resetsAt, now.addingTimeInterval(4 * 3600))
        XCTAssertEqual(free.windows[0].windowMinutes, 1200)
        XCTAssertThrowsError(try AmpUsage.map(displayText: "nothing useful", now: now))
        let envelope = try json(#"{"ok":false,"error":{"code":"auth-required"}}"#)
        XCTAssertThrowsError(try AmpUsage.map(json: envelope, now: now)) {
            XCTAssertTrue(($0 as? ProviderError)?.needsSignIn == true)
        }
    }

    // MARK: Codebuff

    func testCodebuffUsageSubscriptionAndKeychainMember() async throws {
        let usage = try json(#"{"usage":1250,"quota":5000,"remainingBalance":3750,"autoTopupEnabled":true,"next_quota_reset":"2026-05-01T00:00:00Z"}"#)
        let subscription = try json(#"{"hasSubscription":true,"subscription":{"status":"active","tier":"pro","billingPeriodEnd":"2026-05-15T00:00:00Z"},"rateLimit":{"weeklyUsed":2100,"weeklyLimit":7000,"weeklyResetsAt":"2026-05-08T00:00:00Z"},"email":"user@example.com"}"#)
        let mapped = try CodebuffUsage.map(usage: usage, subscription: subscription)
        XCTAssertEqual(mapped.windows.map(\.id), ["credits", "weekly"])
        XCTAssertEqual(mapped.windows[0].usedPercent, 25)
        XCTAssertEqual(mapped.windows[1].usedPercent, 30)
        XCTAssertEqual(mapped.windows[1].windowMinutes, 10080)
        XCTAssertEqual(mapped.plan, "Pro")
        XCTAssertEqual(mapped.email, "user@example.com")
        XCTAssertEqual(mapped.sections[0].rows[0].value, "On")

        let spec = ProviderCatalog.agentCodebuff
        do {
            _ = try await spec.fetch(credential(spec, #"{"id":"u1","tokenStore":"keychain"}"#))
            XCTFail("expected missingCredential")
        } catch let error as ProviderError {
            guard case .missingCredential(let text) = error else { return XCTFail("wrong error") }
            XCTAssertTrue(text.contains("Keychain"))
        }
        let identity = spec.identify?(credential(spec, #"{"id":"u1","email":"a@example.com","authToken":"t"}"#))
        XCTAssertEqual(identity, CredentialIdentity(key: "u1", email: "a@example.com"))
    }

    // MARK: Devin

    func testDevinStatusAndTomlReader() throws {
        let reply = try json(#"{"userStatus":{"planStatus":{"planInfo":{"planName":"Max","hideDailyQuota":false},"dailyQuotaRemainingPercent":100,"dailyQuotaResetAtUnix":"1788940800","weeklyQuotaResetAtUnix":"1789286400","overageBalanceMicros":"964220000"}}}"#)
        let usage = try DevinUsage.map(reply)
        XCTAssertEqual(usage.windows.map(\.id), ["daily", "weekly"])
        XCTAssertEqual(usage.windows[0].usedPercent, 0)
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1_788_940_800))
        XCTAssertEqual(usage.windows[1].usedPercent, 100)
        XCTAssertEqual(usage.cost?.balance ?? 0, 964.22, accuracy: 1e-9)
        XCTAssertEqual(usage.plan, "Max")

        let toml = """
        # Devin CLI
        [section]
        windsurf_api_key = "devin-session-token$abc"  # trailing comment
        api_server_url = 'https://example.test/'
        """
        XCTAssertEqual(DevinUsage.tomlString(toml, key: "windsurf_api_key"), "devin-session-token$abc")
        XCTAssertEqual(DevinUsage.credentials(toml)?.server, "https://example.test")
        XCTAssertEqual(DevinUsage.tomlString("windsurf_api_key = bare # c", key: "windsurf_api_key"), "bare")
        XCTAssertNil(DevinUsage.tomlString("windsurf_api_key = \"\"", key: "windsurf_api_key"))
        XCTAssertNil(DevinUsage.tomlString("other = \"x\"", key: "windsurf_api_key"))
        XCTAssertEqual(DevinUsage.credentials("windsurf_api_key = \"k\"\napi_server_url = \"http://insecure\"")?.server,
                       "https://server.codeium.com")
        let spec = ProviderCatalog.agentDevin
        XCTAssertEqual(spec.identify?(credential(spec, toml))?.key, AgentCLIsKit.fingerprint("devin-session-token$abc"))
    }

    // MARK: OpenCode Go

    func testOpenCodeGoWindowsAndNotStarted() throws {
        let reply = try json(#"{"usage":{"rolling":{"status":"ok","percent":12,"resetsAt":"2026-07-12T13:30:00.662Z"},"weekly":{"status":"ok","percent":8,"resetsAt":"2026-07-13T00:00:00.000Z"},"monthly":{"status":"rate-limited","percent":100,"resetsAt":"2026-08-01T00:00:00.000Z"}}}"#)
        let usage = try OpenCodeGoUsage.map(reply)
        XCTAssertEqual(usage.windows.map(\.usedPercent), [12, 8, 100])
        XCTAssertEqual(usage.windows[0].windowMinutes, 300)
        XCTAssertEqual(usage.plan, "Go")
        let started = now.addingTimeInterval(5 * 3600)
        let text = ISO8601DateFormatter().string(from: started)
        let idle = try OpenCodeGoUsage.map(json(#"{"usage":{"rolling":{"percent":0,"resetsAt":"\#(text)"}}}"#), serverDate: now)
        XCTAssertEqual(idle.windows[0].detail, "Not started")
        XCTAssertNil(idle.windows[0].resetsAt)
        XCTAssertEqual(OpenCodeGoUsage.httpDate("Sat, 11 Jul 2026 10:00:00 GMT"), iso("2026-07-11T10:00:00Z"))
        let spec = ProviderCatalog.agentOpenCodeGo
        XCTAssertEqual(spec.identify?(credential(spec, #"{"type":"api","key":"sk-1"}"#)),
                       CredentialIdentity(key: AgentCLIsKit.fingerprint("sk-1"), plan: "Go"))
        XCTAssertEqual(spec.id.rawValue, "opencodego")
    }

    // MARK: Pi

    func testPiTodayAndThirtyDays() throws {
        func line(_ id: String, _ stamp: String, total: Int) -> String {
            #"{"type":"message","id":"\#(id)","timestamp":"\#(stamp)","message":{"role":"assistant","usage":{"input":100,"output":50,"cacheRead":10,"cacheWrite":5,"totalTokens":\#(total),"cost":{"total":0.5}}}}"#
        }
        let log = [line("m1", "2026-07-12T10:00:00.000Z", total: 150), line("m1", "2026-07-12T10:00:00.000Z", total: 150),
                   line("m2", "2026-06-22T10:00:00.000Z", total: 30), line("m0", "2026-04-01T10:00:00.000Z", total: 999),
                   #"{"type":"message","id":"u","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"user"}}"#]
            .joined(separator: "\n")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let usage = PiUsage.map(PiUsage.entries(in: Data(log.utf8)), now: iso("2026-07-12T12:00:00Z"), calendar: calendar)
        XCTAssertEqual(usage.sections.map(\.title), ["Today", "Last 30 days"])
        XCTAssertEqual(usage.sections[0].rows.first { $0.label == "Messages" }?.value, "1")
        XCTAssertEqual(usage.sections[0].rows.first { $0.label == "Tokens" }?.value, "150")
        XCTAssertEqual(usage.sections[1].rows.first { $0.label == "Messages" }?.value, "2")
        XCTAssertEqual(usage.sections[1].rows.first { $0.label == "Tokens" }?.value, "180")
        XCTAssertEqual(usage.sections[1].rows.first { $0.label == "Recorded cost" }?.value, "$1.00")
    }

    func testPiScanSkipsOldFiles() throws {
        let directory = URL(fileURLWithPath: "/tmp/pi-test-\(UUID().uuidString)")
        let session = directory.appending(path: "--project--")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = #"{"type":"message","id":"ID","timestamp":"\#(stamp)","message":{"role":"assistant","usage":{"input":1,"output":1,"totalTokens":2}}}"#
        try Data(text.replacingOccurrences(of: "ID", with: "recent").utf8).write(to: session.appending(path: "a.jsonl"))
        let old = session.appending(path: "b.jsonl")
        try Data(text.replacingOccurrences(of: "ID", with: "stale").utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86400)], ofItemAtPath: old.path)
        let usage = try PiUsage.scan(now: Date(), directory: directory)
        XCTAssertEqual(usage.sections[0].rows.first { $0.label == "Messages" }?.value, "1")
        XCTAssertThrowsError(try PiUsage.scan(now: Date(), directory: directory.appending(path: "missing")))
    }

    // MARK: Ollama

    private func sshString(_ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        return Data(bytes: &length, count: 4) + data
    }

    /// Builds an unencrypted OpenSSH ed25519 key file for a throwaway key.
    private func sshKeyFile(_ key: Curve25519.Signing.PrivateKey) -> (pem: Data, publicBlob: Data) {
        let type = Data("ssh-ed25519".utf8)
        let pub = key.publicKey.rawRepresentation
        let blob = sshString(type) + sshString(pub)
        var check = UInt32(0x01020304).bigEndian
        let checkBytes = Data(bytes: &check, count: 4)
        let secret = checkBytes + checkBytes + sshString(type) + sshString(pub) + sshString(key.rawRepresentation + pub)
            + sshString(Data("test".utf8)) + Data([1, 2, 3])
        var count = UInt32(1).bigEndian
        let file = Data("openssh-key-v1\0".utf8) + sshString(Data("none".utf8)) + sshString(Data("none".utf8))
            + sshString(Data()) + Data(bytes: &count, count: 4) + sshString(blob) + sshString(secret)
        let body = file.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n\(body)\n-----END OPENSSH PRIVATE KEY-----\n"
        return (Data(pem.utf8), blob)
    }

    func testOllamaKeyParserSignatureAndIdentity() throws {
        let throwaway = Curve25519.Signing.PrivateKey()
        let (pem, blob) = sshKeyFile(throwaway)
        let key = try XCTUnwrap(OllamaUsage.key(pem))
        XCTAssertEqual(key.publicKeyBase64, blob.base64EncodedString())
        XCTAssertEqual(key.seed, throwaway.rawRepresentation)

        let header = try OllamaUsage.authorization(key, method: "GET", requestURI: "/api/usage?ts=1700000000")
        let parts = header.split(separator: ":").map(String.init)
        XCTAssertEqual(parts[0], key.publicKeyBase64)
        let signature = try XCTUnwrap(Data(base64Encoded: parts[1]))
        XCTAssertTrue(throwaway.publicKey.isValidSignature(signature, for: Data("GET,/api/usage?ts=1700000000".utf8)))
        XCTAssertFalse(throwaway.publicKey.isValidSignature(signature, for: Data("POST,/api/usage?ts=1700000000".utf8)))

        var damaged = pem
        damaged.replaceSubrange(60..<62, with: Data("AA".utf8))
        XCTAssertNil(OllamaUsage.key(damaged))
        XCTAssertNil(OllamaUsage.key(Data("not a key".utf8)))
        let spec = ProviderCatalog.agentOllama
        XCTAssertEqual(spec.identify?(ProviderCredential(files: [spec.files[0].id: pem]))?.key, key.publicKeyBase64)
        XCTAssertNil(spec.login)
    }

    func testOllamaUsageLimits() throws {
        let usage = try json(#"{"activity":{"cost":"1.25000","period":{"type":"last_4_weeks"},"models":[]},"limits":{"session":{"usage":0.349},"weekly":{"usage":0.316},"monthly":{"usage":0.053}}}"#)
        let account = try json(#"{"ID":"x","Email":"e@example.com","Name":"n","Plan":"pro"}"#)
        let mapped = try OllamaUsage.map(usage, account: account)
        XCTAssertEqual(mapped.windows.map(\.id), ["session", "weekly", "monthly"])
        XCTAssertEqual(mapped.windows[0].usedPercent ?? 0, 34.9, accuracy: 1e-9)
        XCTAssertEqual(mapped.windows[0].windowMinutes, 300)
        XCTAssertNil(mapped.windows[2].windowMinutes)
        XCTAssertEqual(mapped.cost?.used, 1.25)
        XCTAssertEqual(mapped.plan, "Pro")
        XCTAssertThrowsError(try OllamaUsage.map(json("{}"), account: nil))
    }
}
