import Foundation

extension ProviderCatalog {
    static let minimax = ProviderSpec(
        id: "minimax", name: "MiniMax",
        fields: [
            CredentialField("apiKey", "API key", optional: true, env: ["MINIMAX_CODING_API_KEY", "MINIMAX_API_KEY"]),
            CredentialField("cookie", "Session cookie", optional: true,
                            placeholder: "Cookie header or Copy as cURL from platform.minimax.io (billing and subscription dates)",
                            env: ["MINIMAX_COOKIE", "MINIMAX_COOKIE_HEADER"]),
            CredentialField("region", "Region", secure: false, optional: true, placeholder: "global or cn"),
        ],
        dashboard: "https://platform.minimax.io/user-center/payment/coding-plan?cycle_type=3",
        usage: { credential in
            let china = credential["region"]?.lowercased() == "cn"
            let web = credential["cookie"].flatMap(MiniMaxUsage.web)
            guard credential["apiKey"] != nil || web != nil else {
                throw ProviderError.missingCredential("Add an API key or a session cookie for MiniMax.")
            }
            var usage: ProviderUsage?
            var failure: Error?
            if let key = credential["apiKey"] {
                do { usage = try await MiniMaxUsage.fetchAPI(key: key, china: china) } catch { failure = error }
            }
            // The web session is the fallback when the key is rejected, and it adds billing and subscription dates.
            if let web {
                if usage == nil { usage = try await MiniMaxUsage.fetchWeb(web, china: china) }
                if let base = usage { return try await MiniMaxUsage.enrich(base, web: web, china: china) }
            }
            if let usage { return usage }
            throw failure ?? ProviderError.unavailable("MiniMax is unavailable.")
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
            lane.limit = boost > 0 ? max(1, Int((boost / 10).rounded())) : 100
            lane.percent = min(100, max(0, 100 - remainingPercent))
            lane.usage = Int((lane.percent * Double(lane.limit) / 100).rounded())
        } else if let total = item["current_\(prefix)_total_count"].double, total > 0,
                  let remaining = item["current_\(prefix)_usage_count"].double {
            let used = max(0, total - remaining)
            lane.limit = Int(total)
            lane.usage = Int(used)
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
            rows.append(UsageRow(lane.label, "\(Int(lane.percent.rounded()))% used", progress: lane.percent / 100))
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
        if seconds < 60 { return "Resets in \(Int(seconds)) seconds" }
        if seconds < 3600 { return plural(Int(seconds / 60), "minute") }
        if seconds < 86400 { return plural(Int(seconds / 3600), "hour") }
        return plural(Int(seconds / 86400), "day")
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
                    usage: Int(usage), limit: Int(limit), percent: percent, unlimited: false,
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

    // MARK: Web session (pasted Cookie header or Copy as cURL)

    struct Web: Equatable {
        var cookie: String
        var bearer: String?
        var groupID: String?
    }

    private static func capture(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap {
            Range(match.range(at: $0), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    static func web(_ raw: String) -> Web? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [#"(?i)-H\s*'Cookie:\s*([^']+)'"#, #"(?i)-H\s*\"Cookie:\s*([^\"]+)\""#,
                        #"(?i)\bcookie:\s*'([^']+)'"#, #"(?i)\bcookie:\s*\"([^\"]+)\""#, #"(?i)\bcookie:\s*([^\r\n]+)"#,
                        #"(?i)(?:^|\s)(?:--cookie|-b)\s*'([^']+)'"#, #"(?i)(?:^|\s)(?:--cookie|-b)\s*\"([^\"]+)\""#,
                        #"(?i)(?:^|\s)-b([^\s=]+=[^\s]+)"#, #"(?i)(?:^|\s)(?:--cookie|-b)\s+([^\s]+)"#]
        var cookie = patterns.lazy.compactMap { capture($0, in: text)?.first }.first { !$0.isEmpty } ?? text
        if cookie.lowercased().hasPrefix("cookie:") { cookie = String(cookie.dropFirst(7)) }
        cookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if cookie.count >= 2, let first = cookie.first, first == cookie.last, first == "\"" || first == "'" {
            cookie = String(cookie.dropFirst().dropLast())
        }
        guard !cookie.isEmpty else { return nil }
        let groups = [#"(?i)\bx-group-id:\s*([0-9]{4,})"#, #"(?i)\bminimax_group_id_v2=([0-9]{4,})"#, #"(?i)\bgroup[_]?id=([0-9]{4,})"#]
        return Web(cookie: cookie,
                   bearer: capture(#"(?i)\bauthorization:\s*bearer\s+([A-Za-z0-9._\-+=/]+)"#, in: text)?.first,
                   groupID: groups.lazy.compactMap { capture($0, in: text)?.first }.first)
    }

    private static func visibleText(_ html: String) -> String {
        ["(?is)<script\\b[^>]*>.*?</script>", "(?is)<style\\b[^>]*>.*?</style>", "(?is)<!--.*?-->", "<[^>]+>"]
            .reduce(html) { $0.replacingOccurrences(of: $1, with: "", options: .regularExpression) }
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func looksSignedOut(_ html: String) -> Bool {
        let text = visibleText(html).lowercased()
        return ["sign in", "log in", "\u{767B}\u{5F55}", "\u{767B}\u{5165}"].contains { text.contains($0) }
    }

    // MARK: Coding Plan page (embedded page data, else plain text)

    /// `quotas` is true when the page carried the model quota lanes; text-only pages carry a single reading.
    static func mapHTML(_ html: String, now: Date = Date()) throws -> (usage: ProviderUsage, quotas: Bool) {
        if let open = html.range(of: "id=\"__NEXT_DATA__\""), let tagEnd = html[open.upperBound...].firstIndex(of: ">"),
           let close = html.range(of: "</script>", range: html.index(after: tagEnd)..<html.endIndex),
           let object = try? JSONSerialization.jsonObject(with: Data(html[html.index(after: tagEnd)..<close.lowerBound].utf8)),
           let node = findQuotaNode(object), let usage = try? map(JSON(node), now: now) {
            return (usage, true)
        }
        let text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var plan = [capture(#"(?i)"planName"\s*:\s*"([^"]+)""#, in: html)?.first,
                    capture(#"(?i)"plan"\s*:\s*"([^"]+)""#, in: html)?.first,
                    capture(#"(?i)"packageName"\s*:\s*"([^"]+)""#, in: html)?.first,
                    capture(#"(?i)Coding\s*Plan\s*([A-Za-z0-9][A-Za-z0-9\s._-]{0,32})"#, in: text)?.first]
            .compactMap { $0.map(cleanPlan) }.first { !$0.isEmpty }
        plan = plan?.replacingOccurrences(of: #"(?i)\s+available\s+usage.*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var prompts: Int?, minutes: Int?
        let available = #"(?i)available\s+usage[:\s]*([0-9][0-9,]*)\s*prompts?\s*/\s*([0-9]+(?:\.[0-9]+)?)\s*(hours?|hrs?|h|minutes?|mins?|m|days?|d)"#
        if let m = capture(available, in: text), m.count == 3, let count = Int(m[0].replacingOccurrences(of: ",", with: "")),
           count > 0, let value = Double(m[1]) {
            prompts = count
            let unit = m[2].lowercased()
            let scale: Double = unit.hasPrefix("d") ? 1440 : unit.hasPrefix("h") ? 60 : 1
            minutes = Int(exactly: (value * scale).rounded())
        }
        var used: Double?
        for pattern in [#"(?i)([0-9]{1,3}(?:\.[0-9]+)?)\s*%\s*used"#, #"(?i)used\s*([0-9]{1,3}(?:\.[0-9]+)?)\s*%"#] {
            if let value = capture(pattern, in: text)?.first.flatMap({ Double($0) }), (0...100).contains(value) { used = value; break }
        }
        let reset = textReset(text, now: now)
        if plan == nil, prompts == nil, used == nil { throw ProviderError.parse("MiniMax returned no coding plan data.") }
        var windows: [UsageWindow] = []
        if used != nil || prompts != nil {
            let span = minutes.map { $0 % 1440 == 0 ? "\($0 / 1440) day\($0 == 1440 ? "" : "s")"
                : $0 % 60 == 0 ? "\($0 / 60) hour\($0 == 60 ? "" : "s")" : "\($0) minute\($0 == 1 ? "" : "s")" }
            let detail = prompts.map { "\($0) prompts" + (span.map { " / \($0)" } ?? "") } ?? span
            windows.append(UsageWindow(id: "session", title: "Session", usedPercent: used, resetsAt: reset,
                                       windowMinutes: minutes, detail: detail))
        }
        return (ProviderUsage(windows: windows, plan: plan, fetchedAt: now), false)
    }

    private static func findQuotaNode(_ object: Any) -> [String: Any]? {
        if let dict = object as? [String: Any] {
            if dict["model_remains"] != nil || dict["modelRemains"] != nil { return dict }
            return dict.values.lazy.compactMap(findQuotaNode).first
        }
        return (object as? [Any])?.lazy.compactMap(findQuotaNode).first
    }

    /// Drops the words CodexBar strips from plan names (claude, codex, account, plan) and capitalizes the first letter.
    private static func cleanPlan(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: #"(?i)\b(claude|codex|account|plan)\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result = cleaned.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
        return result.first.map { $0.isLowercase ? result.prefix(1).uppercased() + result.dropFirst() : result } ?? result
    }

    private static func textReset(_ text: String, now: Date) -> Date? {
        if let m = capture(#"(?i)resets?\s+in\s+([0-9]+)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h|days?|d)"#, in: text),
           m.count == 2, let value = Double(m[0]) {
            let unit = m[1].lowercased()
            return now.addingTimeInterval(value * (unit.hasPrefix("d") ? 86400 : unit.hasPrefix("h") ? 3600 : unit.hasPrefix("m") ? 60 : 1))
        }
        guard let m = capture(#"(?i)resets?\s+at\s+([0-9]{1,2}:[0-9]{2})(?:\s*\(([^)]+)\))?"#, in: text), let time = m.first else { return nil }
        return clockDate(time, zone: m.count > 1 ? zone(m[1]) : .current, now: now)
    }

    /// An IANA name, or "UTC+8" / "GMT-05:30".
    private static func zone(_ hint: String) -> TimeZone? {
        if let named = TimeZone(identifier: hint) { return named }
        guard let m = capture(#"(?i)^(?:UTC|GMT)\s*([+-])\s*(\d{1,2})(?::?(\d{2}))?$"#, in: hint), m.count >= 2,
              let hours = Int(m[1]) else { return nil }
        return TimeZone(secondsFromGMT: (m[0] == "-" ? -1 : 1) * (hours * 3600 + (m.count > 2 ? Int(m[2]) ?? 0 : 0) * 60))
    }

    // MARK: Subscription (combo) metadata

    struct Subscription: Equatable {
        var plan: String?
        var expires: Date?
        var renews: Date?
    }

    static func mapSubscription(_ json: JSON) throws -> Subscription {
        let base = json["base_resp"]
        let status = base["status_code"].int ?? 0
        if status != 0 {
            let message = base["status_msg"].string ?? "MiniMax combo metadata error \(status)"
            if status == 1004 || message.lowercased().contains("cookie") { throw ProviderError.unauthorized(message) }
            throw ProviderError.parse(message)
        }
        func strings(_ raw: Any?) -> [String] {
            if let text = raw as? String { return [text] }
            if let list = raw as? [Any] { return list.flatMap(strings) }
            if let dict = raw as? [String: Any] { return dict.sorted { $0.key < $1.key }.flatMap { strings($0.value) } }
            return []
        }
        func current(_ raw: Any?) -> [String] {
            if let list = raw as? [Any] { return list.flatMap(current) }
            guard let dict = raw as? [String: Any] else { return [] }
            return dict.flatMap { key, value -> [String] in
                let k = key.lowercased()
                let own = k.contains("current_subscribe") || k.contains("current_subscription") || k.contains("current_plan")
                return (own ? strings(value) : []) + current(value)
            }
        }
        func rank(_ value: String) -> Int? {
            let lower = value.lowercased()
            if lower.contains("tokenplanplus") { return 0 }
            if lower.contains("tokenplanmax") { return 1 }
            if lower.contains("tokenplanultra") { return 2 }
            if lower.contains("token plan"), lower.contains("plus") || lower.contains("max") || lower.contains("ultra") { return 3 }
            return nil
        }
        func best(_ list: [String]) -> String? {
            let ranked = list.compactMap { value in rank(value).map { ($0, value.trimmingCharacters(in: .whitespacesAndNewlines)) } }
            if let hit = ranked.min(by: { $0.0 == $1.0 ? $0.1.count < $1.1.count : $0.0 < $1.0 }) { return hit.1 }
            return list.first { ["plus", "max", "ultra"].contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        }
        func find(_ key: String, _ raw: Any?) -> Any? {
            if let dict = raw as? [String: Any] {
                if let hit = dict[key] { return hit }
                return dict.values.lazy.compactMap { find(key, $0) }.first
            }
            return (raw as? [Any])?.lazy.compactMap { find(key, $0) }.first
        }
        func date(_ keys: [String]) -> Date? {
            keys.lazy.compactMap { key -> Date? in
                guard let value = find(key, json.raw) else { return nil }
                if let day = (value as? String).flatMap({ shanghai("MM/dd/yyyy").date(from: $0.trimmingCharacters(in: .whitespaces)) }) { return day }
                return Fmt.date(value)
            }.first
        }
        let result = Subscription(plan: best(current(json.raw)) ?? best(strings(json.raw)),
                                  expires: date(["current_subscribe_end_time_ts", "current_subscribe_end_time"]),
                                  renews: date(["renewal_trigger_time_ts", "renewal_date"]))
        guard result.plan != nil || result.expires != nil || result.renews != nil else {
            throw ProviderError.parse("MiniMax combo metadata did not include subscription metadata.")
        }
        return result
    }

    /// The two dates are midnight in Shanghai, so they are shown as that calendar day.
    static func subscriptionSection(_ sub: Subscription) -> UsageSection {
        let day = shanghai("yyyy-MM-dd")
        return UsageSection("Subscription", [sub.expires.map { UsageRow("Expires", day.string(from: $0)) },
                                              sub.renews.map { UsageRow("Renews", day.string(from: $0)) }].compactMap { $0 })
    }

    // MARK: Billing history

    struct Billing {
        var todayTokens = 0, last30Tokens = 0
        var todayCash: Double?, last30Cash: Double?
        var topMethods: [(name: String, tokens: Int)] = []
        var topModels: [(name: String, tokens: Int)] = []
        /// Local-day "yyyy-MM-dd" -> tokens for each of the 30 days, zero when idle.
        var dailyTokens: [String: Double] = [:]
    }

    /// Successful charge records of the last 30 local days (today and the 29 days before).
    static func mapBilling(records: [JSON], now: Date, calendar: Calendar = .current) -> Billing {
        let today = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        func key(_ date: Date) -> String {
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
        func recordDate(_ record: JSON) -> Date? {
            if let created = record["created_at"].double { return Fmt.epoch(created) }
            if let ymd = record["ymd"].string {
                let parser = DateFormatter()
                parser.locale = Locale(identifier: "en_US_POSIX")
                parser.calendar = calendar
                parser.timeZone = calendar.timeZone
                for format in ["yyyy-MM-dd", "yyyyMMdd", "yyyy/MM/dd"] {
                    parser.dateFormat = format
                    if let date = parser.date(from: ymd.trimmingCharacters(in: .whitespaces)) { return calendar.startOfDay(for: date) }
                }
                return nil
            }
            return record["consume_time"].string.flatMap(Fmt.iso)
        }
        var days: [String: (tokens: Int, cash: Double?)] = [:]
        var methods: [String: Int] = [:], models: [String: Int] = [:]
        for record in records {
            // A numeric status such as 0 is not "SUCCESS" either; JSON.string reads 0 as a Bool and drops it.
            func scalar(_ value: JSON) -> String? { (value.raw as? NSNumber)?.stringValue ?? value.string }
            let result = (scalar(record["result"]) ?? scalar(record["status"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let result, !result.isEmpty, result.caseInsensitiveCompare("SUCCESS") != .orderedSame { continue }
            guard let date = recordDate(record), date >= from, date <= now else { continue }
            let consumed = record["consume_token"].int ?? 0
            let tokens = consumed > 0 ? consumed : max(0, (record["consume_input_token"].int ?? 0) + (record["consume_output_token"].int ?? 0))
            let cash = record["consume_cash_after_voucher"].double ?? record["consume_cash"].double
            var day = days[key(date)] ?? (0, nil)
            day.tokens += tokens
            if let cash { day.cash = (day.cash ?? 0) + cash }
            days[key(date)] = day
            if let method = record["method"].string { methods[method, default: 0] += tokens }
            if let model = record["model"].string { models[model, default: 0] += tokens }
        }
        func top(_ totals: [String: Int]) -> [(name: String, tokens: Int)] {
            let all: [(name: String, tokens: Int)] = totals.map { (name: $0.key, tokens: $0.value) }
            let sorted = all.sorted { (a: (name: String, tokens: Int), b: (name: String, tokens: Int)) -> Bool in
                if a.tokens != b.tokens { return a.tokens > b.tokens }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            return Array(sorted.prefix(3))
        }
        let cash = days.values.compactMap(\.cash)
        var daily = Dictionary(uniqueKeysWithValues: (0..<30).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
            .map { (key($0), 0.0) })
        for (day, value) in days where daily[day] != nil { daily[day] = Double(value.tokens) }
        return Billing(todayTokens: days[key(now)]?.tokens ?? 0, last30Tokens: days.values.reduce(0) { $0 + $1.tokens },
                       todayCash: days[key(now)]?.cash, last30Cash: cash.isEmpty ? nil : cash.reduce(0, +),
                       topMethods: top(methods), topModels: top(models), dailyTokens: daily)
    }

    static func billingChart(_ billing: Billing) -> UsageChart? {
        billing.last30Tokens > 0
            ? UsageChart.daily(id: "billing-tokens", title: "Daily tokens", unit: "tokens", values: billing.dailyTokens) : nil
    }

    static func billingSection(_ billing: Billing) -> UsageSection {
        func cash(_ value: Double) -> String { String(format: "%.2f", max(0, value)) }
        var rows = [UsageRow("Today tokens", Fmt.number(Double(billing.todayTokens))),
                    UsageRow("30d tokens", Fmt.number(Double(billing.last30Tokens))),
                    UsageRow("Today cash", billing.todayCash.map(cash) ?? "\u{2014}"),
                    UsageRow("Models", "\(billing.topModels.count)")]
        if let model = billing.topModels.first { rows.append(UsageRow("Top model", model.name)) }
        if let method = billing.topMethods.first { rows.append(UsageRow("Top method", method.name)) }
        if let total = billing.last30Cash { rows.append(UsageRow("30d cash", cash(total))) }
        return UsageSection("Billing history", rows)
    }

    // MARK: Web fetch

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private static func platform(_ china: Bool) -> String { china ? "https://platform.minimaxi.com" : "https://platform.minimax.io" }
    private static func www(_ china: Bool) -> String { china ? "https://www.minimaxi.com" : "https://www.minimax.io" }

    private static func headers(_ web: Web, china: Bool, accept: String, referer: String? = nil) -> [String: String] {
        var result = ["Cookie": web.cookie, "Accept": accept, "User-Agent": userAgent, "Accept-Language": "en-US,en;q=0.9",
                      "Origin": platform(china),
                      "Referer": referer ?? platform(china) + "/user-center/payment/coding-plan"]
        if let bearer = web.bearer { result["Authorization"] = "Bearer \(bearer)" }
        return result
    }

    private static func isJSON(_ response: HTTPResponse) -> Bool {
        (response.headers["content-type"] ?? "").lowercased().contains("application/json")
    }

    /// Quota lanes from the Coding Plan page, else the remains endpoints on the platform and www hosts.
    static func fetchWeb(_ web: Web, china: Bool, now: Date = Date()) async throws -> ProviderUsage {
        var page: ProviderUsage?
        do {
            let response = try await HTTP.send(platform(china) + "/user-center/payment/coding-plan?cycle_type=3",
                                               headers: headers(web, china: china, accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"))
            try HTTP.check(response)
            if isJSON(response) { return try map(try response.json(), now: now) }
            if looksSignedOut(response.text) { throw ProviderError.unauthorized("MiniMax rejected this session cookie.") }
            let parsed = try mapHTML(response.text, now: now)
            if parsed.quotas { return parsed.usage }
            page = parsed.usage
        } catch let error as ProviderError {
            if case .parse = error {} else { throw error }
        }
        do {
            var usage = try await fetchRemains(web, china: china, now: now)
            if usage.plan == nil { usage.plan = page?.plan }
            return usage
        } catch let error as ProviderError {
            if let page, !error.needsSignIn { return page }
            throw error
        }
    }

    private static func fetchRemains(_ web: Web, china: Bool, now: Date) async throws -> ProviderUsage {
        var last: Error = ProviderError.parse("MiniMax returned no coding plan data.")
        for host in [platform(china), www(china)] {
            let group = web.groupID.map { "?GroupId=\($0)" } ?? ""
            var request = headers(web, china: china, accept: "application/json, text/plain, */*")
            request["x-requested-with"] = "XMLHttpRequest"
            do {
                let response = try await HTTP.send(host + "/v1/api/openplatform/coding_plan/remains" + group, headers: request)
                try HTTP.check(response)
                if isJSON(response) { return try map(try response.json(), now: now) }
                if looksSignedOut(response.text) { throw ProviderError.unauthorized("MiniMax rejected this session cookie.") }
                return try mapHTML(response.text, now: now).usage
            } catch let error as ProviderError {
                switch error {
                case .unauthorized, .rateLimited: throw error
                default: last = error
                }
            }
        }
        throw last
    }

    /// Subscription dates need the group id; billing history pages until a record older than 30 days.
    static func enrich(_ usage: ProviderUsage, web: Web, china: Bool, now: Date = Date()) async throws -> ProviderUsage {
        var usage = usage
        func optional<T>(_ work: () async throws -> T) async throws -> T? {
            do { return try await work() } catch is CancellationError { throw CancellationError() } catch { return nil }
        }
        if let group = web.groupID, let sub = try await optional({ () -> Subscription in
            var request = headers(web, china: china, accept: "application/json, text/plain, */*", referer: platform(china) + "/")
            request["x-group-id"] = group
            request["Accept-Language"] = "zh-CN,zh;q=0.9"
            return try mapSubscription(try await HTTP.json(
                www(china) + "/v1/api/openplatform/charge/combo/cycle_audio_resource_package?biz_line=2&cycle_type=3&resource_package_type=7",
                headers: request))
        }) {
            if let plan = sub.plan { usage.plan = plan }
            usage.sections.append(subscriptionSection(sub))
        }
        if let billing = try await optional({ () -> Billing in
            var records: [JSON] = []
            let cutoff = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: now)) ?? now
            // ponytail: 20 pages of 100 records, raise if an account bills more than 2000 calls in 30 days
            for page in 1...20 {
                var request = headers(web, china: china, accept: "application/json, text/plain, */*",
                                      referer: platform(china) + "/account")
                request["x-requested-with"] = "XMLHttpRequest"
                let json = try await HTTP.json(platform(china) + "/account/amount?page=\(page)&limit=100&aggregate=false", headers: request)
                if let status = json["base_resp"]["status_code"].int, status != 0 {
                    throw ProviderError.parse(json["base_resp"]["status_msg"].string ?? "status_code \(status)")
                }
                let batch = json["charge_records"].array
                if batch.isEmpty { break }
                records += batch
                let older = batch.contains { record in
                    guard let created = record["created_at"].double.flatMap(Fmt.epoch) else { return false }
                    return created < cutoff
                }
                if older || records.count >= (json["total_cnt"].int ?? Int.max) { break }
            }
            return mapBilling(records: records, now: now)
        }) {
            usage.sections.append(billingSection(billing))
            usage.charts += [billingChart(billing)].compactMap { $0 }
        }
        return usage
    }
}
