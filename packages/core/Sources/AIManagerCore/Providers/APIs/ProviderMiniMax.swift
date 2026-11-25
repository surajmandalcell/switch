import Foundation

extension ProviderCatalog {
    static let minimax = ProviderSpec(
        id: "minimax", name: "MiniMax",
        fields: [
            CredentialField("apiKey", "API key", env: ["MINIMAX_CODING_API_KEY", "MINIMAX_API_KEY"]),
            CredentialField("region", "Region", secure: false, optional: true, placeholder: "global or cn"),
        ],
        dashboard: "https://platform.minimax.io/user-center/payment/coding-plan?cycle_type=3",
        usage: { credential in
            try await MiniMaxUsage.fetchAPI(key: try credential.require("apiKey"),
                                            china: credential["region"]?.lowercased() == "cn")
        })
}

enum MiniMaxUsage {
    // MARK: API key path

    static func fetchAPI(key: String, china: Bool) async throws -> ProviderUsage {
        let hosts = ["https://api.minimax.io", "https://api.minimaxi.com"]
        if china { return try await fetch(key: key, host: hosts[1]) }
        do {
            return try await fetch(key: key, host: hosts[0])
        } catch let error as ProviderError where error.needsSignIn {
            // A key from the China platform is rejected by the global host.
            if let usage = try? await fetch(key: key, host: hosts[1]) { return usage }
            throw error
        }
    }

    static func fetch(key: String, host: String) async throws -> ProviderUsage {
        let headers = HTTP.bearer(key).merging(["MM-API-Source": "Switch"]) { first, _ in first }
        var last: Error = ProviderError.unavailable("MiniMax is unavailable.")
        for path in ["/v1/token_plan/remains", "/v1/api/openplatform/coding_plan/remains"] {
            do {
                return try map(try await HTTP.json(host + path, headers: headers))
            } catch { last = error }
        }
        throw last
    }

    // MARK: Quota lanes

    /// One quota lane: a model's interval window, a text model's weekly window, or a legacy service row.
    private struct Lane {
        var label: String
        var name: String
        var isText: Bool
        var weekly: Bool
        var windowType: String
        var timeRange: String
        var usage: Int
        var limit: Int
        var percent: Double
        var unlimited: Bool
        var resetsAt: Date?
    }

    static func isText(_ model: String) -> Bool {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name == "general" || name.contains("minimax-m") || name.hasPrefix("m2.")
    }

    /// Display name of a model lane, as the Token Plan page names its services.
    static func serviceName(_ model: String) -> String {
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower == "general" { return "General" }
        if lower == "video" { return "Video" }
        if isText(model) { return "Text Generation" }
        if lower.contains("speech") { return "Text to Speech" }
        if lower.contains("hailuo") { return lower.contains("fast") ? "Image to Video" : "Text to Video" }
        if lower.hasPrefix("image-") { return "Image Generation" }
        if lower.contains("music") { return "Music Generation" }
        return model
    }

    private static func shanghai(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = pattern
        return formatter
    }

    private static func windowInfo(start: Date?, end: Date?) -> (type: String, range: String) {
        guard let start, let end else { return ("Unknown", "N/A") }
        let hours = end.timeIntervalSince(start) / 3600
        let type = (23...25).contains(hours) ? "Today" : (4...6).contains(hours) ? "5 hours"
            : (1..<23).contains(hours) ? "\(Int(hours)) hours" : "Custom"
        let clock = shanghai("HH:mm")
        return (type, "\(clock.string(from: start))-\(clock.string(from: end))(UTC+8)")
    }

    /// Minutes of a window label such as "Today", "Weekly", or "5 hours".
    static func windowMinutes(_ type: String) -> Int? {
        let lower = type.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower == "today" { return 1440 }
        if lower == "weekly" { return 10080 }
        let parts = lower.split(separator: " ")
        guard parts.count >= 2, let value = Int(parts[0]) else { return nil }
        switch parts[1] {
        case "hour", "hours", "h", "hr", "hrs": return value * 60
        case "minute", "minutes", "min", "mins", "m": return value
        case "day", "days", "d": return value * 1440
        default: return nil
        }
    }

