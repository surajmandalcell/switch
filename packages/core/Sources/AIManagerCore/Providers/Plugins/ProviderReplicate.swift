import Foundation

extension ProviderCatalog {
    static let replicate = ProviderSpec(
        id: "replicate", name: "Replicate",
        fields: [.cookie("Cookie header from replicate.com")],
        dashboard: "https://replicate.com/account/billing",
        usage: { credential in
            let cookie = ["Cookie": try credential.require("cookie")]
            let page = try await HTTP.send("https://replicate.com/account/billing",
                                           headers: cookie.merging(["Accept": "text/html"]) { $1 })
            try HTTP.check(page)
            guard let account = ReplicateUsage.account(html: page.text) else {
                throw ReplicateUsage.signedOut(page.text)
                    ? ProviderError.unauthorized("Replicate session expired. Paste a fresh Cookie header.")
                    : ProviderError.parse("Replicate billing page format changed.")
            }
            let base = "https://replicate.com/api/\(account.isOrganization ? "organizations" : "users")/"
                + (account.username.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? account.username)
            let invoices = try await HTTP.json("\(base)/invoices", headers: cookie)
            // The unused credit is optional: a failure keeps the spend.
            let credit = try? await HTTP.json("\(base)/unused-credit", headers: cookie)
            return try ReplicateUsage.map(invoices: invoices, credit: credit, account: account)
        })
}

enum ReplicateUsage {
    struct Account: Equatable {
        var username: String
        var isOrganization: Bool
    }

    /// Finds `account` in the `react-component-props` JSON script tags of the billing page.
    static func account(html: String) -> Account? {
        guard let scripts = try? NSRegularExpression(pattern: "<script\\b([^>]*)>([\\s\\S]*?)</script\\s*>",
                                                     options: .caseInsensitive) else { return nil }
        let text = html as NSString
        for match in scripts.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let attributes = text.substring(with: match.range(at: 1))
            guard attributes.contains("react-component-props"), attributes.contains("application/json"),
                  let payload = try? JSON(data: Data(text.substring(with: match.range(at: 2)).utf8)),
                  let found = find(payload) else { continue }
            return found
        }
        return nil
    }

    private static func find(_ node: JSON) -> Account? {
        if let kind = node["account"]["kind"].string, kind == "user" || kind == "organization",
           let name = node["account"]["username"].string?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return Account(username: name, isOrganization: kind == "organization")
        }
        for child in node.array + Array(node.object.values) { if let found = find(child) { return found } }
        return nil
    }

    static func signedOut(_ html: String) -> Bool {
        html.range(of: "<title>\\s*Sign in\\s*\\|\\s*Replicate\\s*</title>", options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func map(invoices: JSON, credit: JSON?, account: Account, now: Date = Date()) throws -> ProviderUsage {
        let current = invoices["invoices"].array.first { invoice in
            guard invoice["type"].string == "monthly-usage" else { return false }
            guard let end = invoice["ended_before"].string else { return !invoice["ended_before"].exists }
            return Fmt.iso(end).map { $0 > now } ?? false
        }
        guard let current else { throw ProviderError.parse("Replicate returned no current monthly-usage invoice.") }
        guard let used = current["total_cost_before_adjustments"].double, used >= 0 else {
            throw ProviderError.parse("Replicate invoice has no valid total cost.")
        }
        let balance = credit?["unused_credit"].double
        var rows = [UsageRow("Spent this month", Fmt.money(used))]
        if let balance { rows.append(UsageRow("Credit balance", Fmt.money(balance))) }
        return ProviderUsage(cost: UsageCost(used: used, balance: balance, period: "This month"),
                             sections: [UsageSection("Billing", rows), UsageSection("Account", [UsageRow("Username", account.username)])],
                             organization: account.isOrganization ? account.username : nil)
    }
}
