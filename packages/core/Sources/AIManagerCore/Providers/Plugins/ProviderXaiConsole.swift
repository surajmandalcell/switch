import Foundation

extension ProviderCatalog {
    /// The xAI API console (Management API). The Grok CLI is a separate provider.
    static let xaiConsole = ProviderSpec(
        id: "xai", name: "xAI",
        fields: [CredentialField("apiKey", "Management API key", env: ["XAI_MANAGEMENT_API_KEY"]),
                 CredentialField("teamID", "Team ID", secure: false, placeholder: "Team ID from the xAI Console")],
        dashboard: "https://console.x.ai",
        usage: { credential in
            let key = try credential.require("apiKey")
            let team = try credential.require("teamID")
            guard !team.contains("/"), team != ".", team != ".." else {
                throw ProviderError.missingCredential("The xAI team ID is not valid.")
            }
            let root = "https://management-api.x.ai/v1/billing/teams/\(team.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? team)"
            let headers = HTTP.bearer(key)
            let balance = try await HTTP.json(root + "/prepaid/balance", headers: headers)

            // Spend history is optional: a failure keeps the balance.
            let now = Date()
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "GMT")!
            let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -29, to: now) ?? now)
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.timeZone = calendar.timeZone
            stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let query: [String: Any] = ["analyticsRequest": [
                "timeRange": ["startTime": stamp.string(from: start), "endTime": stamp.string(from: now), "timezone": "Etc/GMT"],
                "timeUnit": "TIME_UNIT_DAY",
                "values": [["name": "usd", "aggregation": "AGGREGATION_SUM"]],
                "groupBy": [], "filters": [],
            ]]
            let history = try? await HTTP.json(root + "/usage", headers: headers, object: query)
            return try XaiConsoleUsage.map(balance: balance, history: history)
        })
}

enum XaiConsoleUsage {
    /// `balance.total.val` is a ledger amount in cents: negative means prepaid credit remaining.
    static func map(balance: JSON, history: JSON?) throws -> ProviderUsage {
        guard let raw = balance.at("total.val").double else {
            throw ProviderError.parse("Could not parse xAI billing data: balance total.val is not a cent amount.")
        }
        let remaining = -raw / 100
        var rows = [UsageRow("Prepaid balance", Fmt.money(remaining))]
        var spent: Double?
        if let series = history?["timeSeries"], series.exists {
            let total = series.array.flatMap { $0["dataPoints"].array }.reduce(0.0) { $0 + ($1["values"][0].double ?? 0) }
            let partial = history?["limitReached"].bool == true
            spent = total
            rows.append(UsageRow(partial ? "Last 30 days (partial)" : "Last 30 days", Fmt.money(total)))
        }
        return ProviderUsage(
            cost: UsageCost(used: spent, balance: remaining, period: spent == nil ? "Prepaid credits" : "Last 30 days"),
            sections: [UsageSection("Billing summary", rows)])
    }
}