    private static func placeholder(_ item: JSON, _ prefix: String) -> Bool {
        item["current_\(prefix)_status"].int == 3 && (item["current_\(prefix)_total_count"].double ?? 0) == 0
            && (item["current_\(prefix)_usage_count"].double ?? 0) == 0
            && (item["current_\(prefix)_remaining_percent"].double ?? 0) >= 100
    }

    /// `current_*_usage_count` is the REMAINING count despite the name.
    private static func lane(_ item: JSON, weekly: Bool, now: Date) -> Lane? {
        let prefix = weekly ? "weekly" : "interval"
        let model = item["model_name"].string ?? ""
        let remainingPercent = item["current_\(prefix)_remaining_percent"].double
        let unlimited = weekly && isText(model) && item["current_\(prefix)_status"].int == 3 && (remainingPercent ?? 0) >= 100
        // Status 3 with nothing granted is a lane the subscription does not include.
        if !unlimited, placeholder(item, prefix) { return nil }
        let start = item[weekly ? "weekly_start_time" : "start_time"].double.flatMap(Fmt.epoch)
        let end = item[weekly ? "weekly_end_time" : "end_time"].double.flatMap(Fmt.epoch)
        var info = windowInfo(start: start, end: end)
        if weekly {
            info.type = "Weekly"
            if let start, let end {
                let stamp = shanghai("MM/dd HH:mm")
                info.range = "\(stamp.string(from: start)) - \(stamp.string(from: end))(UTC+8)"
            }
        }
        var resetsAt: Date?
        if !unlimited {
            resetsAt = end.flatMap { $0 > now ? $0 : nil }
            if resetsAt == nil, let left = item[weekly ? "weekly_remains_time" : "remains_time"].double, left > 0 {
                resetsAt = now.addingTimeInterval(left > 1_000_000 ? left / 1000 : left)
            }
        }
        var lane = Lane(label: model, name: serviceName(model), isText: isText(model), weekly: weekly,
                        windowType: info.type, timeRange: info.range, usage: 0, limit: 0, percent: 0,
                        unlimited: unlimited, resetsAt: resetsAt)
        if unlimited { return lane }
        if let remainingPercent {
            // A boost multiplies the nominal 100 quota; permille spelling varies between responses.
            let boost = item["\(prefix)_boost_permill"].double ?? item["\(prefix)_boost_permille"].double ?? 0
            lane.limit = boost > 0 ? max(1, Fmt.int((boost / 10).rounded()) ?? 100) : 100
            lane.percent = min(100, max(0, 100 - remainingPercent))
            lane.usage = Fmt.int((lane.percent * Double(lane.limit) / 100).rounded()) ?? 0
        } else if let total = item["current_\(prefix)_total_count"].double, total > 0,
                  let remaining = item["current_\(prefix)_usage_count"].double {
            let used = max(0, total - remaining)
            lane.limit = Fmt.int(total) ?? 0
            lane.usage = Fmt.int(used) ?? 0
            lane.percent = min(100, used / total * 100)
        } else {
            return nil
        }
        return lane
    }

    // MARK: Response mapping

    /// Adds snake_case twins of camelCase keys, as embedded page data spells them.
    private static func snake(_ raw: Any?) -> JSON {
        guard var dict = raw as? [String: Any] else { return JSON(raw) }
        for (key, value) in dict {
            let twin = key.replacingOccurrences(of: "([A-Z])", with: "_$1", options: .regularExpression).lowercased()
            if dict[twin] == nil { dict[twin] = value }
        }
        if let data = dict["data"] { dict["data"] = snake(data).raw }
        return JSON(dict)
    }

