import Foundation

extension ProviderCatalog {
    private static let kiroDatabase = "Library/Application Support/kiro-cli/data.sqlite3"
    private static let kiroTokens = LiveFile(
        sqlite: kiroDatabase, table: "auth_kv",
        keys: ["kirocli:odic:token", "kirocli:odic:device-registration", "kirocli:social:token"])
    private static let kiroProfile = LiveFile(sqlite: kiroDatabase, table: "state", keys: ["api.codewhisperer.profile"])

    /// Reads Kiro CLI's own rows. Kiro's CLI owns token refresh, so this never refreshes.
    static let agentKiro = ProviderSpec(
        id: "kiro", name: "Kiro", style: .files,
        files: [kiroTokens, kiroProfile],
        dashboard: "https://app.kiro.dev/account/usage",
        identify: { credential in
            KiroUsage.profileARN(credential.json(kiroProfile.id)).map { CredentialIdentity(key: $0) }
        },
        usage: { credential in
            guard let token = KiroUsage.accessToken(credential.json(kiroTokens.id)),
                  let arn = KiroUsage.profileARN(credential.json(kiroProfile.id)) else {
                throw ProviderError.missingCredential("Sign in with kiro-cli login, then import the sign-in.")
            }
            guard let endpoint = KiroUsage.endpoint(arn) else {
                throw ProviderError.unsupported("Kiro region in this profile is not supported yet.")
            }
            let response = try await HTTP.send(
                endpoint, method: "POST",
                headers: HTTP.bearer(token).merging([
                    "Content-Type": "application/x-amz-json-1.0",
                    "X-Amz-Target": "AmazonCodeWhispererService.GetUsageLimits",
                ]) { $1 },
                body: try JSONSerialization.data(withJSONObject: ["profileArn": arn]))
            if response.status == 401 || response.status == 403 {
                throw ProviderError.unauthorized("Open Kiro to refresh this sign-in (run kiro-cli whoami).")
            }
            try HTTP.check(response)
            return try KiroUsage.map(response.json())
        })
}

enum KiroUsage {
    static func accessToken(_ rows: JSON?) -> String? {
        guard let rows else { return nil }
        return ["kirocli:odic:token", "kirocli:social:token"].lazy
            .compactMap { AgentCLIsKit.embedded(rows[$0])["access_token"].string }.first
    }

    static func profileARN(_ rows: JSON?) -> String? {
        rows.flatMap { AgentCLIsKit.embedded($0["api.codewhisperer.profile"])["arn"].string }
    }

    /// Only regions that are verified. The token never goes to any other host.
    static func endpoint(_ arn: String) -> String? {
        let parts = arn.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts[1] == "aws", parts[2] == "codewhisperer" else { return nil }
        switch parts[3] {
        case "us-east-1": return "https://codewhisperer.us-east-1.amazonaws.com/"
        case "eu-central-1": return "https://q.eu-central-1.amazonaws.com/"
        default: return nil
        }
    }

