import Foundation

extension ProviderCatalog {
    static let chutes = ProviderSpec(
        id: "chutes", name: "Chutes",
        fields: [.apiKey("CHUTES_API_KEY")],
        dashboard: "https://chutes.ai",
        usage: { credential in
            let headers = HTTP.bearer(try credential.require("apiKey"))
            let base = "https://api.chutes.ai/users/me"
            let subscription = try await HTTP.json("\(base)/subscription_usage", headers: headers)
            // Quota detail is best-effort: it only fills windows the subscription did not report.
            var quotas: JSON?
            if !ChutesUsage.hasBothWindows(subscription), let list = try? await HTTP.json("\(base)/quotas", headers: headers) {
                var enriched: [Any] = []
                let items = [list, list["quotas"], list["data"], list.at("data.quotas")].first { $0.raw is [Any] }?.array ?? []
                for item in items.prefix(5) {
                    var merged = item.object.mapValues(\.raw)
                    if let id = (item["chute_id"].string ?? item["chuteId"].string ?? item["id"].string)?
                        .addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                       let usage = try? await HTTP.json("\(base)/quota_usage/\(id)", headers: headers) {
                        let body = usage["data"].exists ? usage["data"] : usage["result"].exists ? usage["result"] : usage
                        for (key, value) in body.object { merged[key] = value.raw }
                    }
                    enriched.append(merged as Any)
                }
                quotas = enriched.isEmpty ? list : JSON(["quotas": enriched])
            }
            return try ChutesUsage.map(subscription, quotas: quotas)
        })
}

