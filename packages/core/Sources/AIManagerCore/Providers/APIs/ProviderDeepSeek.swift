import Foundation

extension ProviderCatalog {
    /// Balance only. Spend and token history live behind the Platform web session, which Switch does not take.
    static let deepseek = ProviderSpec(
        id: "deepseek", name: "DeepSeek",
        fields: [CredentialField("apiKey", "API key", env: ["DEEPSEEK_API_KEY", "DEEPSEEK_KEY"])],
        dashboard: "https://platform.deepseek.com/usage",
        statusPage: "https://status.deepseek.com",
        usage: { credential in
            try DeepSeekUsage.map(try await HTTP.json("https://api.deepseek.com/user/balance",
                                                      headers: HTTP.bearer(try credential.require("apiKey"))))
        })
}

enum DeepSeekUsage {
    /// `GET /user/balance`. All amounts are strings.
    static func map(_ json: JSON) throws -> ProviderUsage {
        let infos = json["balance_infos"].array
        guard json["is_available"].exists || !infos.isEmpty else {
            throw ProviderError.parse("DeepSeek returned an unexpected balance shape.")
        }
        let info = infos.first { $0["currency"].string == "USD" && ($0["total_balance"].double ?? 0) > 0 }
            ?? infos.first { ($0["total_balance"].double ?? 0) > 0 }
            ?? infos.first { $0["currency"].string == "USD" } ?? infos.first
        let currency = info?["currency"].string ?? "USD"
        let total = info?["total_balance"].double ?? 0
        let available = json["is_available"].bool ?? (total > 0)
        var rows: [UsageRow] = []
        if let paid = info?["topped_up_balance"].double { rows.append(UsageRow("Paid", Fmt.money(paid, currency: currency))) }
        if let granted = info?["granted_balance"].double { rows.append(UsageRow("Granted", Fmt.money(granted, currency: currency))) }
        if total <= 0 { rows.append(UsageRow("Status", "Add credits")) }
        else if !available { rows.append(UsageRow("Status", "Balance unavailable for API calls")) }
        return ProviderUsage(cost: UsageCost(balance: total, currency: currency), sections: [UsageSection(nil, rows)])
    }
}