    static func map(_ json: JSON) throws -> ProviderUsage {
        let credits = json["usageBreakdownList"].array.filter { $0["resourceType"].string == "CREDIT" }
        guard credits.count == 1, let limit = credits[0]["usageLimitWithPrecision"].double
                ?? credits[0]["usageLimit"].double, limit > 0 else {
            throw ProviderError.parse("Kiro returned no credit limit.")
        }
        let credit = credits[0]
        // currentUsage includes overage, so the plan share is the total minus the overage part.
        let total = credit["currentUsageWithPrecision"].double ?? credit["currentUsage"].double ?? 0
        let overage = credit["currentOveragesWithPrecision"].double ?? credit["currentOverages"].double ?? 0
        let reset = (credit["nextDateReset"].double ?? json["nextDateReset"].double).flatMap(Fmt.epoch)
        // Bonus spend is folded into currentUsage (CodexBar), so each bonus entry's own usage leaves the plan share.
        let bonuses = credit["bonuses"].array.compactMap(bonus)
        let bonusUsed = bonuses.reduce(0) { $0 + $1.used }
        let bonusLimit = bonuses.reduce(0) { $0 + $1.limit }
        let planUsed = max(0, total - overage - bonusUsed)
        var windows = [UsageWindow(id: "monthly", title: "Monthly credits", usedPercent: planUsed / limit * 100,
                                   resetsAt: reset, windowMinutes: 43200,
                                   detail: "\(Fmt.number(planUsed)) / \(Fmt.number(limit)) credits")]
        var rows = [UsageRow("Credits left", Fmt.number(max(0, limit - planUsed), digits: 2)),
                    UsageRow("Credits used", Fmt.number(planUsed, digits: 2)),
                    UsageRow("Credits total", Fmt.number(limit, digits: 2))]
        // Free-trial credits are separate from the plan; Kiro shows them as bonus credits.
        let trial = credit["freeTrialInfo"]
        var bonusPool = bonuses.isEmpty ? nil : (used: bonusUsed, limit: bonusLimit, expires: bonuses.compactMap(\.expires).min())
        if bonusPool == nil, trial["freeTrialStatus"].string != "EXPIRED",
           let trialLimit = trial["usageLimitWithPrecision"].double ?? trial["usageLimit"].double, trialLimit > 0 {
            bonusPool = (trial["currentUsageWithPrecision"].double ?? trial["currentUsage"].double ?? 0, trialLimit,
                         trial["freeTrialExpiry"].double.flatMap(Fmt.epoch))
        }
        if let pool = bonusPool, pool.limit > 0 {
            windows.append(UsageWindow(id: "bonus", title: "Bonus credits", usedPercent: pool.used / pool.limit * 100,
                                       resetsAt: pool.expires,
                                       detail: "\(Fmt.number(pool.used)) / \(Fmt.number(pool.limit)) credits"))
            rows.append(UsageRow("Bonus credits left", "\(Fmt.number(max(0, pool.limit - pool.used), digits: 2)) of \(Fmt.number(pool.limit, digits: 2))"
                + (pool.expires.map { " · expires \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")))
        }
        let status = json.at("overageConfiguration.overageStatus").string
        if let status { rows.append(UsageRow("Overages", status.capitalized)) }
        let cap = credit["overageCapWithPrecision"].double ?? credit["overageCap"].double ?? 0
        let charges = credit["overageCharges"].double
        let currency = credit["currency"].string ?? "USD"
        if status == "ENABLED", cap > 0 {
            windows.append(UsageWindow(id: "overage", title: "Overage", usedPercent: overage / cap * 100, resetsAt: reset,
                                       detail: "\(Fmt.number(overage)) / \(Fmt.number(cap)) credits"))
            rows.append(UsageRow("Overage usage", "\(Fmt.number(overage, digits: 2)) credits of \(Fmt.number(cap, digits: 2))"))
            rows.append(UsageRow("Overage credits left", Fmt.number(max(0, cap - overage), digits: 2)))
            if let charges { rows.append(UsageRow("Overage cost", Fmt.money(charges, currency: currency))) }
        }
        let cost = charges.map { UsageCost(used: $0, limit: cap > 0 ? cap * (credit["overageRate"].double ?? 0) : nil,
                                           currency: currency, period: "Overage", resetsAt: reset) }
        return ProviderUsage(windows: windows, cost: cost, sections: [UsageSection("Usage", rows)],
                             plan: json.at("subscriptionInfo.subscriptionTitle").string)
    }

    /// One bonus grant with numeric limit and usage; entries without numbers are skipped, never guessed.
    private static func bonus(_ entry: JSON) -> (used: Double, limit: Double, expires: Date?)? {
        guard entry["status"].string != "EXPIRED",
              let limit = entry["usageLimitWithPrecision"].double ?? entry["usageLimit"].double, limit > 0 else { return nil }
        return (entry["currentUsageWithPrecision"].double ?? entry["currentUsage"].double ?? 0, limit,
                entry["expiresAt"].double.flatMap(Fmt.epoch))
    }
}
