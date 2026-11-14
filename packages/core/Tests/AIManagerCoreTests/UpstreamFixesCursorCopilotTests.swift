import XCTest
@testable import AIManagerCore

/// Synthetic fixtures only. Ports of the upstream OpenUsage fixes for Cursor spend and seats, the Cursor
/// token refresh, and Copilot on GitHub Enterprise Cloud (`*.ghe.com`).
final class UpstreamFixesCursorCopilotTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }

    // MARK: Cursor on-demand spend comes from the budget of its limit

    private func onDemand(_ spend: String, plan: String? = "Team", membership: String? = nil,
                          summary: String? = nil) throws -> ProviderUsage {
        try CursorUsage.map(
            usage: json(#"{"enabled":true,"planUsage":{"limit":2000,"totalPercentUsed":10,"autoPercentUsed":5,"apiPercentUsed":5},"spendLimitUsage":\#(spend)}"#),
            plan: plan.map { try json(#"{"planInfo":{"planName":"\#($0)"}}"#) }, credits: nil,
            membership: membership, email: nil, summary: summary.map { try json($0) })
    }

    func testIndividualCapIgnoresTheTeamPoolSpend() throws {
        // The member spent nothing of their own 5000-cent cap; the team pool spent 90000.
        let mapped = try onDemand(#"{"individualLimit":5000,"individualUsed":0,"individualRemaining":5000,"pooledLimit":200000,"pooledUsed":90000,"totalSpend":90000,"limitType":"user"}"#)
        XCTAssertEqual(mapped.cost?.used, 0)
        XCTAssertEqual(mapped.cost?.limit, 50)
    }

    func testIndividualPlanKeepsItsOwnNumbers() throws {
        let used = try onDemand(#"{"limitType":"individual","individualLimit":5000,"individualRemaining":4000,"individualUsed":1000}"#, plan: "Pro")
        XCTAssertEqual(used.cost?.used, 10)
        XCTAssertEqual(used.cost?.limit, 50)
        // A personal cap with no team pool still takes totalSpend when individualUsed reads 0.
        let total = try onDemand(#"{"individualLimit":5000,"individualUsed":0,"individualRemaining":4500,"totalSpend":1200}"#, plan: "Pro")
        XCTAssertEqual(total.cost?.used, 12)
        // No reported spend: the same budget's limit minus what is left.
        let inferred = try onDemand(#"{"individualLimit":10000,"individualRemaining":7500,"pooledUsed":12000,"totalSpend":12000}"#)
        XCTAssertEqual(inferred.cost?.used, 25)
    }

    func testTeamPoolShowsThePoolSpendNotOneMembers() throws {
        let mapped = try onDemand(#"{"limitType":"team","pooledLimit":50000,"pooledUsed":12000,"pooledRemaining":38000,"individualUsed":3400}"#)
        XCTAssertEqual(mapped.cost?.used, 120)
        XCTAssertEqual(mapped.cost?.limit, 500)
    }

    func testNoLimitStillShowsWhatWasSpent() throws {
        let mapped = try onDemand(#"{"individualUsed":0,"pooledUsed":0,"totalSpend":700}"#, plan: "Pro")
        XCTAssertEqual(mapped.cost?.used, 7)
        XCTAssertNil(mapped.cost?.limit)
    }

    // MARK: Cursor Team and Enterprise seats

    func testMembershipComesFromTheSummaryThenTheLocalRow() throws {
        XCTAssertEqual(CursorUsage.seatMembership(summary: try json(#"{"membershipType":" Enterprise "}"#), local: "pro"), "enterprise")
        XCTAssertEqual(CursorUsage.seatMembership(summary: nil, local: "Team"), "team")
        XCTAssertNil(CursorUsage.seatMembership(summary: try json(#"{"membershipType":""}"#), local: nil))
        XCTAssertEqual(CursorUsage.seatPlan("Pro", membership: "enterprise"), "enterprise")
        XCTAssertEqual(CursorUsage.seatPlan("Pro", membership: "pro"), "Pro")
        XCTAssertEqual(CursorUsage.resolvedPlanName("Pro", membership: "team"), "team")
        XCTAssertNil(CursorUsage.resolvedPlanName(nil, membership: nil))
        XCTAssertEqual(CursorUsage.resolvedPlanName("Ultra", membership: "enterprise"), "Ultra", "another plan name stays")
    }

    func testEnterpriseSeatReportedAsProReadsTheRequestBasedUsage() throws {
        let usage = try json(#"{"enabled":true,"planUsage":{"totalPercentUsed":10}}"#)
        XCTAssertFalse(CursorUsage.wantsFallback(usage: usage, planName: CursorUsage.seatPlan("Pro", membership: "pro"), planInfoUnavailable: false))
        XCTAssertTrue(CursorUsage.wantsFallback(usage: usage, planName: CursorUsage.seatPlan("Pro", membership: "enterprise"), planInfoUnavailable: false))

        let plan = try json(#"{"planInfo":{"planName":"Pro"}}"#)
        let requests = try json(#"{"gpt-4":{"numRequests":120,"maxRequestUsage":500}}"#)
        let summary = try json(#"{"membershipType":"enterprise","individualUsage":{"onDemand":{"enabled":true,"used":700,"limit":5000}}}"#)
        let mapped = try CursorUsage.map(usage: usage, plan: plan, credits: nil, membership: "pro", email: nil,
                                         requests: requests, summary: summary)
        XCTAssertEqual(mapped.windows.map(\.id), ["total", "requests"])
        XCTAssertEqual(mapped.cost?.used, 7)
        XCTAssertEqual(mapped.cost?.limit, 50)
        XCTAssertEqual(mapped.plan, "Enterprise")
    }

    func testTeamSeatWithPoolsTakesMissingOnDemandFromTheSummary() throws {
        let usage = try json(#"{"enabled":true,"planUsage":{"limit":2000,"totalPercentUsed":8,"autoPercentUsed":5,"apiPercentUsed":10}}"#)
        let plan = try json(#"{"planInfo":{"planName":"Pro"}}"#)
        let summary = try json(#"{"membershipType":"team","teamUsage":{"onDemand":{"enabled":true,"used":1500,"limit":10000}}}"#)
        let mapped = try CursorUsage.map(usage: usage, plan: plan, credits: nil, membership: nil, email: nil, summary: summary)
        XCTAssertEqual(mapped.windows.map(\.id), ["total", "auto", "api"])
        XCTAssertEqual(mapped.cost?.used, 15)
        XCTAssertEqual(mapped.cost?.limit, 100)
        XCTAssertEqual(mapped.plan, "Team")
    }

    func testIndividualPlanIgnoresTheSummaryAndKeepsItsPlan() throws {
        let usage = try json(#"{"enabled":true,"planUsage":{"limit":2000,"totalPercentUsed":8,"autoPercentUsed":5,"apiPercentUsed":10}}"#)
        let plan = try json(#"{"planInfo":{"planName":"Pro"}}"#)
        let summary = try json(#"{"membershipType":"pro","individualUsage":{"onDemand":{"enabled":true,"used":900,"limit":9000}}}"#)
        let mapped = try CursorUsage.map(usage: usage, plan: plan, credits: nil, membership: "pro", email: nil, summary: summary)
        XCTAssertNil(mapped.cost, "an individual seat with no on-demand budget keeps none")
        XCTAssertEqual(mapped.plan, "Pro")
    }

    func testAccountWithNoSubscriptionStillSaysSo() throws {
        let usage = try json(#"{"enabled":true}"#)
        let summary = try json(#"{"membershipType":"free"}"#)
        let plan = try json(#"{"planInfo":{"planName":"Pro"}}"#)
        XCTAssertThrowsError(try CursorUsage.map(usage: usage, plan: plan, credits: nil, membership: nil, email: nil, summary: summary)) { error in
            XCTAssertEqual(error as? ProviderError, .unavailable("No active Cursor subscription."))
        }
    }

    // MARK: Cursor token refresh

    private func reply(_ status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(status: status, data: Data(body.utf8), headers: [:])
    }

    func testOnlyARefusedRefreshTokenNeedsASignIn() {
        for status in [400, 401, 403] {
            XCTAssertThrowsError(try CursorUsage.renewal(reply(status, #"{"error":"invalid_grant"}"#)), "\(status)") {
                XCTAssertEqual($0 as? ProviderError, .unauthorized("Sign in to Cursor again."))
            }
        }
        XCTAssertThrowsError(try CursorUsage.renewal(reply(200, #"{"shouldLogout":true}"#))) {
            XCTAssertEqual($0 as? ProviderError, .unauthorized("Sign in to Cursor again."))
        }
    }

    func testOtherRefreshFailuresRetryLater() {
        for (status, body) in [(400, #"{"error":"invalid_request"}"#), (400, ""), (401, #"{"error":"temporarily_unavailable"}"#),
                               (401, "not json"), (403, "{}")] {
            XCTAssertThrowsError(try CursorUsage.renewal(reply(status, body)), "\(status) \(body)") { error in
                guard case ProviderError.http(let code, _) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(code, status)
                XCTAssertFalse((error as? ProviderError)?.needsSignIn ?? true)
            }
        }
        XCTAssertThrowsError(try CursorUsage.renewal(reply(429, "{}"))) {
            guard case ProviderError.rateLimited = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try CursorUsage.renewal(reply(503, "{}"))) {
            guard case ProviderError.unavailable = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try CursorUsage.renewal(reply(200, "{}"))) {
            guard case ProviderError.parse = $0 else { return XCTFail("\($0)") }
        }
    }

    func testASuccessfulRefreshReturnsTheNewTokens() throws {
        let renewed = try CursorUsage.renewal(reply(200, #"{"access_token":"new-access","refresh_token":"new-refresh"}"#))
        XCTAssertEqual(renewed.access, "new-access")
        XCTAssertEqual(renewed.refresh, "new-refresh")
        XCTAssertNil(try CursorUsage.renewal(reply(200, #"{"access_token":"only-access"}"#)).refresh)
    }

    // MARK: Copilot on GitHub Enterprise Cloud

    private func apps(_ text: String) throws -> JSON { try json(text) }

    func testGitHubComAccountIsUnchanged() throws {
        let file = try apps(#"{"github.com:Iv1.b507a08c87ecfe98":{"user":"Octo","oauth_token":"gho_a"}}"#)
        let login = try XCTUnwrap(CopilotUsage.login(file))
        XCTAssertEqual(login.host, "github.com")
        XCTAssertEqual(login.entry["oauth_token"].string, "gho_a")
        XCTAssertEqual(CopilotUsage.apiURL(login.host, "/copilot_internal/user"), "https://api.github.com/copilot_internal/user")
        XCTAssertEqual(CopilotUsage.identity(file), CredentialIdentity(key: "github:octo"))
    }

    func testTenantAccountCallsTheTenantsAPIHost() throws {
        for key in ["octocorp.ghe.com", "octocorp.ghe.com:Iv1.b507a08c87ecfe98"] {
            let file = try apps(#"{"\#(key)":{"user":"Kim","oauth_token":"ghu_t"}}"#)
            let login = try XCTUnwrap(CopilotUsage.login(file), key)
            XCTAssertEqual(login.host, "octocorp.ghe.com")
            XCTAssertEqual(login.entry["oauth_token"].string, "ghu_t")
            XCTAssertEqual(CopilotUsage.apiURL(login.host, "/copilot_internal/user"), "https://api.octocorp.ghe.com/copilot_internal/user")
            XCTAssertEqual(CopilotUsage.apiURL(login.host, "/user/orgs?per_page=100"), "https://api.octocorp.ghe.com/user/orgs?per_page=100")
            XCTAssertEqual(CopilotUsage.identity(file), CredentialIdentity(key: "github:octocorp.ghe.com:kim"))
        }
    }

    func testATokenStaysWithItsOwnHost() throws {
        // Both accounts present: github.com wins, and its token is never paired with the tenant host or the reverse.
        let both = try apps(#"{"acme.ghe.com":{"user":"t","oauth_token":"ghu_tenant"},"github.com":{"user":"g","oauth_token":"gho_github"}}"#)
        let login = try XCTUnwrap(CopilotUsage.login(both))
        XCTAssertEqual(login.host, "github.com")
        XCTAssertEqual(login.entry["oauth_token"].string, "gho_github")
        // Two tenants: the first key in sorted order, with its own token.
        let tenants = try apps(#"{"zeta.ghe.com":{"oauth_token":"z"},"alpha.ghe.com":{"oauth_token":"a"}}"#)
        let tenant = try XCTUnwrap(CopilotUsage.login(tenants))
        XCTAssertEqual(tenant.host, "alpha.ghe.com")
        XCTAssertEqual(tenant.entry["oauth_token"].string, "a")
        // An entry without a token is skipped.
        XCTAssertEqual(CopilotUsage.login(try apps(#"{"github.com":{"user":"g"},"acme.ghe.com":{"oauth_token":"t"}}"#))?.host, "acme.ghe.com")
    }

    func testOtherHostsStaySkipped() throws {
        for key in ["github.example.com", "evil.com", "github.com.evil.com", "octocorp.ghe.com.evil.com", "ghe.com", ".ghe.com",
                    "a.b.ghe.com", "-octo.ghe.com", "octo-.ghe.com", "Octocorp.ghe.com", "octo_corp.ghe.com", "notgithub.com"] {
            let file = try apps(#"{"\#(key)":{"user":"x","oauth_token":"secret"}}"#)
            XCTAssertNil(CopilotUsage.login(file), key)
            XCTAssertNil(CopilotUsage.identity(file), key)
        }
        XCTAssertFalse(CopilotUsage.isKnownHost("api.github.com"))
    }
}
