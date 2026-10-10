import Foundation

extension ProviderCatalog {
    private static let copilotApps = LiveFile(".config/github-copilot/apps.json")

    static let copilot = ProviderSpec(
        id: "copilot", name: "GitHub Copilot", style: .files, files: [copilotApps],
        dashboard: "https://github.com/settings/copilot", statusPage: "https://www.githubstatus.com",
        identify: { credential in CopilotUsage.identity(credential.json(copilotApps.id)) },
        usage: { credential in
            guard let token = CopilotUsage.entry(credential.json(copilotApps.id))?["oauth_token"].string else {
                throw ProviderError.missingCredential("Sign in to GitHub Copilot in your editor first.")
            }
            let body = try await HTTP.json("https://api.github.com/copilot_internal/user", headers: [
                "Authorization": "token \(token)",
                "Editor-Version": "vscode/1.96.2", "Editor-Plugin-Version": "copilot-chat/0.26.7",
                "User-Agent": "GitHubCopilotChat/0.26.7", "X-Github-Api-Version": "2025-04-01",
            ])
            var usage = try CopilotUsage.map(body)
            // An org-managed seat has no per-seat quota; its usage lives in the organization's billing.
            if CopilotUsage.isOrgManaged(body, usage) {
                usage.sections += await CopilotUsage.orgBilling(token: token)
            }
            return usage
        })
    // Follow-up: a device-flow sign-in (client id Iv1.b507a08c87ecfe98) once Switch has UI for it.
}

enum CopilotUsage {
    /// Business and Enterprise seats billed per token: the response has no percent quota at all.
    static func isOrgManaged(_ body: JSON, _ usage: ProviderUsage) -> Bool {
        usage.windows.isEmpty && body["token_based_billing"].bool == true
    }

    // MARK: Organization billing

    private static let billingHeaders = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
    private static let rememberedOrgs = OrgMemory()

