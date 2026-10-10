import Foundation

extension ProviderCatalog {
    /// GLM Coding Plan quota on z.ai (global) or open.bigmodel.cn (China). Both hosts serve the same undocumented monitor API.
    static let zai = ProviderSpec(
        id: "zai", name: "z.ai / GLM",
        fields: [.apiKey("Z_AI_API_KEY", "ZAI_API_KEY", "GLM_API_KEY"),
                 CredentialField("region", "Region", secure: false, optional: true, placeholder: "global or cn (default global)"),
                 CredentialField("organization", "Organization ID", secure: false, optional: true, placeholder: "Team plans only"),
                 CredentialField("project", "Project ID", secure: false, optional: true, placeholder: "Team plans only")],
        dashboard: "https://z.ai/manage-apikey/coding-plan/personal/my-plan",
        usage: { credential in
            let key = try credential.require("apiKey")
            let china = ZaiUsage.isChina(credential["region"])
            let base = china ? "https://open.bigmodel.cn" : "https://api.z.ai"
            var headers = HTTP.bearer(key)
            var query = ""
            if let organization = credential["organization"], let project = credential["project"] {
                headers["Bigmodel-Organization"] = organization
                headers["Bigmodel-Project"] = project
                query = "?type=2"
            }
            var usage = try ZaiUsage.map(try await HTTP.json("\(base)/api/monitor/usage/quota/limit\(query)", headers: headers))
            // The plan name and the China account balance come from separate endpoints. Both are optional.
            if usage.plan == nil, !china,
               let plan = try? await HTTP.json("https://api.z.ai/api/biz/subscription/list", headers: headers) {
                usage.plan = plan["data"][0]["productName"].string
            }
            if china, let balance = try? await HTTP.json("https://www.bigmodel.cn/api/biz/account/query-customer-account-report", headers: headers) {
                ZaiUsage.addBalance(balance, to: &usage)
            }
            // Optional token analytics per model (hourly for today, daily for 30 days); a failure hides them.
            let team = query.isEmpty ? "" : "&type=3"
            for (days, title) in [(1, "Hourly tokens"), (30, "Daily tokens")] {
                let range = ZaiUsage.timeRange(days: days)
                if let json = try? await HTTP.json("\(base)/api/monitor/usage/model-usage?startTime=\(range.start)&endTime=\(range.end)\(team)",
                                                   headers: headers),
                   let section = ZaiUsage.modelUsage(json, title: title) {
                    usage.sections.append(section)
                }
            }
            return usage
        })
}

enum ZaiUsage {
    static func isChina(_ region: String?) -> Bool {
        ["cn", "china", "bigmodel-cn"].contains(region?.lowercased() ?? "")
    }

    private struct Limit {
        let type: String
        let unit: Int, number: Int
        let percent: Double
        let usage: Double?, current: Double?
        let minutes: Int?
        let reset: Date?
        let models: [JSON]
    }

    static func map(_ json: JSON, now: Date = Date()) throws -> ProviderUsage {
        guard json["success"].bool == true, json["code"].int == 200 else {
            if (json["msg"].string ?? "").lowercased().contains("coding plan") {
                throw ProviderError.unsupported("No active GLM Coding Plan on this account.")
            }
            throw ProviderError.parse("z.ai returned an error instead of quota data.")
        }
        let data = json["data"]
        guard data["limits"].raw is [Any] else { throw ProviderError.parse("Unsupported z.ai quota format.") }

        var limits: [Limit] = []
        for raw in data["limits"].array {
            guard let type = raw["type"].string else { continue }
            guard ["TOKENS_LIMIT", "CREDIT_LIMIT", "TIME_LIMIT"].contains(type) else { continue }
            guard let unit = raw["unit"].int, let number = raw["number"].int, let reported = raw["percentage"].double else {
                throw ProviderError.parse("Unsupported z.ai quota entry.")
            }
            let usage = raw["usage"].double, current = raw["currentValue"].double, remaining = raw["remaining"].double
            var percent = reported
            if let usage, usage > 0 {
                var used: Double?
                if let remaining { used = max(usage - remaining, current ?? usage - remaining) } else { used = current }
                if let used { percent = min(max(used, 0), usage) / usage * 100 }
            }
            let unitMinutes = [1: 1440, 3: 60, 4: 1440, 5: 1, 6: 10080][unit]
            var minutes = number > 0 ? unitMinutes.map { $0 * number } : nil
            // One month of MCP calls is reported as unit 5, number 1.
            if type == "TIME_LIMIT", unit == 5, number == 1 { minutes = 43200 }
            var reset = raw["nextResetTime"].double.flatMap(Fmt.epoch)
            // A five-hour reset cannot be further away than five hours, so a larger value is a timezone slip.
            if type != "TIME_LIMIT", minutes == 300, let date = reset, date > now.addingTimeInterval(5 * 3600 + 60) { reset = nil }
            limits.append(Limit(type: type, unit: unit, number: number, percent: min(max(percent, 0), 100), usage: usage,
                                current: current, minutes: minutes, reset: reset, models: raw["usageDetails"].array))
        }

        var windows: [UsageWindow] = []
        var seen = Set<String>()
        let tokenLimits = limits.filter { $0.type != "TIME_LIMIT" }.sorted { ($0.minutes ?? .max) < ($1.minutes ?? .max) }
        for (index, limit) in tokenLimits.enumerated() {
            let short = (limit.minutes ?? .max) < 1440
            var id = short ? "session" : "weekly"
            if !seen.insert(id).inserted { id = "limit-\(index + 1)" }
            let unit = limit.type == "CREDIT_LIMIT" ? "credits" : "tokens"
            windows.append(UsageWindow(id: id, title: id == "session" ? "Session" : id == "weekly" ? "Weekly" : "Quota",
                                       usedPercent: limit.percent, resetsAt: limit.reset, windowMinutes: limit.minutes,
                                       detail: amount(limit, unit: unit)))
        }
        var sections: [UsageSection] = []
        if let mcp = limits.last(where: { $0.type == "TIME_LIMIT" }) {
            windows.append(UsageWindow(id: "mcp", title: "MCP and web searches", usedPercent: mcp.percent, resetsAt: mcp.reset,
                                       windowMinutes: mcp.minutes, detail: amount(mcp, unit: "calls")))
            let rows = mcp.models.prefix(6).compactMap { model -> UsageRow? in
                guard let name = model["modelCode"].string, let count = model["usage"].int else { return nil }
                return UsageRow(name, String(count))
            }
            sections.append(UsageSection("MCP usage by tool", rows))
        }
        if windows.isEmpty { sections.append(UsageSection(nil, [UsageRow("Quota", "No usage data")])) }
        if limits.contains(where: { $0.type == "CREDIT_LIMIT" }) { sections.append(UsageSection(nil, [quotaRate(now)])) }
        let plan = ["planName", "plan", "plan_type", "packageName", "level"].lazy.compactMap { data[$0].string }.first
        return ProviderUsage(windows: windows, sections: sections, plan: plan)
    }

