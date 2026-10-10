import Foundation

extension ProviderCatalog {
    private static let grokAuthFile = LiveFile(".grok/auth.json", homeEnv: "GROK_HOME")

    /// Reads the Grok CLI sign-in that Switch's own Grok engine owns. It never refreshes tokens.
    static let agentGrok = ProviderSpec(
        id: "grok-build", name: "Grok Build", style: .files,
        files: [grokAuthFile],
        dashboard: "https://grok.com/?_s=usage",
        identify: { GrokBuildUsage.identity($0.json(grokAuthFile.id)) },
        usage: { credential in
            let auth = try GrokBuildUsage.token(credential.json(grokAuthFile.id), now: Date())
            let headers = GrokBuildUsage.headers(auth.token)
            async let settings = try? HTTP.json("https://cli-chat-proxy.grok.com/v1/settings", headers: headers)
            let response = try await HTTP.send(
                "https://cli-chat-proxy.grok.com/v1/billing?format=credits", headers: headers)
            let plan = await settings?["subscription_tier_display"].string
            if response.status == 401 || response.status == 403 {
                throw ProviderError.unauthorized(GrokBuildUsage.refreshMessage)
            }
            if GrokBuildUsage.isTeamResponse(status: response.status, body: response.text) {
                return GrokBuildUsage.teamOnly(plan: plan, email: auth.email)
            }
            try HTTP.check(response)
            return try GrokBuildUsage.map(billing: response.json(), plan: plan, email: auth.email)
        })
}

enum GrokBuildUsage {
    static let refreshMessage = "Open Grok to refresh this sign-in."

    /// The login record Grok itself would use: OIDC entry first, then the legacy session entry.
    private static func entry(_ file: JSON?) -> JSON? {
        let entries = (file?.object ?? [:]).filter { $0.value["key"].string != nil }
        let ordered = entries.sorted { $0.key < $1.key }
        return (ordered.first { $0.key.hasPrefix("https://auth.x.ai::") }
            ?? ordered.first { $0.key.contains("/sign-in") } ?? ordered.first)?.value
    }

    static func identity(_ file: JSON?) -> CredentialIdentity? {
        guard let entry = entry(file),
              let key = entry["user_id"].string ?? entry["email"].string else { return nil }
        return CredentialIdentity(key: key, email: entry["email"].string)
    }

    static func token(_ file: JSON?, now: Date) throws -> (token: String, email: String?) {
        guard let entry = entry(file), let token = entry["key"].string else {
            throw ProviderError.missingCredential("Sign in to Grok first, then import the sign-in.")
        }
        let expiry = (entry["expires_at"].date ?? entry["expires"].date)
            ?? Fmt.jwtClaims(token)?["exp"].date
        if let expiry, expiry <= now { throw ProviderError.unauthorized(refreshMessage) }
        return (token, entry["email"].string)
    }

    static func headers(_ token: String) -> [String: String] {
        HTTP.bearer(token).merging(["X-XAI-Token-Auth": "xai-grok-cli"]) { $1 }
    }

    /// HTTP 412 "no personal team": the sign-in is fine, but a team has no personal quota.
    static func isTeamResponse(status: Int, body: String) -> Bool {
        status == 412 && body.localizedCaseInsensitiveContains("no personal team")
    }

    static func teamOnly(plan: String?, email: String?) -> ProviderUsage {
        ProviderUsage(sections: [UsageSection(nil, [UsageRow("Weekly limit", "Team accounts have no personal quota")])],
                      plan: plan, email: email)
    }

    /// `GET /v1/billing?format=credits`. Proto3 JSON drops zero values, so a missing percent means 0.
    static func map(billing: JSON, plan: String? = nil, email: String? = nil) throws -> ProviderUsage {
        let config = billing["config"]
        guard config.exists else { throw ProviderError.parse("Grok returned an unexpected billing reply.") }
        var windows: [UsageWindow] = []
        let period = config["currentPeriod"]
        if let start = period["start"].date, let end = period["end"].date, end > start {
            let type = period["type"].string ?? ""
            let title = type.hasSuffix("WEEKLY") ? "Weekly" : type.hasSuffix("MONTHLY") ? "Monthly" : nil
            if let title {
                windows.append(UsageWindow(
                    id: title.lowercased(), title: title, usedPercent: config["creditUsagePercent"].double ?? 0,
                    resetsAt: end, windowMinutes: Int(end.timeIntervalSince(start) / 60)))
            }
        }
        let cap = config.at("onDemandCap.val").double ?? 0
        var rows = [UsageRow("Pay as you go", cap > 0 ? "\(Fmt.number(cap)) credit cap" : "Disabled")]
        if cap > 0, let used = config.at("onDemandUsed.val").double {
            rows.append(UsageRow("On-demand used", Fmt.number(used), progress: used / cap))
        }
        let prepaid = config.at("prepaidBalance.val").double ?? 0
        return ProviderUsage(windows: windows, cost: prepaid > 0 ? UsageCost(balance: prepaid / 100) : nil,
                             sections: [UsageSection(nil, rows)],
                             plan: plan ?? config["subscriptionTier"].string, email: email)
    }
}
