import Foundation

extension ProviderCatalog {
    static let mimo = ProviderSpec(
        id: "mimo", name: "Xiaomi MiMo",
        fields: [
            CredentialField("cookie", "Cookie header", optional: true,
                            placeholder: "api-platform_serviceToken and userId from platform.xiaomimimo.com"),
            CredentialField("localUsagePath", "Local usage cache", secure: false, optional: true,
                            placeholder: MiMoUsage.defaultLocalPath, env: ["MIMO_LOCAL_USAGE_PATH"]),
        ],
        dashboard: "https://platform.xiaomimimo.com/#/console/balance",
        usage: { credential in
            // Without a usable web session, fall back to the local token cache when it exists.
            do {
                guard let raw = credential["cookie"] else {
                    throw ProviderError.missingCredential("Add a Cookie header from platform.xiaomimimo.com.")
                }
                let cookie = try MiMoUsage.cookie(raw)
                let headers = [
                    "Accept": "application/json, text/plain, */*", "Cookie": cookie,
                    "Accept-Language": "en-US,en;q=0.9", "x-timeZone": "UTC+01:00",
                    "Origin": "https://platform.xiaomimimo.com",
                    "Referer": "https://platform.xiaomimimo.com/#/console/balance",
                ]
                let base = "https://platform.xiaomimimo.com/api/v1"
                async let balance = HTTP.send(base + "/balance", headers: headers)
                async let detail = try? HTTP.send(base + "/tokenPlan/detail", headers: headers)
                async let usage = try? HTTP.send(base + "/tokenPlan/usage", headers: headers)
                let balanceResponse = try await balance
                // An expired session redirects to the login flow.
                if (300..<400).contains(balanceResponse.status) {
                    throw ProviderError.unauthorized("MiMo session expired. Paste a new Cookie header.")
                }
                try HTTP.check(balanceResponse)
                guard let balanceJSON = try? balanceResponse.json() else {
                    throw ProviderError.unauthorized("MiMo session expired. Paste a new Cookie header.")
                }
                return try MiMoUsage.map(balance: balanceJSON,
                                         detail: await detail.flatMap { try? $0.json() },
                                         usage: await usage.flatMap { try? $0.json() })
            } catch let error as ProviderError where error.needsSignIn {
                if let local = MiMoUsage.local(path: credential["localUsagePath"] ?? MiMoUsage.defaultLocalPath) {
                    return local
                }
                throw error
            }
        })
}

/// Pasted Cookie headers often keep the "Cookie:" label or surrounding quotes.
enum PastedCookie {
    static func clean(_ raw: String) -> String {
        let trim = CharacterSet(charactersIn: "\"'").union(.whitespacesAndNewlines)
        var text = raw.trimmingCharacters(in: trim)
        if text.lowercased().hasPrefix("cookie:") { text = String(text.dropFirst(7)) }
        return text.trimmingCharacters(in: trim)
    }
}

enum MiMoUsage {
    /// Keeps only the cookies MiMo reads; both `api-platform_serviceToken` and `userId` are required.
    static func cookie(_ header: String) throws -> String {
        let keep = ["api-platform_serviceToken", "userId", "api-platform_ph", "api-platform_slh"]
        let header = PastedCookie.clean(header)
        let pairs = keep.sorted().compactMap { name in Fmt.cookie(name, in: header).map { "\(name)=\($0)" } }
        guard pairs.contains(where: { $0.hasPrefix("api-platform_serviceToken=") }),
              pairs.contains(where: { $0.hasPrefix("userId=") }) else {
            throw ProviderError.missingCredential("The Cookie header needs api-platform_serviceToken and userId.")
        }
        return pairs.joined(separator: "; ")
    }

    private static func check(_ json: JSON) throws {
        guard let code = json["code"].int, code != 0 else { return }
        if code == 401 || code == 403 { throw ProviderError.unauthorized("MiMo rejected this session. Paste a new Cookie header.") }
        throw ProviderError.parse("MiMo returned error code \(code).")
    }

    static func map(balance: JSON, detail: JSON?, usage: JSON?, now: Date = Date()) throws -> ProviderUsage {
        try check(balance)
        let data = balance["data"]
        guard let amount = data["balance"].double, let currency = data["currency"].string else {
            throw ProviderError.parse("MiMo returned an unexpected balance shape.")
        }
        var rows: [UsageRow] = []
        if let cash = data["cashBalance"].double { rows.append(UsageRow("Paid", Fmt.money(cash, currency: currency))) }
        if let gift = data["giftBalance"].double { rows.append(UsageRow("Granted", Fmt.money(gift, currency: currency))) }
        var plan: String?
        var periodEnd: Date?
        if let detail, (try? check(detail)) != nil {
            plan = detail["data"]["planCode"].string?.capitalized
            periodEnd = detail["data"]["currentPeriodEnd"].date
        }
        var windows: [UsageWindow] = []
        if let usage, (try? check(usage)) != nil {
            let month = usage["data"]["monthUsage"]
            let item = month["items"][0]
            if let limit = item["limit"].double, limit > 0 {
                let used = item["used"].double ?? 0
                let percent = (item["percent"].double ?? month["percent"].double).map { $0 * 100 } ?? used / limit * 100
                windows.append(UsageWindow(id: "monthly", title: "Credits", usedPercent: percent, resetsAt: periodEnd,
                                           windowMinutes: periodEnd == nil ? nil : 43200,
                                           detail: "\(Fmt.number(used)) / \(Fmt.number(limit)) Credits"))
            }
        }
        return ProviderUsage(windows: windows, cost: UsageCost(balance: amount, currency: currency),
                             sections: [UsageSection("Credits", rows)], plan: plan, fetchedAt: now)
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
