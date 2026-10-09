import Foundation

extension ProviderCatalog {
    static let atlascloud = ProviderSpec(
        id: "atlascloud", name: "Atlas Cloud",
        fields: [.apiKey("ATLASCLOUD_API_KEY")],
        dashboard: "https://www.atlascloud.ai/console",
        usage: { credential in
            let key = try credential.require("apiKey")
            return try AtlascloudUsage.map(try await HTTP.json("https://api.atlascloud.ai/public/v1/balance",
                                                               headers: HTTP.bearer(key)))
        })
}

enum AtlascloudUsage {
    static func map(_ json: JSON) throws -> ProviderUsage {
        guard json["object"].string == "balance", json["scope"].string == "account",
              json.at("available.currency").string == "usd", let balance = json.at("available.value").double else {
            throw ProviderError.parse("Atlas Cloud returned an unrecognized USD account balance.")
        }
        return ProviderUsage(cost: UsageCost(balance: balance),
                             sections: [.init("Account balance", [.init("Available balance", Fmt.money(balance))])])
    }
}
