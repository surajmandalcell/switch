import Foundation

extension ProviderCatalog {
    static let sailresearch = ProviderSpec(
        id: "sailresearch", name: "Sail Research",
        fields: [.apiKey("SAIL_API_KEY")],
        dashboard: "https://app.sailresearch.com",
        usage: { credential in
            let key = try credential.require("apiKey")
            let response = try await HTTP.send("https://api.sailresearch.com/v2/usage/summary?range=30d", headers: HTTP.bearer(key))
            if response.status == 402 {
                throw ProviderError.unauthorized("Sail Research disabled this API key because credits are exhausted.")
            }
            try HTTP.check(response)
            return try SailResearchUsage.map(try response.json())
        })
}

enum SailResearchUsage {
    static func map(_ json: JSON) throws -> ProviderUsage {
        guard json["object"].string == "usage.summary", let available = json["available"].bool,
              let hasBilling = json["has_metronome_customer"].bool, let balanceUnavailable = json["balance_unavailable"].bool,
              let spend = json["period_spend"].double, spend >= 0,
              let range = json["effective_range"].string else {
            throw ProviderError.parse("Sail Research returned an unrecognized billing summary.")
        }
        guard available else { throw ProviderError.unavailable("Sail Research billing data is unavailable.") }
        guard hasBilling else { throw ProviderError.unsupported("This Sail Research organization has no billing account.") }
        let labels = ["1h": "Last hour", "6h": "Last 6 hours", "24h": "Last 24 hours", "7d": "Last 7 days",
                      "30d": "Last 30 days", "period": "Billing period"]
        // Amounts arrive in cents.
        let balance = balanceUnavailable ? nil : json["balance"].double.map { $0 / 100 }
        return ProviderUsage(
            cost: UsageCost(used: spend / 100, balance: balance, period: labels[range] ?? range),
            sections: [UsageSection("Organization billing", [
                UsageRow("Credit balance", balance.map { Fmt.money($0) } ?? "Unavailable"),
                UsageRow("\(labels[range] ?? range) spend", Fmt.money(spend / 100)),
            ])], plan: "API key")
    }
}