    static func map(_ response: JSON, now: Date = Date()) throws -> ProviderUsage {
        let json = snake(response.raw)
        let base = json.at("data.base_resp").exists ? json.at("data.base_resp") : json["base_resp"]
        let status = base["status_code"].int ?? 0
        if status != 0 {
            let message = (base["status_msg"].string ?? "").lowercased()
            if status == 1004 || message.contains("cookie") || message.contains("login") || message.contains("api key") {
                throw ProviderError.unauthorized("MiniMax rejected this API key.")
            }
            throw ProviderError.parse("MiniMax returned error code \(status).")
        }
        let root = json["model_remains"].exists ? json : json["data"]
        let items = root["model_remains"].array
        var lanes: [Lane] = []
        var plan: String?
        if items.isEmpty, !json.at("data.services").array.isEmpty {
            lanes = json.at("data.services").array.compactMap { legacyLane($0, now: now) }
            guard !lanes.isEmpty else { throw ProviderError.parse("MiniMax returned no model quotas.") }
            // The legacy shape carries no plan field; a service named like a tier stands in.
            plan = json.at("data.services").array.compactMap { $0["service_type"].string }
                .first { $0.lowercased().contains("pro") || $0.lowercased().contains("max") }
        } else {
            guard !items.isEmpty else { throw ProviderError.parse("MiniMax returned no model quotas.") }
            for item in items {
                if let interval = lane(item, weekly: false, now: now) { lanes.append(interval) }
                // Only text models carry a weekly quota.
                if isText(item["model_name"].string ?? ""), let weekly = lane(item, weekly: true, now: now) {
                    lanes.append(weekly)
                }
            }
        }
        for key in ["current_subscribe_title", "plan_name", "combo_title", "current_plan_title", "current_combo_card.title"] {
            if let value = root.at(key).string ?? json.at(key).string {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { plan = trimmed; break }
            }
        }
        // A text lane next to a video lane the subscription lacks is the Plus tier.
        if plan == nil, items.contains(where: { isText($0["model_name"].string ?? "") }),
           items.contains(where: { ($0["model_name"].string ?? "").lowercased() == "video" && placeholder($0, "interval") }) {
            plan = "Plus"
        }
        var points: Double?
        for key in ["points_balance", "point_balance", "credits_balance", "credit_balance", "balance"] {
            if let value = root[key].double ?? json[key].double { points = value; break }
        }
        return build(lanes, plan: plan, points: points, now: now)
    }

    private static func build(_ lanes: [Lane], plan: String?, points: Double?, now: Date) -> ProviderUsage {
        // Text lanes first, intervals before weeklies, then the order of the response.
        let ordered = lanes.enumerated().sorted {
            ($0.element.isText ? 0 : 1, $0.element.weekly ? 1 : 0, $0.offset)
                < ($1.element.isText ? 0 : 1, $1.element.weekly ? 1 : 0, $1.offset)
        }.map(\.element)

        var windows: [UsageWindow] = []
        var seen: [String: Int] = [:]
        func window(_ lane: Lane) -> UsageWindow {
            let minutes = lane.weekly ? 10080 : windowMinutes(lane.windowType)
            var (id, title) = lane.weekly ? ("weekly", "Weekly") : (minutes ?? 0) >= 1000 ? ("daily", "Today") : ("session", "Session")
            if lane.isText == false { (id, title) = (lane.label, lane.name) }
            seen[id, default: 0] += 1
            if seen[id]! > 1 { id += "-\(seen[id]!)" }
            return UsageWindow(id: id, title: title, usedPercent: lane.percent, resetsAt: lane.resetsAt,
                               windowMinutes: minutes, detail: "\(Fmt.number(Double(lane.usage))) / \(Fmt.number(Double(lane.limit)))")
        }
        for lane in ordered where lane.isText && !lane.unlimited { windows.append(window(lane)) }
        // A plan with no text lane still needs a first window for the menu bar.
        let promoted = windows.isEmpty
        if promoted, let first = ordered.first(where: { !$0.weekly && !$0.unlimited }) { windows.append(window(first)) }

        var rows: [UsageRow] = []
        if ordered.contains(where: { $0.unlimited }) { rows.append(UsageRow("Weekly", "Unlimited")) }
        for (index, lane) in ordered.enumerated() where !lane.isText && !lane.unlimited && !(promoted && index == 0) {
            rows.append(UsageRow(lane.label, "\(Fmt.int(lane.percent.rounded()) ?? 0)% used", progress: lane.percent / 100))
        }
        if let points { rows.append(UsageRow("Points", Fmt.number(points))) }

        let names = Dictionary(grouping: ordered.map(\.name), by: { $0 }).mapValues(\.count)
        let services = ordered.map { lane -> UsageRow in
            let label = (names[lane.name] ?? 0) > 1 ? "\(lane.name) \u{00B7} \(lane.windowType)" : lane.name
            if lane.unlimited { return UsageRow(label, "Unlimited") }
            let percent = lane.percent == lane.percent.rounded() ? String(format: "%.0f%%", lane.percent) : String(format: "%.1f%%", lane.percent)
            return UsageRow(label, "\(Fmt.number(Double(lane.usage))) / \(Fmt.number(Double(lane.limit))) \u{00B7} \(percent) used \u{00B7} \(resetText(lane, now: now))",
                            progress: lane.percent / 100)
        }
        return ProviderUsage(windows: windows, sections: [UsageSection("Services", rows), UsageSection("Quota services", services)],
                             plan: plan, fetchedAt: now)
    }

