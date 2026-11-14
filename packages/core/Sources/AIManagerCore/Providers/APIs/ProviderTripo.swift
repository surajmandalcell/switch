import Foundation

// Billing contract: CodexBar 5927aafa6 (MIT), copyright 2026 Peter Steinberger.
extension ProviderCatalog {
    static let tripo = ProviderSpec(
        id: "tripo", name: "Tripo",
        fields: [.apiKey("TRIPO_API_KEY")],
        dashboard: "https://developers.tripo3d.ai/en/keys",
        usage: { try await TripoUsage.fetch(key: $0.require("apiKey")) })
}

enum TripoUsage {
    typealias Send = @Sendable (String, [String: String]) async throws -> HTTPResponse
    static let liveSend: Send = { try await HTTP.send($0, headers: $1) }

    static func fetch(key: String, send: Send = liveSend) async throws -> ProviderUsage {
        let response = try await send("https://openapi.tripo3d.ai/v3/account/balance", HTTP.bearer(key))
        try HTTP.check(response)
        guard response.status == 200 else {
            throw ProviderError.http(response.status, "Tripo returned an unexpected balance response.")
        }
        return try map(response.json())
    }

    /// `balance` is already the available credit amount; `frozen` is a separate reservation. Both are credits, not money.
    static func map(_ json: JSON) throws -> ProviderUsage {
        guard let code = json["code"].raw as? NSNumber, !JSON.isBoolean(json["code"].raw), json.at("data").exists else {
            throw ProviderError.parse("Tripo returned an unrecognized balance response.")
        }
        guard code.intValue == 0 else { throw ProviderError.unavailable("Tripo request failed. Try refreshing later.") }
        func credits(_ value: JSON) throws -> Double {
            guard let number = value.raw as? NSNumber, !JSON.isBoolean(value.raw),
                  number.doubleValue.isFinite, number.doubleValue >= 0 else {
                throw ProviderError.parse("Tripo returned invalid credit amounts.")
            }
            return number.doubleValue
        }
        let balance = try credits(json.at("data.balance"))
        let reserved = try credits(json.at("data.frozen"))
        return ProviderUsage(windows: [], sections: [UsageSection("Credits", [
            UsageRow("Balance", Fmt.number(balance, digits: 2)),
            UsageRow("Reserved", Fmt.number(reserved, digits: 2)),
        ])])
    }
}
