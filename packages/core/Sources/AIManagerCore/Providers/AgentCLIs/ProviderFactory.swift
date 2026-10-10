import Foundation

extension ProviderCatalog {
    static let agentFactory = ProviderSpec(
        id: "factory", name: "Factory",
        fields: [CredentialField("apiKey", "API key", placeholder: "fk-...", env: ["FACTORY_API_KEY"])],
        dashboard: "https://app.factory.ai/settings/billing", statusPage: "https://status.factory.ai",
        usage: { credential in
            let headers = FactoryUsage.headers(try credential.require("apiKey"))
            let me = try await HTTP.json("https://api.factory.ai/api/app/auth/me", headers: headers)
            let billing = try? await HTTP.json("https://api.factory.ai/api/billing/limits", headers: headers)
            var legacy: JSON?
            if billing?["usesTokenRateLimitsBilling"].bool != true {
                let id = (me.at("userProfile.id").string ?? "")
                    .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                legacy = try? await HTTP.json(
                    "https://api.factory.ai/api/organization/subscription/usage?useCache=true&userId=\(id)",
                    headers: headers)
            }
            return try FactoryUsage.map(me: me, billing: billing, legacy: legacy, now: Date())
        })
}

enum FactoryUsage {
    static func headers(_ key: String) -> [String: String] {
        HTTP.bearer(key).merging([
            "Origin": "https://app.factory.ai", "Referer": "https://app.factory.ai/", "x-factory-client": "web-app",
        ]) { $1 }
    }

    static func map(me: JSON, billing: JSON?, legacy: JSON?, now: Date) throws -> ProviderUsage {
        var plan = [me.at("organization.subscription.factoryTier").string.map { "Factory \($0.capitalized)" },
                    me.at("organization.subscription.orbSubscription.plan.name").string.flatMap {
                        $0.localizedCaseInsensitiveContains("factory") ? nil : $0 }]
            .compactMap { $0 }.joined(separator: " - ")
        var windows: [UsageWindow] = []
        var cost: UsageCost?
        if let billing, billing["usesTokenRateLimitsBilling"].bool == true {
            let standard = billing.at("limits.standard")
            windows += [window("session", "5-hour", standard["fiveHour"], 300, now),
                        window("weekly", "Weekly", standard["weekly"], 10080, now),
                        window("monthly", "Monthly", standard["monthly"], nil, now)].compactMap { $0 }
            let core = billing.at("limits.core")
            let coreWindows = [window("factory-core-5h", "Core 5-hour", core["fiveHour"], 300, now),
                               window("factory-core-7d", "Core weekly", core["weekly"], 10080, now),
                               window("factory-core-monthly", "Core monthly", core["monthly"], nil, now)]
                .compactMap { $0 }
            if coreWindows.contains(where: { ($0.usedPercent ?? 0) > 0 || $0.resetsAt != nil }) {
                windows += coreWindows
            }
            if let cents = billing["extraUsageBalanceCents"].double {
                cost = UsageCost(balance: cents / 100, period: "Extra usage balance")
            }
            if let preference = billing["overagePreference"].string, !plan.isEmpty {
                plan += " - Fallback: \(preference)"
            }
        } else if let usage = legacy?["usage"], usage.exists {
            let end = usage["endDate"].date
            windows += [("standard", "Standard"), ("premium", "Premium")].compactMap { id, title in
                let pool = usage[id]
                return pool.exists ? UsageWindow(id: id, title: title, usedPercent: legacyPercent(pool), resetsAt: end) : nil
            }
        }
        guard !windows.isEmpty || cost != nil else { throw ProviderError.parse("Factory returned no usage limits.") }
        return ProviderUsage(windows: windows, cost: cost, plan: plan.isEmpty ? nil : plan,
                             organization: me.at("organization.name").string)
    }

    private static func window(_ id: String, _ title: String, _ limit: JSON, _ minutes: Int?, _ now: Date) -> UsageWindow? {
        guard limit.exists else { return nil }
        let seconds = limit["secondsRemaining"].double
        let end = limit["windowEnd"].date
        var reset: Date?
        if let seconds, seconds > 0 { reset = now.addingTimeInterval(seconds) } else if let end, end > now { reset = end }
        // A window that already ended with no countdown is stale, so its old percent no longer applies.
        let stale = end != nil && seconds == nil && reset == nil
        return UsageWindow(id: id, title: title, usedPercent: stale ? 0 : (limit["usedPercent"].double ?? 0),
                           resetsAt: reset, windowMinutes: minutes)
    }

    private static func legacyPercent(_ pool: JSON) -> Double {
        let tokens = pool["userTokens"].double ?? 0
        let allowance = pool["totalAllowance"].double ?? 0
        let unreliable = allowance <= 0 || allowance > 1e12
        if let ratio = pool["usedRatio"].double, ratio.isFinite {
            if ratio >= -0.001, ratio <= 1.001, !(ratio == 0 && tokens > 0 && !unreliable) { return ratio * 100 }
            if unreliable, ratio >= 0, ratio <= 100.1 { return ratio }
        }
        if allowance > 1e12 { return tokens / 100_000_000 * 100 }
        return allowance > 0 ? tokens / allowance * 100 : 0
    }
}
