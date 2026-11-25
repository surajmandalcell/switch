import XCTest
@testable import AIManagerCore

/// Synthetic fixtures only. CodexBar bbc5e711b: TrustedRouter key limit and spend in microdollars.
final class TrustedRouterUsageTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }
    private func key(limit: String, remaining: String) throws -> JSON { try json(keyText(limit: limit, remaining: remaining)) }
    private func keyText(limit: String, remaining: String) -> String {
        (#"{"data":{"usage_microdollars":42000000,"usage_daily_microdollars":1500000,"usage_weekly_microdollars":2000000,"usage_monthly_microdollars":3000000,"limit_microdollars":\#(limit),"limit_remaining_microdollars":\#(remaining)}}"#)
    }

    func testLimitedUnlimitedAndZeroLimitKeys() throws {
        let limited = try TrustedRouterUsage.map(key(limit: "10000000", remaining: "7500000"))
        XCTAssertEqual(limited.windows.first?.usedPercent, 25)
        XCTAssertEqual(limited.windows.first?.detail, "$2.50 / $10.00")
        XCTAssertEqual(limited.sections.first?.rows.map(\.value),
                       ["$7.50", "$10.00", "$1.50", "$2.00", "$3.00", "$42.00"])
        let unlimited = try TrustedRouterUsage.map(key(limit: "null", remaining: "null"))
        XCTAssertTrue(unlimited.windows.isEmpty)
        XCTAssertEqual(unlimited.sections.first?.rows.first?.value, "Unlimited")
        let zero = try TrustedRouterUsage.map(key(limit: "0", remaining: "0"))
        XCTAssertTrue(zero.windows.isEmpty, "A $0 limit has no bar")
        XCTAssertEqual(zero.sections.first?.rows.prefix(2).map(\.value), ["$0.00", "$0.00"])
    }

    func testRejectsMalformedAmounts() throws {
        XCTAssertThrowsError(try TrustedRouterUsage.map(key(limit: "10000000", remaining: "null")))
        for bad in ["-1", "1.5", #""5""#, "true"] {
            XCTAssertThrowsError(try TrustedRouterUsage.map(key(limit: bad, remaining: "0")), bad)
        }
        XCTAssertThrowsError(try TrustedRouterUsage.map(json(#"{"data":{"usage_microdollars":1}}"#)))
        XCTAssertThrowsError(try TrustedRouterUsage.map(json("{}")))
    }

    func testFetchUsesBearerKeyEndpointAndIsRegistered() async throws {
        let result = try await TrustedRouterUsage.fetch(key: "synthetic-key") { url, headers in
            XCTAssertEqual(url, "https://api.trustedrouter.com/v1/key")
            XCTAssertEqual(headers["Authorization"], "Bearer synthetic-key")
            return HTTPResponse(status: 200, data: Data(self.keyText(limit: "null", remaining: "null").utf8), headers: [:])
        }
        XCTAssertEqual(result.sections.first?.rows.last?.value, "$42.00")
        do {
            _ = try await TrustedRouterUsage.fetch(key: "synthetic-key") { _, _ in HTTPResponse(status: 401, data: Data(), headers: [:]) }
            XCTFail("Accepted HTTP 401")
        } catch ProviderError.unauthorized {}
        XCTAssertTrue(ProviderCatalog.apisB.contains { $0.id.rawValue == "trustedrouter" })
        XCTAssertEqual(ProviderCatalog.trustedrouter.fields.first?.env, ["TRUSTEDROUTER_API_KEY"])
    }
}
