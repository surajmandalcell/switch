import Foundation

extension ProviderCatalog {
    static let raycast = ProviderSpec(
        id: "raycast", name: "Raycast",
        fields: [.cookie("__raycast_session and csrf_token from www.raycast.com")],
        dashboard: "https://www.raycast.com/settings",
        usage: { credential in
            // Send only the two cookies the credits endpoint needs.
            let header = try credential.require("cookie")
            let cookie = ["__raycast_session", "csrf_token"].compactMap { name in
                Fmt.cookie(name, in: header).map { "\(name)=\($0)" }
            }.joined(separator: "; ")
            guard Fmt.cookie("__raycast_session", in: cookie) != nil else {
                throw ProviderError.missingCredential("Paste a Cookie header that includes __raycast_session.")
            }
            let json = try await HTTP.json(
                "https://www.raycast.com/frontend_api/current_user/ai_credits",
                headers: ["Cookie": cookie, "Origin": "https://www.raycast.com",
                          "Referer": "https://www.raycast.com/settings"])
            return try RaycastUsage.map(json)
        })
}

enum RaycastUsage {
    private static func amount(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }

    static func map(_ root: JSON) throws -> ProviderUsage {
        let remaining = root["remaining_balance_credits"].double, total = root["total_balance_credits"].double
        guard remaining != nil || total != nil else {
            throw ProviderError.parse("Invalid Raycast credits response: no credit amounts.")
        }
        guard (remaining ?? 0) >= 0, (total ?? 0) >= 0 else {
            throw ProviderError.parse("Invalid Raycast credits response: negative credits.")
        }
        let renewal = root["next_credits_at"].date
        let tier = root.at("funding_subscription.tier").string
        let plan = tier.map { ["pro": "Pro", "pro_plus": "Pro+", "max": "Max"][$0] ?? $0 }
        if let remaining, let total, total > 0 {
            var window = UsageWindow(id: "credits", title: "Credits",
                                     usedPercent: max(0, total - remaining) / total * 100, resetsAt: renewal)
            window.detail = "\(amount(remaining)) / \(amount(total)) credits left"
            return ProviderUsage(windows: [window], plan: plan)
        }
        var rows: [UsageRow] = []
        if let remaining { rows.append(UsageRow("Left", amount(remaining))) }
        if let total { rows.append(UsageRow("Total", amount(total))) }
        if let renewal { rows.append(UsageRow("Renews", renewal.formatted(date: .abbreviated, time: .omitted))) }
        return ProviderUsage(sections: [UsageSection("Credits", rows)], plan: plan)
    }
}
