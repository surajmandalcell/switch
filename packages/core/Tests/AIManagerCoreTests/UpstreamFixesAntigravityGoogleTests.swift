import XCTest
@testable import AIManagerCore

/// Synthetic fixtures for the Antigravity Argon bucket and host merge, and Google refresh failures.
final class UpstreamFixesAntigravityGoogleTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }

    private func map(_ summary: JSON?) throws -> [UsageWindow] {
        try AntigravityCLIUsage.map(assist: json("{}"), summary: summary, models: nil, claims: nil).windows
    }

    private let shared = """
    {"displayName":"Gemini models","buckets":[
      {"bucketId":"gemini-5h","remainingFraction":0.8,"resetTime":"2026-07-02T16:00:00Z"},
      {"bucketId":"gemini-weekly","remainingFraction":0.9}]},
    {"displayName":"Claude and other models","buckets":[
      {"bucketId":"3p-5h","remainingFraction":0.4},{"bucketId":"3p-weekly","remainingFraction":1}]}
    """
    private let argon = """
    {"displayName":"Gemini 4 Argon","buckets":[
      {"bucketId":"argon-w","window":"weekly","remainingFraction":0.355,"resetTime":"2026-07-06T07:00:00Z"}]}
    """

    // MARK: Antigravity

    func testArgonWeeklyBucketAppearsBeforeClaudeAndPercentIsUnrounded() throws {
        let windows = try map(json(#"{"groups":[\#(shared),\#(argon)]}"#))
        XCTAssertEqual(windows.map(\.id), ["session", "weekly", "argon-weekly", "claude-session", "claude-weekly"])
        let argonWindow = try XCTUnwrap(windows.first { $0.id == "argon-weekly" })
        XCTAssertEqual(argonWindow.usedPercent ?? -1, 64.5, accuracy: 1e-9)
        XCTAssertEqual(argonWindow.windowMinutes, 10_080)
        XCTAssertEqual(argonWindow.resetsAt, Fmt.iso("2026-07-06T07:00:00Z"))
    }

    func testArgonBucketIsDroppedWhenAmbiguousDisabledOrNotWeekly() throws {
        func ids(_ group: String) throws -> [String] { try map(json(#"{"groups":[\#(shared),\#(group)]}"#)).map(\.id) }
        let base = ["session", "weekly", "claude-session", "claude-weekly"]
        let two = #"{"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"a","window":"weekly","remainingFraction":0.5},{"bucketId":"b","window":"weekly","remainingFraction":0.5}]}"#
        XCTAssertEqual(try ids(two), base)
        let disabled = #"{"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"a","window":"weekly","disabled":true,"remainingFraction":0.5}]}"#
        XCTAssertEqual(try ids(disabled), base)
        let badFlag = #"{"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"a","window":"weekly","disabled":{},"remainingFraction":0.5}]}"#
        XCTAssertEqual(try ids(badFlag), base)
        let daily = #"{"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"a","window":"daily","remainingFraction":0.5}]}"#
        XCTAssertEqual(try ids(daily), base)
        // An Argon bucket that borrows a shared pool id cannot override that pool.
        let clash = #"{"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0}]}"#
        let windows = try map(json(#"{"groups":[\#(shared),\#(clash)]}"#))
        XCTAssertEqual(windows.map(\.id), base)
        XCTAssertEqual(windows[1].usedPercent ?? -1, 10, accuracy: 1e-9)
    }

    func testOldShapeWithoutArgonMapsAsBefore() throws {
        let windows = try map(json(#"{"groups":[\#(shared)]}"#))
        XCTAssertEqual(windows.map(\.id), ["session", "weekly", "claude-session", "claude-weekly"])
        XCTAssertEqual(windows[0].usedPercent ?? -1, 20, accuracy: 1e-9)
    }

    func testLegacyModelQuotaSkipsArgon() throws {
        let models = try json("""
        {"models":{"MODEL_PLACEHOLDER_M421":{"displayName":"Gemini 4 Argon","quotaInfo":{"remainingFraction":0.1}},
                   "a":{"displayName":"Gemini 3 Pro","quotaInfo":{"remainingFraction":0.8}}}}
        """)
        let windows = try AntigravityCLIUsage.map(assist: json("{}"), summary: nil, models: models, claims: nil).windows
        XCTAssertEqual(windows.map(\.id), ["session"])
        XCTAssertEqual(windows[0].usedPercent ?? -1, 20, accuracy: 1e-9)
    }

    func testBothHostsMergeAndDailyBucketWins() async throws {
        let daily = try json(#"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.5}]},\#(argon)]}"#)
        let prod = try json(#"{"groups":[\#(shared),{"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"argon-w","window":"weekly","remainingFraction":0.9}]}]}"#)
        var asked: [String] = []
        let merged = await AntigravityCLIUsage.quotaSummary { host in
            asked.append(host)
            return host.contains("daily") ? daily : prod
        }
        XCTAssertEqual(asked, AntigravityCLIUsage.quotaHosts)
        let windows = try map(merged)
        XCTAssertEqual(windows.map(\.id), ["session", "weekly", "argon-weekly", "claude-session", "claude-weekly"])
        XCTAssertEqual(windows[0].usedPercent ?? -1, 50, accuracy: 1e-9)   // daily wins over production's 20
        XCTAssertEqual(windows[1].usedPercent ?? -1, 10, accuracy: 1e-9)   // missing on daily, filled from production
        XCTAssertEqual(windows[2].usedPercent ?? -1, 64.5, accuracy: 1e-9) // daily Argon wins
    }

    func testCompleteDailyAnswerSkipsProduction() async throws {
        let daily = try json(#"{"groups":[\#(shared)]}"#)
        var asked: [String] = []
        let summary = await AntigravityCLIUsage.quotaSummary { host in asked.append(host); return daily }
        XCTAssertEqual(asked, [AntigravityCLIUsage.quotaHosts[0]])
        XCTAssertEqual(try map(summary).count, 4)
    }

    func testOneHostFailingStillAnswersFromTheOther() async throws {
        let prod = try json(#"{"groups":[\#(shared)]}"#)
        let fromProd = await AntigravityCLIUsage.quotaSummary { host in
            if host.contains("daily") { throw ProviderError.unavailable("down") }
            return prod
        }
        XCTAssertEqual(try map(fromProd).count, 4)
        let daily = try json(#"{"groups":[\#(shared)]}"#)
        var asked: [String] = []
        let fromDaily = await AntigravityCLIUsage.quotaSummary { host in
            asked.append(host)
            if host.contains("daily") { return daily }
            throw ProviderError.network("offline")
        }
        XCTAssertEqual(try map(fromDaily).count, 4)
        let none = await AntigravityCLIUsage.quotaSummary { _ in throw ProviderError.network("offline") }
        XCTAssertNil(none)
    }

    func testUserAgentUsesHubIdentity() {
        XCTAssertTrue(AntigravityCLIUsage.userAgent.hasPrefix("antigravity/hub/2.24.0 (aidev_client; os_type=darwin; arch="))
    }

    // MARK: Google refresh

    private func reply(_ status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(status: status, data: Data(body.utf8), headers: [:])
    }

    func testInvalidGrantMeansSignInNeeded() {
        for status in [400, 401, 403] {
            XCTAssertThrowsError(try IDEAuth.refreshed(reply(status, #"{"error":"invalid_grant"}"#))) { error in
                XCTAssertEqual((error as? ProviderError)?.needsSignIn, true, "status \(status)")
            }
        }
    }

    func testOtherRefreshRepliesAreFailuresNotSignOuts() {
        let cases: [(Int, String)] = [
            (400, #"{"error":"invalid_request"}"#), (400, "not json"),
            (401, #"{"error":"unauthorized_client"}"#), (401, ""), (403, #"{"error":"access_denied"}"#),
        ]
        for (status, body) in cases {
            XCTAssertThrowsError(try IDEAuth.refreshed(reply(status, body))) { error in
                let failure = error as? ProviderError
                XCTAssertNotNil(failure, "status \(status)")
                XCTAssertEqual(failure?.needsSignIn, false, "status \(status)")
            }
        }
        XCTAssertThrowsError(try IDEAuth.refreshed(reply(503, "{}"))) { XCTAssertEqual(($0 as? ProviderError)?.needsSignIn, false) }
        XCTAssertThrowsError(try IDEAuth.refreshed(reply(429, "{}"))) { XCTAssertEqual(($0 as? ProviderError)?.needsSignIn, false) }
    }

    func testInvalidClientStillTriesTheNextSecret() {
        XCTAssertThrowsError(try IDEAuth.refreshed(reply(401, #"{"error":"invalid_client"}"#))) { error in
            guard case IDEAuth.RefreshFailure.invalidClient = error else { return XCTFail("\(error)") }
        }
    }

    func testSuccessfulRefreshReturnsTokens() throws {
        let fresh = try IDEAuth.refreshed(reply(200, #"{"access_token":"new","id_token":"id","expires_in":1800}"#))
        XCTAssertEqual(fresh.accessToken, "new")
        XCTAssertEqual(fresh.idToken, "id")
        XCTAssertEqual(fresh.expiresIn, 1800)
        XCTAssertThrowsError(try IDEAuth.refreshed(reply(200, "{}")))
    }
}
