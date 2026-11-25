import Foundation

extension ProviderCatalog {
    static let alibaba = ProviderSpec(
        id: "alibaba", name: "Alibaba Coding Plan",
        fields: [
            CredentialField("apiKey", "API key",
                            env: ["ALIBABA_CODING_PLAN_API_KEY", "ALIBABA_QWEN_API_KEY", "DASHSCOPE_API_KEY"]),
            CredentialField("region", "Region", secure: false, optional: true, placeholder: "intl or cn"),
        ],
        dashboard: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan#/efm/coding_plan",
        statusPage: nil,
        usage: { credential in
            let key = try credential.require("apiKey")
            func run(_ cn: Bool) async throws -> ProviderUsage { try await AlibabaUsage.fetchKey(key, cn: cn) }
            if credential["region"]?.lowercased() == "cn" { return try await run(true) }
            do {
                return try await run(false)
            } catch where AlibabaUsage.retryOnChina(error) {
                // Some accounts live on the China console.
                return try await run(true)
            }
        })
}

enum AlibabaUsage {
    private struct Site {
        let gateway: String, dashboard: String, rpc: String, rpcAction: String
        let region: String, commodity: String, domain: String, site: String
    }

    private static func site(cn: Bool) -> Site {
        cn ? Site(gateway: "https://bailian.console.aliyun.com",
                  dashboard: "https://bailian.console.aliyun.com/cn-beijing/?tab=model#/efm/coding_plan",
                  rpc: "https://bailian-cs.console.aliyun.com", rpcAction: "BroadScopeAspnGateway",
                  region: "cn-beijing", commodity: "sfm_codingplan_public_cn",
                  domain: "bailian.console.aliyun.com", site: "BAILIAN_ALIYUN")
           : Site(gateway: "https://modelstudio.console.alibabacloud.com",
                  dashboard: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan#/efm/coding_plan",
                  rpc: "https://bailian-singapore-cs.alibabacloud.com", rpcAction: "IntlBroadScopeAspnGateway",
                  region: "ap-southeast-1", commodity: "sfm_codingplan_public_intl",
                  domain: "modelstudio.console.alibabacloud.com", site: "MODELSTUDIO_ALIBABACLOUD")
    }

    private static let api = "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2"

    /// Credential, host, or empty-plan failures on the international console that the China console may still answer.
    static func retryOnChina(_ error: Error) -> Bool {
        switch error as? ProviderError {
        case .unauthorized, .parse: true
        case .http(let code, _): code == 404
        default: false
        }
    }

    static func fetchKey(_ key: String, cn: Bool) async throws -> ProviderUsage {
        let s = site(cn: cn)
        let url = "\(s.gateway)/data/api.json?action=\(api)&product=broadscope-bailian&api=queryCodingPlanInstanceInfoV2&currentRegionId=\(s.region)"
        let headers = ["Authorization": "Bearer \(key)", "x-api-key": key, "X-DashScope-API-Key": key,
                       "User-Agent": OneConsole.userAgent, "Origin": s.gateway, "Referer": s.dashboard]
        return try map(try await HTTP.json(url, headers: headers,
                                           object: ["queryCodingPlanInstanceInfoRequest": ["commodityCode": s.commodity]]),
                       apiKey: true)
    }

    private static let instanceKeys = ["codingPlanInstanceInfos", "coding_plan_instance_infos"]
    private static let quotaKeys = ["codingPlanQuotaInfo", "coding_plan_quota_info"]

