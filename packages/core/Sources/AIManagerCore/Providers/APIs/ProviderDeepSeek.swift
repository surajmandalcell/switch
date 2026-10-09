import Foundation

extension ProviderCatalog {
    static let deepseek = ProviderSpec(
        id: "deepseek", name: "DeepSeek",
        fields: [
            CredentialField("apiKey", "API key", optional: true, env: ["DEEPSEEK_API_KEY", "DEEPSEEK_KEY"]),
            CredentialField("token", "Platform session token", optional: true,
                            placeholder: "userToken from platform.deepseek.com (used when no API key)",
                            env: ["DEEPSEEK_PLATFORM_TOKEN", "DEEPSEEK_USER_TOKEN"]),
        ],
        dashboard: "https://platform.deepseek.com/usage",
        statusPage: "https://status.deepseek.com",
        usage: { credential in
            if let key = credential["apiKey"] {
                return try DeepSeekUsage.map(try await HTTP.json("https://api.deepseek.com/user/balance",
                                                                 headers: HTTP.bearer(key)))
            }
            guard let token = credential["token"] else {
                throw ProviderError.missingCredential("Add an API key or a platform session token for DeepSeek.")
            }
            let response = try await HTTP.send("https://platform.deepseek.com/api/v0/users/get_user_summary",
                                               headers: HTTP.bearer(token).merging(["x-client-platform": "web"]) { first, _ in first })
            try HTTP.check(response)
            return try DeepSeekUsage.mapSummary(try response.json())
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
        return result(total: total, paid: info?["topped_up_balance"].double, granted: info?["granted_balance"].double,
                      currency: currency, available: json["is_available"].bool ?? (total > 0))
    }

    /// Platform `get_user_summary`: wallets with balances as string or number.
    static func mapSummary(_ json: JSON) throws -> ProviderUsage {
        let codes = [json["code"].int, json["data"]["biz_code"].int]
        if codes.contains(40002) || codes.contains(40003) {
            throw ProviderError.unauthorized("DeepSeek rejected this session token. Paste a new one.")
        }
        let data = json.at("data.biz_data")
        guard data.exists else { throw ProviderError.parse("DeepSeek returned an unexpected summary shape.") }
        let normal = data["normal_wallets"].array, bonus = data["bonus_wallets"].array
        let currency = (normal + bonus).first { $0["currency"].string == "USD" }?["currency"].string
            ?? (normal + bonus).first?["currency"].string ?? "USD"
        func sum(_ wallets: [JSON]) -> Double {
            wallets.filter { ($0["currency"].string ?? "USD") == currency }.reduce(0) { $0 + ($1["balance"].double ?? 0) }
        }
        let paid = sum(normal), granted = sum(bonus)
        return result(total: paid + granted, paid: paid, granted: granted, currency: currency, available: paid + granted > 0)
    }

    private static func result(total: Double, paid: Double?, granted: Double?, currency: String,
                               available: Bool) -> ProviderUsage {
        var rows: [UsageRow] = []
        if let paid { rows.append(UsageRow("Paid", Fmt.money(paid, currency: currency))) }
        if let granted { rows.append(UsageRow("Granted", Fmt.money(granted, currency: currency))) }
        if total <= 0 { rows.append(UsageRow("Status", "Add credits")) }
        else if !available { rows.append(UsageRow("Status", "Balance unavailable for API calls")) }
        return ProviderUsage(cost: UsageCost(balance: total, currency: currency), sections: [UsageSection(nil, rows)])
    }
}
