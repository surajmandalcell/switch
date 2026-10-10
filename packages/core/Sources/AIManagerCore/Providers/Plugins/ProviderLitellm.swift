import Foundation

extension ProviderCatalog {
    static let litellm = ProviderSpec(
        id: "litellm", name: "LiteLLM",
        fields: [
            .apiKey("LITELLM_API_KEY"),
            CredentialField("baseURL", "Base URL", secure: false, placeholder: "https://litellm.example.com"),
            CredentialField("modelActivity", "Show model activity (true or blank)", secure: false, optional: true,
                            env: ["LITELLM_MODEL_USAGE_ENABLED"]),
        ],
        dashboard: "https://docs.litellm.ai/docs/proxy/users",
        usage: { credential in
            let key = try credential.require("apiKey")
            var base = try credential.require("baseURL").replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            if base.hasSuffix("/v1") { base.removeLast(3) }
            let headers = HTTP.bearer(key)
            /// Returns nil for 401/403/404 when `optional`, so a key without key/info rights can use the spend report.
            func get(_ path: String, optional: Bool = false) async throws -> JSON? {
                let response = try await HTTP.send("\(base)/\(path)", headers: headers)
                if optional, [401, 403, 404].contains(response.status) { return nil }
                try HTTP.check(response)
                return try response.json()
            }
            func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value }
            let now = Date()
            guard let keyRoot = try await get("key/info", optional: true) else {
                let end = LiteLLMUsage.day(now), start = String(end.prefix(7)) + "-01"
                let query = "?start_date=\(start)&end_date=\(end)"
                if let rows = try await get("key/spend/report\(query)", optional: true) {
                    return try LiteLLMUsage.mapSpendReport(rows, scope: "Key", start: start, end: end)
                }
                return try LiteLLMUsage.mapSpendReport(try await get("user/spend/report\(query)")!,
                                                       scope: "User", start: start, end: end)
            }
            let info = keyRoot["info"]
            var user: JSON?, team: JSON?
            if let userID = info["user_id"].string {
                user = try await get("user/info?user_id=\(encoded(userID))")
            } else if let teamID = info["team_id"].string {
                team = try await get("team/info?team_id=\(encoded(teamID))")
            }
            // Optional history must never discard the budgets that were already fetched.
            var activity: UsageSection?
            if let userID = info["user_id"].string, credential["modelActivity"] == "true" {
                let end = LiteLLMUsage.day(now)
                let start = LiteLLMUsage.day(now.addingTimeInterval(-29 * 86_400))
                var pages: [JSON] = []
                for page in 1...3 {
                    guard let json = try? await get("user/daily/activity?user_id=\(encoded(userID))&start_date=\(start)"
                                                    + "&end_date=\(end)&page=\(page)&page_size=1000") else { break }
                    pages.append(json)
                    let meta = json["metadata"]
                    if meta["has_more"].bool != true && page >= (meta["total_pages"].int ?? 1) { break }
                }
                activity = LiteLLMUsage.modelActivity(pages)
            }
            return try LiteLLMUsage.map(key: keyRoot, user: user, team: team, activity: activity)
        })
}

enum LiteLLMUsage {
    static func day(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }

    private struct Budget {
        var teamID: String?
        var alias: String?
        var window: UsageWindow?
        var cost: UsageCost?
    }

    private static func budget(_ info: JSON, team: Bool) -> Budget {
        let used = info["spend"].double ?? 0, limit = max(0, info["max_budget"].double ?? 0)
        let reset = info["budget_reset_at"].date
        let alias = team ? info["team_alias"].string : nil
        var window: UsageWindow?
        if limit > 0 {
            let id = team ? "team" : "personal"
            window = UsageWindow(id: id, title: team ? "Team budget" : "Personal budget",
                                 usedPercent: used / limit * 100, resetsAt: reset,
                                 detail: "\(alias.map { "\($0): " } ?? "")\(Fmt.money(used)) / \(Fmt.money(limit))")
        }
        let cost = used > 0 || limit > 0
            ? UsageCost(used: used, limit: limit > 0 ? limit : nil, period: "\(team ? "Team" : "Personal") \(limit > 0 ? "budget" : "spend")", resetsAt: reset)
            : nil
        return Budget(teamID: team ? info["team_id"].string : nil, alias: alias, window: window, cost: cost)
    }

