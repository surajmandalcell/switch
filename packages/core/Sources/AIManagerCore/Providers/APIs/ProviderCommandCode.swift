import Foundation

extension ProviderCatalog {
    static let commandcode = ProviderSpec(
        id: "commandcode", name: "Command Code",
        fields: [.cookie("__Secure-commandcode_prod_.session_token=... from commandcode.ai")],
        dashboard: "https://commandcode.ai/studio",
        usage: { credential in
            let cookie = try CommandCodeUsage.sessionCookie(try credential.require("cookie"))
            let headers = [
                "Cookie": cookie, "Accept": "application/json, text/plain, */*",
                "Origin": "https://commandcode.ai", "Referer": "https://commandcode.ai/",
            ]
            let credits = try await HTTP.json("https://api.commandcode.ai/internal/billing/credits", headers: headers)
            let subscription = try? await HTTP.json("https://api.commandcode.ai/internal/billing/subscriptions", headers: headers)
            return try CommandCodeUsage.map(credits: credits, subscription: subscription)
        })
}

enum CommandCodeUsage {
    private static let cookieNames = [
        "__Secure-commandcode_prod_.session_token", "commandcode_prod_.session_token",
        "__Host-commandcode_prod_.session_token", "__Host-better-auth.session_token",
        "__Secure-better-auth.session_token", "better-auth.session_token",
    ]
    /// Monthly credit size in USD for each plan id.
    private static let plans: [String: (name: String, usd: Double)] = [
        "individual-go": ("Go", 10), "individual-pro": ("Pro", 30), "individual-pro-v1": ("Pro", 80),
        "individual-goat": ("GOAT", 70), "individual-max": ("Max", 150), "individual-ultra": ("Ultra", 300),
    ]

    /// Keeps only the session cookie. A bare token (no `=` or `;`) uses the production cookie name.
    static func sessionCookie(_ raw: String) throws -> String {
        if !raw.contains("="), !raw.contains(";") { return "\(cookieNames[0])=\(raw)" }
        for name in cookieNames {
            for part in raw.split(separator: ";") {
                let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pair.count == 2, pair[0].lowercased() == name.lowercased(), !pair[1].isEmpty { return "\(pair[0])=\(pair[1])" }
            }
        }
        throw ProviderError.missingCredential("The Cookie header needs the Command Code session_token cookie.")
    }

    /// `credits` is the billing credits reply; `subscription` is nil when that optional call failed.
    static func map(credits json: JSON, subscription: JSON?) throws -> ProviderUsage {
        let credits = json["credits"]
        guard credits.exists else { throw ProviderError.parse("Command Code returned an unexpected credits reply.") }
        let remaining = credits["monthlyCredits"].double ?? 0
        let purchased = credits["purchasedCredits"].double ?? 0
        let limits = json["windowLimits"].exists ? json["windowLimits"] : credits["windowLimits"]
        var windows: [UsageWindow] = []
        for (key, id, title, minutes) in [("fiveHour", "session", "5-hour", 300), ("weekly", "weekly", "Weekly", 10_080)] {
            let limit = limits[key]
            if let cap = limit["cap"].double, let used = limit["used"].double,
               let window = UsageWindow.amounts(id: id, title: title, used: used, limit: cap, resetsAt: limit["resetAt"].date,
                                                windowMinutes: minutes) {
                windows.append(window)
            }
        }
        let sub = subscription?["data"]
        let planID = sub?["planId"].string
        let plan = planID.flatMap { plans[$0] }
        let periodEnd = sub?["currentPeriodEnd"].date
        let granted = credits["monthlyCreditsGranted"].double
        let total = granted.flatMap { $0 > 0 ? $0 : nil } ?? plan?.usd
        var used: Double?
        if let total {
            used = max(0, min(total, total - remaining))
            windows.append(UsageWindow(id: "credits", title: "Monthly credits", usedPercent: used! / total * 100, resetsAt: periodEnd,
                                       detail: "\(Fmt.money(used!)) / \(Fmt.money(total))"))
        } else if subscription != nil, remaining > 0 || purchased > 0 {
            // Free tier: any spendable balance keeps the monthly bar untouched.
            windows.append(UsageWindow(id: "credits", title: "Monthly credits", usedPercent: 0, resetsAt: periodEnd))
        }
        var rows = [UsageRow("Monthly credits left", Fmt.money(remaining)), UsageRow("Purchased credits", Fmt.money(purchased))]
        for (key, label) in [("premiumMonthlyCredits", "Premium monthly"), ("opensourceMonthlyCredits", "Open-source monthly")] {
            if let value = credits[key].double, value > 0 { rows.append(UsageRow(label, Fmt.money(value))) }
        }
        return ProviderUsage(
            windows: windows,
            cost: total == nil && purchased <= 0 ? nil : UsageCost(used: used, limit: total, balance: purchased,
                                                                 period: "Monthly credits", resetsAt: periodEnd),
            sections: [UsageSection("Credits", rows)],
            plan: plan?.name ?? planID)
    }
}
