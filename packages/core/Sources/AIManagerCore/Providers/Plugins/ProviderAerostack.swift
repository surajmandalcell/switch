import Foundation

extension ProviderCatalog {
    static let aerostack = ProviderSpec(
        id: "aerostack", name: "Aerostack",
        fields: [.init("token", "Account JWT", env: ["AEROSTACK_TOKEN"])],
        dashboard: "https://app.aerostack.dev/settings/billing",
        usage: { credential in
            let token = try credential.require("token")
            return try AerostackUsage.map(try await HTTP.json("https://api.aerostack.dev/api/billing/usage",
                                                              headers: HTTP.bearer(token)))
        })
}

enum AerostackUsage {
    static func map(_ json: JSON) throws -> ProviderUsage {
        let tokens = json.at("usage.ai_tokens")
        let used = tokens["used"].double, limit = tokens["limit"].double
        guard tokens.exists, used != nil || limit != nil else {
            throw ProviderError.parse("Aerostack returned an unrecognized account AI-token usage response.")
        }
        var rows: [UsageRow] = []
        if let used { rows.append(.init("Tokens used", Fmt.number(used))) }
        if let limit { rows.append(.init("Allowance", Fmt.number(limit))) }
        if let used, let limit {
            rows.append(.init("Remaining", Fmt.number(max(0, limit - used))))
            if used > limit { rows.append(.init("Above allowance", Fmt.number(used - limit))) }
        }
        if let period = json["period"].string { rows.append(.init("Period", period)) }
        var windows: [UsageWindow] = []
        if let used, let limit {
            windows = [.amounts(id: "monthly", title: "Monthly AI tokens", used: used, limit: limit,
                                windowMinutes: 30 * 24 * 60, unit: "tokens")].compactMap { $0 }
        }
        return ProviderUsage(windows: windows, sections: [.init("Monthly AI tokens", rows)],
                             plan: json["tier"].string?.trimmingCharacters(in: .whitespaces))
    }
}