    /// `key` is the `/key/info` response; `user` the `/user/info` response (key has a user_id) or
    /// `team` the `/team/info` response (key has only a team_id).
    static func map(key: JSON, user: JSON?, team: JSON?, activity: UsageSection? = nil) throws -> ProviderUsage {
        let info = key["info"]
        let userID = info["user_id"].string, teamID = info["team_id"].string
        guard userID != nil || teamID != nil else {
            throw ProviderError.parse("LiteLLM key info did not include a user_id or team_id.")
        }
        var email: String?
        var personal: Budget?, teamBudget: Budget?
        if userID != nil {
            guard let user else { throw ProviderError.parse("LiteLLM user info is missing.") }
            let account = user["user_info"]
            if let responseID = account["user_id"].string ?? user["user_id"].string, responseID != userID {
                throw ProviderError.parse("LiteLLM user_id did not match /key/info.")
            }
            email = account["user_email"].string ?? account["user_alias"].string
                ?? account.at("metadata.preferred_username").string
            personal = budget(account, team: false)
            teamBudget = user["teams"].array.map { budget($0, team: true) }.first { $0.teamID == teamID }
        } else {
            guard let team else { throw ProviderError.parse("LiteLLM team info is missing.") }
            teamBudget = budget(team["team_info"], team: true)
        }
        // key.expires is the plugin's subscriptionExpiresAt.
        let sections = [activity, info["expires"].date.map { PluginFmt.renewal(nil, expires: $0) }].compactMap { $0 }
        return ProviderUsage(windows: [personal?.window, teamBudget?.window].compactMap { $0 },
                             cost: (personal ?? teamBudget)?.cost, sections: sections, plan: "API", email: email,
                             organization: teamBudget?.alias)
    }

    /// "Model activity · 30d UTC": the 20 busiest models over the `user/daily/activity` pages.
    static func modelActivity(_ pages: [JSON]) -> UsageSection? {
        var totals: [String: [Double]] = [:]
        let fields = ["prompt_tokens", "completion_tokens", "total_tokens", "api_requests"]
        for page in pages {
            for day in page["results"].array {
                for (name, value) in day.at("breakdown.models").object {
                    let metrics = value["metrics"].exists ? value["metrics"] : value
                    var sum = totals[name] ?? [0, 0, 0, 0]
                    for (index, field) in fields.enumerated() { sum[index] += metrics[field].double ?? 0 }
                    totals[name] = sum
                }
            }
        }
        let rows = totals.sorted { $0.value[2] != $1.value[2] ? $0.value[2] > $1.value[2] : $0.key < $1.key }
            .prefix(20).map { name, sum in
                PluginFmt.row(name, "\(Int(sum[2])) tokens · \(Int(sum[3])) requests",
                              "Input \(Int(sum[0])) · Output \(Int(sum[1]))")
            }
        return rows.isEmpty ? nil : UsageSection("Model activity · 30d UTC", rows)
    }

    /// Spend-only fallback for keys that cannot read `/key/info`.
    static func mapSpendReport(_ rows: JSON, scope: String, start: String, end: String) throws -> ProviderUsage {
        let list = rows.array
        guard !list.isEmpty else { throw ProviderError.parse("LiteLLM returned an empty spend report.") }
        var used = 0.0
        for row in list {
            guard let cost = row["total_cost"].double, cost >= 0 else {
                throw ProviderError.parse("LiteLLM spend report has an invalid total_cost.")
            }
            used += cost
        }
        return ProviderUsage(cost: UsageCost(used: used, period: "\(scope) spend only (\(start) to \(end) UTC)"), plan: "API")
    }
}
