import Foundation

extension ProviderCatalog {
    /// Hermes Agent owns the Nous Portal login; Switch reads its access token, never refreshes it.
    static let nous = ProviderSpec(
        id: "nous", name: "Nous Portal",
        fields: [CredentialField("token", "Access token (optional)", optional: true, env: ["NOUS_PORTAL_ACCESS_TOKEN"])],
        files: [LiveFile(".hermes/auth.json", homeEnv: "HERMES_HOME", optional: true)],
        login: ["hermes", "auth", "add", "nous"],
        dashboard: "https://portal.nousresearch.com/usage",
        usage: { credential in
            guard let stored = NousUsage.token(credential) else {
                throw ProviderError.missingCredential("Sign in with Hermes Agent (hermes auth add nous) or paste an access token.")
            }
            var portal = "https://portal.nousresearch.com"
            if let custom = stored.portal, let url = URL(string: custom), url.scheme == "https",
               let host = url.host, host == "nousresearch.com" || host.hasSuffix(".nousresearch.com") {
                portal = custom.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            }
            let response = try await HTTP.send("\(portal)/api/oauth/account", headers: HTTP.bearer(stored.token))
            if response.status == 401 {
                throw ProviderError.unauthorized("Nous Portal rejected the access token. Run hermes to refresh your login.")
            }
            try HTTP.check(response)
            return try NousUsage.map(try response.json())
        })
}

enum NousUsage {
    /// Pasted token first, then the Hermes auth file (providers.nous, credential_pool.nous[], or a bare object).
    static func token(_ credential: ProviderCredential) -> (token: String, portal: String?)? {
        if let pasted = credential["token"] { return (pasted, nil) }
        for file in credential.files.values {
            guard let root = try? JSON(data: file) else { continue }
            let pool = root.at("credential_pool.nous").array
            for state in [root.at("providers.nous"), pool.first ?? JSON(nil), root] {
                if let token = state["access_token"].string { return (token, state["portal_base_url"].string) }
            }
        }
        return nil
    }

    static func map(_ root: JSON, now: Date = Date()) throws -> ProviderUsage {
        if root["error"].string != nil || !root["error"].object.isEmpty {
            throw ProviderError.unavailable("Nous Portal account endpoint reported an error.")
        }
        let sub = root["subscription"], access = root["paid_service_access"]
        let monthly = sub["monthly_credits"].double
        let remaining = sub["credits_remaining"].double ?? access["subscription_credits_remaining"].double
        let rollover = sub["rollover_credits"].double
        let purchased = root["purchased_credits_remaining"].double ?? access["purchased_credits_remaining"].double
        let total = access["total_usable_credits"].double
        guard [monthly, remaining, rollover, purchased, total].contains(where: { $0 != nil }) else {
            throw ProviderError.parse("Nous Portal account response has no credit amounts.")
        }
        let renewal = sub["current_period_end"].date
        var windows: [UsageWindow] = []
        if let monthly, monthly > 0, let remaining,
           let window = UsageWindow.amounts(id: "monthly", title: "Monthly credits",
                                            used: monthly - max(0, remaining), limit: monthly, resetsAt: renewal) {
            var window = window
            window.detail = "\(Fmt.money(max(0, remaining))) left of \(Fmt.money(monthly))"
            windows.append(window)
        }
        var rows: [UsageRow] = []
        if let rollover, rollover > 0 { rows.append(UsageRow("Rollover credits", Fmt.money(rollover))) }
        if let purchased { rows.append(UsageRow("Top-up credits", Fmt.money(purchased))) }
        if let total { rows.append(UsageRow("Total usable", Fmt.money(total))) }
        let plan = sub["plan"].string ?? (access["has_active_subscription"].bool == true ? "Subscription" : nil)
        return ProviderUsage(
            windows: windows,
            cost: (total ?? purchased).map { UsageCost(balance: $0, period: "Usable credits") },
            sections: [UsageSection("Credits", rows)], plan: plan,
            email: root.at("user.email").string, organization: root.at("organisation.name").string)
    }
}
