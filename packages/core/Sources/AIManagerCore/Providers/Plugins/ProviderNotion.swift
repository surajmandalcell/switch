import Foundation

extension ProviderCatalog {
    static let notion = ProviderSpec(
        id: "notion", name: "Notion AI",
        fields: [
            .cookie("token_v2 from app.notion.com"),
            CredentialField("workspaceID", "Workspace ID", secure: false, optional: true,
                            placeholder: "Workspace UUID, to skip account discovery"),
        ],
        dashboard: "https://app.notion.com",
        usage: { credential in
            var cookie = try credential.require("cookie")
            if !cookie.contains("=") { cookie = "token_v2=\(cookie)" }
            let headers = ["Cookie": cookie, "Origin": "https://app.notion.com", "Referer": "https://app.notion.com/"]
            func post(_ endpoint: String, _ body: [String: String]) async throws -> JSON {
                try await HTTP.json("https://app.notion.com/api/v3/\(endpoint)", headers: headers, object: body)
            }
            let preferred = credential["workspaceID"]
            var identity = NotionUsage.Identity()
            if let preferred {
                identity.workspaceID = NotionUsage.dashed(preferred)
            } else {
                identity = try NotionUsage.identity(spaces: try await post("getSpaces", [:]), preferred: nil)
            }
            guard let workspace = identity.workspaceID else {
                throw ProviderError.unavailable("No Notion workspace found for this account.")
            }
            let usage = try await post("getCreditRateLimitStatus", ["spaceId": workspace])
            return try NotionUsage.map(usage, identity: identity)
        })
}

enum NotionUsage {
    struct Identity: Equatable {
        var email: String?
        var workspaceID: String?
        var workspaceName: String?
        var tier: String?
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Re-adds the dashes of a 32-hex workspace UUID; other text is returned as is.
    static func dashed(_ value: String) -> String {
        let hex = normalize(value)
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return value }
        let chars = Array(hex)
        let cuts = [0, 8, 12, 16, 20, 32]
        return (0..<5).map { String(chars[cuts[$0]..<cuts[$0 + 1]]) }.joined(separator: "-")
    }

    private static func unwrap(_ record: JSON) -> JSON {
        let inner = record["value"]
        let deep = inner["value"]
        return deep.exists ? deep : (inner.exists ? inner : record)
    }

    /// Reads the user and workspace out of the `getSpaces` response.
    static func identity(spaces: JSON, preferred: String?) throws -> Identity {
        let ids = spaces.object.keys.filter { unwrap(spaces[$0]["notion_user"][$0])["id"].string == $0 }
        guard let userID = ids.count == 1 ? ids.first : (spaces.object.count == 1 ? spaces.object.keys.first : nil) else {
            throw ProviderError.parse("Notion getSpaces response did not identify a single user.")
        }
        let container = spaces[userID]
        let user = unwrap(container["notion_user"][userID])
        let records = container["space"].object
        let workspaces = records.keys.sorted().map { key -> (id: String, record: JSON) in
            let record = unwrap(records[key]!)
            return (record["id"].string ?? key, record)
        }
        let wanted = preferred.map(normalize)
        let chosen = wanted.flatMap { w in workspaces.first { normalize($0.id) == w } }
            ?? workspaces.first { ["business", "enterprise"].contains($0.record["subscription_tier"].string?.lowercased() ?? "") }
            ?? workspaces.first
        return Identity(email: user["email"].string, workspaceID: chosen?.id,
                        workspaceName: chosen?.record["name"].string, tier: chosen?.record["subscription_tier"].string)
    }

    private static func window(_ raw: JSON, id: String, title: String, rolling: Bool, resetsIn: Double?,
                               now: Date) -> UsageWindow? {
        guard let used = raw["used"].double, let limit = raw["limit"].double, limit > 0 else { return nil }
        var minutes: Int?
        var resetsAt: Date?
        if rolling {
            // Rolling windows read like "5h", "1d", "1w".
            let token = raw["window"].string?.lowercased() ?? ""
            if let unit = token.last, let count = Int(token.dropLast()), count > 0,
               let scale = ["m": 1, "h": 60, "d": 1440, "w": 10080][String(unit)], count * scale != 43200 {
                minutes = count * scale
            }
            resetsAt = resetsIn.flatMap { $0 >= 0 ? now.addingTimeInterval($0) : nil }
        } else {
            minutes = 43200
            resetsAt = raw["periodEndMs"].double.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        }
        return UsageWindow(id: id, title: title, usedPercent: max(0, used / limit * 100), resetsAt: resetsAt,
                           windowMinutes: minutes)
    }

    static func map(_ usage: JSON, identity: Identity = Identity(), now: Date = Date()) throws -> ProviderUsage {
        if usage["status"].string?.lowercased() == "not_applicable" {
            throw ProviderError.unsupported("Notion AI allowances apply to Business and Enterprise workspaces only.")
        }
        guard usage["window"].exists || usage["billingPeriodWindow"].exists else {
            throw ProviderError.parse("Could not parse Notion usage: no usage windows.")
        }
        let windows = [
            window(usage["window"], id: "rolling", title: "Rolling", rolling: true,
                   resetsIn: usage["resetsInSeconds"].double, now: now),
            window(usage["billingPeriodWindow"], id: "monthly", title: "Monthly", rolling: false, resetsIn: nil, now: now),
        ].compactMap { $0 }
        return ProviderUsage(windows: windows, plan: identity.tier?.capitalized, email: identity.email,
                             organization: identity.workspaceName)
    }
}
