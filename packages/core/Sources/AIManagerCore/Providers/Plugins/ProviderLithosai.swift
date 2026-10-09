import Foundation

extension ProviderCatalog {
    static let lithosai = ProviderSpec(
        id: "lithosai", name: "LithosAI",
        fields: [.cookie("__Host-console_session and __Host-console_csrf from console.lithosai.cloud")],
        dashboard: "https://console.lithosai.cloud",
        usage: { credential in
            let cookie = try credential.require("cookie")
            var headers = ["Cookie": cookie, "Origin": "https://console.lithosai.cloud"]
            if let csrf = Fmt.cookie("__Host-console_csrf", in: cookie) { headers["X-Console-Csrf"] = csrf }
            let base = "https://console.lithosai.cloud"
            let me = try await HTTP.json("\(base)/api/me", headers: headers)
            guard let org = me.at("activeOrganization.id").string,
                  org.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
                throw ProviderError.parse("Could not parse LithosAI active organization.")
            }
            headers["X-Organization-Id"] = org
            let billing = try await HTTP.json("\(base)/api/billing", headers: headers)
            // Spend is optional: a broken report must not hide an authenticated balance.
            let end = utcDay(Date()), start = String(end.prefix(7)) + "-01"
            let spend = try? await HTTP.json("\(base)/api/billing/spend?start=\(start)&end=\(end)", headers: headers)
            return try LithosAIUsage.map(me: me, billing: billing, spend: spend, today: end)
        })
}

private func utcDay(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter.string(from: date)
}

enum LithosAIUsage {
    private static func money(_ value: Double) -> String {
        value > 0 && value < 0.01 ? "Less than $0.01" : Fmt.money(value)
    }

    /// `today` is the UTC day as yyyy-MM-dd.
    static func map(me: JSON, billing: JSON, spend: JSON?, today: String) throws -> ProviderUsage {
        guard let nanos = billing["balanceNanos"].double, let hasCard = billing["hasCard"].bool,
              let onHold = billing["onHold"].bool else {
            throw ProviderError.parse("Could not parse LithosAI billing.")
        }
        let balance = nanos / 1e9
        var rows = [UsageRow("Balance", money(balance)),
                    UsageRow("Payment card", hasCard ? "Added" : "Not added"),
                    UsageRow("Account status", onHold ? "On hold" : "Active")]
        if let days = spend?["days"].array, !days.isEmpty {
            var todayNanos = 0.0, monthNanos = 0.0
            for day in days {
                let amount = day["nanos"].double ?? 0
                monthNanos += amount
                if day["day"].string == today { todayNanos += amount }
            }
            rows.append(UsageRow("Today (UTC)", money(todayNanos / 1e9)))
            rows.append(UsageRow("This month (UTC)", money(monthNanos / 1e9)))
        } else {
            rows.append(UsageRow("Spend", "Unavailable"))
        }
        return ProviderUsage(cost: UsageCost(balance: balance, period: "Prepaid credits"),
                             sections: [UsageSection("Billing", rows)],
                             email: me.at("user.email").string, organization: me.at("activeOrganization.name").string)
    }
}