enum ChutesUsage {
    private static func key(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII }
    }
    private static func value(_ object: JSON, _ keys: [String]) -> JSON {
        let entries = object.object
        for wanted in keys {
            if let entry = entries.first(where: { key($0.key) == wanted }) { return entry.value }
        }
        return JSON(nil)
    }
    private static func number(_ json: JSON, _ keys: [String]) -> Double? {
        let found = value(json, keys)
        if let text = found.raw as? String { return Double(text.trimmingCharacters(in: .whitespaces).filter { !",$%".contains($0) }) }
        return found.double
    }
    private static func date(_ json: JSON) -> Date? { json.date }

    private struct Quota: Equatable {
        var label: String?, unit: String
        var percent: Double, windowMinutes: Int?, resetsAt: Date?, detail: String?
    }
    private struct Parsed {
        var rolling: Quota?, monthly: Quota?, fallback: [Quota] = []
        var plan: String?, active: Bool?, renewal: Date?
    }

    private static func minutes(_ payload: JSON) -> Int? {
        for (keys, factor) in [(["windowminutes", "periodminutes", "durationminutes"], 1.0),
                               (["windowhours", "periodhours", "durationhours"], 60),
                               (["windowdays", "perioddays", "durationdays"], 1440),
                               (["windowseconds", "periodseconds", "durationseconds"], 1.0 / 60)] {
            if let n = number(payload, keys) { return positive(n * factor) }
        }
        let text = value(payload, ["window", "period", "interval", "duration"]).string?.lowercased().replacingOccurrences(of: " ", with: "")
        guard let text, let match = text.range(of: #"^\+?(?:\d+\.?\d*|\.\d+)"#, options: .regularExpression),
              let amount = Double(text[match]), amount > 0 else { return nil }
        let unit = text[match.upperBound...]
        let factor: Double = unit.hasPrefix("min") || unit == "m" ? 1 : unit.hasPrefix("hour") || unit.hasPrefix("hr") || unit == "h"
            ? 60 : unit.hasPrefix("day") || unit == "d" ? 1440 : unit.hasPrefix("month") || unit == "mo" ? 43200 : .nan
        return positive(amount * factor)
    }
    private static func positive(_ minutes: Double) -> Int? {
        let rounded = minutes.rounded()
        return rounded > 0 && rounded < 1e15 ? Int(rounded) : nil
    }

    private static func quota(_ payload: JSON, label: String? = nil, minutes defaultMinutes: Int? = nil) -> Quota? {
        let limit = number(payload, ["limit", "cap", "max", "maximum", "quota", "quotalimit", "monthlycap", "monthlylimit",
                                      "requestlimit", "tokenlimit", "hardlimit", "total"])
        let used = number(payload, ["used", "usage", "usedamount", "consumed", "consumedamount", "current", "currentusage",
                                     "requests", "requestcount", "tokens", "tokenusage", "monthlyusage"])
        let remaining = number(payload, ["remaining", "available", "balance", "left", "remainingamount", "availableamount"])
        func normalize(_ v: Double) -> Double { max(0, min(100, abs(v) < 1 ? v * 100 : v)) }
        let percentUsed = number(payload, ["percentused", "usagepercent", "usedpercent", "utilization", "utilizationpercent"])
        let percentRemaining = number(payload, ["percentremaining", "remainingpercent"])
        let total = limit ?? (used != nil && remaining != nil ? used! + remaining! : nil)
        let consumed = used ?? (total != nil && remaining != nil ? total! - remaining! : nil)
        let percent: Double
        if let percentUsed { percent = normalize(percentUsed) }
        else if let percentRemaining { percent = 100 - normalize(percentRemaining) }
        else if let total, total > 0, let consumed { percent = consumed / total * 100 }
        else { return nil }
        let unit = value(payload, ["unit", "units", "currency", "quotaunit"]).string ?? "credits"
        let described = used ?? (limit != nil && remaining != nil ? max(0, limit! - remaining!) : nil)
        var detail: String?
        if let limit, limit > 0, let described { detail = "\(Fmt.number(described, digits: 2))/\(Fmt.number(limit, digits: 2)) \(unit)" }
        return Quota(label: value(payload, ["label", "name", "title", "type", "quotatype", "period", "window", "windowname",
                                            "chuteid"]).string ?? label,
                     unit: unit, percent: max(0, min(100, percent)), windowMinutes: minutes(payload) ?? defaultMinutes,
                     resetsAt: date(value(payload, ["resetat", "resetsat", "resettime", "nextresetat", "renewsat", "renewalat",
                                                    "periodend", "currentperiodend", "expiresat", "windowend", "endtime"])),
                     detail: detail)
    }

    /// The same quota found again by the tree scan carries no default label, so compare the numbers only (a missing duration matches any).
    private static func same(_ a: Quota, _ b: Quota?) -> Bool {
        guard let b else { return false }
        return a.percent == b.percent && (a.windowMinutes == nil || b.windowMinutes == nil || a.windowMinutes == b.windowMinutes) && a.resetsAt == b.resetsAt && a.detail == b.detail
    }

    private static func parse(_ input: JSON) -> Parsed {
        let root = input.raw is [Any] ? JSON(["quotas": input.raw as Any]) : input
        let dataValue = value(root, ["data", "result"])
        let data = dataValue.raw is [String: Any] ? dataValue : root
        func dictionary(_ keys: [String]) -> JSON? {
            for candidate in [root, data] {
                let found = value(candidate, keys)
                if found.raw is [String: Any] { return found }
            }
            return nil
        }
        let subscription = dictionary(["subscription", "subscriptionusage", "currentsubscription", "plan"]) ?? JSON([String: Any]())
        func context(_ keys: [String]) -> JSON {
            [root, data, subscription].map { value($0, keys) }.first { $0.exists } ?? JSON(nil)
        }
        var windows: [Quota] = []
        func collect(_ node: JSON) {
            if node.raw is [Any] { node.array.forEach(collect); return }
            guard node.raw is [String: Any] else { return }
            if let q = quota(node), !windows.contains(q) { windows.append(q) }
            node.object.values.forEach(collect)
        }
        let containerKeys = ["quotas", "quota", "quotausage", "limits", "usage", "entries", "subscriptionusage"]
        [value(root, containerKeys), value(data, containerKeys), data, root].forEach(collect)
        func kind(_ q: Quota) -> String? {
            let label = "\(q.label ?? "") \(q.unit)".lowercased()
            if label.range(of: "rolling|4h|4 h|4-hour|four hour|four-hour", options: .regularExpression) != nil
                || q.windowMinutes == 240 { return "rolling" }
            if label.range(of: "month|billing|subscription", options: .regularExpression) != nil
                || (q.windowMinutes ?? 0) >= 40320 { return "monthly" }
            return nil
        }
        let rolling = dictionary(["rolling", "rollingwindow", "rolling4h", "fourhour", "fourhourusage", "window4h"])
            .flatMap { quota($0, label: "4-hour quota", minutes: 240) } ?? windows.first { kind($0) == "rolling" }
        let monthly = dictionary(["monthly", "monthlyusage", "subscription", "subscriptionusage", "billingperiod"])
            .flatMap { quota($0, label: "Monthly quota", minutes: 43200) } ?? windows.first { kind($0) == "monthly" }
        var active = context(["active", "isactive", "subscriptionactive", "hassubscription"]).bool
        if active == nil {
            let status = context(["status", "state", "subscriptionstatus"]).string?.lowercased() ?? ""
            if status.contains("active") && !status.contains("inactive") { active = true }
            else if status.range(of: "free|inactive|cancel|none|expired", options: .regularExpression) != nil { active = false }
        }
        return Parsed(rolling: rolling, monthly: monthly,
                      fallback: windows.filter { !same($0, rolling) && !same($0, monthly) },
                      plan: context(["planname", "plan", "tier", "subscriptionplan", "subscriptiontier"]).string,
                      active: active,
                      renewal: date(context(["resetat", "resetsat", "resettime", "nextresetat", "renewsat", "renewalat",
                                             "periodend", "currentperiodend", "expiresat", "windowend", "endtime"])))
    }

    static func hasBothWindows(_ subscription: JSON) -> Bool {
        let parsed = parse(subscription)
        return parsed.rolling != nil && parsed.monthly != nil
    }

    /// `quotas` is the optional `/quotas` payload (with per-chute usage merged in), used only for missing windows.
    static func map(_ subscription: JSON, quotas: JSON? = nil) throws -> ProviderUsage {
        guard subscription.raw is [String: Any] || subscription.raw is [Any] else {
            throw ProviderError.parse("Chutes usage parse error: invalid JSON.")
        }
        var parsed = parse(subscription)
        if (parsed.rolling == nil || parsed.monthly == nil), let quotas {
            let extra = parse(quotas)
            if extra.rolling != nil || extra.monthly != nil || !extra.fallback.isEmpty {
                parsed.rolling = parsed.rolling ?? extra.rolling
                parsed.monthly = parsed.monthly ?? extra.monthly
                parsed.fallback += extra.fallback
            }
        }
        func window(_ id: String, _ title: String, _ q: Quota, minutes: Int? = nil, resets: Date? = nil) -> UsageWindow {
            UsageWindow(id: id, title: q.label ?? title, usedPercent: q.percent, resetsAt: q.resetsAt ?? resets,
                        windowMinutes: q.windowMinutes ?? minutes, detail: q.detail)
        }
        var windows: [UsageWindow] = []
        if let rolling = parsed.rolling { windows.append(window("rolling", "4-hour quota", rolling, minutes: 240)) }
        if let monthly = parsed.monthly {
            windows.append(window("monthly", "Monthly quota", monthly, minutes: 43200, resets: parsed.renewal))
        }
        for (index, quota) in parsed.fallback.enumerated() { windows.append(window("quota-\(index)", "Quota", quota)) }
        return ProviderUsage(windows: windows, plan: parsed.plan ?? (parsed.active == false ? "No active subscription" : nil))
    }
}
