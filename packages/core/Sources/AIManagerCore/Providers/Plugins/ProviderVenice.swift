import Foundation

extension ProviderCatalog {
    static let venice = ProviderSpec(
        id: "venice", name: "Venice",
        fields: [.apiKey("VENICE_API_KEY", "VENICE_KEY")],
        dashboard: "https://venice.ai/settings/api",
        usage: { credential in
            let key = try credential.require("apiKey")
            return try VeniceUsage.map(try await HTTP.json("https://api.venice.ai/api/v1/billing/balance", headers: HTTP.bearer(key)))
        })
}

enum VeniceUsage {
    static func map(_ json: JSON) throws -> ProviderUsage {
        guard let canConsume = json["canConsume"].raw as? Bool, json["balances"].exists else {
            throw ProviderError.parse("Venice returned an unrecognized balance response.")
        }
        let currency = json["consumptionCurrency"].string?.uppercased()
        let diem = json.at("balances.diem").double, usd = json.at("balances.usd").double
        let allocation = json["diemEpochAllocation"].double
        func money(_ value: Double) -> String { String(format: "$%.2f USD remaining", value) }
        func tokens(_ value: Double) -> String { String(format: "DIEM %.2f remaining", value) }

        var used = 100.0
        var text = "No Venice API balance available"
        if !canConsume {
            text = "Balance unavailable for API calls"
        } else if currency == "USD", let usd, usd > 0 {
            used = 0; text = money(usd)
        } else if currency != "USD", let diem, let allocation, allocation > 0 {
            used = (allocation - diem) / allocation * 100
            text = String(format: "DIEM %.2f / %.2f epoch allocation", diem, allocation)
        } else if let diem, diem > 0 {
            used = 0; text = tokens(diem)
        } else if let usd, usd > 0 {
            used = 0; text = money(usd)
        }
        var rows: [UsageRow] = []
        if let diem { rows.append(UsageRow("DIEM", Fmt.number(diem, digits: 2))) }
        if let usd { rows.append(UsageRow("USD", Fmt.money(usd))) }
        return ProviderUsage(
            windows: [UsageWindow(id: "balance", title: "Balance", usedPercent: used, detail: text)],
            cost: usd.map { UsageCost(balance: $0) },
            sections: [UsageSection("Balances", rows)])
    }
}
