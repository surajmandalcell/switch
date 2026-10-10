import Foundation

extension ProviderCatalog {
    static let sub2api = ProviderSpec(
        id: "sub2api", name: "sub2api",
        fields: [.apiKey("SUB2API_API_KEY"),
                 CredentialField("baseURL", "Base URL", secure: false, placeholder: "https://gateway.example.com", env: ["SUB2API_BASE_URL"])],
        usage: { credential in
            let key = try credential.require("apiKey")
            let url = try Sub2ApiUsage.endpoint(try credential.require("baseURL"), timeZone: TimeZone.current.identifier)
            return try Sub2ApiUsage.map(try await HTTP.json(url, headers: HTTP.bearer(key)))
        })
}

enum Sub2ApiUsage {
    /// Normalizes any of `host`, `host/v1`, or `host/v1/usage` to the usage endpoint.
    static func endpoint(_ baseURL: String, timeZone: String) throws -> String {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard base.hasPrefix("https://") || base.hasPrefix("http://127.0.0.1") || base.hasPrefix("http://localhost") else {
            throw ProviderError.missingCredential("The sub2api base URL must start with https://.")
        }
        if !(base.hasSuffix("/v1") || base.hasSuffix("/v1/usage")) { base += "/v1" }
        if !base.hasSuffix("/usage") { base += "/usage" }
        return "\(base)?days=30&timezone=\(timeZone.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "UTC")"
    }

    static func map(_ json: JSON) throws -> ProviderUsage {
        guard json.raw is [String: Any] else { throw ProviderError.parse("Could not parse sub2api usage: response must be an object.") }
        if json["isValid"].bool == false {
            throw ProviderError.unauthorized("sub2api rejected the API key. Check that the key is active and assigned to a group.")
        }
        let unit = json["unit"].string ?? json.at("quota.unit").string ?? "USD"
        func money(_ value: Double, _ unit: String = "USD") -> String {
            unit.uppercased() == "USD" ? Fmt.money(value) : "\(Fmt.number(value, digits: 2)) \(unit)"
        }
        func window(_ id: String, _ title: String, used: Double, limit: Double?, minutes: Int?, resetsAt: Date? = nil, unit: String = "USD") -> [UsageWindow] {
            guard let limit, limit > 0 else { return [] }
            return [UsageWindow(id: id, title: title, usedPercent: used / limit * 100, resetsAt: resetsAt, windowMinutes: minutes,
                                detail: "\(money(used, unit)) / \(money(limit, unit))")]
        }

        var windows: [UsageWindow] = []
        let sub = json["subscription"], quota = json["quota"]
        if sub.exists {
            for (id, title, field, minutes) in [("daily", "Daily", "daily", 1440), ("weekly", "Weekly", "weekly", 10080), ("monthly", "Monthly", "monthly", 43200)] {
                windows += window(id, title, used: sub["\(field)_usage_usd"].double ?? 0, limit: sub["\(field)_limit_usd"].double, minutes: minutes)
            }
        } else if let limit = quota["limit"].double, let used = quota["used"].double {
            windows += window("quota", "Quota", used: used, limit: limit, minutes: nil, unit: quota["unit"].string ?? unit)
        }
        let rateTitles = ["5h": "5 hour limit", "1d": "Daily limit", "7d": "7 day limit"]
        let rateMinutes = ["5h": 300, "1d": 1440, "7d": 10080]
        for rate in json["rate_limits"].array {
            guard let name = rate["window"].string, let used = rate["used"].double else { continue }
            windows += window("rate-\(name)", rateTitles[name.lowercased()] ?? "\(name) limit", used: used, limit: rate["limit"].double,
                              minutes: rateMinutes[name.lowercased()], resetsAt: rate["reset_at"].date)
        }

        var rows: [UsageRow] = []
        let balance = json["balance"].double
        if let balance { rows.append(UsageRow("Balance", money(balance, unit))) }
        for (title, key) in [("Today", "today"), ("All time", "total")] {
            let totals = json.at("usage.\(key)")
            guard totals.exists else { continue }
            rows.append(UsageRow("\(title) requests", Fmt.number(totals["requests"].double ?? 0)))
            rows.append(UsageRow("\(title) tokens", "\(Fmt.number(totals["total_tokens"].double ?? 0)) (\(money(totals["actual_cost"].double ?? 0)))"))
        }
        let plan = json["planName"].string
        let expires = sub["expires_at"].date ?? json["expires_at"].date
        return ProviderUsage(
            windows: windows,
            cost: unit.uppercased() == "USD" ? balance.map { UsageCost(balance: $0) } : nil,
            sections: [UsageSection("Usage summary", rows), PluginFmt.renewal(nil, expires: expires)],
            plan: plan, organization: plan)
    }
}
