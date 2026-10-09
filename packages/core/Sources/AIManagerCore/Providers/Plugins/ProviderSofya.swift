import Foundation

extension ProviderCatalog {
    static let sofya = ProviderSpec(
        id: "sofya", name: "Sofya",
        fields: [.apiKey("SOFYA_API_KEY")],
        dashboard: "https://sofya.co/dashboard",
        usage: { credential in
            let key = try credential.require("apiKey")
            return try SofyaUsage.map(try await HTTP.json("https://sofya.co/v1/auth/me", headers: HTTP.bearer(key)))
        })
}

enum SofyaUsage {
    static func map(_ json: JSON) throws -> ProviderUsage {
        var rows: [UsageRow] = []
        for (key, label) in [("credits", "Available credits"), ("plan_credits", "Plan credits"), ("purchased_credits", "Purchased credits")] {
            if let value = json[key].double, value >= 0 { rows.append(UsageRow(label, Fmt.number(value, digits: 6))) }
        }
        guard !rows.isEmpty else { throw ProviderError.parse("Sofya returned an unrecognized account credit response.") }
        let freeTier = json["is_free_tier"].bool
        var windows: [UsageWindow] = []
        // Only free-tier credits refill monthly. The amount has no known limit, so no percent is shown.
        if freeTier == true, let reset = json["credits_reset_at"].date {
            windows.append(UsageWindow(id: "monthly", title: "Monthly credits", usedPercent: nil, resetsAt: reset))
        }
        return ProviderUsage(windows: windows, sections: [UsageSection("Account credits", rows)],
                             plan: freeTier == true ? "Free tier" : freeTier == false ? "Pay as you go" : nil)
    }
}
