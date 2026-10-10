import Foundation

extension ProviderCatalog {
    static let openrouter = ProviderSpec(
        id: "openrouter", name: "OpenRouter",
        fields: [.apiKey("OPENROUTER_API_KEY"),
                 CredentialField("managementKey", "Management API key", optional: true,
                                 placeholder: "Optional, adds 30-day activity", env: ["OPENROUTER_MANAGEMENT_API_KEY"])],
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
            var usage = try OpenRouterUsage.map(credits: credits, key: key)
            // Activity needs a management key: the one pasted here, or the main key when it is one.
            let manager = credential["managementKey"] ?? (key?.at("data.is_management_key").bool == true ? credential["apiKey"] : nil)
            if let manager, let section = await OpenRouterUsage.activity(token: manager) {
                usage.sections.append(section)
            }
            return usage
        })
}

enum OpenRouterUsage {
    private static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Account activity of the last 30 completed UTC days. Needs a management key; any failure hides the rows.
    static func activity(token: String, now: Date = Date()) async -> UsageSection? {
        let headers = HTTP.bearer(token)
        let latest = utcDay(now.addingTimeInterval(-86_400))
        async let history = try? HTTP.json("https://openrouter.ai/api/v1/activity", headers: headers)
        async let newest = try? HTTP.json("https://openrouter.ai/api/v1/activity?date=\(latest)", headers: headers)
        guard let history = await history, let newest = await newest else { return nil }
        return activitySection(rows: history["data"].array + newest["data"].array, now: now)
    }

    static func activitySection(rows: [JSON], now: Date) -> UsageSection? {
        let latest = utcDay(now.addingTimeInterval(-86_400))
        let cutoff = utcDay(now.addingTimeInterval(-30 * 86_400))
        var seen = Set<String>()
        var tokens = 0.0, requests = 0.0, spend = 0.0
        var models = Set<String>()
        for row in rows {
            guard let day = row["date"].string.map({ String($0.prefix(10)) }), day <= latest, day >= cutoff else { continue }
            let model = (row["model_permaslug"].string ?? row["model"].string)?.trimmingCharacters(in: .whitespaces)
            let identity = [day, model, row["endpoint_id"].string, row["provider_name"].string, row["workspace_id"].string]
                .map { $0 ?? "" }.joined(separator: "|")
            guard seen.insert(identity).inserted else { continue }
            tokens += max(0, row["prompt_tokens"].double ?? 0) + max(0, row["completion_tokens"].double ?? 0)
            requests += max(0, row["requests"].double ?? 0)
            spend += max(0, row["usage"].double ?? 0) + max(0, row["byok_usage_inference"].double ?? 0)
            if let model, !model.isEmpty { models.insert(model) }
        }
        return UsageSection("Activity (last 30 completed UTC days)", [
            UsageRow("Tokens", MajorsSpend.compact(Int(min(tokens, 1e15)))), UsageRow("Requests", Fmt.number(requests)),
            UsageRow("Models", String(models.count)), UsageRow("Spend", dollars(spend)),
        ])
    }

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
        if let credit, let total = credit["total_credits"].double, let spent = credit["total_usage"].double {
            sections.append(UsageSection("Credits", [UsageRow("Used", dollars(spent)), UsageRow("Total added", dollars(total))]))
        }
        if let keyData {
            var keyRows: [UsageRow] = []
            if let limit = keyData["limit"].double, limit > 0 {
                keyRows.append(UsageRow("API key limit", "\(dollars(limit)) (spending cap, not balance)"))
                if let left = keyData["limit_remaining"].double { keyRows.append(UsageRow("API key remaining", dollars(min(limit, left)))) }
                if let used = keyData["usage"].double { keyRows.append(UsageRow("API key used", dollars(used))) }
            } else {
                keyRows.append(UsageRow("API key limit", "No limit configured"))
            }
            if let reset = keyData["limit_reset"].string { keyRows.append(UsageRow("Reset window", reset)) }
            sections.append(UsageSection("API key", keyRows))
        }
        guard !windows.isEmpty || cost != nil || !sections.isEmpty else {
            throw ProviderError.parse("OpenRouter returned no credit or key data.")
        }
        let plan = keyData?["is_free_tier"].bool.map { $0 ? "Free tier" : "Pay as you go" }
        return ProviderUsage(windows: windows, cost: cost, sections: sections, plan: plan)
    }
}
