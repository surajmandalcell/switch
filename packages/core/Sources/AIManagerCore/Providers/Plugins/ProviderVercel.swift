import Foundation

extension ProviderCatalog {
    static let vercel = ProviderSpec(
        id: "vercel", name: "Vercel AI Gateway",
        fields: [.apiKey("AI_GATEWAY_API_KEY")],
        dashboard: "https://vercel.com/d?to=%2F%5Bteam%5D%2F%7E%2Fai-gateway",
        usage: { credential in
            let key = try credential.require("apiKey")
            return try VercelUsage.map(try await HTTP.json("https://ai-gateway.vercel.sh/v1/credits", headers: HTTP.bearer(key)))
        })
}

enum VercelUsage {
    static func map(_ json: JSON) throws -> ProviderUsage {
        // Amounts arrive as decimal strings such as "12.34".
        guard let balance = json["balance"].double, let spent = json["total_used"].double, spent >= 0 else {
            throw ProviderError.parse("Vercel AI Gateway returned an unrecognized credit balance.")
        }
        return ProviderUsage(cost: UsageCost(used: spent, balance: balance, period: "Lifetime"))
    }
}
