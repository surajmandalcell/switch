import Foundation

extension ProviderCatalog {
    static let hyper = ProviderSpec(
        id: "hyper", name: "Charm Hyper",
        fields: [.init("apiKey", "API key", optional: true, env: ["HYPER_API_KEY"]),
                 .init("cookie", "Cookie header", optional: true, placeholder: "Cookie header from hyper.charm.land")],
        dashboard: "https://hyper.charm.land",
        usage: { credential in
            guard credential["apiKey"] != nil || credential["cookie"] != nil else {
                throw ProviderError.missingCredential("Add a Charm Hyper API key or a Cookie header from hyper.charm.land.")
            }
            let session = credential["apiKey"] == nil
            let headers = session ? ["Cookie": credential["cookie"] ?? ""] : HTTP.bearer(credential["apiKey"] ?? "")
            let response = try await HTTP.send("https://hyper.charm.land/v1/credits", headers: headers)
            if session, (300..<400).contains(response.status)
                || (response.status == 200 && response.headers["content-type"]?.lowercased().contains("text/html") == true) {
                throw ProviderError.unauthorized("Charm Hyper session expired. Paste a fresh Cookie header.")
            }
            try HTTP.check(response)
            var usage = try HyperUsage.map(try response.json())
            usage.plan = session ? "Browser session" : "API key"
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
