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
        var sections: [UsageSection] = []
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
            // Core windows show only when the pool carries data: a percent, a window end, or a countdown.
            let coreData = ["fiveHour", "weekly", "monthly"].contains {
                (core[$0]["usedPercent"].double ?? 0) > 0 || core[$0]["windowEnd"].exists
                    || core[$0]["secondsRemaining"].exists
            }
            if coreData { windows += coreWindows }
            if let cents = billing["extraUsageBalanceCents"].double {
                cost = UsageCost(balance: cents / 100, period: "Extra usage balance")
            }
            if let preference = billing["overagePreference"].string, !plan.isEmpty {
                plan += " - Fallback: \(preference)"
            }
        } else if let usage = legacy?["usage"], usage.exists {
            let start = usage["startDate"].date, end = usage["endDate"].date
            let minutes = start.flatMap { s in end.map { Int($0.timeIntervalSince(s) / 60) } }.flatMap { $0 > 0 ? $0 : nil }
            for (id, title) in [("standard", "Standard"), ("premium", "Premium")] where usage[id].exists {
                let pool = usage[id]
                let tokens = pool["userTokens"].double ?? 0
                let allowance = pool["totalAllowance"].double ?? 0
                // An allowance above a trillion means unlimited, so only the token count is real.
                let detail = allowance > 0 && allowance <= 1e12
                    ? "\(Fmt.number(tokens)) / \(Fmt.number(allowance)) tokens" : "\(Fmt.number(tokens)) tokens"
                windows.append(UsageWindow(id: id, title: title, usedPercent: legacyPercent(pool), resetsAt: end,
                                           windowMinutes: minutes, detail: detail))
                var rows: [UsageRow] = []
                if let org = pool["orgTotalTokensUsed"].double { rows.append(UsageRow("Org tokens used", Fmt.number(org))) }
                if let basic = pool["basicAllowance"].double, basic > 0, basic <= 1e12 {
                    rows.append(UsageRow("Basic allowance", Fmt.number(basic)))
                }
                if let over = pool["orgOverageUsed"].double, over > 0 {
                    let limit = pool["orgOverageLimit"].double.map { " / \(Fmt.number($0))" } ?? ""
                    rows.append(UsageRow("Org overage", "\(Fmt.number(over))\(limit)"))
                }
                sections.append(UsageSection("\(title) tokens", rows))
            }
            if let start { sections.append(UsageSection("Billing period", [
                UsageRow("Starts", start.formatted(date: .abbreviated, time: .omitted)),
            ] + (end.map { [UsageRow("Ends", $0.formatted(date: .abbreviated, time: .omitted))] } ?? []))) }
        }
        guard !windows.isEmpty || cost != nil else { throw ProviderError.parse("Factory returned no usage limits.") }
        return ProviderUsage(windows: windows, cost: cost, sections: sections, plan: plan.isEmpty ? nil : plan,
                             email: me.at("userProfile.email").string, organization: me.at("organization.name").string)
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
