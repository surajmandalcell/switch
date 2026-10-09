import Foundation

extension ProviderCatalog {
    static let openrouter = ProviderSpec(
        id: "openrouter", name: "OpenRouter",
        fields: [.apiKey("OPENROUTER_API_KEY")],
        dashboard: "https://openrouter.ai/credits",
        statusPage: "https://status.openrouter.ai",
        usage: { credential in
            let headers = HTTP.bearer(try credential.require("apiKey"))
            // /credits has the balance, /key the key cap and period spend. One may fail without hiding the other.
            var firstError: Error?
            func load(_ path: String) async -> JSON? {
                do { return try await HTTP.json("https://openrouter.ai/api/v1/\(path)", headers: headers) } catch {
                    firstError = firstError ?? error
                    return nil
                }
            }
            let credits = await load("credits"), key = await load("key")
            if credits == nil && key == nil, let firstError { throw firstError }
            return try OpenRouterUsage.map(credits: credits, key: key)
        })
}

enum OpenRouterUsage {
    private static func dollars(_ value: Double) -> String { Fmt.money(max(0, value)) }

    /// `credits` and `key` are the raw `{ "data": ... }` payloads; either may be nil.
    static func map(credits: JSON?, key: JSON?) throws -> ProviderUsage {
        let credit = credits?["data"], keyData = key?["data"]
        var windows: [UsageWindow] = []
        var rows: [UsageRow] = []
        var cost: UsageCost?
        var sections: [UsageSection] = []

        if let keyData, let limit = keyData["limit"].double, limit > 0 {
            let remaining = keyData["limit_remaining"].double.map { min(limit, max(0, $0)) }
            let reset = keyData["limit_reset"].string?.lowercased()
            let used = remaining.map { limit - $0 } ?? keyData["usage_\(reset ?? "")"].double ?? keyData["usage"].double
            let minutes = ["daily": 1440, "weekly": 10080, "monthly": 43200][reset ?? ""]
            if let used, var window = UsageWindow.amounts(id: "key", title: "API key limit", used: used, limit: limit,
                                                          windowMinutes: minutes) {
                window.detail = "\(dollars(used)) / \(dollars(limit))"
                windows.append(window)
            }
        }
        if let credit, let total = credit["total_credits"].double, let spent = credit["total_usage"].double {
            if var window = UsageWindow.amounts(id: "credits", title: "Credits", used: spent, limit: total) {
                window.detail = "\(dollars(spent)) / \(dollars(total))"
                windows.append(window)
            }
            cost = UsageCost(used: max(0, spent), limit: total > 0 ? total : nil, balance: max(0, total - spent),
                             period: "Lifetime")
            rows.append(UsageRow("Remaining", dollars(total - spent)))
        }
        if let keyData {
            for (label, field) in [("Today", "usage_daily"), ("This week", "usage_weekly"), ("This month", "usage_monthly")] {
                if let value = keyData[field].double { rows.append(UsageRow(label, dollars(value))) }
            }
        }
        if !rows.isEmpty { sections.append(UsageSection("Spend", rows)) }
        guard !windows.isEmpty || cost != nil || !sections.isEmpty else {
            throw ProviderError.parse("OpenRouter returned no credit or key data.")
        }
        let plan = keyData?["is_free_tier"].bool.map { $0 ? "Free tier" : "Pay as you go" }
        return ProviderUsage(windows: windows, cost: cost, sections: sections, plan: plan)
    }
}
