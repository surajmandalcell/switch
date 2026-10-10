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
            return try CopilotUsage.map(body)
        })
    // Follow-up: a device-flow sign-in (client id Iv1.b507a08c87ecfe98) once Switch has UI for it.
}

enum CopilotUsage {
    /// The first github.com entry of apps.json. Keys read `github.com` or `github.com:<appId>`; other
    /// hosts are skipped so an enterprise token never goes to api.github.com.
    static func entry(_ apps: JSON?) -> JSON? {
        apps?.object.sorted { $0.key < $1.key }
            .first { ($0.key == "github.com" || $0.key.hasPrefix("github.com:")) && $0.value["oauth_token"].string != nil }?.value
    }

    static func identity(_ apps: JSON?) -> CredentialIdentity? {
        guard let entry = entry(apps) else { return nil }
        if let user = entry["user"].string { return CredentialIdentity(key: "github:\(user.lowercased())") }
        return entry["oauth_token"].string.map { CredentialIdentity(key: "token:\($0.prefix(12))") }
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
        if !windows.isEmpty, premium["overage_permitted"].bool == true {
            rows.append(UsageRow("Extra usage", "\(Fmt.number(max(0, premium["overage_count"].double ?? 0))) requests"))
        }
        if windows.isEmpty, body["token_based_billing"].bool == true, let used = premium["credits_used"].double, used > 0 {
            rows.append(UsageRow("Credits used", Fmt.number(used)))
        } else if windows.isEmpty, rows.isEmpty, body["token_based_billing"].bool != true {
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
