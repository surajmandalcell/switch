import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

extension ProviderCatalog {
    static let commandcode = ProviderSpec(
        id: "commandcode", name: "Command Code",
        fields: [.cookie("__Secure-commandcode_prod_.session_token=... from commandcode.ai")],
        dashboard: "https://commandcode.ai/studio",
        usage: { credential in
            let raw = try credential.require("cookie")
            let cookie = try CommandCodeUsage.sessionCookie(raw)
            let headers = [
                "Cookie": cookie, "Accept": "application/json, text/plain, */*",
                "Origin": "https://commandcode.ai", "Referer": "https://commandcode.ai/",
            ]
            let credits = try await HTTP.json("https://api.commandcode.ai/internal/billing/credits", headers: headers)
            let subscription = try? await HTTP.json("https://api.commandcode.ai/internal/billing/subscriptions", headers: headers)
            let now = Date()
            let memory = CommandCodePlanMemory.shared
            let fingerprint = CommandCodePlanMemory.fingerprint(raw)
            let usage = try CommandCodeUsage.map(credits: credits, subscription: subscription,
                                                 remembered: memory.entry(fingerprint, now: now), now: now)
            CommandCodeUsage.remember(subscription, fingerprint: fingerprint, memory: memory, now: now)
            return usage
        })
}

/// The last confirmed plan per credential, so a failed subscription lookup still sizes the monthly bar.
/// Memory only: nothing is written to disk.
final class CommandCodePlanMemory: @unchecked Sendable {
    static let shared = CommandCodePlanMemory()
    struct Entry: Equatable {
        let planID: String
        let periodEnd: Date
        let storedAt: Date
    }

