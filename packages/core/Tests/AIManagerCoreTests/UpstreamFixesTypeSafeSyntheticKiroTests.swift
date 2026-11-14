import Foundation
import XCTest
@testable import AIManagerCore

/// CodexBar fixes ported to TypeSafe, Synthetic and Kiro. All data is synthetic.
final class UpstreamFixesTypeSafeSyntheticKiroTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }

    private final class Recorder: @unchecked Sendable {
        var url: String?
        var headers: [String: String] = [:]
        var body: Data?
        var calls = 0
    }

    // MARK: TypeSafe

    private let overview = #"{"billing":{"plan":"free_plan","spent":0.01,"balance":4.98,"cycleLabel":"September 2026","credits":[{"amount":5,"remaining":4.98,"expiresAt":"2026-10-19T00:00:00Z"}]}}"#

    private func typeSafe(status: Int, body: String = "", headers: [String: String] = [:], recorder: Recorder = Recorder()) async throws -> ProviderUsage {
        try await TypeSafeUsage.fetch(cookie: "session=fixture") { url, sent in
            recorder.url = url
            recorder.headers = sent
            return HTTPResponse(status: status, data: Data(body.utf8), headers: headers)
        }
    }

    private func expect(_ matches: (ProviderError) -> Bool, _ message: String,
                        _ work: () async throws -> ProviderUsage) async {
        do {
            _ = try await work()
            XCTFail("\(message): no error")
        } catch let error as ProviderError {
            XCTAssertTrue(matches(error), "\(message): \(error)")
        } catch {
            XCTFail("\(message): \(error)")
        }
    }

    private func isExpired(_ error: ProviderError) -> Bool { if case .unauthorized = error { return true }; return false }
    private func isIntegration(_ error: ProviderError) -> Bool { if case .http = error { return true }; return false }

    func testTypeSafeOverviewReplyAndSameOriginRequest() async throws {
        let recorder = Recorder()
        let usage = try await typeSafe(status: 200, body: overview, recorder: recorder)
        XCTAssertEqual(usage.cost?.used, 0.01)
        XCTAssertEqual(usage.cost?.balance, 4.98)
        XCTAssertEqual(usage.cost?.period, "September 2026")
        XCTAssertEqual(usage.plan, "Free")
        XCTAssertEqual(usage.sections[0].rows.map(\.label), ["Spent (September 2026)", "Credit"])
        XCTAssertEqual(recorder.url, "https://console.typesafe.ai/api/billing/overview")
        XCTAssertEqual(recorder.headers["Cookie"], "session=fixture")
        XCTAssertEqual(recorder.headers["Origin"], "https://console.typesafe.ai")
        XCTAssertEqual(recorder.headers["Referer"], "https://console.typesafe.ai/billing")
        XCTAssertEqual(recorder.headers["Sec-Fetch-Site"], "same-origin")
        XCTAssertEqual(recorder.headers["Sec-Fetch-Mode"], "cors")
        XCTAssertEqual(recorder.headers["Sec-Fetch-Dest"], "empty")
        XCTAssertFalse(try XCTUnwrap(recorder.headers["User-Agent"]).contains("curl/"))
    }

    func testTypeSafeCrossOriginRefusalIsAFailureNotASignOut() async {
        await expect(isIntegration, "403 cross-origin") {
            try await typeSafe(status: 403, body: #"{"detail":"Cross-origin request refused"}"#)
        }
    }

    func testTypeSafePlain401And403AreSignOuts() async {
        for status in [401, 403] {
            await expect(isExpired, "HTTP \(status)") { try await typeSafe(status: status) }
        }
    }

    func testTypeSafeRedirects() async {
        await expect(isExpired, "302 to login") { try await typeSafe(status: 302, headers: ["location": "/login?next=/billing"]) }
        await expect(isExpired, "302 off site") { try await typeSafe(status: 302, headers: ["location": "https://evil.example/billing"]) }
        await expect(isExpired, "302 to sso host path") { try await typeSafe(status: 302, headers: ["location": "https://console.typesafe.ai/sso/start"]) }
        await expect(isIntegration, "302 to /billing") { try await typeSafe(status: 302, headers: ["location": "/billing"]) }
        await expect(isIntegration, "302 to full /billing url") { try await typeSafe(status: 308, headers: ["location": "https://console.typesafe.ai/billing"]) }
        await expect(isIntegration, "302 without location") { try await typeSafe(status: 302) }
    }

    func testTypeSafeHtmlBody() async {
        await expect(isExpired, "login page") { try await typeSafe(status: 200, body: "<html><body><h1>Sign in</h1></body></html>") }
        await expect(isIntegration, "other html") { try await typeSafe(status: 200, body: "<html><body>Maintenance</body></html>") }
    }

    func testTypeSafeBadJsonAndMissingBilling() async {
        await expect({ if case .parse = $0 { return true }; return false }, "not json") { try await typeSafe(status: 200, body: "nope") }
        await expect({ if case .parse = $0 { return true }; return false }, "no billing") { try await typeSafe(status: 200, body: #"{"data":{}}"#) }
    }

    func testTypeSafeStatusMapping() async {
        await expect({ if case .rateLimited = $0 { return true }; return false }, "429") { try await typeSafe(status: 429) }
        await expect({ if case .unavailable = $0 { return true }; return false }, "503") { try await typeSafe(status: 503) }
        await expect(isIntegration, "404") { try await typeSafe(status: 404) }
    }

    // MARK: Synthetic

    func testSyntheticPlanWeeklyLimitIsAlreadyInPercentagePoints() throws {
        let usage = try SyntheticUsage.map(json(#"""
        {"planWeeklyLimit":{"percentUsed":0.5,"nextRegenPercent":0.2,"resetAt":"2026-11-20T00:00:00Z"},
         "rollingFiveHourLimit":{"limit":100,"used":10,"window":"5h"}}
        """#))
        XCTAssertEqual(usage.windows.map(\.id), ["weekly"])
        XCTAssertEqual(usage.windows[0].title, "Weekly quota")
        XCTAssertEqual(try XCTUnwrap(usage.windows[0].usedPercent), 0.5, accuracy: 1e-9)
        XCTAssertEqual(usage.windows[0].detail, "Next regen 0.2%")
        XCTAssertNotNil(usage.windows[0].resetsAt)

        let nested = try SyntheticUsage.map(json(#"{"data":{"planWeeklyLimit":{"percentRemaining":99.5}}}"#))
        XCTAssertEqual(try XCTUnwrap(nested.windows[0].usedPercent), 0.5, accuracy: 1e-9)
    }

    func testSyntheticOldFormatStillMapsAsBefore() throws {
        let usage = try SyntheticUsage.map(json(#"""
        {"rollingFiveHourLimit":{"limit":100,"used":10,"window":"5h","tickPercent":0.05},
         "weeklyTokenLimit":{"percentUsed":0.5}}
        """#))
        XCTAssertEqual(usage.windows.map(\.id), ["session", "weekly"])
        XCTAssertEqual(usage.windows[0].detail, "10 / 100 · 5 hours window · Next regen 5%")
        XCTAssertEqual(try XCTUnwrap(usage.windows[1].usedPercent), 50, accuracy: 1e-9)
    }

    // MARK: Kiro

    private let kiroReply = #"{"usageBreakdownList":[{"resourceType":"CREDIT","currentUsage":10,"usageLimit":100}]}"#

    private func kiro(tokens: String? = #"{"kirocli:odic:token":"{\"access_token\":\"synthetic-token\"}"}"#,
                      profile: String?, recorder: Recorder = Recorder(), status: Int = 200) async throws -> ProviderUsage {
        try await KiroUsage.fetch(try tokens.map(json), profile: try profile.map(json)) { url, headers, body in
            recorder.url = url
            recorder.headers = headers
            recorder.body = body
            recorder.calls += 1
            return HTTPResponse(status: status, data: Data(kiroReply.utf8), headers: [:])
        }
    }

    func testKiroTokenOnlyCredentialPostsEmptyBodyToUsEast1() async throws {
        for profile in [nil, "{}"] as [String?] {
            let recorder = Recorder()
            let usage = try await kiro(profile: profile, recorder: recorder)
            XCTAssertEqual(recorder.url, "https://codewhisperer.us-east-1.amazonaws.com/")
            XCTAssertEqual(try XCTUnwrap(recorder.body), Data("{}".utf8))
            XCTAssertEqual(recorder.headers["Authorization"], "Bearer synthetic-token")
            XCTAssertEqual(usage.windows[0].usedPercent ?? 0, 10, accuracy: 1e-9)
        }
    }

    func testKiroStoredProfileStillSendsItsArn() async throws {
        let recorder = Recorder()
        _ = try await kiro(profile: #"{"api.codewhisperer.profile":"{\"arn\":\"arn:aws:codewhisperer:eu-central-1:1:profile/A\"}"}"#, recorder: recorder)
        XCTAssertEqual(recorder.url, "https://q.eu-central-1.amazonaws.com/")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(recorder.body)) as? [String: String]
        XCTAssertEqual(body, ["profileArn": "arn:aws:codewhisperer:eu-central-1:1:profile/A"])
    }

    func testKiroPresentButInvalidProfileStillFailsWithoutARequest() async throws {
        let profiles = [
            #"{"api.codewhisperer.profile":"{"}"#, #"{"api.codewhisperer.profile":null}"#,
            #"{"api.codewhisperer.profile":"{}"}"#, #"{"api.codewhisperer.profile":"{\"arn\":7}"}"#,
            #"{"api.codewhisperer.profile":"{\"arn\":\"not an arn\"}"}"#,
            #"{"api.codewhisperer.profile":"{\"arn\":\"arn:aws:codewhisperer:ap-south-1:1:profile/A\"}"}"#,
        ]
        for profile in profiles {
            let recorder = Recorder()
            do {
                _ = try await kiro(profile: profile, recorder: recorder)
                XCTFail("Accepted profile \(profile)")
            } catch is ProviderError {}
            XCTAssertEqual(recorder.calls, 0, profile)
        }
    }

    func testKiroWithoutATokenSendsNothing() async throws {
        for tokens in [nil, "{}"] as [String?] {
            let recorder = Recorder()
            do {
                _ = try await kiro(tokens: tokens, profile: nil, recorder: recorder)
                XCTFail("Accepted missing token")
            } catch is ProviderError {}
            XCTAssertEqual(recorder.calls, 0)
        }
    }

    func testKiroTokenOnlyLoginIsCompleteAndIdentifiedByItsRegistration() throws {
        let spec = ProviderCatalog.agentKiro
        XCTAssertEqual(spec.files.map(\.optional), [false, true])
        let tokens = ProviderCredential(files: [spec.files[0].id: Data(
            #"{"kirocli:odic:token":"{\"access_token\":\"t\"}","kirocli:odic:device-registration":"{\"client_id\":\"synthetic-client\"}"}"#.utf8)])
        let identity = try XCTUnwrap(spec.identify?(tokens))
        XCTAssertTrue(identity.key.hasPrefix("kiro-client-"))
        XCTAssertFalse(identity.key.contains("synthetic-client"))
        var malformed = tokens
        malformed.files[spec.files[1].id] = Data(#"{"api.codewhisperer.profile":"{"}"#.utf8)
        XCTAssertNil(spec.identify?(malformed))
    }
}
