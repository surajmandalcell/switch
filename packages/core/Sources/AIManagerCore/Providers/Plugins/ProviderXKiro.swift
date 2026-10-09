import Foundation

extension ProviderCatalog {
    /// xKiro is a third-party API gateway at xkiro.com, unrelated to AWS Kiro.
    static let xkiro = ProviderSpec(
        id: "xkiro", name: "xKiro",
        fields: [.apiKey("XKIRO_API_KEY")],
        dashboard: "https://xkiro.com",
        usage: { credential in
            let key = try credential.require("apiKey")
            return try XKiroUsage.map(try await HTTP.json("https://api.xkiro.com/v1/usage", headers: HTTP.bearer(key)))
        })
}

enum XKiroUsage {
    static func map(_ json: JSON, now: Date = Date()) throws -> ProviderUsage {
        let free = json["free_tokens"]
        guard json["object"].string == "usage", free.raw is [String: Any] else {
            throw ProviderError.parse("xKiro returned an unrecognized free-token usage response.")
        }
        let used = free["used_today"].double, limit = free["limit_per_day"].double, left = free["remaining"].double
        var rows: [UsageRow] = []
        if let used { rows.append(UsageRow("Tokens used today", Fmt.number(used))) }
        if let limit { rows.append(UsageRow("Daily allowance", Fmt.number(limit))) }
        else if free["limit_per_day"].raw == nil { rows.append(UsageRow("Daily allowance", "No cap reported")) }
        if let left { rows.append(UsageRow("Tokens remaining", Fmt.number(left))) }
        rows.append(UsageRow("Daily reset", "00:00 UTC"))

        var windows: [UsageWindow] = []
        if let used, let limit {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            let reset = utc.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime)
            windows.append(UsageWindow(id: "daily", title: "Daily free tokens", usedPercent: limit == 0 ? 100 : used / limit * 100,
                                       resetsAt: reset, windowMinutes: 1440))
        }
        // A null plan means pay as you go.
        let plan = json["plan"].raw == nil ? "Pay as you go" : json["plan"].string
        return ProviderUsage(windows: windows, sections: [UsageSection("Free tokens", rows)], plan: plan, email: json.at("user.email").string)
    }
}
