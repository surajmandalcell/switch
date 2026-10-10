import Foundation

extension ProviderCatalog {
    static let v0 = ProviderSpec(
        id: "v0", name: "v0",
        fields: [.apiKey("V0_API_KEY"),
                 CredentialField("scope", "Scope", secure: false, optional: true, placeholder: "Project ID or slug")],
        dashboard: "https://v0.app/settings/billing",
        usage: { credential in
            let headers = HTTP.bearer(try credential.require("apiKey"))
            let scope = credential["scope"]
            let query = scope.map { "?scope=" + ($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0) } ?? ""
            let billing = try await HTTP.json("https://api.v0.dev/v1/user/billing" + query, headers: headers)
            let rateLimit = try await HTTP.json("https://api.v0.dev/v1/rate-limits" + query, headers: headers)
            return try V0Usage.map(billing: billing, rateLimit: rateLimit, scope: scope)
        })
}

enum V0Usage {
    static func map(billing: JSON, rateLimit: JSON, scope: String? = nil) throws -> ProviderUsage {
        func fail(_ field: String) -> ProviderError { .parse("Could not parse v0 usage: \(field)") }
        guard let type = billing["billingType"].string, type == "token" || type == "legacy" else { throw fail("billingType") }

        // Token billing reports balance.total/remaining; legacy billing reports limit/remaining.
        let data = billing["data"]
        let limit: Double, remaining: Double?, reset: Date?
        if type == "token" {
            guard let total = data.at("balance.total").double, let left = data.at("balance.remaining").double, total >= 0 else {
                throw fail("billing.data.balance")
            }
            (limit, remaining, reset) = (total, left, data.at("billingCycle.end").date)
        } else {
            guard let max = data["limit"].double, max >= 0 else { throw fail("billing.data.limit") }
            (limit, remaining, reset) = (max, data["remaining"].double, data["reset"].date)
        }
        guard let rateMax = rateLimit["limit"].double, rateMax >= 0 else { throw fail("rate limit response.limit") }
        let rateLeft = rateLimit["remaining"].double

        func window(_ id: String, _ title: String, limit: Double, remaining: Double?, reset: Date?) -> [UsageWindow] {
            guard let remaining, limit > 0 else { return [] }
            return [UsageWindow(id: id, title: title, usedPercent: max(0, limit - remaining) / limit * 100, resetsAt: reset,
                                detail: "\(Fmt.number(remaining, digits: 2)) / \(Fmt.number(limit, digits: 2)) left")]
        }
        func remainingRow(_ label: String, _ remaining: Double?, _ limit: Double) -> UsageRow {
            PluginFmt.row(label, remaining.map { Fmt.number($0, digits: 2) } ?? "Unavailable",
                          "\(remaining == nil ? "limit" : "of") \(Fmt.number(limit, digits: 2))")
        }
        var rows = [remainingRow("Billing remaining", remaining, limit)]
        if let onDemand = data.at("onDemand.balance").double { rows.append(UsageRow("On-demand balance", Fmt.number(onDemand, digits: 2))) }
        rows.append(remainingRow("Rate-limit remaining", rateLeft, rateMax))
        rows.append(UsageRow("Billing type", type))
        if let scope { rows.append(UsageRow("Scope", String(scope.prefix(120)))) }
        return ProviderUsage(
            windows: window("billing", "Billing", limit: limit, remaining: remaining, reset: reset)
                + window("rate-limit", "Rate limit", limit: rateMax, remaining: rateLeft, reset: rateLimit["reset"].date),
            sections: [UsageSection("v0 API", rows)], plan: "API key")
    }
}
