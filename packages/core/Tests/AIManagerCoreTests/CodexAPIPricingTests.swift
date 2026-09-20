import Foundation
import XCTest
@testable import AIManagerCore

final class CodexAPIPricingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "CodexAPIPricingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testPricingUsesConfiguredModelAndCachedCatalogOffline() async throws {
        let catalog = Data(#"""
        {
          "gpt-5.6-sol": {
            "litellm_provider": "openai",
            "input_cost_per_token": 0.000004,
            "cache_read_input_token_cost": 0.0000004,
            "output_cost_per_token": 0.00002
          },
          "azure/gpt-5.6-sol": {
            "litellm_provider": "azure",
            "input_cost_per_token": 0.000005,
            "output_cost_per_token": 0.000025
          }
        }
        """#.utf8)
        let cache = root.appending(path: "model-pricing.json")
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let online = CodexAPIPricingResolver(
            cacheURL: cache, now: { instant }, fetch: { _ in catalog })

        let model = CodexAPIPricingResolver.configuredModel(
            in: Data("model = \"gpt-5.6-sol\" # shared default\n".utf8))
        XCTAssertEqual(model, "gpt-5.6-sol")
        let price = try await online.price(for: try XCTUnwrap(model))
        XCTAssertEqual(price?.model, "gpt-5.6-sol")
        XCTAssertEqual(price?.inputPerMillion, 4)
        XCTAssertEqual(try XCTUnwrap(price?.cachedInputPerMillion), 0.4, accuracy: 0.000_001)
        XCTAssertEqual(price?.outputPerMillion, 20)
        XCTAssertEqual(price?.inputEquivalent(for: 412_000_000), 1_648)
        XCTAssertEqual(price?.cachedInputEquivalent(for: 412_000_000), 164.8)
        XCTAssertEqual(price?.outputEquivalent(for: 412_000_000), 8_240)

        try FileManager.default.setAttributes(
            [.modificationDate: instant.addingTimeInterval(-CodexAPIPricingResolver.cacheTTL - 1)],
            ofItemAtPath: cache.path)
        let offline = CodexAPIPricingResolver(
            cacheURL: cache, now: { instant }, fetch: { _ in throw URLError(.notConnectedToInternet) })
        let offlinePrice = try await offline.price(for: "gpt-5.6-sol")
        XCTAssertEqual(offlinePrice, price)
    }
}
