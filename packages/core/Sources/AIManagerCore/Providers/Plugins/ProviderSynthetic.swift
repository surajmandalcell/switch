import Foundation

extension ProviderCatalog {
    static let synthetic = ProviderSpec(
        id: "synthetic", name: "Synthetic",
        fields: [.apiKey("SYNTHETIC_API_KEY")],
        usage: { credential in
            let key = try credential.require("apiKey")
            return try SyntheticUsage.map(try await HTTP.json("https://api.synthetic.new/v2/quotas", headers: HTTP.bearer(key)))
        })
}

enum SyntheticUsage {
    private static let percentUsed = ["percentUsed", "usedPercent", "usagePercent", "usage_percent", "used_percent", "percent_used", "percent"]
    private static let percentRemaining = ["percentRemaining", "remainingPercent", "remaining_percent", "percent_remaining"]
    private static let limits = ["limit", "messageLimit", "message_limit", "messages", "maxRequests", "max_requests", "requestLimit", "request_limit", "quota", "max", "total", "capacity", "allowance"]
    private static let useds = ["used", "usage", "usedMessages", "used_messages", "messagesUsed", "messages_used", "requests", "requestCount", "request_count", "consumed", "spent"]
    private static let remainings = ["remaining", "left", "available", "balance"]
    private static let resets = ["resetAt", "reset_at", "resetsAt", "resets_at", "renewAt", "renew_at", "renewsAt", "renews_at", "nextTickAt", "next_tick_at", "nextRegenAt", "next_regen_at", "periodEnd", "period_end", "expiresAt", "expires_at", "endAt", "end_at"]
    private static let plans = ["plan", "planName", "plan_name", "subscription", "subscriptionPlan", "tier", "package", "packageName"]
    private static let labels = ["name", "label", "type", "period", "scope", "title", "id"]

    private struct Quota {
        var window: UsageWindow
        var cost: UsageCost?
    }

    static func map(_ json: JSON) throws -> ProviderUsage {
        let root = json.raw is [Any] ? JSON(["quotas": json.raw as Any]) : json
        guard root.raw is [String: Any] else { throw ProviderError.parse("Failed to parse Synthetic response: expected an object or array.") }
        let data = root["data"]
        let slots: [(String, String, [JSON])] = [
            ("session", "Five-hour quota", [root["rollingFiveHourLimit"], data["rollingFiveHourLimit"]]),
            ("weekly", "Weekly tokens", [root["weeklyTokenLimit"], data["weeklyTokenLimit"]]),
            ("search", "Search hourly", [root.at("search.hourly"), data.at("search.hourly")]),
        ]
        var quotas: [Quota] = []
        let named = slots.map { id, title, candidates in
            candidates.first(where: isQuota).flatMap { parse($0, id: id, title: title) }
        }
        if named.contains(where: { $0 != nil }) {
            quotas = named.compactMap { $0 }
        } else {
            let candidates = [root["quotas"], root["quota"], root["limits"], root["usage"], root["entries"], root["subscription"], root["data"],
                              data["quotas"], data["quota"], data["limits"], data["usage"], data["entries"], data["subscription"]]
            for candidate in candidates {
                let found = collect(candidate)
                if !found.isEmpty {
                    quotas = found.enumerated().compactMap { index, quota in
                        parse(quota, id: "quota-\(index + 1)", title: first(quota, labels) ?? "Quota \(index + 1)")
                    }
                    break
                }
            }
        }
        guard !quotas.isEmpty else { throw ProviderError.parse("Failed to parse Synthetic response: missing quota data.") }
        return ProviderUsage(windows: quotas.map(\.window), cost: quotas.compactMap(\.cost).first,
                             plan: first(root, plans) ?? first(data, plans))
    }

    private static func isQuota(_ json: JSON) -> Bool {
        json.raw is [String: Any] && [limits, useds, remainings, percentUsed, percentRemaining].contains { number(json, $0) != nil }
    }

    private static func collect(_ json: JSON) -> [JSON] {
        if json.raw is [Any] { return json.array.flatMap(collect) }
        guard let object = json.raw as? [String: Any] else { return [] }
        return isQuota(json) ? [json] : object.keys.sorted().flatMap { collect(json[$0]) }
    }

    private static func parse(_ json: JSON, id: String, title: String) -> Quota? {
        func normalized(_ value: Double?) -> Double? { value.map { $0 <= 1 ? $0 * 100 : $0 } }
        var used = normalized(number(json, percentUsed))
        if used == nil, let left = normalized(number(json, percentRemaining)) { used = 100 - left }
        var amount: String?
        if used == nil {
            var limit = number(json, limits), spent = number(json, useds)
            let left = number(json, remainings)
            if limit == nil, let spent, let left { limit = spent + left }
            if spent == nil, let limit, let left { spent = limit - left }
            if let limit, let spent, limit > 0 {
                used = spent / limit * 100
                amount = "\(Fmt.number(spent)) / \(Fmt.number(limit))"
            }
        }
        guard let percent = used else { return nil }
        let reset = resets.lazy.compactMap { json[$0].date }.first
        let window = UsageWindow(id: id, title: title, usedPercent: percent, resetsAt: reset, windowMinutes: minutes(json), detail: amount)

        var cost: UsageCost?
        if let max = currency(json, ["maxCredits", "max_credits"]) {
            let left = currency(json, ["remainingCredits", "remaining_credits"])
            let spent = currency(json, ["usedCredits", "used_credits"]) ?? left.map { Swift.max(0, max - $0) } ?? window.usedPercent.map { $0 / 100 * max }
            cost = UsageCost(used: spent, limit: max, period: "Weekly", resetsAt: reset)
        }
        return Quota(window: window, cost: cost)
    }

    private static func minutes(_ json: JSON) -> Int? {
        for (keys, scale) in [(["windowMinutes", "window_minutes", "periodMinutes", "period_minutes"], 1.0),
                              (["windowHours", "window_hours", "periodHours", "period_hours"], 60),
                              (["windowDays", "window_days", "periodDays", "period_days"], 1440),
                              (["windowSeconds", "window_seconds", "periodSeconds", "period_seconds"], 1.0 / 60)] {
            if let value = number(json, keys) { return Int((value * scale).rounded()) }
        }
        return nil
    }

    private static func number(_ json: JSON, _ keys: [String]) -> Double? { keys.lazy.compactMap { json[$0].double }.first }
    private static func first(_ json: JSON, _ keys: [String]) -> String? { keys.lazy.compactMap { json[$0].string }.first }

    /// Reads "$36.00" or 36.
    private static func currency(_ json: JSON, _ keys: [String]) -> Double? {
        keys.lazy.compactMap { key -> Double? in
            json[key].double ?? json[key].string.flatMap { Double($0.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")) }
        }.first
    }
}
