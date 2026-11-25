import Foundation
import XCTest
@testable import AIManagerCore

/// CodexBar fixes ported to Synthetic and Kiro. All data is synthetic.
final class UpstreamFixesTypeSafeSyntheticKiroTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }

    private final class Recorder: @unchecked Sendable {
        var url: String?
        var headers: [String: String] = [:]
        var body: Data?
        var calls = 0
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
