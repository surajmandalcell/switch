import Foundation
import XCTest
@testable import AIManagerCore

final class ProvidersApisBTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }

    func testMistralSpendCreditsAndSubscription() throws {
        let usage = try json("""
        {"currency":"EUR","completion":{"models":{"large::1":{
          "input":[{"event_type":"api","billing_metric":"large","billing_group":"in","timestamp":"2026-10-02","value":1000,"value_paid":1000}],
          "output":[{"event_type":"api","billing_metric":"large","billing_group":"out","timestamp":"2026-10-02","value":500,"value_paid":500}]}}},
         "prices":[{"event_type":"api","billing_metric":"large","billing_group":"in","price":"0.000002"},
                   {"event_type":"api","billing_metric":"large","billing_group":"out","price":"0.000006"}]}
        """)
        let credits = try json(#"{"wallet_amount":12.5,"credit_notes_amount":2.25,"ongoing_usage_balance":1.5,"currency":"EUR"}"#)
        let html = #"<script>self.__next_f.push([1,"7:[\"$\",null,null,{\"budget\":{\"api_budget\":{\"usage_percentage\":1.1,\"initial_budget\":25.5,\"currency\":\"eur\",\"reset_at\":\"2026-10-01T00:00:00.000Z\",\"payg_enabled\":true}}}]\n"])</script>"#
        let result = try MistralUsage.map(usage: usage, credits: credits, subscriptionHTML: html)
        XCTAssertEqual(result.cost?.used ?? 0, 0.005, accuracy: 1e-9)
        XCTAssertEqual(result.cost?.balance, 13.25)
        XCTAssertEqual(result.cost?.currency, "EUR")
        XCTAssertEqual(result.windows.first?.title, "Included API")
        XCTAssertEqual(result.windows.first?.usedPercent ?? 0, 1.1, accuracy: 1e-9)
        XCTAssertNotNil(result.windows.first?.resetsAt)
        XCTAssertEqual(result.sections.first?.rows.first?.value, "1,000")
    }

    func testGroqActivity() throws {
        let activity = try json("""
        {"data":[{"organization_name":"Personal","model":"a","timestamp":1783900800,"num_requests":3,"n_context_tokens_total":100,"n_generated_tokens_total":40,"cost":0.01},
                 {"organization_name":"Personal","model":"a","timestamp":1783814400,"num_requests":2,"n_context_tokens_total":50,"n_generated_tokens_total":10,"cost":0.02}]}
        """)
        let result = try GroqUsage.map(activity, now: Date(timeIntervalSince1970: 1_783_900_800 + 3600))
        XCTAssertEqual(result.cost?.used ?? 0, 0.03, accuracy: 1e-9)
        XCTAssertEqual(result.organization, "Personal")
        XCTAssertEqual(result.sections[0].rows[1].value, "3")
        XCTAssertEqual(result.sections[0].rows[2].value, "140")
        XCTAssertEqual(result.sections[1].rows[1].value, "200")
        let payload = Data(#"{"https://groq.com/organization":{"id":"org_123"}}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(GroqUsage.organizationID(jwt: "h.\(payload).s"), "org_123")
    }

    func testBedrockCostExplorerMapping() throws {
        let page = try json("""
        {"ResultsByTime":[{"TimePeriod":{"Start":"2026-04-01","End":"2026-04-06"},"Groups":[
         {"Keys":["Claude Opus (Bedrock Edition)"],"Metrics":{"UnblendedCost":{"Amount":"30.00","Unit":"USD"}}},
         {"Keys":["Amazon EC2"],"Metrics":{"UnblendedCost":{"Amount":"5.00","Unit":"USD"}}}]}]}
        """)
        let result = try BedrockUsage.map([page], budget: 100, now: Date(timeIntervalSince1970: 1_775_000_000))
        XCTAssertEqual(result.cost?.used, 30)
        XCTAssertEqual(result.windows.first?.usedPercent, 30)
        XCTAssertEqual(result.sections.first?.rows.count, 1)
        XCTAssertNil(try BedrockUsage.map([page], budget: nil).windows.first)
    }

    /// AWS Signature Version 4 test suite, case "get-vanilla".
    func testSigV4AwsDocumentationVector() throws {
        let date = try XCTUnwrap(Fmt.iso("2015-08-30T12:36:00Z"))
        let headers = BedrockSigV4.sign(
            method: "GET", host: "example.amazonaws.com", path: "/", query: "", headers: [:], body: Data(),
            accessKeyID: "AKIDEXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", sessionToken: nil,
            region: "us-east-1", service: "service", date: date)
        XCTAssertEqual(headers["x-amz-date"], "20150830T123600Z")
        XCTAssertEqual(headers["authorization"],
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
            + "SignedHeaders=host;x-amz-date, "
            + "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    func testAzureOpenAIDeploymentList() throws {
        XCTAssertEqual(try AzureOpenAIUsage.endpoint("res.openai.azure.com/openai/v1/"), "https://res.openai.azure.com")
        XCTAssertThrowsError(try AzureOpenAIUsage.endpoint("http://res.openai.azure.com"))
        let list = try json(#"{"data":[{"id":"gpt4o-prod","model":"gpt-4o","status":"succeeded"},{"id":"mini","model":"gpt-4o-mini"}]}"#)
        let result = try AzureOpenAIUsage.map(list, models: false, host: "res.openai.azure.com")
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.sections.first?.rows.first?.value, "2")
        XCTAssertEqual(result.sections.first?.rows[1].value, "succeeded")
        XCTAssertEqual(result.organization, "res.openai.azure.com")
    }

    func testCommandCodeCreditsAndPlan() throws {
        let credits = try json("""
        {"credits":{"monthlyCredits":8.5,"purchasedCredits":0,"premiumMonthlyCredits":0,"opensourceMonthlyCredits":0},
         "windowLimits":{"fiveHour":{"cap":3,"used":0.75,"resetAt":1780000000000},"weekly":{"cap":15,"used":1.5,"resetAt":1780100000000}}}
        """)
        let sub = try json(#"{"success":true,"data":{"planId":"individual-pro","status":"active","currentPeriodEnd":"2026-11-01T00:00:00Z"}}"#)
        let result = try CommandCodeUsage.map(credits: credits, subscription: sub)
        XCTAssertEqual(result.windows.map(\.id), ["session", "weekly", "credits"])
        XCTAssertEqual(result.windows[0].usedPercent, 25)
        XCTAssertEqual(result.windows[0].windowMinutes, 300)
        XCTAssertEqual(result.windows[1].usedPercent, 10)
        XCTAssertEqual(result.windows[2].usedPercent ?? 0, 21.5 / 30 * 100, accuracy: 1e-9)
        XCTAssertEqual(result.plan, "Pro")
        XCTAssertEqual(try CommandCodeUsage.sessionCookie("abc"), "__Secure-commandcode_prod_.session_token=abc")
        XCTAssertEqual(try CommandCodeUsage.sessionCookie("x=1; better-auth.session_token=tok"), "better-auth.session_token=tok")
    }

    func testWayfinderGateway() throws {
        let metrics = """
        wayfinder_router_decision_latency_seconds_sum 0.5
        wayfinder_router_decision_latency_seconds_count 100
        """
        let result = WayfinderUsage.map(
            health: try json(#"{"status":"degraded","missing_keys":["A","B"]}"#),
            models: try json(#"{"models":[{"name":"m1"},{"name":"m2"}],"dry_run":false}"#),
            savings: try json(#"{"priced":true,"requests":10,"saved":1.5,"saved_pct":30,"by_route":{"fast":{"requests":7},"cheap":{"requests":3}}}"#),
            metrics: metrics)
        let gateway = try XCTUnwrap(result.sections.first?.rows)
        XCTAssertEqual(gateway[0].value, "Degraded, 2 keys missing")
        XCTAssertEqual(gateway[1].value, "2")
        XCTAssertEqual(gateway[2].value, "5 ms")
        XCTAssertEqual(result.sections[1].rows[0].value, "$1.50, 30% vs highest-cost route")
        XCTAssertEqual(result.sections[1].rows[1].label, "fast")
    }

    func testIBMBobProfileAndTeam() throws {
        let profile = try json("""
        {"instances":[{"instance_id":"instance-one","instance_name":"Personal","user_id":"user-one","plan_name":"Pro+","refresh_at":1788220800,
          "region_domain":"us-east.bob.ibm.com","teams":[{"id":"team-one","name":"Solo","budget_limit":40,"usage":10}]}]}
        """)
        let team = try json(#"{"usage":12.5,"budget_limit":80}"#)
        let result = try IBMBobUsage.map(profile: profile, teams: ["instance-one/team-one": team])
        XCTAssertEqual(result.windows.first?.usedPercent ?? 0, 12.5 / 80 * 100, accuracy: 1e-9)
        XCTAssertEqual(result.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_788_220_800))
        XCTAssertEqual(result.plan, "Pro+")
        XCTAssertEqual(result.sections.first?.rows.first?.label, "Personal - Solo")
        XCTAssertEqual(try IBMBobUsage.host("us-east.bob.ibm.com"), "api.us-east.bob.ibm.com")
        XCTAssertThrowsError(try IBMBobUsage.host("evil.example.com"))
    }

    func testWarpRequestLimitAndBonusGrants() throws {
        let reply = try json("""
        {"data":{"user":{"__typename":"UserOutput","user":{
          "requestLimitInfo":{"isUnlimited":false,"nextRefreshTime":"2026-02-28T19:16:33.462988Z","requestLimit":1500,"requestsUsedSinceLastRefresh":5},
          "bonusGrants":[{"requestCreditsGranted":20,"requestCreditsRemaining":10,"expiration":"2026-03-01T10:00:00Z"}],
          "workspaces":[{"bonusGrantsInfo":{"grants":[{"requestCreditsGranted":"15","requestCreditsRemaining":"5","expiration":"2026-03-15T10:00:00Z"}]}}]}}}}
        """)
        let result = try WarpUsage.map(reply)
        XCTAssertEqual(result.windows[0].usedPercent ?? 0, 5.0 / 1500 * 100, accuracy: 1e-9)
        XCTAssertNotNil(result.windows[0].resetsAt)
        XCTAssertEqual(result.windows[1].usedPercent ?? 0, 20.0 / 35 * 100, accuracy: 1e-9)
        XCTAssertEqual(result.windows[1].detail, "10 credits expires on Mar 1, 2026")
        XCTAssertThrowsError(try WarpUsage.map(try json(#"{"errors":[{"message":"bad"}]}"#)))
    }

    func testCatalogListsAllProviders() {
        XCTAssertEqual(ProviderCatalog.apisB.map(\.id.rawValue),
                       ["mistral", "groq", "bedrock", "azureopenai", "commandcode", "wayfinder", "ibmbob", "warp"])
    }
}
