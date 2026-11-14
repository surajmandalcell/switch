import Foundation
import XCTest
@testable import AIManagerCore

final class UpstreamFixesOpenRouterGrokMuseTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }

    private func spend(_ usage: ProviderUsage) -> [String: String] {
        let rows = usage.sections.first { $0.title == "Spend" }?.rows ?? []
        return Dictionary(uniqueKeysWithValues: rows.filter { $0.label != "Remaining" }.map { ($0.label, $0.value) })
    }

    // MARK: OpenRouter

    func testOpenRouterStandardKeyKeepsItsOwnSpendAndIgnoresListedKeys() throws {
        let key = try json(#"{"data":{"is_management_key":false,"usage_daily":1.5,"usage_weekly":2,"usage_monthly":3}}"#)
        let other = try json(#"{"usage_daily":99,"usage_weekly":99,"usage_monthly":99}"#)
        let rows = spend(try OpenRouterUsage.map(credits: nil, key: key, keys: [other]))
        XCTAssertEqual(rows, ["Today": "$1.50", "This week": "$2.00", "This month": "$3.00"])
    }

    func testOpenRouterManagementKeySumsListedKeys() throws {
        let key = try json(#"{"data":{"is_management_key":true,"usage":0,"usage_daily":0,"usage_weekly":0,"usage_monthly":0}}"#)
        let credits = try json(#"{"data":{"total_credits":100,"total_usage":40}}"#)
        let keys = [
            try json(#"{"usage_daily":1.25,"usage_weekly":5,"usage_monthly":10}"#),
            try json(#"{"usage_daily":0.75,"usage_weekly":2,"usage_monthly":20,"disabled":true}"#),
            try json(#"{"usage_weekly":1}"#),
        ]
        let usage = try OpenRouterUsage.map(credits: credits, key: key, keys: keys)
        XCTAssertEqual(spend(usage), ["Today": "$2.00", "This week": "$8.00", "This month": "$30.00"])
        XCTAssertEqual(usage.cost?.balance, 60)
    }

    func testOpenRouterManagementKeyWithNoKeysShowsZeroAndWithoutTheListShowsNoSpend() throws {
        let key = try json(#"{"data":{"is_management_key":true,"usage_daily":0,"usage_weekly":0,"usage_monthly":0}}"#)
        let empty = try OpenRouterUsage.map(credits: nil, key: key, keys: [])
        XCTAssertEqual(spend(empty), ["Today": "$0.00", "This week": "$0.00", "This month": "$0.00"])
        // A failed or capped listing is unknown, not zero.
        let unknown = try OpenRouterUsage.map(credits: nil, key: key, keys: nil)
        XCTAssertTrue(spend(unknown).isEmpty)
    }

    func testOpenRouterWorkspaceManagementKeyMapsWithoutCredits() throws {
        // /credits answers 403 for a workspace-scoped management key, so the credits payload is nil.
        let key = try json(#"{"data":{"is_management_key":true,"usage_daily":0,"usage_weekly":0,"usage_monthly":0}}"#)
        let usage = try OpenRouterUsage.map(credits: nil, key: key, keys: [try json(#"{"usage_daily":4,"usage_weekly":4,"usage_monthly":4}"#)])
        XCTAssertNil(usage.cost)
        XCTAssertEqual(spend(usage)["Today"], "$4.00")
    }

    // MARK: Grok

    private let grokPeriod = #""currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-01T00:00:00Z","end":"2026-07-08T00:00:00Z"}"#

    func testGrokPayAsYouGoCapAndUsedAreCentsShownAsDollars() throws {
        let usage = try GrokBuildUsage.map(billing: json(
            "{\"config\":{\(grokPeriod),\"onDemandCap\":{\"val\":2500},\"onDemandUsed\":{\"val\":500}}}"))
        let rows = try XCTUnwrap(usage.sections.first?.rows)
        XCTAssertEqual(rows[0].value, "$25.00 cap")
        XCTAssertEqual(rows[1].value, "$5.00")
        XCTAssertEqual(try XCTUnwrap(rows[1].progress), 0.2, accuracy: 1e-9)
    }

    func testGrokWithoutPayAsYouGoIsUnchanged() throws {
        let usage = try GrokBuildUsage.map(billing: json("{\"config\":{\(grokPeriod),\"onDemandCap\":{\"val\":0}}}"))
        XCTAssertEqual(usage.sections.first?.rows.map(\.value), ["Disabled"])
    }

    // MARK: Muse

    func testMuseWithoutUsageInventsNoWindow() throws {
        // Absent subs_usage means an idle 5-hour window or no first use; the week may still have usage, so no 0%.
        let usage = try MuseUsage.map(json(#"{"is_subs_active":true,"subs_tier_name":"Power Usage"}"#))
        XCTAssertEqual(usage.plan, "Power Usage")
        XCTAssertTrue(usage.windows.isEmpty)
        let rows = usage.sections.first?.rows ?? []
        XCTAssertEqual(rows.first { $0.label == "Quota" }?.value, "Not included in this login response")
    }

    func testMuseReportedUsageIsUnchanged() throws {
        let usage = try MuseUsage.map(json("""
        {"is_subs_active":true,"subs_tier_name":"Power Usage",
         "subs_usage":{"window":{"used_percent":12,"window_duration_mins":300},"weekly":{"used_percent":3}}}
        """))
        XCTAssertEqual(usage.windows.map(\.usedPercent), [12, 3])
    }
}
