import Foundation

extension ProviderCatalog {
    static let perplexity = ProviderSpec(
        id: "perplexity", name: "Perplexity",
        fields: [CredentialField("cookie", "Session cookie or token",
                                 placeholder: "__Secure-authjs.session-token=…")],
        dashboard: "https://www.perplexity.ai/account/usage",
        usage: { credential in
            let candidates = PerplexityUsage.cookies(try credential.require("cookie"))
            var rejected = false
            for cookie in candidates {
                let response = try await HTTP.send(
                    "https://www.perplexity.ai/rest/billing/credits?version=2.18&source=default",
                    headers: ["Cookie": cookie, "Origin": "https://www.perplexity.ai",
                              "Referer": "https://www.perplexity.ai/account/usage"])
                if response.status == 401 || response.status == 403 { rejected = true; continue }
                try HTTP.check(response)
                return try PerplexityUsage.map(try response.json())
            }
            throw rejected
                ? ProviderError.unauthorized("Perplexity session token is invalid or expired. Paste a fresh one.")
                : ProviderError.missingCredential("Paste the Perplexity session cookie.")
        })
}

enum PerplexityUsage {
    private static let names = ["__Secure-authjs.session-token", "authjs.session-token",
                                "__Secure-next-auth.session-token", "next-auth.session-token"]

    /// A bare token is tried under each known session cookie name; a Cookie header is sent as pasted.
    static func cookies(_ raw: String) -> [String] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("cookie:") { text = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        return text.contains("=") || text.contains(";") ? [text] : names.map { "\($0)=\(text)" }
    }

    static func map(_ data: JSON, now: Date = Date()) throws -> ProviderUsage {
        func field(_ snake: String, _ camel: String) -> JSON { data[snake].exists ? data[snake] : data[camel] }
        guard data.object.isEmpty == false, field("balance_cents", "balanceCents").double != nil,
              let renewalTs = field("renewal_date_ts", "renewalDateTs").double,
              let purchasedField = field("current_period_purchased_cents", "currentPeriodPurchasedCents").double,
              var remaining = field("total_usage_cents", "totalUsageCents").double,
              field("credit_grants", "creditGrants").raw is [Any] else {
            throw ProviderError.parse("Failed to parse Perplexity usage data: invalid credit fields.")
        }
        struct Grant { var type: String; var amount: Double; var expires: Double? }
        let grants: [Grant] = try field("credit_grants", "creditGrants").array.map { grant in
            guard let type = grant["type"].string,
                  let amount = (grant["amount_cents"].exists ? grant["amount_cents"] : grant["amountCents"]).double else {
                throw ProviderError.parse("Failed to parse Perplexity usage data: invalid credit grant.")
            }
            let expiry = grant["expires_at_ts"].exists ? grant["expires_at_ts"] : grant["expiresAtTs"]
            return Grant(type: type, amount: amount, expires: expiry.double)
        }
        func sum(_ list: [Grant]) -> Double { max(0, list.reduce(0) { $0 + $1.amount }) }
        let recurring = sum(grants.filter { $0.type == "recurring" })
        let promoGrants = grants.filter { $0.type == "promotional" && ($0.expires ?? .infinity) > now.timeIntervalSince1970 }
        let promo = sum(promoGrants)
        let purchased = max(sum(grants.filter { $0.type == "purchased" }), purchasedField, 0)
        // Spend drains recurring credits first, then purchased, then bonus.
        let recurringUsed = min(remaining, recurring); remaining -= recurringUsed
        let purchasedUsed = min(remaining, purchased); remaining -= purchasedUsed
        let promoUsed = min(remaining, promo)
        let renewal = Date(timeIntervalSince1970: renewalTs)
        let promoExpiry = promoGrants.compactMap(\.expires).min().map { Date(timeIntervalSince1970: $0) }

        var windows: [UsageWindow] = []
        if let window = UsageWindow.amounts(id: "credits", title: "Credits", used: recurringUsed, limit: recurring,
                                            resetsAt: renewal, unit: "credits") {
            windows.append(window)
        } else if promo <= 0 && purchased <= 0 {
            windows.append(UsageWindow(id: "credits", title: "Credits", usedPercent: 100, resetsAt: renewal,
                                       detail: "0 / 0 credits"))
        }
        if var window = UsageWindow.amounts(id: "bonus", title: "Bonus credits", used: promoUsed, limit: promo,
                                            resetsAt: promoExpiry, unit: "bonus") {
            if let promoExpiry { window.detail = (window.detail ?? "") + " · exp. \(PluginFmt.monthDay(promoExpiry))" }
            windows.append(window)
        }
        if let window = UsageWindow.amounts(id: "purchased", title: "Purchased", used: purchasedUsed, limit: purchased,
                                            unit: "credits") {
            windows.append(window)
        }
        return ProviderUsage(windows: windows, plan: recurring <= 0 ? nil : recurring < 5000 ? "Pro" : "Max")
    }
}
