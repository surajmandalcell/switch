import Foundation

// Billing contract: CodexBar 897bff3 (MIT), copyright 2026 Peter Steinberger.
extension ProviderCatalog {
    static let abliteration = ProviderSpec(
        id: "abliteration", name: "abliteration.ai",
        fields: [.apiKey("ABLITERATION_API_KEY")],
        dashboard: "https://abliteration.ai",
        usage: { try await AbliterationUsage.fetch(key: $0.require("apiKey")) })
}

enum AbliterationUsage {
    typealias Send = @Sendable (String, [String: String]) async throws -> HTTPResponse
    static let liveSend: Send = { try await HTTP.send($0, headers: $1) }

    static func fetch(key: String, send: Send = liveSend) async throws -> ProviderUsage {
        let response = try await send("https://api.abliteration.ai/v1/credits", HTTP.bearer(key))
        try HTTP.check(response)
        guard response.status == 200 else {
            throw ProviderError.http(response.status, "abliteration.ai returned an unexpected billing response.")
        }
        return try map(response.json())
    }

    static func map(_ json: JSON) throws -> ProviderUsage {
        func amount(_ value: JSON) throws -> Double {
            guard let number = value.raw as? NSNumber, !JSON.isBoolean(value.raw),
                  number.doubleValue.isFinite, number.doubleValue >= 0 else {
                throw ProviderError.parse("abliteration.ai returned invalid credit amounts.")
            }
            return number.doubleValue
        }
        let total = try amount(json.at("data.total_credits"))
        let used = try amount(json.at("data.total_usage"))
        let window = total > 0 ? UsageWindow(id: "credits", title: "Credits",
            usedPercent: min(100, used / total * 100),
            detail: "\(Fmt.money(used)) / \(Fmt.money(total))") : nil
        return ProviderUsage(windows: window.map { [$0] } ?? [], sections: [UsageSection("Credits", [
            UsageRow("Balance", Fmt.money(max(0, total - used))),
            UsageRow("Credits used", Fmt.money(used)), UsageRow("Credits", Fmt.money(total)),
        ])])
    }
}
