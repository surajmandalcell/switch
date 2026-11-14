import Foundation
import XCTest
@testable import AIManagerCore

/// A 403 or 429 that carries a rate-limit signal is a rate limit, never a rejected sign-in.
final class HTTPRateLimitTests: XCTestCase {
    private func error(_ status: Int, _ headers: [String: String] = [:]) -> ProviderError? {
        do { try HTTP.check(HTTPResponse(status: status, data: Data(), headers: headers)); return nil }
        catch { return error as? ProviderError }
    }

    private func isRateLimited(_ error: ProviderError?) -> Bool {
        if case .rateLimited? = error { return true }
        return false
    }

    func testForbiddenWithARateLimitSignalIsARateLimit() {
        for headers in [["retry-after": "120"], ["x-ratelimit-remaining": "0"],
                        ["x-ratelimit-remaining-requests": "0"], ["ratelimit-remaining": "0"]] {
            let error = error(403, headers)
            XCTAssertTrue(isRateLimited(error), "\(headers) gave \(String(describing: error))")
            XCTAssertEqual(error?.needsSignIn, false)
        }
    }

    func testForbiddenWithoutASignalIsStillARejectedKey() {
        for headers in [[:], ["x-ratelimit-remaining": "57"]] {
            XCTAssertEqual(error(403, headers)?.needsSignIn, true, "\(headers)")
        }
        XCTAssertEqual(error(401, ["retry-after": "60"])?.needsSignIn, true)
    }

    func testRateLimitMessageNamesTheRetryTime() {
        XCTAssertEqual(error(429, ["retry-after": "120"])?.errorDescription,
                       "The provider is rate limiting usage checks. Try again in about 2 minutes.")
        XCTAssertEqual(error(403, ["retry-after": "5"])?.errorDescription,
                       "The provider is rate limiting usage checks. Try again in about 1 minute.")
        XCTAssertEqual(error(429)?.errorDescription,
                       "The provider is rate limiting usage checks. Switch will retry later.")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(HTTP.retryDelay(["retry-after": "Fri, 15 Jan 2027 08:10:00 GMT"], now: now), 600)
        XCTAssertNil(HTTP.retryDelay(["retry-after": "soon"], now: now))
        XCTAssertNil(HTTP.retryDelay(["retry-after": "1e300"], now: now))
    }
}