    /// Maps the instance-info response; embedded JSON strings are expanded first. The active
    /// instance wins, its quota is never borrowed from another one, and a plan that is provably
    /// active but exposes no counters still shows its name.
    static func map(_ json: JSON, now: Date = Date(), apiKey: Bool = false) throws -> ProviderUsage {
        guard let root = OneConsole.expand(json.raw) as? [String: Any] else {
            throw ProviderError.parse("Alibaba returned an unexpected payload.")
        }
        try check(root, apiKey: apiKey)

        let instances = (OneConsole.first(instanceKeys, in: root) { $0 as? [Any] } ?? []).compactMap { $0 as? [String: Any] }
        var best: [String: Any]?
        var bestScore = Int.min
        for item in instances where score(item, now) > bestScore {
            best = item
            bestScore = score(item, now)
        }
        let active = bestScore > 0 ? best : instances.first
        let scoped = instances.count > 1 && (active.map { score($0, now) > 0 } ?? false)
        let own = active.flatMap { findQuota($0) }
        let quota = scoped ? own : (own ?? findQuota(root))
        let plan = active.flatMap { planName(in: $0) } ?? planName(in: root)

        /// Plan name alone, when the payload proves the plan is active.
        func planOnly(_ failure: String) throws -> ProviderUsage {
            let source = active ?? root
            let proof = instances.isEmpty ? score(source, now) > 0 || score(root, now) > 0 : score(source, now) > 0
            guard proof, let name = planName(in: source) ?? planName(in: root) else { throw ProviderError.parse(failure) }
            return ProviderUsage(plan: name, fetchedAt: now)
        }
        guard let quota else { return try planOnly("Alibaba returned no coding plan quota.") }

        let slots: [(String, String, [String], Int)] = [
            ("session", "Session", ["per5Hour", "perFiveHour"], 300),
            ("weekly", "Weekly", ["perWeek"], 10080),
            ("monthly", "Monthly", ["perBillMonth", "perMonth"], 43200),
        ]
        func read(_ prefixes: [String], _ suffix: String) -> Any? { prefixes.lazy.compactMap { quota[$0 + suffix] }.first }
        guard slots.contains(where: { OneConsole.int(read($0.2, "TotalQuota")) != nil }) else {
            return try planOnly("Alibaba returned no coding plan quota windows.")
        }
        var windows: [UsageWindow] = []
        for (id, title, prefixes, minutes) in slots {
            guard let total = OneConsole.int(read(prefixes, "TotalQuota")).map(Double.init), total > 0 else { continue }
            var reset = OneConsole.date(read(prefixes, "QuotaNextRefreshTime"))
            if id == "session", var date = reset, date.timeIntervalSince(now) < 60 {
                date = date.addingTimeInterval(18000)
                reset = date.timeIntervalSince(now) < 60 ? now.addingTimeInterval(18000) : date
            }
            let used = min(max(Double(OneConsole.int(read(prefixes, "UsedQuota")) ?? 0), 0), total)
            windows.append(UsageWindow(id: id, title: title, usedPercent: used / total * 100, resetsAt: reset,
                                       windowMinutes: minutes, detail: "\(Fmt.number(used)) / \(Fmt.number(total)) requests"))
        }
        return ProviderUsage(windows: windows, plan: plan, fetchedAt: now)
    }

    /// Error shapes the console wraps in a 200 answer.
    private static func check(_ root: [String: Any], apiKey: Bool) throws {
        func str(_ keys: [String]) -> String? { OneConsole.first(keys, in: root, OneConsole.string) }
        if let status = OneConsole.first(["statusCode", "status_code", "code"], in: root, OneConsole.int), status != 0, status != 200 {
            let message = str(["statusMessage", "status_msg", "message", "msg"]) ?? "status code \(status)"
            let lower = message.lowercased()
            if status == 401 || status == 403 || lower.contains("api key") || lower.contains("unauthorized") {
                throw ProviderError.unauthorized("Alibaba rejected this API key. Paste a fresh key.")
            }
            throw ProviderError.http(status, "Alibaba returned an error: \(message)")
        }
        let consoleOnly: ProviderError = apiKey
            ? .unsupported("Alibaba Coding Plan quota is not available through API keys for this account or region.")
            : .unauthorized("Alibaba Coding Plan rejected this API key.")
        if str(["code", "status", "statusCode"])?.lowercased().contains("login") == true { throw consoleOnly }
        if let message = str(["message", "msg", "statusMessage"])?.lowercased() {
            if message.contains("log in") || message.contains("login") { throw consoleOnly }
            if apiKey, message.contains("console session") || message.contains("api key mode may be unavailable") { throw consoleOnly }
        }
    }

    /// The named quota object (dictionaries only), else the first object that holds a quota counter.
    private static func findQuota(_ value: Any?) -> [String: Any]? {
        OneConsole.first(quotaKeys, in: value, arrays: false, OneConsole.dict)
            ?? OneConsole.find(["per5HourUsedQuota", "per5HourTotalQuota", "perWeekUsedQuota", "perWeekTotalQuota",
                                "perBillMonthUsedQuota", "perBillMonthTotalQuota"], in: value)
    }

