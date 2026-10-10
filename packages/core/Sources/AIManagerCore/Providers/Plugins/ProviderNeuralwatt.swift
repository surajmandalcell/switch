import Foundation

extension ProviderCatalog {
    static let neuralwatt = ProviderSpec(
        id: "neuralwatt", name: "Neuralwatt",
        fields: [
            .apiKey("NEURALWATT_API_KEY"),
            CredentialField("baseURL", "Base URL", secure: false, optional: true,
                            placeholder: "https://api.neuralwatt.com"),
        ],
        dashboard: "https://portal.neuralwatt.com/dashboard",
        usage: { credential in
            let key = try credential.require("apiKey")
            var base = (credential["baseURL"] ?? "https://api.neuralwatt.com")
                .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            if !base.hasSuffix("/v1") { base += "/v1" }
            let json = try await HTTP.json("\(base)/quota", headers: HTTP.bearer(key))
            return try NeuralwattUsage.map(json)
        })
}

enum NeuralwattUsage {
    static func map(_ root: JSON) throws -> ProviderUsage {
        let balance = root["balance"]
        guard balance.exists else { throw ProviderError.parse("Neuralwatt response has no balance.") }
        func nonnegative(_ value: JSON) -> Double? { value.double.flatMap { $0 >= 0 ? $0 : nil } }
        func positive(_ value: Double?) -> Double? { value.flatMap { $0 > 0 ? $0 : nil } }
        let granted = positive(balance["total_credits_usd"].double)
        let used = nonnegative(balance["credits_used_usd"])
        let remaining = nonnegative(balance["credits_remaining_usd"])
            ?? { () -> Double? in
                guard let granted, let used else { return nil }
                return max(0, granted - used)
            }()
        guard remaining != nil || used != nil || granted != nil else {
            throw ProviderError.parse("Neuralwatt response has no credit balance fields.")
        }

        let sub = root["subscription"]
        let kwhUsed = nonnegative(sub["kwh_used"]), kwhLeft = nonnegative(sub["kwh_remaining"])
        let included = positive(sub["kwh_included"].double)
            ?? positive((kwhUsed ?? .nan) + (kwhLeft ?? .nan))
        let consumed = kwhUsed ?? { () -> Double? in
            guard let included, let kwhLeft else { return nil }
            return max(0, included - kwhLeft)
        }()
        let end = sub["current_period_end"].date, start = sub["current_period_start"].date
        var windows: [UsageWindow] = []
        if let included, let consumed,
           let window = UsageWindow.amounts(
               id: "subscription", title: "Subscription", used: consumed, limit: included, resetsAt: end,
               windowMinutes: end.flatMap { e in start.map { max(1, Int(e.timeIntervalSince($0) / 60)) } },
               unit: "kWh") {
            windows.append(window)
        }
        let allowance = root["key"]["allowance"]
        let allowanceLimit = allowance["limit_usd"].double ?? 0
        // The key window is named after its period: "Key Monthly".
        let keyTitle = "Key \((allowance["period"].string ?? "allowance").lowercased().capitalized)"
        if allowance["blocked"].bool == true {
            windows.append(UsageWindow(id: "key", title: keyTitle, usedPercent: 100))
        } else if let spent = allowance["spent_usd"].double,
                  let window = UsageWindow.amounts(id: "key", title: keyTitle, used: spent,
                                                   limit: allowanceLimit) {
            windows.append(window)
        }
        let plan = sub["plan"].string?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: " ")
        let accounting = balance["accounting_method"].string
        return ProviderUsage(
            windows: windows,
            cost: remaining.map { UsageCost(limit: granted, balance: $0, period: "Prepaid balance") },
            sections: [PluginFmt.renewal(sub["auto_renew"].bool == false || consumed == nil || included == nil ? nil : end)],
            plan: plan.map { "\($0.capitalized) plan" } ?? accounting?.capitalized)
    }
}
