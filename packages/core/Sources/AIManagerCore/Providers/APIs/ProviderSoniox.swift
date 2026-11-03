import Foundation

// Billing contract: CodexBar 897bff3 (MIT), copyright 2026 Peter Steinberger.
extension ProviderCatalog {
    static let soniox = ProviderSpec(
        id: "soniox", name: "Soniox",
        fields: [CredentialField("apiKey", "Organization API key", env: ["SONIOX_ORG_API_KEY"])],
        dashboard: "https://console.soniox.com",
        statusPage: "https://status.soniox.com",
        usage: { try await SonioxUsage.fetch(key: $0.require("apiKey")) })
}

enum SonioxUsage {
    typealias Send = @Sendable (String, [String: String]) async throws -> HTTPResponse
    static let liveSend: Send = { try await HTTP.send($0, headers: $1) }

    static func fetch(key: String, send: Send = liveSend) async throws -> ProviderUsage {
        func get(_ path: String) async throws -> JSON {
            let response = try await send("https://api.soniox.com/v1/organization/\(path)", HTTP.bearer(key))
            if response.status == 403 {
                throw ProviderError.http(403, "Soniox needs an organization API key with Balance and spend and Usage and limits access. Project API keys do not work.")
            }
            try HTTP.check(response)
            guard response.status == 200 else {
                throw ProviderError.http(response.status, "Soniox returned an unexpected billing response.")
            }
            return try response.json()
        }
        let balance = try await get("balance")
        let monthly = try await get("usage/monthly")
        return try map(balance: balance, monthly: monthly)
    }

    static func map(balance: JSON, monthly: JSON) throws -> ProviderUsage {
        func invalid(_ field: String) -> ProviderError {
            .parse("Soniox returned invalid billing data: \(field).")
        }
        func money(_ value: JSON, field: String, signed: Bool = false) throws -> Double {
            guard let raw = value.raw as? String else { throw invalid(field) }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
                  let amount = Double(text), amount.isFinite, signed || amount >= 0 else { throw invalid(field) }
            return amount
        }
        let available = try money(balance["available_balance_usd"], field: "available_balance_usd", signed: true)
        guard JSON.isBoolean(balance["invoice_billing_enabled"].raw),
              let invoiced = balance["invoice_billing_enabled"].bool else { throw invalid("invoice_billing_enabled") }
        let used = try money(monthly["usage_usd"], field: "usage_usd")
        let budget = try money(monthly["monthly_budget_usd"], field: "monthly_budget_usd")
        guard let month = monthly["month"].raw as? String,
              month.range(of: #"^[0-9]{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil,
              let start = ISO8601DateFormatter().date(from: "\(month)-01T00:00:00Z") else { throw invalid("month") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let reset = calendar.date(byAdding: .month, value: 1, to: start) else { throw invalid("month") }
        let window = budget > 0 ? UsageWindow(id: "monthly", title: "Monthly",
            usedPercent: min(100, used / budget * 100), resetsAt: reset,
            detail: "\(Fmt.money(used)) / \(Fmt.money(budget))") : nil
        var rows = [UsageRow(invoiced ? "Invoice billing" : "Prepaid", "USD")]
        if budget == 0 { rows.append(UsageRow("Monthly budget", Fmt.money(budget))) }
        return ProviderUsage(windows: window.map { [$0] } ?? [],
            cost: UsageCost(used: used, limit: budget, balance: invoiced ? nil : available,
                currency: "USD", period: "This month", resetsAt: reset),
            sections: [UsageSection("Billing", rows)])
    }
}