    /// Credit plans charge 1x in peak hours (Mon-Fri 06:00-10:00 UTC) and 0.5x otherwise. No endpoint reports
    /// this; it is a function of the clock (docs.z.ai/devpack/overview).
    static func quotaRate(_ now: Date) -> UsageRow {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.weekday, .hour], from: now)
        let weekday = parts.weekday ?? 2, hour = parts.hour ?? 0   // 1 = Sunday
        let isPeak = (2...6).contains(weekday) && (6..<10).contains(hour)
        var boundary = utc.startOfDay(for: now).addingTimeInterval(TimeInterval((isPeak ? 10 : 6) * 3600))
        if !isPeak {
            if hour >= 6 { boundary = boundary.addingTimeInterval(86_400) }
            while [1, 7].contains(utc.component(.weekday, from: boundary)) { boundary = boundary.addingTimeInterval(86_400) }
        }
        let minutes = max(1, Int((boundary.timeIntervalSince(now) / 60).rounded(.up)))
        let wait = minutes >= 1440 ? "\(minutes / 1440)d \(minutes / 60 % 24)h" : minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        return UsageRow("Quota rate", "\(isPeak ? "Peak" : "Off-peak") (\(isPeak ? "off-peak" : "peak") in \(wait))")
    }

    /// Local-time `yyyy-MM-dd HH:mm:ss` bounds, percent-encoded: `days` back from midnight to the end of this hour.
    static func timeRange(days: Int, now: Date = Date()) -> (start: String, end: String) {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? now
        var end = calendar.dateComponents([.year, .month, .day, .hour], from: now)
        end.minute = 59
        end.second = 59
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func encode(_ date: Date) -> String {
            formatter.string(from: date).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        }
        return (encode(start), encode(calendar.date(from: end) ?? now))
    }

    /// Token totals per model from `/api/monitor/usage/model-usage`, largest first.
    static func modelUsage(_ json: JSON, title: String) -> UsageSection? {
        guard json["success"].bool == true else { return nil }
        let totals = json.at("data.modelDataList").array.compactMap { model -> (String, Int)? in
            let sum = model["tokensUsage"].array.reduce(0.0) { $0 + max(0, $1.double ?? 0) }
            return sum > 0 ? (model["modelName"].string ?? "Unknown", Int(min(sum, 1e15))) : nil
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        return totals.isEmpty ? nil : UsageSection(title, totals.prefix(20).map { UsageRow($0.0, MajorsSpend.compact($0.1)) })
    }

    private static func amount(_ limit: Limit, unit: String) -> String? {
        guard let usage = limit.usage, usage > 0, let used = limit.current else { return nil }
        return "\(Fmt.number(used)) / \(Fmt.number(usage)) \(unit)"
    }

    /// China pay-as-you-go balance in yuan.
    static func addBalance(_ json: JSON, to usage: inout ProviderUsage) {
        let data = json["data"]
        guard json["success"].bool == true, let balance = data["availableBalance"].double ?? data["balance"].double else { return }
        usage.cost = UsageCost(used: data["totalSpendAmount"].double, balance: balance, currency: "CNY", period: "Account balance")
        let rows = [("Recharged", "rechargeAmount"), ("Granted", "giveAmount")].compactMap { label, key -> UsageRow? in
            data[key].double.flatMap { $0 > 0 ? UsageRow(label, Fmt.money($0, currency: "CNY")) : nil }
        }
        if !rows.isEmpty { usage.sections.append(UsageSection("Account balance", rows)) }
    }
}
