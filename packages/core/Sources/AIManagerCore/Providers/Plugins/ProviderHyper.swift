import Foundation

extension ProviderCatalog {
    static let hyper = ProviderSpec(
        id: "hyper", name: "Charm Hyper",
        fields: [.init("apiKey", "API key", env: ["HYPER_API_KEY"])],
        dashboard: "https://hyper.charm.land",
        usage: { credential in
            var usage = try HyperUsage.map(try await HTTP.json("https://hyper.charm.land/v1/credits",
                                                               headers: HTTP.bearer(try credential.require("apiKey"))))
            usage.plan = "API key"
            return usage
        })
}

enum HyperUsage {
    static func map(_ json: JSON) throws -> ProviderUsage {
        guard let balance = json["balance"].double, balance >= 0 else {
            throw ProviderError.parse("Charm Hyper balance must be a non-negative number.")
        }
        return ProviderUsage(cost: UsageCost(balance: balance, currency: "HC"),
                             sections: [.init("Hypercredits", [.init("Balance", "\(Fmt.number(balance, digits: 2)) HC")])])
    }
}