    /// Org slug that last carried Copilot credit usage, per token, so later refreshes make one call.
    private final class OrgMemory: @unchecked Sendable {
        private let lock = NSLock()
        private var orgs: [String: String] = [:]
        func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return orgs[key] }
        func set(_ key: String, _ org: String?) { lock.lock(); defer { lock.unlock() }; orgs[key] = org }
    }

    /// Org Credits and Org Spend for the first organization whose billing shows Copilot AI credits.
    /// Only org owners and billing managers can read billing; everyone else gets no extra rows.
    static func orgBilling(token: String) async -> [UsageSection] {
        let headers = billingHeaders.merging(["Authorization": "token \(token)"]) { $1 }
        let memory = AgentCLIsKit.fingerprint(token)
        func summary(_ org: String) async -> (section: UsageSection?, transient: Bool) {
            guard let slug = org.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let response = try? await HTTP.send("https://api.github.com/orgs/\(slug)/settings/billing/usage/summary",
                                                      headers: headers) else { return (nil, true) }
            if response.status == 429 || response.status >= 500 { return (nil, true) }
            guard response.status == 200, let json = try? response.json() else { return (nil, false) }
            return (orgSection(json), false)
        }
        if let org = rememberedOrgs.get(memory) {
            let found = await summary(org)
            if let section = found.section { return [section] }
            if found.transient { return [] }
            rememberedOrgs.set(memory, nil)
        }
        guard let response = try? await HTTP.send("https://api.github.com/user/orgs?per_page=100", headers: headers),
              response.status == 200, let list = try? response.json() else { return [] }
        // ponytail: probes at most 10 organizations per refresh until one answers; remembered per token.
        for login in list.array.compactMap({ $0["login"].string }).prefix(10) {
            if let section = await summary(login).section {
                rememberedOrgs.set(memory, login)
                return [section]
            }
        }
        return []
    }

    /// `usageItems` of the billing usage summary. Only credit units count, so seat fees do not mix in.
    /// The summary reports usage only, never the org's allotment, so credits stay a plain count.
    static func orgSection(_ summary: JSON) -> UsageSection? {
        let items = summary["usageItems"].array.filter {
            $0["product"].string?.lowercased() == "copilot"
                && ["ai-units", "ai-credits"].contains($0["unitType"].string?.lowercased() ?? "")
        }
        guard !items.isEmpty else { return nil }
        let credits = items.reduce(0.0) { $0 + max(0, $1["grossQuantity"].double ?? 0) }
        let spend = items.reduce(0.0) { $0 + max(0, $1["netAmount"].double ?? 0) }
        return UsageSection("Organization billing (this month)", [
            UsageRow("Org credits", "\(Fmt.number(credits)) credits"), UsageRow("Org spend", Fmt.money(spend)),
        ])
    }

    /// The first github.com entry of apps.json. Keys read `github.com` or `github.com:<appId>`; other
    /// hosts are skipped so an enterprise token never goes to api.github.com.
    static func entry(_ apps: JSON?) -> JSON? {
        apps?.object.sorted { $0.key < $1.key }
            .first { ($0.key == "github.com" || $0.key.hasPrefix("github.com:")) && $0.value["oauth_token"].string != nil }?.value
    }

    static func identity(_ apps: JSON?) -> CredentialIdentity? {
        guard let entry = entry(apps) else { return nil }
        if let user = entry["user"].string { return CredentialIdentity(key: "github:\(user.lowercased())") }
        // Never keep part of the token itself in the account index.
        return entry["oauth_token"].string.map { CredentialIdentity(key: "token:\(AgentCLIsKit.fingerprint($0))") }
    }

    /// Pure mapper for `/copilot_internal/user`. Unlimited (-1) and zero-entitlement buckets are dropped.
    static func map(_ body: JSON) throws -> ProviderUsage {
        let reset = (body["quota_reset_date"].string ?? body["limited_user_reset_date"].string).flatMap(Fmt.iso)
        let snapshots = body["quota_snapshots"]
        var windows = [("credits", "Credits", "premium_interactions"), ("chat", "Chat", "chat"),
                       ("completions", "Completions", "completions")].compactMap { id, title, key in
            window(id: id, title: title, snapshots[key], reset: reset)
        }
        if windows.isEmpty {
            // Older free-tier shape: remaining counts against monthly limits.
            windows = [("chat", "Chat"), ("completions", "Completions")].compactMap { key, title in
                guard let total = body.at("monthly_quotas.\(key)").double, total > 0,
                      let left = body.at("limited_user_quotas.\(key)").double else { return nil }
                return UsageWindow.amounts(id: key, title: title, used: max(0, total - left), limit: total,
                                           resetsAt: reset, windowMinutes: 43_200)
            }
        }
        var rows: [UsageRow] = []
        let premium = snapshots["premium_interactions"]
        // The seat's own AI credits used this cycle: a plain count, since no allotment is published.
        let creditsUsed = premium["credits_used"].double ?? 0
        if creditsUsed > 0 { rows.append(UsageRow("Credits used", Fmt.number(creditsUsed))) }
        if !windows.isEmpty, premium["overage_permitted"].bool == true {
            rows.append(UsageRow("Extra usage", "\(Fmt.number(max(0, premium["overage_count"].double ?? 0))) requests"))
        }
        if windows.isEmpty, rows.isEmpty, body["token_based_billing"].bool != true {
            throw ProviderError.parse("Copilot returned no quota for this account.")
        }
        let plan = body["copilot_plan"].string.map {
            $0.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return ProviderUsage(windows: windows, sections: [UsageSection(nil, rows)], plan: plan)
    }

    private static func window(id: String, title: String, _ snapshot: JSON, reset: Date?) -> UsageWindow? {
        let entitlement = snapshot["entitlement"].double, remaining = snapshot["remaining"].double
        if snapshot["unlimited"].bool == true || entitlement == -1 || remaining == -1 || entitlement == 0 { return nil }
        let used: Double
        if let left = snapshot["percent_remaining"].double {
            used = 100 - left
        } else if let entitlement, entitlement > 0, let remaining {
            used = 100 - remaining / entitlement * 100
        } else {
            return nil
        }
        return UsageWindow(id: id, title: title, usedPercent: used, resetsAt: reset, windowMinutes: 43_200)
    }
}
