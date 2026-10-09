import Foundation

extension ProviderCatalog {
    static let helmcode = ProviderSpec(
        id: "helmcode", name: "Helmcode",
        fields: [.cookie("Cookie header from cloud.helmcode.com or cloud.nan.builders"),
                 .init("tenant", "Tenant", secure: false, optional: true, placeholder: "helmcode or nanBuilders")],
        dashboard: "https://cloud.helmcode.com/dashboard",
        usage: { credential in
            // A pasted header has no origin metadata, so the tenant field picks the host.
            let nan = credential["tenant"] == "nanBuilders"
            let domain = nan ? "nan.builders" : "helmcode.com"
            let headers = ["Cookie": try credential.require("cookie"), "Origin": "https://cloud.\(domain)",
                           "Referer": "https://cloud.\(domain)/dashboard"]
            let api = "https://cloud-api.\(domain)"
            let quota = try await HTTP.json("\(api)/api/usage/quota", headers: headers)
            let billing = try? await HTTP.json("\(api)/api/billing", headers: headers)
            let credits = nan ? nil : try? await HTTP.json("\(api)/api/billing/credits", headers: headers)
            return try HelmcodeUsage.map(quota, billing: billing, credits: credits,
                                         organization: nan ? "NaN Builders" : "Helmcode Cloud")
        })
}

enum HelmcodeUsage {
    static func map(_ quota: JSON, billing: JSON? = nil, credits: JSON? = nil, organization: String) throws -> ProviderUsage {
        guard let periodStart = quota["periodStart"].string, quota["models"].raw is [Any] else {
            throw ProviderError.parse("Helmcode quota response format changed: periodStart or models")
        }
        let premium = billing?.at("subscription.premium").bool == true
        // The period rolls over on the first of the month after periodStart when periodEnd is missing.
        var fallback: Date?
        let parts = periodStart.prefix(10).split(separator: "-").compactMap { Int($0) }
        if parts.count == 3, (1...12).contains(parts[1]) {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            fallback = utc.date(from: DateComponents(year: parts[0], month: parts[1] + 1, day: 1))
        }
        let rows = quota["models"].array.compactMap { row -> (name: String, cap: Double, used: Double, credit: Double, hours: Int?, reset: Date?)? in
            guard let name = row["model"].string, let cap = row["cap"].double, cap > 0,
                  let used = row["tokensUsed"].double else { return nil }
            let hours = row["windowHours"].int
            if hours != nil && !premium { return nil }
            return (name, cap, used, row["creditTokens"].double ?? 0, hours, row["periodEnd"].date ?? fallback)
        }.sorted { ($0.used / $0.cap, $1.name) > ($1.used / $1.cap, $0.name) }
        let windows = rows.map { row in
            UsageWindow(id: "helmcode-\(row.name)", title: row.name, usedPercent: row.used / row.cap * 100,
                        resetsAt: row.reset, windowMinutes: row.hours.map { $0 * 60 },
                        detail: "\(Fmt.number(row.used)) / \(Fmt.number(row.cap)) tokens"
                            + (row.credit > 0 ? " · \(Fmt.number(row.credit)) credit-funded" : ""))
        }
        var cost: UsageCost?
        if let balance = credits?["balanceMicros"].double {
            let currency = credits?["currency"].string?.uppercased() ?? "EUR"
            if currency.count == 3 { cost = UsageCost(balance: max(0, balance / 1e6), currency: currency, period: "Prepaid balance") }
        }
        return ProviderUsage(windows: windows, cost: cost, organization: organization)
    }
}
