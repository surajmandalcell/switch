import Foundation

extension ProviderCatalog {
    static let moonshot = ProviderSpec(
        id: "moonshot", name: "Moonshot / Kimi Open Platform",
        fields: [
            .apiKey("MOONSHOT_API_KEY"),
            CredentialField("region", "Region", secure: false, optional: true, placeholder: "global or cn"),
        ],
        dashboard: "https://platform.moonshot.ai",
        usage: { credential in
            let key = try credential.require("apiKey")
            let china = credential["region"]?.lowercased() == "cn"
            let origin = china ? "https://api.moonshot.cn" : "https://api.moonshot.ai"
            let json = try await HTTP.json("\(origin)/v1/users/me/balance", headers: HTTP.bearer(key))
            return try MoonshotUsage.map(json, currency: china ? "CNY" : "USD")
        })
}

enum MoonshotUsage {
    static func map(_ json: JSON, currency: String = "USD") throws -> ProviderUsage {
        let data = json["data"]
        guard let balance = data["available_balance"].double, let cash = data["cash_balance"].double,
              json["code"].exists, json["status"].exists else {
            throw ProviderError.parse("Failed to parse the Moonshot balance response.")
        }
        guard json["code"].int == 0, json["status"].bool == true else {
            throw ProviderError.unavailable("Moonshot reported an error (code \(json["code"].int ?? -1)).")
        }
        var rows = [UsageRow("Cash balance", Fmt.money(cash, currency: currency))]
        if let voucher = data["voucher_balance"].double {
            rows.append(UsageRow("Voucher balance", Fmt.money(voucher, currency: currency)))
        }
        if cash < 0 { rows.append(UsageRow("In deficit", Fmt.money(-cash, currency: currency))) }
        let deficit = cash < 0 ? " · \(Fmt.money(-cash, currency: currency)) in deficit" : ""
        return ProviderUsage(
            cost: UsageCost(balance: balance, currency: currency),
            sections: [UsageSection("Balance", rows)],
            plan: "Balance: \(Fmt.money(balance, currency: currency))\(deficit)")
    }
}
