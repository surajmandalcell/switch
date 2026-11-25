import Foundation
import XCTest
@testable import AIManagerCore

/// `Int(Double)` traps on NaN, infinity and values outside Int's range; provider JSON must never crash Switch.
final class JSONIntSafetyTests: XCTestCase {
    func testOutOfRangeNumbersReadAsNil() throws {
        for raw: Any in [1e300, -1e300, Double.infinity, -Double.infinity, Double.nan, 9.3e18, -9.3e18,
                         "1e300", "inf", "nan", "-1e19"] {
            XCTAssertNil(JSON(raw).int, "\(raw)")
        }
        let decoded = try JSON(data: Data(#"{"big":1e300,"neg":-1e300}"#.utf8))
        XCTAssertNil(decoded["big"].int)
        XCTAssertNil(decoded["neg"].int)
    }

    func testOrdinaryNumbersStillRead() {
        XCTAssertEqual(JSON(42).int, 42)
        XCTAssertEqual(JSON(42.9).int, 42)
        XCTAssertEqual(JSON(-7.5).int, -7)
        XCTAssertEqual(JSON("1700000000000").int, 1_700_000_000_000)
        XCTAssertEqual(JSON(9.2e18).int, 9_200_000_000_000_000_000)
        XCTAssertEqual(Fmt.int(Double(Int.max)), nil)
    }
}