    /// Bounds reuse when no lookup confirms the plan, even with a distant period end.
    static let maxAge: TimeInterval = 86_400
    /// A rotated session cookie gives a new fingerprint, so this only stops the map from growing.
    private static let capacity = 4
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Hash of the credential; the cookie itself is never kept.
    static func fingerprint(_ credential: String) -> String {
        SHA256.hash(data: Data(credential.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func entry(_ fingerprint: String, now: Date) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[fingerprint], entry.storedAt <= now, entry.periodEnd > now,
              now.timeIntervalSince(entry.storedAt) < Self.maxAge else { return nil }
        return entry
    }

    func store(planID: String, periodEnd: Date, fingerprint: String, now: Date) {
        lock.lock(); defer { lock.unlock() }
        entries[fingerprint] = Entry(planID: planID, periodEnd: periodEnd, storedAt: now)
        // ponytail: overlapping refreshes are not ordered; add a per-entry observation time if they race.
        while entries.count > Self.capacity, let oldest = entries.min(by: { $0.value.storedAt < $1.value.storedAt }) {
            entries[oldest.key] = nil
        }
    }

    func clear(_ fingerprint: String) {
        lock.lock(); defer { lock.unlock() }
        entries[fingerprint] = nil
    }
}

enum CommandCodeUsage {
    private static let cookieNames = [
        "__Secure-commandcode_prod_.session_token", "commandcode_prod_.session_token",
        "__Host-commandcode_prod_.session_token", "__Host-better-auth.session_token",
        "__Secure-better-auth.session_token", "better-auth.session_token",
    ]
    /// Monthly credit size in USD for each plan id.
    static let plans: [String: (name: String, usd: Double)] = [
        "individual-go": ("Go", 10), "individual-pro": ("Pro", 30), "individual-pro-v1": ("Pro", 80),
        "individual-goat": ("GOAT", 70), "individual-max": ("Max", 150), "individual-ultra": ("Ultra", 300),
    ]
    /// Window length of the monthly credits bar (30 days), the same sentinel CodexBar uses for pace.
    static let monthlyMinutes = 30 * 24 * 60

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

    /// Updates the plan memory from one refresh. A failed lookup (`subscription` nil or not successful) keeps it;
    /// a verified free tier, an unsizable plan, or a plan with no period end forgets it.
    static func remember(_ subscription: JSON?, fingerprint: String, memory: CommandCodePlanMemory, now: Date) {
        guard subscription?["success"].bool == true else { return }
        let sub = subscription?["data"]
        if let id = sub?["planId"].string, plans[id.lowercased()] != nil,
           let end = sub?["currentPeriodEnd"].date, end > now {
            memory.store(planID: id.lowercased(), periodEnd: end, fingerprint: fingerprint, now: now)
        } else {
            memory.clear(fingerprint)
        }
    }

    /// `credits` is the billing credits reply; `subscription` is nil when that optional call failed.
    /// `remembered` sizes the monthly grant when the lookup failed and the credits reply omits the grant.
    static func map(credits json: JSON, subscription: JSON?, remembered: CommandCodePlanMemory.Entry? = nil,
                    now: Date = Date()) throws -> ProviderUsage {
        let credits = json["credits"]
        guard credits.exists, let remaining = credits["monthlyCredits"].double else {
            throw ProviderError.parse("Command Code returned an unexpected credits reply.")
        }
        let purchased = credits["purchasedCredits"].double ?? 0
        let limits = json["windowLimits"].exists ? json["windowLimits"] : credits["windowLimits"]
        var windows: [UsageWindow] = []
        for (key, id, title, minutes) in [("fiveHour", "session", "5-hour", 300), ("weekly", "weekly", "Weekly", 10_080)] {
            let limit = limits[key]
            if let cap = limit["cap"].double,
               let window = UsageWindow.amounts(id: id, title: title, used: limit["used"].double ?? 0, limit: cap,
                                                resetsAt: limit["resetAt"].date, windowMinutes: minutes) {
                windows.append(window)
            }
        }
        // Only a successful reply proves the free tier; a failure envelope is a failed lookup.
        let lookupOK = subscription?["success"].bool == true
        let sub = lookupOK ? subscription?["data"] : nil
        var planID = sub?["planId"].string
        var periodEnd = sub?["currentPeriodEnd"].date
        if !lookupOK, let remembered {
            planID = remembered.planID
            periodEnd = remembered.periodEnd
        }
        let plan = planID.flatMap { plans[$0.lowercased()] }
        let granted = credits["monthlyCreditsGranted"].double
        let total = granted.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? plan?.usd
        var used: Double?
        if let total {
            used = max(0, min(total, total - remaining))
            windows.append(UsageWindow(id: "credits", title: "Monthly credits", usedPercent: used! / total * 100, resetsAt: periodEnd,
                                       windowMinutes: monthlyMinutes, detail: "\(Fmt.money(used!)) / \(Fmt.money(total))"))
        } else if lookupOK, planID == nil, remaining > 0 || purchased > 0 {
            // Free tier: any spendable balance keeps the monthly bar untouched. An unknown grant never borrows it.
            windows.append(UsageWindow(id: "credits", title: "Monthly credits", usedPercent: 0, resetsAt: periodEnd,
                                       windowMinutes: monthlyMinutes))
        }
        var rows = [UsageRow("Monthly credits left", Fmt.money(remaining)), UsageRow("Purchased credits", Fmt.money(purchased))]
        for (key, label) in [("premiumMonthlyCredits", "Premium monthly"), ("opensourceMonthlyCredits", "Open-source monthly")] {
            if let value = credits[key].double, value > 0 { rows.append(UsageRow(label, Fmt.money(value))) }
        }
        if let status = sub?["status"].string { rows.append(UsageRow("Subscription", status.capitalized)) }
        return ProviderUsage(
            windows: windows,
            cost: total == nil && purchased <= 0 ? nil : UsageCost(used: used, limit: total, balance: purchased,
                                                                 period: "Monthly credits", resetsAt: periodEnd),
            sections: [UsageSection("Credits", rows)],
            plan: plan?.name ?? planID)
    }
}
