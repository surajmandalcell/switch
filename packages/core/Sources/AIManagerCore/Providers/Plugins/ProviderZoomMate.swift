import Foundation

extension ProviderCatalog {
    /// Either a Cookie header (exchanged for a short-lived token) or a captured Authorization token works.
    static let zoommate = ProviderSpec(
        id: "zoommate", name: "ZoomMate",
        fields: [CredentialField("cookie", "Cookie header", optional: true, placeholder: "Cookie header from zoommate.zoom.us"),
                 CredentialField("token", "Authorization token", optional: true, placeholder: "Bearer token from a credits/status request")],
        dashboard: "https://zoommate.zoom.us/#/?settings=credit-usage",
        statusPage: "https://www.zoomstatus.com",
        usage: { credential in
            let cookie = credential["cookie"]
            guard cookie != nil || credential["token"] != nil else {
                throw ProviderError.missingCredential("Add a Cookie header or an Authorization token for ZoomMate.")
            }
            func get(_ path: String, token: String?) async throws -> JSON {
                var headers = [
                    "Accept": "application/json, text/plain, */*",
                    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
                    "Origin": "https://zoommate.zoom.us", "Referer": "https://zoommate.zoom.us",
                ]
                if let cookie { headers["Cookie"] = cookie }
                if let token { headers["Authorization"] = ZoomMateUsage.bearer(token) }
                var failure: Error = ProviderError.network("ZoomMate could not be reached.")
                // Both hosts serve the same API; an authentication failure is final.
                for host in ["ai.zoom.us", "zoommate.zoom.us"] {
                    do { return try await HTTP.json("https://\(host)/ai-computer/api/v1/\(path)", headers: headers) }
                    catch let error as ProviderError where error.needsSignIn { throw error }
                    catch { failure = error }
                }
                throw failure
            }
            var token = credential["token"], email: String?
            if token == nil {
                let login = try await get("login/?continue=https%3A%2F%2Fzoommate.zoom.us%2F", token: nil)
                token = login.at("data.nak").string
                email = login.at("data.user_profile.email").string
                guard token != nil else { throw ProviderError.parse("Could not parse ZoomMate usage: missing nak in login response.") }
            }
            var usage = try ZoomMateUsage.map(try await get("credits/status", token: token))
            usage.email = email
            return usage
        })
}

enum ZoomMateUsage {
    static func bearer(_ token: String) -> String {
        token.lowercased().hasPrefix("bearer ") ? token : "Bearer \(token)"
    }

    static func map(_ json: JSON) throws -> ProviderUsage {
        let status = json.at("data.credit_status")
        guard status.raw is [String: Any] else { throw ProviderError.parse("Could not parse ZoomMate usage: missing credit_status object.") }
        let cap = status["budget_cap"].double ?? 0, used = status["used_credit"].double ?? 0
        guard status["is_unlimited"].bool != true, cap > 0 else {
            return ProviderUsage(sections: [UsageSection("Credits", [UsageRow("Credits", "Unlimited")])])
        }
        var rows = [UsageRow("Credits used", "\(Fmt.number(used, digits: 2)) / \(Fmt.number(cap, digits: 2))")]
        if let overage = status["overage_credit"].double, overage > 0 { rows.append(UsageRow("Overage credits", Fmt.number(overage, digits: 2))) }
        return ProviderUsage(
            windows: [UsageWindow(id: "credits", title: "Credits", usedPercent: used / cap * 100,
                                  resetsAt: status["cycle_end_date"].date, detail: "\(Fmt.number(used, digits: 2)) / \(Fmt.number(cap, digits: 2)) credits")],
            sections: [UsageSection("Credits", rows)])
    }
}
