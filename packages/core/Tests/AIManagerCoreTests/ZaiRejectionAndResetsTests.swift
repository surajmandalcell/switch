import Foundation
import XCTest
@testable import AIManagerCore

/// openusage a67a7835 (a 401 inside an HTTP 200 body) and d4fcdeee (banked Session and Weekly resets).
final class ZaiRejectionAndResetsTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }

    func testInBody401IsARejectedKey() throws {
        for body in [#"{"success":false,"code":401,"msg":"token expired"}"#, #"{"code":401}"#] {
            XCTAssertThrowsError(try ZaiUsage.map(json(body)), body) {
                guard case .unauthorized? = $0 as? ProviderError else { return XCTFail("\(body): \($0)") }
            }
        }
        // Other in-body errors keep their meaning.
        XCTAssertThrowsError(try ZaiUsage.map(json(#"{"success":false,"code":500,"msg":"busy"}"#))) {
            XCTAssertEqual(($0 as? ProviderError)?.needsSignIn, false)
        }
    }

    /// 2026-11-04 00:00 UTC; expiries are UTC+8 wall-clock text.
    private let now = Date(timeIntervalSince1970: 1_793_750_400)
    private let list = #"""
    {"code":200,"success":true,"data":{
      "fiveHourResets":[
        {"recordId":12,"available":true,"expireTime":"2026-11-10 08:00:00","grantType":"GLOBAL"},
        {"recordId":11,"available":true,"expireTime":"2026-11-06 20:00:00","grantType":"GLOBAL"},
        {"recordId":13,"available":false,"expireTime":"2026-11-07 08:00:00","grantType":"GLOBAL"},
        {"recordId":14,"available":true,"expireTime":"2026-11-03 08:00:00","grantType":"GLOBAL"}
      ],
      "weekResets":[{"recordId":21,"available":true,"expireTime":"2026-11-06 20:00:00","grantType":"GLOBAL"}]
    }}
    """#

    func testBankedResetsCountOnlyAvailableUnexpiredRecordsPerWindow() throws {
        let section = try XCTUnwrap(ZaiUsage.resets(json(list), now: now))
        XCTAssertEqual(section.title, "Limit resets")
        XCTAssertEqual(section.rows.map(\.label), ["Session", "Weekly"])
        XCTAssertTrue(section.rows[0].value.hasPrefix("2 available"), section.rows[0].value)
        XCTAssertTrue(section.rows[1].value.hasPrefix("1 available"), section.rows[1].value)
        // The earliest expiry is named: 2026-11-06 20:00 UTC+8 is 12:00 UTC.
        XCTAssertEqual(ZaiUsage.resetExpiry("2026-11-06 20:00:00"), Date(timeIntervalSince1970: 1_793_966_400))
        XCTAssertNil(ZaiUsage.resetExpiry("2026-11-06T20:00:00Z"))
    }

    func testNoBankedResetsOrAFailedListShowsNothing() throws {
        XCTAssertNil(ZaiUsage.resets(try json(#"{"success":true,"data":{"fiveHourResets":[],"weekResets":[]}}"#), now: now))
        XCTAssertNil(ZaiUsage.resets(try json(#"{"success":false,"msg":"error","data":null}"#), now: now))
    }
}