    private static func resetText(_ lane: Lane, now: Date) -> String {
        guard let reset = lane.resetsAt, reset > now else { return "\(lane.windowType): \(lane.timeRange)" }
        let seconds = reset.timeIntervalSince(now)
        func plural(_ n: Int, _ unit: String) -> String { "Resets in \(n) \(unit)\(n == 1 ? "" : "s")" }
        if seconds < 60 { return "Resets in \(Fmt.int(seconds) ?? 0) seconds" }
        if seconds < 3600 { return plural(Fmt.int(seconds / 60) ?? 0, "minute") }
        if seconds < 86400 { return plural(Fmt.int(seconds / 3600) ?? 0, "hour") }
        return plural(Fmt.int(seconds / 86400) ?? 0, "day")
    }

    // MARK: Legacy `data.services` shape

    private static func legacyLane(_ item: JSON, now: Date) -> Lane? {
        guard let type = item["service_type"].string, let window = item["window_type"].string,
              let range = item["time_range"].string, let usage = item["usage"].double,
              let limit = item["limit"].double, limit > 0 else { return nil }
        let lower = type.lowercased()
        let name = lower.contains("text") && lower.contains("generation") ? "Text Generation"
            : lower.contains("text") && lower.contains("speech") ? "Text to Speech"
            : lower.contains("image") ? "Image" : type
        let percent = min(100, max(0, item["percent"].double ?? usage / limit * 100))
        return Lane(label: name, name: name, isText: name == "Text Generation" || lower == "general",
                    weekly: window.lowercased() == "weekly", windowType: window, timeRange: range,
                    usage: Fmt.int(usage) ?? 0, limit: Fmt.int(limit) ?? 0, percent: percent, unlimited: false,
                    resetsAt: legacyReset(range: range, window: window, now: now))
    }

    private static func legacyReset(range: String, window: String, now: Date) -> Date? {
        let lower = window.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower == "today" {
            let parts = range.split(separator: "-", maxSplits: 1)
            return parts.count == 2 ? shanghai("yyyy/MM/dd HH:mm").date(from: parts[1].trimmingCharacters(in: .whitespaces)) : nil
        }
        if lower.contains("h") {
            let parts = range.split(separator: "-")
            guard parts.count >= 2 else { return nil }
            let end = String(parts[1]).replacingOccurrences(of: "\\(.*\\)", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return clockDate(end, zone: TimeZone(secondsFromGMT: 8 * 3600), now: now)
        }
        return nil
    }

    /// Next occurrence of "HH:mm" in `zone`: today, or tomorrow when that time has passed.
    private static func clockDate(_ time: String, zone: TimeZone?, now: Date) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, let zone else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var day = calendar.dateComponents([.year, .month, .day], from: now)
        day.hour = parts[0]
        day.minute = parts[1]
        guard let candidate = calendar.date(from: day) else { return nil }
        return candidate < now ? calendar.date(byAdding: .day, value: 1, to: candidate) : candidate
    }
}
