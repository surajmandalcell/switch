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

    func testAutomaticRefreshWaitsForTheRetryTime() {
        let failed = Date(timeIntervalSince1970: 1_800_000_000)
        func due(_ error: ProviderError?, after seconds: TimeInterval) -> Bool {
            ProviderRefreshPolicy.isDue(lastError: error, failedAt: failed, now: failed + seconds, cooldown: 300)
        }
        let limited = error(429, ["retry-after": "7200"])
        if case .rateLimited(_, let retryAfter)? = limited { XCTAssertEqual(retryAfter, 7200) } else { XCTFail("\(String(describing: limited))") }
        XCTAssertFalse(due(limited, after: 7199))
        XCTAssertTrue(due(limited, after: 7200))
        // A short Retry-After never shortens the normal cooldown; other errors use the cooldown only.
        XCTAssertFalse(due(error(429, ["retry-after": "10"]), after: 299))
        XCTAssertTrue(due(error(429), after: 300))
        XCTAssertTrue(due(.unavailable("down"), after: 300))
        XCTAssertTrue(due(nil, after: 300))
        // A huge Retry-After is capped at one day.
        XCTAssertTrue(due(.rateLimited("x", retryAfter: 1e300), after: 86_400))
        XCTAssertTrue(due(.rateLimited("x", retryAfter: .nan), after: 300))
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
