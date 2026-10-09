import Foundation

extension ProviderCatalog {
    static let gitkraken = ProviderSpec(
        id: "gitkraken", name: "GitKraken AI",
        fields: [.init("token", "GitKraken access token", env: ["GITKRAKEN_API_TOKEN"]),
                 .init("orgID", "API organization ID", secure: false, optional: true, env: ["GITKRAKEN_ORG_ID"])],
        dashboard: "https://gitkraken.dev/account#ai-usage",
        usage: { credential in
            var headers = HTTP.bearer(try credential.require("token"))
            headers["Client-Name"] = "Switch"
            headers["Client-Version"] = "0.0.0"
            if let org = credential["orgID"] { headers["gk-org-id"] = org }
            return try GitkrakenUsage.map(try await HTTP.json("https://api.gitkraken.dev/v1/ai-tasks/usage", headers: headers))
        })
}

enum GitkrakenUsage {
    private struct Quota { var used: Double, limit: Double }

    private static func quota(_ json: JSON) -> Quota? {
        guard let used = json["used"].double, used >= 0, let limit = json["limit"].double,
              limit >= 0 || limit == -1 else { return nil }
        return Quota(used: used, limit: limit)
    }

    static func map(_ body: JSON) throws -> ProviderUsage {
        let data = body["data"]
        guard !body["error"].exists, let personal = quota(data), let resetsAt = data["resetsOn"].date else {
            throw ProviderError.parse("GitKraken returned an unrecognized usage response.")
        }
        let pool = quota(data["organization"])
        func description(_ q: Quota) -> String {
            q.limit <= 0 ? "\(Fmt.number(q.used, digits: 2)) credits used · \(q.limit == -1 ? "Unlimited" : "No allowance")"
                : "\(Fmt.number(q.used, digits: 2)) / \(Fmt.number(q.limit, digits: 2)) credits used"
        }
        var rows = [UsageRow("Personal", description(personal))]
        if let pool {
            rows.append(.init("Shared pool", description(pool)))
            // sharedUsed is a slice of the pool, never additional personal usage.
            if let shared = data["sharedUsed"].double, shared >= 0, shared <= pool.used {
                rows.append(.init("Your shared usage", "\(Fmt.number(shared, digits: 2)) credits"))
                rows.append(.init("Rest of organization", "\(Fmt.number(pool.used - shared, digits: 2)) credits"))
            }
        }
        func window(_ id: String, _ title: String, _ q: Quota?) -> UsageWindow? {
            guard let q, q.limit > 0 else { return nil }
            return .amounts(id: id, title: title, used: q.used, limit: q.limit, resetsAt: resetsAt, windowMinutes: 10_080,
                            unit: "credits")
        }
        return ProviderUsage(windows: [window("personal", "Personal", personal), window("shared", "Shared pool", pool)].compactMap { $0 },
                             sections: [.init("Weekly usage", rows)], plan: "API")
    }
}
