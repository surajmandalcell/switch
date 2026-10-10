import Foundation

extension ProviderCatalog {
    static let tavily = ProviderSpec(
        id: "tavily", name: "Tavily",
        fields: [.apiKey("TAVILY_API_KEY")],
        dashboard: "https://app.tavily.com",
        usage: { credential in
            let key = try credential.require("apiKey")
            // The usage endpoint allows ten requests per ten minutes, so there is no retry.
            return try TavilyUsage.map(try await HTTP.json("https://api.tavily.com/usage", headers: HTTP.bearer(key)))
        })
}

enum TavilyUsage {
    static func map(_ json: JSON) throws -> ProviderUsage {
        let account = json["account"], key = json["key"]
        guard account.exists, key.exists,
              let used = account["plan_usage"].double, let limit = account["plan_limit"].double,
              let keyUsed = key["usage"].double else {
            throw ProviderError.parse("Tavily returned an unrecognized credit usage response.")
        }
        let keyLimit = key["limit"].double
        func rows(_ used: Double, _ cap: Double?) -> [UsageRow] {
            var rows = [UsageRow("Used", "\(Fmt.number(used)) credits"),
                        UsageRow("Limit", cap.map { "\(Fmt.number($0)) credits" } ?? "Unlimited")]
            if let cap { rows.append(UsageRow("Remaining", "\(Fmt.number(max(0, cap - used))) credits")) }
            return rows
        }
        var sections = [UsageSection("Account plan", rows(used, limit)), UsageSection("API key", rows(keyUsed, keyLimit))]
        if let paygo = account["paygo_usage"].double {
            sections.append(UsageSection("Pay as you go", rows(paygo, account["paygo_limit"].double)))
        }
        let windows = [
            UsageWindow.amounts(id: "plan", title: "Plan credits", used: used, limit: limit, unit: "credits"),
            keyLimit.flatMap { UsageWindow.amounts(id: "key", title: "API key", used: keyUsed, limit: $0, unit: "credits") },
        ].compactMap { $0 }
        return ProviderUsage(windows: windows, sections: sections, plan: account["current_plan"].string?.trimmingCharacters(in: .whitespaces) ?? "API key")
    }
}