    private static func planName(in payload: Any?) -> String? {
        if let infos = OneConsole.first(instanceKeys, in: payload, { $0 as? [Any] }) {
            for case let info as [String: Any] in infos {
                let keys = ["planName", "plan_name", "instanceName", "instance_name", "packageName", "package_name"]
                if let name = keys.lazy.compactMap({ OneConsole.string(info[$0]) }).first { return name }
            }
        }
        return OneConsole.first(["planName", "plan_name", "packageName", "package_name"], in: payload, OneConsole.string)
    }

    /// Ranks plan instances so the live one wins when several are returned.
    private static func score(_ item: [String: Any], _ now: Date) -> Int {
        let status = ["status", "instanceStatus"].lazy.compactMap { OneConsole.string(item[$0]) }.first?.uppercased() ?? ""
        if ["VALID", "ACTIVE"].contains(status) { return 3 }
        if ["EXPIRED", "INVALID", "INACTIVE", "DISABLED", "TERMINATED", "STOPPED"].contains(status) { return -1 }
        if let active = ["isActive", "active"].lazy.compactMap({ OneConsole.bool(item[$0]) }).first { return active ? 3 : -1 }
        let end = ["endTime", "periodEndTime", "expireTime", "expirationTime"].lazy.compactMap { OneConsole.date(item[$0]) }.first
        return end.map { $0 > now ? 1 : 0 } ?? 0
    }
}

/// Aliyun OneConsole gateway helpers. Answers nest JSON inside JSON strings and move fields between
/// shapes, so lookups walk the whole tree instead of fixed paths.
enum OneConsole {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36"

    /// Replaces every string value that holds JSON with its parsed value.
    static func expand(_ value: Any?) -> Any? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
                  let parsed = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else { return value }
            return expand(parsed)
        case let dict as [String: Any]: return dict.mapValues { expand($0) ?? $0 }
        case let array as [Any]: return array.map { expand($0) ?? $0 }
        default: return value
        }
    }

    /// First value `transform` accepts, checking each dictionary (keys in caller order) before its children.
    static func first<T>(_ keys: [String], in value: Any?, arrays: Bool = true, _ transform: (Any?) -> T?) -> T? {
        if let dict = value as? [String: Any] {
            for key in keys { if let found = transform(dict[key]) { return found } }
            for nested in dict.values { if let found = first(keys, in: nested, arrays: arrays, transform) { return found } }
        } else if arrays, let list = value as? [Any] {
            for nested in list { if let found = first(keys, in: nested, arrays: arrays, transform) { return found } }
        }
        return nil
    }

    /// First dictionary, depth first, that holds any of the keys.
    static func find(_ keys: [String], in value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if dict.keys.contains(where: keys.contains) { return dict }
            for nested in dict.values { if let found = find(keys, in: nested) { return found } }
        } else if let list = value as? [Any] {
            for nested in list { if let found = find(keys, in: nested) { return found } }
        }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    static func dict(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where !JSON.isBoolean(number): number.doubleValue
        case let text as String: Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ""))
        default: nil
        }
    }

    static func int(_ value: Any?) -> Int? { double(value).flatMap(Fmt.int) }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        case let text as String:
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "active", "valid", "normal": return true
            case "false", "0", "no", "inactive", "invalid", "expired": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// Epoch seconds or milliseconds, ISO-8601, "yyyy-MM-dd", "yyyy-MM-dd HH:mm" and "yyyy-MM-dd HH:mm:ss".
    /// Numbers at or below `floor` are not dates.
    static func date(_ value: Any?, above floor: Double = 0) -> Date? {
        if let number = double(value) { return number > floor ? Fmt.epoch(number) : nil }
        guard let text = value as? String else { return nil }
        if let date = Fmt.iso(text) { return date }
        let minute = DateFormatter()
        minute.locale = Locale(identifier: "en_US_POSIX")
        minute.dateFormat = "yyyy-MM-dd HH:mm"
        return minute.date(from: text)
    }
}
