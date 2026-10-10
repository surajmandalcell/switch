import Foundation
import XCTest
@testable import AIManagerCore

final class CodexUsageExtrasTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func response(_ json: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, data: Data(json.utf8), headers: headers)
    }

    // MARK: Plan names

    func testPlanNamesMapPublishedIdsAndKeepUnknownCapitalized() {
        XCTAssertEqual(CodexPlanNames.display("prolite"), "Pro 100")
        XCTAssertEqual(CodexPlanNames.display("pro"), "Pro 200")
        XCTAssertEqual(CodexPlanNames.display("PROMAX"), "Pro 500")
        XCTAssertEqual(CodexPlanNames.display("self_serve_business_prolite"), "Business Premium")
        XCTAssertEqual(CodexPlanNames.display("plus"), "Plus")
        XCTAssertEqual(CodexPlanNames.display(" team "), "Team")
        XCTAssertNil(CodexPlanNames.display(""))
        XCTAssertNil(CodexPlanNames.display(nil))
    }

    // MARK: Credits

    func testCreditsShowDollarsAndFlooredCredits() {
        XCTAssertEqual(CodexCreditsText.text(balance: 796.4009760000), "$31.84 · 796 credits")
        XCTAssertEqual(CodexCreditsText.text(balance: "796.4009760000"), "$31.84 · 796 credits")
        XCTAssertEqual(CodexCreditsText.text(balance: 0.9), "$0.00 · 0 credits")
        XCTAssertEqual(CodexCreditsText.text(balance: -5), "$0.00 · 0 credits")
        XCTAssertEqual(CodexCreditsText.text(balance: 1), "$0.04 · 1 credit")
        XCTAssertEqual(CodexCreditsText.text(balance: 30_000), "$1,200.00 · 30,000 credits")
        XCTAssertNil(CodexCreditsText.text(balance: "not a number"))
    }

    // MARK: Bucket and window naming

    func testBucketTitlesName_Spark_and_keepReportedNames() {
        XCTAssertEqual(CodexBucketNaming.title(id: "codex_bengalfox", name: "GPT-5.3-Codex-Spark", fallback: "x"), "Spark")
        XCTAssertEqual(CodexBucketNaming.title(id: "codex_spark_preview", name: "Research Preview", fallback: "x"), "Spark")
        XCTAssertEqual(CodexBucketNaming.title(id: "codex", name: nil, fallback: "default"), "Codex")
        XCTAssertEqual(CodexBucketNaming.title(id: "codex_other", name: "Some Other Model", fallback: "x"), "Some Other Model")
        XCTAssertEqual(CodexBucketNaming.title(id: nil, name: nil, fallback: "extra_limit"), "Extra Limit")
    }

    func testWindowsAreNamedByDurationNotSlot() {
        XCTAssertEqual(CodexBucketNaming.windowTitle(minutes: 300, fallback: "f"), "Session")
        XCTAssertEqual(CodexBucketNaming.windowTitle(minutes: 10_080, fallback: "f"), "Weekly")
        XCTAssertEqual(CodexBucketNaming.windowTitle(minutes: 120, fallback: "f"), "2-hour window")
        XCTAssertEqual(CodexBucketNaming.windowTitle(minutes: 2_880, fallback: "f"), "2-day window")
        XCTAssertEqual(CodexBucketNaming.windowTitle(minutes: 45, fallback: "f"), "45-minute window")
        XCTAssertEqual(CodexBucketNaming.windowTitle(minutes: nil, fallback: "Current window"), "Current window")
    }

    func testLoneWeeklyWindowTakesPrimarySlotAndSlotsSortByDuration() {
        func window(_ percent: Int?, _ minutes: Int64?) -> CodexRateLimitWindowSnapshot {
            .init(usedPercent: percent, windowDurationMinutes: minutes, resetsAt: nil)
        }
        func bucket(_ primary: CodexRateLimitWindowSnapshot?, _ secondary: CodexRateLimitWindowSnapshot?)
            -> CodexRateLimitBucketSnapshot {
            .init(id: "codex", name: nil, plan: nil, model: nil, primary: primary, secondary: secondary,
                  credits: nil, spendControlReached: nil)
        }

        let lone = bucket(nil, window(40, 10_080)).windowRows(idPrefix: "codex/")
        XCTAssertEqual(lone.map(\.id), ["codex/primary"])
        XCTAssertEqual(lone.map(\.usage.title), ["Weekly"])
        XCTAssertEqual(lone.first?.usage.windowMinutes, 10_080)

        let swapped = bucket(window(70, 10_080), window(10, 300)).windowRows()
        XCTAssertEqual(swapped.map(\.usage.title), ["Session", "Weekly"])
        XCTAssertEqual(swapped.map(\.slot), ["primary", "secondary"])

        let normal = bucket(window(10, 300), window(70, 10_080)).windowRows()
        XCTAssertEqual(normal.map(\.usage.usedPercent), [10, 70])

        XCTAssertTrue(bucket(window(nil, 300), nil).windowRows().isEmpty)
    }

    // MARK: wham/usage parsing

    func testSparkBucketFromAdditionalRateLimits() throws {
        let nowSec = Int(now.timeIntervalSince1970)
        let usage = response("""
        {
          "rate_limit": { "primary_window": { "used_percent": 5, "reset_after_seconds": 60 } },
          "additional_rate_limits": [
            null,
            {
              "limit_name": "GPT-5.3-Codex-Spark",
              "metered_feature": "codex_bengalfox",
              "rate_limit": {
                "primary_window": { "used_percent": 25, "limit_window_seconds": 18000,
                                    "reset_after_seconds": 3600, "reset_at": \(nowSec + 3600) },
                "secondary_window": { "used_percent": 40, "limit_window_seconds": 604800,
                                      "reset_after_seconds": 86400, "reset_at": \(nowSec + 86400) }
              }
            },
            { "limit_name": "GPT-5.3-Codex-Spark" }
          ]
        }
        """)
        let extras = try XCTUnwrap(CodexWhamExtras.parse(usage: usage, resetCredits: nil, now: now))
        XCTAssertEqual(extras.additionalBuckets.count, 1)
        let bucket = extras.additionalBuckets[0]
        XCTAssertEqual(CodexBucketNaming.title(id: bucket.id, name: bucket.name, fallback: ""), "Spark")
        XCTAssertEqual(bucket.primary?.usedPercent, 25)
        XCTAssertEqual(bucket.primary?.windowDurationMinutes, 300)
        XCTAssertEqual(bucket.primary?.resetsAt, Date(timeIntervalSince1970: TimeInterval(nowSec + 3600)))
        XCTAssertEqual(bucket.windowRows().map(\.usage.title), ["Session", "Weekly"])
    }

    func testWeeklyOnlySparkPrimaryWindowKeepsWeeklyName() throws {
        let usage = response("""
        {"additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","rate_limit":
          {"primary_window":{"used_percent":7,"limit_window_seconds":604800,"reset_after_seconds":60},"secondary_window":null}}]}
        """)
        let extras = try XCTUnwrap(CodexWhamExtras.parse(usage: usage, resetCredits: nil, now: now))
        let rows = extras.additionalBuckets[0].windowRows()
        XCTAssertEqual(rows.map(\.usage.title), ["Weekly"])
        XCTAssertEqual(rows[0].window.resetsAt, now.addingTimeInterval(60))
    }

    func testResetCreditsFromDedicatedEndpointSortedAndFiltered() throws {
        for status in ["available", nil] as [String?] {
            let field = status.map { "\"status\":\"\($0)\"," } ?? ""
            let credits = response("""
            {"available_count":2,"credits":[
              {\(field)"expires_at":"2026-02-20T19:00:00.000Z"},
              {\(field)"expires_at":"2026-02-20T17:30:00.000Z"},
              {"status":"consumed","expires_at":"2026-02-20T16:10:00.000Z"}
            ]}
            """)
            let extras = try XCTUnwrap(CodexWhamExtras.parse(usage: response("{}"), resetCredits: credits, now: now))
            XCTAssertEqual(extras.resetCredits?.count, 2)
            XCTAssertEqual(extras.resetCredits?.expiries, [
                Fmt.iso("2026-02-20T17:30:00.000Z")!, Fmt.iso("2026-02-20T19:00:00.000Z")!,
            ])
            XCTAssertTrue(extras.resetCredits!.summary.hasPrefix("2 · next expires "))
            XCTAssertTrue(extras.resetCredits!.expiryList!.hasPrefix("Expires: "))
        }
    }

    func testResetCreditsFallBackToUsageBodyCount() throws {
        let usage = response(#"{"rate_limit_reset_credits":{"available_count":3}}"#)
        let bad: [HTTPResponse?] = [
            nil,
            response(#"{"available_count":null}"#),
            response("<html>oops</html>", status: 500),
        ]
        for dedicated in bad {
            let extras = try XCTUnwrap(CodexWhamExtras.parse(usage: usage, resetCredits: dedicated, now: now))
            XCTAssertEqual(extras.resetCredits?.count, 3)
            XCTAssertEqual(extras.resetCredits?.expiries, [])
            XCTAssertEqual(extras.resetCredits?.summary, "3")
            XCTAssertNil(extras.resetCredits?.expiryList)
        }
        let zero = try XCTUnwrap(CodexWhamExtras.parse(
            usage: response(#"{"rate_limit_reset_credits":{"available_count":0}}"#), resetCredits: nil, now: now))
        XCTAssertEqual(zero.resetCredits?.count, 0)
        XCTAssertNil(CodexWhamExtras.parse(
            usage: response(#"{"rate_limit_reset_credits":{"available_count":null}}"#), resetCredits: nil, now: now))
    }

    func testCreditsBalanceFromBodyOrHeader() throws {
        let body = try XCTUnwrap(CodexWhamExtras.parse(
            usage: response(#"{"credits":{"balance":"796.4"}}"#), resetCredits: nil, now: now))
        XCTAssertEqual(body.creditsBalance.flatMap(CodexCreditsText.text(balance:)), "$31.84 · 796 credits")
        let header = try XCTUnwrap(CodexWhamExtras.parse(
            usage: response("{}", headers: ["x-codex-credits-balance": "100"]), resetCredits: nil, now: now))
        XCTAssertEqual(header.creditsBalance.flatMap(CodexCreditsText.text(balance:)), "$4.00 · 100 credits")
        let none = try XCTUnwrap(CodexWhamExtras.parse(
            usage: response(#"{"credits":{"has_credits":false}}"#), resetCredits: nil, now: now))
        XCTAssertEqual(none.creditsBalance, "0")
    }

    // MARK: individual_limit

    func testMonthlyCreditPoolFromEachIndividualLimitLocation() throws {
        let rootLimit = #"{"limit":100000,"used":"7761","remaining_percent":92.239,"resets_at":1782864000}"#
        let spend = """
        {"spend_control":{"reached":false,"individual_limit":{"source":"workspace_spend_controls","limit":"1000",
          "used":"36.79748725891113","remaining":"963.2","used_percent":4,"remaining_percent":96,"reset_at":1788220800}}}
        """
        let bodies = [
            "{\"individual_limit\":\(rootLimit)}",
            "{\"rate_limit\":{\"primary_window\":null,\"individual_limit\":\(rootLimit)}}",
        ]
        for body in bodies {
            let pool = try XCTUnwrap(CodexWhamExtras.parse(usage: response(body), resetCredits: nil, now: now)?.monthlyCredits)
            XCTAssertEqual(pool.limit, 100_000)
            XCTAssertEqual(pool.used, 7_761)
            XCTAssertEqual(pool.remainingPercent, 92.239, accuracy: 0.0001)
            XCTAssertEqual(pool.resetsAt, Date(timeIntervalSince1970: 1_782_864_000))
            XCTAssertEqual(pool.window.title, "Monthly credits")
            XCTAssertEqual(try XCTUnwrap(pool.window.usedPercent), 7.761, accuracy: 0.0001)
            XCTAssertEqual(pool.window.detail, "7,761 / 100,000 credits")
        }
        let team = try XCTUnwrap(CodexWhamExtras.parse(usage: response(spend), resetCredits: nil, now: now)?.monthlyCredits)
        XCTAssertEqual(team.limit, 1_000)
        XCTAssertEqual(team.remainingPercent, 96)
        XCTAssertEqual(team.resetsAt, Date(timeIntervalSince1970: 1_788_220_800))
    }

    func testMonthlyCreditPoolDerivesMissingValuesAndRejectsZeroLimit() throws {
        let derivedUsed = try XCTUnwrap(CodexWhamExtras.parse(
            usage: response(#"{"individual_limit":{"limit":200,"remaining_percent":75}}"#),
            resetCredits: nil, now: now)?.monthlyCredits)
        XCTAssertEqual(derivedUsed.used, 50)
        XCTAssertNil(derivedUsed.resetsAt)
        let derivedPercent = try XCTUnwrap(CodexWhamExtras.parse(
            usage: response(#"{"individual_limit":{"limit":200,"used":50}}"#),
            resetCredits: nil, now: now)?.monthlyCredits)
        XCTAssertEqual(derivedPercent.remainingPercent, 75)
        XCTAssertNil(CodexWhamExtras.parse(
            usage: response(#"{"individual_limit":{"limit":0,"used":0}}"#), resetCredits: nil, now: now))
    }

    // MARK: Snapshot helpers

    func testSnapshotExtraWindowsAndFactRows() throws {
        let spark = CodexRateLimitBucketSnapshot(
            id: "codex_bengalfox", name: "GPT-5.3-Codex-Spark", plan: nil, model: nil,
            primary: .init(usedPercent: 25, windowDurationMinutes: 300, resetsAt: nil),
            secondary: nil, credits: nil, spendControlReached: nil)
        let main = CodexRateLimitBucketSnapshot(
            id: "codex", name: nil, plan: "prolite", model: nil,
            primary: .init(usedPercent: 1, windowDurationMinutes: 300, resetsAt: nil), secondary: nil,
            credits: .init(hasCredits: true, unlimited: false, balance: "796.4"), spendControlReached: nil)
        let extras = CodexWhamExtras(
            resetCredits: .init(count: 1, expiries: []),
            monthlyCredits: .init(limit: 100, used: 10, remainingPercent: 90, resetsAt: nil),
            additionalBuckets: [spark], creditsBalance: nil)
        let snapshot = CodexAccountUsageSnapshot(
            account: nil, requiresOpenAIAuthentication: nil,
            rateLimits: .init(accountID: nil, ordinaryUsageAllowed: nil, defaultBucket: main,
                              buckets: ["codex": main]),
            usage: nil, dailyUsage: [], fetchedAt: now, extras: extras)
        XCTAssertEqual(snapshot.extraWindows.map(\.title), ["Spark Session", "Monthly credits"])
        XCTAssertEqual(snapshot.factRows.map(\.label), ["Reset credits", "Credits"])
        XCTAssertEqual(snapshot.factRows.last?.value, "$31.84 · 796 credits")
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(CodexAccountUsageSnapshot.self, from: encoded), snapshot)
    }

    func testOldCachedSnapshotWithoutExtrasStillDecodes() throws {
        let json = #"{"dailyUsage":[],"fetchedAt":790000000}"#
        let snapshot = try JSONDecoder().decode(CodexAccountUsageSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.extras)
    }

    // MARK: Client

    private func authFile(token: String, accountID: String? = "acct-synthetic") throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "CodexWham-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var tokens: [String: Any] = ["access_token": token, "refresh_token": "synthetic-refresh"]
        tokens["account_id"] = accountID
        let file = root.appending(path: "auth.json")
        try JSONSerialization.data(withJSONObject: ["tokens": tokens]).write(to: file)
        return (root, file)
    }

    private func jwt(exp: Date) -> String {
        let payload = Data(#"{"exp":\#(Int(exp.timeIntervalSince1970))}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(payload).signature"
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(url: String, headers: [String: String])] = []
        func add(_ url: String, _ headers: [String: String]) { lock.lock(); items.append((url, headers)); lock.unlock() }
        var all: [(url: String, headers: [String: String])] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func testClientSendsAccountHeadersAndParsesBothEndpoints() async throws {
        let (root, file) = try authFile(token: jwt(exp: now.addingTimeInterval(3_600)))
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        let client = CodexWhamClient { url, headers in
            recorder.add(url, headers)
            return url.hasSuffix("rate-limit-reset-credits")
                ? HTTPResponse(status: 200, data: Data(#"{"available_count":2,"credits":[]}"#.utf8), headers: [:])
                : HTTPResponse(status: 200, data: Data(#"{"credits":{"balance":"100"}}"#.utf8), headers: [:])
        }
        let extras = await client.fetch(authFile: file, now: now)
        XCTAssertEqual(extras?.resetCredits?.count, 2)
        XCTAssertEqual(extras?.creditsBalance, "100.0")
        let calls = recorder.all
        XCTAssertEqual(Set(calls.map(\.url)), [
            "https://chatgpt.com/backend-api/wham/usage",
            "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
        ])
        for call in calls {
            XCTAssertTrue(call.headers["Authorization"]?.hasPrefix("Bearer ") == true)
            XCTAssertEqual(call.headers["ChatGPT-Account-Id"], "acct-synthetic")
        }
        XCTAssertEqual(calls.first { $0.url.hasSuffix("credits") }?.headers["originator"], "Codex Desktop")
    }

    func testClientSkipsExpiredOrUnreadableTokensWithoutAnyRequest() async throws {
        let recorder = Recorder()
        let client = CodexWhamClient { url, headers in
            recorder.add(url, headers)
            return HTTPResponse(status: 200, data: Data("{}".utf8), headers: [:])
        }
        for token in [jwt(exp: now.addingTimeInterval(-60)), jwt(exp: now.addingTimeInterval(10)), "opaque-token"] {
            let (root, file) = try authFile(token: token)
            defer { try? FileManager.default.removeItem(at: root) }
            let extras = await client.fetch(authFile: file, now: now)
            XCTAssertNil(extras)
        }
        let missing = FileManager.default.temporaryDirectory.appending(path: "CodexWham-missing/auth.json")
        let none = await client.fetch(authFile: missing, now: now)
        XCTAssertNil(none)
        XCTAssertTrue(recorder.all.isEmpty)
    }

    func testClientTreatsFailedRequestsAsNoData() async throws {
        let (root, file) = try authFile(token: jwt(exp: now.addingTimeInterval(3_600)))
        defer { try? FileManager.default.removeItem(at: root) }
        let client = CodexWhamClient { _, _ in throw ProviderError.network("down") }
        let extras = await client.fetch(authFile: file, now: now)
        XCTAssertNil(extras)
        let unauthorized = CodexWhamClient { _, _ in HTTPResponse(status: 401, data: Data("{}".utf8), headers: [:]) }
        let denied = await unauthorized.fetch(authFile: file, now: now)
        XCTAssertNil(denied)
    }
}
