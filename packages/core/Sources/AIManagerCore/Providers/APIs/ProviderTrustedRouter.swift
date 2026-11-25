import Foundation

// Key contract: CodexBar bbc5e711b (MIT), copyright 2026 Peter Steinberger.
extension ProviderCatalog {
    static let trustedrouter = ProviderSpec(
        id: "trustedrouter", name: "TrustedRouter",
        fields: [.apiKey("TRUSTEDROUTER_API_KEY")],
        dashboard: "https://trustedrouter.com/console/api-keys",
        usage: { try await TrustedRouterUsage.fetch(key: $0.require("apiKey")) })
}

enum TrustedRouterUsage {
    typealias Send = @Sendable (String, [String: String]) async throws -> HTTPResponse
    static let liveSend: Send = { try await HTTP.send($0, headers: $1) }

    static func fetch(key: String, send: Send = liveSend) async throws -> ProviderUsage {
        let response = try await send("https://api.trustedrouter.com/v1/key", HTTP.bearer(key))
        try HTTP.check(response)
        guard response.status == 200 else {
            throw ProviderError.http(response.status, "TrustedRouter returned an unexpected key response.")
        }
        return try map(response.json())
    }

    /// Money fields are integer microdollars. A `null` limit is an unlimited key; a $0 limit shows its
    /// amounts without a bar. `limit_remaining` already leaves out in-flight requests, so it is not recomputed.
    static func map(_ json: JSON) throws -> ProviderUsage {
        let data = json["data"]
        func dollars(_ field: String) throws -> Double {
            let value = data[field]
            guard let number = value.raw as? NSNumber, !JSON.isBoolean(value.raw), number.doubleValue.isFinite,
                  number.doubleValue >= 0, number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue <= 9_007_199_254_740_991 else {
                throw ProviderError.parse("TrustedRouter returned invalid spend amounts.")
            }
            return number.doubleValue / 1_000_000
        }
        func optional(_ field: String) throws -> Double? { data[field].exists ? try dollars(field) : nil }
        // `exists` is false for both null and missing; a missing limit field is still malformed.
        guard let object = data.raw as? [String: Any], object.keys.contains("limit_microdollars"),
              object.keys.contains("limit_remaining_microdollars") else {
            throw ProviderError.parse("TrustedRouter returned an unrecognized response.")
        }
        let limit = try optional("limit_microdollars"), remaining = try optional("limit_remaining_microdollars")
        guard (limit == nil) == (remaining == nil) else {
            throw ProviderError.parse("TrustedRouter returned a limit without its remaining amount.")
        }
        var rows: [UsageRow] = []
        var windows: [UsageWindow] = []
        if let limit, let remaining {
            let spent = max(0, limit - remaining)
            if limit > 0 {
                windows.append(UsageWindow(id: "limit", title: "Key limit", usedPercent: min(100, spent / limit * 100),
                                           detail: "\(Fmt.money(spent)) / \(Fmt.money(limit))"))
            }
            rows += [UsageRow("Remaining", Fmt.money(remaining)), UsageRow("Limit", Fmt.money(limit))]
        } else {
            rows.append(UsageRow("Limit", "Unlimited"))
        }
        rows += [UsageRow("Today", Fmt.money(try dollars("usage_daily_microdollars"))),
                 UsageRow("This week", Fmt.money(try dollars("usage_weekly_microdollars"))),
                 UsageRow("This month", Fmt.money(try dollars("usage_monthly_microdollars"))),
                 UsageRow("Total usage", Fmt.money(try dollars("usage_microdollars")))]
        return ProviderUsage(windows: windows, sections: [UsageSection("Usage", rows)])
    }
}
