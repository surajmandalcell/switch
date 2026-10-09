import Foundation

extension ProviderCatalog {
    static let linkup = ProviderSpec(
        id: "linkup", name: "Linkup",
        fields: [.apiKey("LINKUP_API_KEY")],
        dashboard: "https://app.linkup.so",
        usage: { credential in
            let key = try credential.require("apiKey")
            let json = try await HTTP.json("https://api.linkup.so/v1/credits/balance", headers: HTTP.bearer(key))
            return try LinkupUsage.map(json)
        })
}

enum LinkupUsage {
    static func map(_ json: JSON) throws -> ProviderUsage {
        guard let balance = json["balance"].double, balance.isFinite else {
            throw ProviderError.parse("Linkup returned an unrecognized credit balance.")
        }
        return ProviderUsage(
            cost: UsageCost(balance: balance),
            sections: [UsageSection("Account balance", [UsageRow("Credit balance", Fmt.money(balance))])],
            plan: "API")
    }
}
