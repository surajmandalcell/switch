import Foundation

extension ProviderCatalog {
    static let aixy = ProviderSpec(
        id: "aixy", name: "Aixy",
        fields: [.apiKey("AIXY_API_KEY"),
                 .init("baseURL", "Base URL", secure: false, optional: true,
                       placeholder: "https://api.aixy-gateway.com", env: ["AIXY_BASE_URL"])],
        dashboard: "https://dash.aixy-gateway.com",
        usage: { credential in
            let key = try credential.require("apiKey")
            var base = credential["baseURL"] ?? "https://api.aixy-gateway.com"
            while base.hasSuffix("/") { base.removeLast() }
            if base.hasSuffix("/v1") { base.removeLast(3) }
            guard !base.contains("?"), !base.contains("#") else {
                throw ProviderError.unsupported("Aixy Base URL must not contain a query or fragment.")
            }
            let response = try await HTTP.send("\(base)/v1/usage", headers: HTTP.bearer(key))
            if response.status == 404 {
                throw ProviderError.unsupported("This Aixy installation does not provide the usage endpoint. Update the gateway or check its Base URL.")
            }
            try HTTP.check(response)
            return try AixyUsage.map(try response.json())
        })
}

enum AixyUsage {
    private static let labels = ["organization": "Organization", "project": "Project", "team": "Team", "user": "User",
                                 "api_key": "Key", "daily": "Daily", "weekly": "Weekly", "monthly": "Monthly",
                                 "lifetime": "Lifetime"]

    private struct Budget {
        var id: String, title: String, hard: Bool, known: Bool
        var limit: Double, spent: Double?, reserved: Double?, remaining: Double?
        var used: Double?, startsAt: Date?, resetsAt: Date?

        var percent: Double { used.map { $0 / limit * 100 } ?? 0 }
        var window: UsageWindow {
            let minutes = startsAt.flatMap { start in resetsAt.map { Int($0.timeIntervalSince(start) / 60) } }
            return UsageWindow(id: "aixy-\(id)", title: title, usedPercent: known ? percent : nil, resetsAt: resetsAt,
                               windowMinutes: minutes.flatMap { $0 > 0 ? $0 : nil },
                               detail: known ? "\(Fmt.money(remaining ?? 0)) remaining" : "Unavailable")
        }
    }

    static func map(_ root: JSON) throws -> ProviderUsage {
        guard root["object"].string == "key.usage", root["currency"].string == "USD" else {
            throw ProviderError.parse("Aixy: unsupported usage contract.")
        }
        let key = root["key"]
        guard let keyID = key["id"].string, root["budgets"].raw is [Any] else {
            throw ProviderError.parse("Aixy: invalid usage response.")
        }
        var budgets = root["budgets"].array.prefix(64).compactMap { raw -> Budget? in
            guard let id = raw["id"].string, let scope = raw["scope"].string, let interval = raw["interval"].string,
                  let limit = raw["limit_usd"].double, limit > 0 else { return nil }
            let hard = raw["enforcement"].string == "hard"
            let availability = raw["availability"]
            let known = hard ? availability["status"].string == "available" : raw["spend_status"].string == "available"
            let spent = (hard ? availability["spent_usd"] : raw["spend_usd"]).double
            let reserved = hard ? availability["reserved_usd"].double : 0
            let remaining = (hard ? availability["remaining_usd"] : raw["remaining_usd"]).double
            if known, spent == nil || reserved == nil || remaining == nil { return nil }
            let title = "\(labels[scope] ?? scope) · \(labels[interval] ?? interval) · "
                + "\(raw["shared"].bool == true ? "Shared" : "Personal") · \(hard ? "Hard" : "Monitor")"
            return Budget(id: id, title: title, hard: hard, known: known, limit: limit, spent: spent,
                          reserved: reserved, remaining: remaining,
                          used: known ? (spent ?? 0) + (reserved ?? 0) : nil,
                          startsAt: raw["starts_at"].date, resetsAt: raw["resets_at"].date)
        }
        // Menu bar shows the first window: known budgets first, hard before monitor, fullest first.
        budgets.sort {
            ($0.known ? 0 : 1, $0.hard ? 0 : 1, -$0.percent, $0.id) < ($1.known ? 0 : 1, $1.hard ? 0 : 1, -$1.percent, $1.id)
        }
        var sections = [UsageSection("Aixy key", [
            .init("Key", key["name"].string ?? keyID),
            .init("Project", key["project_name"].string ?? key["project_id"].string ?? ""),
        ])]
        var cost: UsageCost?
        let usage = root["usage"]
        if usage.exists {
            let requests = usage["requests"].double ?? 0, attributed = usage["attributed_requests"].double ?? 0
            let spend = usage["spend_usd"].double
            if let spend { cost = UsageCost(used: spend, period: "Last 7 days · attributed") }
            sections.append(.init("Last 7 days · this key", [
                .init("Requests", Fmt.number(requests)),
                .init("Tokens", Fmt.number(usage["total_tokens"].double ?? 0)),
                .init("Attributed spend", spend.map { Fmt.money($0) } ?? "Unavailable"),
                .init("Cost coverage", "\(Fmt.number(attributed)) / \(Fmt.number(requests)) requests"),
            ]))
        }
        return ProviderUsage(windows: budgets.map(\.window), cost: cost, sections: sections, plan: "API key")
    }
}
