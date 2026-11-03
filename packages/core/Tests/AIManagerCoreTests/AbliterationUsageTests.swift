import Foundation
import XCTest
@testable import AIManagerCore

final class AbliterationUsageTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }

    func testCreditsBalanceOverageAndZeroLimit() throws {
        let usage = try AbliterationUsage.map(json(#"{"data":{"total_credits":25,"total_usage":5}}"#))
        XCTAssertEqual(usage.windows.first?.usedPercent, 20)
        XCTAssertEqual(usage.sections.first?.rows.map(\.value), ["$20.00", "$5.00", "$25.00"])
        XCTAssertNil(usage.cost)
        XCTAssertNil(usage.windows.first?.resetsAt)
        let overage = try AbliterationUsage.map(json(#"{"data":{"total_credits":10,"total_usage":12}}"#))
        XCTAssertEqual(overage.windows.first?.usedPercent, 100)
        XCTAssertEqual(overage.sections.first?.rows.first?.value, "$0.00")
        let empty = try AbliterationUsage.map(json(#"{"data":{"total_credits":0,"total_usage":0}}"#))
        XCTAssertTrue(empty.windows.isEmpty)
        XCTAssertEqual(empty.sections.first?.rows.first?.value, "$0.00")
    }

    func testRejectsCoercibleAndInvalidAmounts() throws {
        for value in [#""10""#, "true", "null", "-1", "{}", "[]"] {
            for field in ["total_credits", "total_usage"] {
                var object: [String: Any] = ["total_credits": 10, "total_usage": 2]
                object[field] = try JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed])
                XCTAssertThrowsError(try AbliterationUsage.map(JSON(["data": object])), "\(field): \(value)")
            }
        }
        XCTAssertThrowsError(try AbliterationUsage.map(JSON(["data": ["total_credits": Double.infinity, "total_usage": 2]])))
        XCTAssertThrowsError(try AbliterationUsage.map(json("{}")))
    }

    func testFetchUsesBearerCreditsEndpointAndMapsHttpFailures() async throws {
        let result = try await AbliterationUsage.fetch(key: "synthetic-key") { url, headers in
            XCTAssertEqual(url, "https://api.abliteration.ai/v1/credits")
            XCTAssertEqual(headers["Authorization"], "Bearer synthetic-key")
            return HTTPResponse(status: 200, data: Data(#"{"data":{"total_credits":10,"total_usage":1}}"#.utf8), headers: [:])
        }
        XCTAssertEqual(result.windows.first?.usedPercent, 10)
        for status in [201, 401, 403, 429, 500] {
            do {
                _ = try await AbliterationUsage.fetch(key: "synthetic-key") { _, _ in
                    HTTPResponse(status: status, data: Data(), headers: [:])
                }
                XCTFail("Accepted HTTP \(status)")
            } catch let error as ProviderError {
                switch (status, error) {
                case (401, .unauthorized), (403, .unauthorized), (429, .rateLimited), (500, .unavailable), (201, .http): break
                default: XCTFail("Wrong HTTP \(status) error: \(error)")
                }
            }
        }
        let field = try XCTUnwrap(ProviderCatalog.abliteration.fields.first)
        XCTAssertEqual(field.key, "apiKey")
        XCTAssertEqual(field.env, ["ABLITERATION_API_KEY"])
        XCTAssertTrue(field.secure)
    }
}
