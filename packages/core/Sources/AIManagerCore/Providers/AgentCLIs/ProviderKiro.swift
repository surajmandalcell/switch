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
        var windows = [UsageWindow(id: "monthly", title: "Monthly credits", usedPercent: max(0, total - overage) / limit * 100,
                                   resetsAt: reset, windowMinutes: 43200,
                                   detail: "\(Fmt.number(max(0, total - overage))) / \(Fmt.number(limit)) credits")]
        let cap = credit["overageCapWithPrecision"].double ?? credit["overageCap"].double ?? 0
        if json.at("overageConfiguration.overageStatus").string == "ENABLED", cap > 0 {
            windows.append(UsageWindow(id: "overage", title: "Overage", usedPercent: overage / cap * 100, resetsAt: reset))
        }
        let charges = credit["overageCharges"].double
        let cost = charges.map { UsageCost(used: $0, limit: cap > 0 ? cap * (credit["overageRate"].double ?? 0) : nil,
                                           period: "Overage") }
        return ProviderUsage(windows: windows, cost: cost, plan: json.at("subscriptionInfo.subscriptionTitle").string)
    }
}
