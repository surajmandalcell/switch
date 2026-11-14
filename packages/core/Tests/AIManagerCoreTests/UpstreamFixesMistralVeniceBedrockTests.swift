import Foundation
import XCTest
@testable import AIManagerCore

final class UpstreamFixesMistralVeniceBedrockTests: XCTestCase {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }

    // MARK: Mistral

    private func mistral(status: Int, location: String?) async throws -> JSON {
        try await MistralUsage.json("https://admin.mistral.ai/api/billing/v2/usage", headers: [:]) { _, _ in
            HTTPResponse(status: status, data: Data("{}".utf8), headers: location.map { ["location": $0] } ?? [:])
        }
    }

    func testMistralLoginRedirectMeansSignInAgain() async throws {
        for status in [301, 302, 303, 307, 308] {
            do {
                _ = try await mistral(status: status, location: "https://auth.mistral.ai/self-service/login/browser?return_to=x")
                XCTFail("Accepted redirect \(status)")
            } catch let error as ProviderError {
                guard case .unauthorized = error else { return XCTFail("Wrong error: \(error)") }
                XCTAssertTrue(error.needsSignIn)
            }
        }
    }

    func testMistralOtherRedirectsStayApiFailures() async throws {
        for location in [nil, "https://auth.mistral.ai/other", "https://evil.example/self-service/login",
                         "http://auth.mistral.ai/self-service/login", "https://auth.mistral.ai/self-service/loginx"] {
            do {
                _ = try await mistral(status: 302, location: location)
                XCTFail("Accepted redirect to \(location ?? "nil")")
            } catch let error as ProviderError {
                XCTAssertEqual(error, .http(302, ""), location ?? "nil")
            }
        }
        let ok = try await mistral(status: 200, location: nil)
        XCTAssertTrue(ok.exists)
    }

    // MARK: Venice

    func testVeniceBlockedCallsKeepKnownBalance() throws {
        let usd = try VeniceUsage.map(json(#"{"canConsume":false,"consumptionCurrency":"USD","balances":{"usd":5.25}}"#))
        XCTAssertEqual(usd.windows[0].detail, "$5.25")
        XCTAssertEqual(usd.windows[0].usedPercent, 100)
        XCTAssertEqual(usd.cost?.balance, 5.25)
        let noCurrency = try VeniceUsage.map(json(#"{"canConsume":false,"balances":{"usd":5.25}}"#))
        XCTAssertEqual(noCurrency.windows[0].detail, "$5.25")
        let diem = try VeniceUsage.map(json(#"{"canConsume":false,"consumptionCurrency":"DIEM","balances":{"diem":3,"usd":5.25}}"#))
        XCTAssertEqual(diem.windows[0].detail, "DIEM 3.00")
        let none = try VeniceUsage.map(json(#"{"canConsume":false,"balances":{"diem":null,"usd":null}}"#))
        XCTAssertEqual(none.windows[0].detail, "Balance unavailable for API calls")
    }

    // MARK: Bedrock

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testBedrockCostExplorerIsCachedForSixHoursPerCredential() async throws {
        let counter = Counter()
        let send: BedrockUsage.Send = { _, _, _ in
            _ = counter.next()
            return HTTPResponse(status: 200, data: Data(#"{"ResultsByTime":[]}"#.utf8), headers: [:])
        }
        let cache = BedrockCostCache()
        // Noon UTC, so every probe below stays on the same Cost Explorer date range.
        let t0 = Date(timeIntervalSince1970: 1_774_958_400)
        func pages(_ key: String = "AKIA1", secret: String = "s1", at date: Date) async throws -> [JSON] {
            try await BedrockUsage.costPages(keyID: key, secret: secret, token: nil, now: date, send: send, cache: cache)
        }
        _ = try await pages(at: t0)
        _ = try await pages(at: t0.addingTimeInterval(5 * 3600))
        XCTAssertEqual(counter.count, 1)
        // A changed secret or key misses the cache.
        _ = try await pages(secret: "s2", at: t0.addingTimeInterval(60))
        XCTAssertEqual(counter.count, 2)
        _ = try await pages("AKIA2", at: t0.addingTimeInterval(60))
        XCTAssertEqual(counter.count, 3)
        // After 6 hours the original entry is fetched again.
        _ = try await pages(at: t0.addingTimeInterval(6 * 3600 + 1))
        XCTAssertEqual(counter.count, 4)
        _ = try await pages(at: t0.addingTimeInterval(6 * 3600 + 60))
        XCTAssertEqual(counter.count, 4)
    }

    func testBedrockFailureIsNotCached() async throws {
        let counter = Counter()
        let send: BedrockUsage.Send = { _, _, _ in
            _ = counter.next()
            return HTTPResponse(status: 500, data: Data(), headers: [:])
        }
        let cache = BedrockCostCache()
        for _ in 0..<2 {
            do {
                _ = try await BedrockUsage.costPages(keyID: "k", secret: "s", token: nil, now: Date(), send: send, cache: cache)
                XCTFail("Accepted HTTP 500")
            } catch is ProviderError {}
        }
        XCTAssertEqual(counter.count, 2)
    }
}
