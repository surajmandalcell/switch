import Foundation

extension ProviderCatalog {
    static let mimo = ProviderSpec(
        id: "mimo", name: "Xiaomi MiMo",
        fields: [
            CredentialField("apiKey", "Token Plan API key", optional: true, env: ["MIMO_API_KEY"]),
            CredentialField("region", "Region", secure: false, optional: true, placeholder: "cn or sgp"),
            CredentialField("localUsagePath", "Local usage cache", secure: false, optional: true,
                            placeholder: MiMoUsage.defaultLocalPath, env: ["MIMO_LOCAL_USAGE_PATH"]),
        ],
        dashboard: "https://platform.xiaomimimo.com/#/console/balance",
        usage: { credential in
            guard let key = credential["apiKey"] else {
                // Without a key, show the local token cache when it exists.
                if let local = MiMoUsage.local(path: credential["localUsagePath"] ?? MiMoUsage.defaultLocalPath) {
                    return local
                }
                throw ProviderError.missingCredential("Add a MiMo Token Plan API key.")
            }
            let region = (credential["region"] ?? "cn").lowercased()
            guard region == "cn" || region == "sgp" else {
                throw ProviderError.missingCredential("MiMo region must be cn or sgp.")
            }
            let response = try await HTTP.send("https://token-plan-\(region).xiaomimimo.com/v1/platform/token_plan",
                                               headers: HTTP.bearer(key))
            if response.status == 401 || response.status == 403 {
                throw ProviderError.unauthorized("MiMo rejected this API key. Check the key and its region.")
            }
            try HTTP.check(response)
            return try MiMoUsage.map(try response.json())
        })
}

enum MiMoUsage {
    /// `GET /v1/platform/token_plan`. Credit counts must agree; period times have no zone and are UTC.
    static func map(_ root: JSON, now: Date = Date()) throws -> ProviderUsage {
        let invalid = ProviderError.parse("MiMo returned an unrecognized Token Plan response.")
        guard root["object"].string == "token_plan" else { throw invalid }
        func count(_ value: JSON) throws -> Int {
            guard let number = value.raw as? NSNumber, !JSON.isBoolean(number), let int = Int(exactly: number.doubleValue),
                  int >= 0 else { throw invalid }
            return int
        }
        let quota = root["quota"]
        let total = try count(quota["total_credits"]), used = try count(quota["used_credits"])
        guard try count(quota["remaining_credits"]) == max(0, total - used) else { throw invalid }
        func date(_ value: JSON) throws -> Date? {
            guard value.exists, !(value.raw is NSNull) else { return nil }
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = TimeZone(identifier: "UTC")
            parser.dateFormat = "yyyy-MM-dd HH:mm:ss"
            guard let text = value.raw as? String, let parsed = parser.date(from: text),
                  parser.string(from: parsed) == text else { throw invalid }
            return parsed
        }
        let start = try date(root["period"]["start_at"]), end = try date(root["period"]["end_at"])
        if let start, let end, end <= start { throw invalid }
        let minutes = start.flatMap { start in end.map { Int($0.timeIntervalSince(start) / 60) } }
        let windows = total > 0 ? [UsageWindow(id: "monthly", title: "Credits", usedPercent: Double(used) / Double(total) * 100,
                                               resetsAt: end, windowMinutes: minutes,
                                               detail: "\(Fmt.number(Double(used))) / \(Fmt.number(Double(total))) Credits")] : []
        return ProviderUsage(windows: windows, plan: root["plan_code"].string, fetchedAt: now)
    }

    // MARK: Local fallback

    static var defaultLocalPath: String { "~/.codexbar/mimo-local-usage.json" }

    /// Reads the token cache written by CodexBar's `mimo-usage` script; nil when absent or malformed.
    static func local(path: String, now: Date = Date()) -> ProviderUsage? {
        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: file), let json = try? JSON(data: data) else { return nil }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return mapLocal(json, modified: modified, now: now)
    }

    /// Local accounting only: token sums per window, never a quota percentage.
    static func mapLocal(_ json: JSON, modified: Date? = nil, now: Date = Date()) -> ProviderUsage? {
        let windows = json["windows"]
        guard windows["week"].exists, windows["today"].exists, windows["all_time"].exists else { return nil }
        func tokens(_ key: String) -> Int {
            ["input", "output", "cache_read", "cache_create"].reduce(0) { sum, lane in
                let raw = windows[key][lane].double ?? 0
                let value = raw >= 0 ? Int(exactly: raw.rounded(.towardZero)) ?? 0 : 0
                let (total, overflow) = sum.addingReportingOverflow(value)
                return overflow ? Int.max : total
            }
        }
        let today = tokens("today"), week = tokens("week"), all = tokens("all_time")
        let sessions = max(0, json["sessions_scanned"].int ?? 0)
        let updated = json["updated_at"].date ?? modified ?? now
        func short(_ n: Int) -> String {
            n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000)
                : n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
        }
        var parts = ["Local"]
        if today > 0 { parts.append("\(short(today)) today") }
        if week > 0 { parts.append("\(short(week)) week") }
        if all > 0 { parts.append("\(short(all)) total") }
        parts.append("\(sessions) sessions")
        // The cache is only as fresh as the last script run; flag a frozen one.
        let age = now.timeIntervalSince(updated)
        if age > 12 * 3600 { parts.append("stale " + (age >= 86400 ? "\(Int(age) / 86400)d" : "\(max(1, Int(age) / 3600))h")) }
        let rows = [("Today", today), ("This week", week), ("All time", all)]
            .map { UsageRow($0.0, Fmt.number(Double($0.1)) + " tokens") } + [UsageRow("Sessions", Fmt.number(Double(sessions)))]
        return ProviderUsage(sections: [UsageSection("Local tokens", rows)], plan: parts.joined(separator: " \u{B7} "),
                             fetchedAt: updated)
    }
}
