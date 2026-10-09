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
            let key = try credential.require("apiKey")
            let china = credential["region"]?.lowercased() == "cn"
            let hosts = ["https://api.minimax.io", "https://api.minimaxi.com"]
            if china { return try await MiniMaxUsage.fetch(key: key, host: hosts[1]) }
            do {
                return try await MiniMaxUsage.fetch(key: key, host: hosts[0])
            } catch let error as ProviderError where error.needsSignIn {
                // A key from the China platform is rejected by the global host.
                if let usage = try? await MiniMaxUsage.fetch(key: key, host: hosts[1]) { return usage }
                throw error
            }
        })
}

enum MiniMaxUsage {
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

    /// `current_*_usage_count` is the REMAINING count despite the name.
    static func map(_ json: JSON, now: Date = Date()) throws -> ProviderUsage {
        let status = json["base_resp"]["status_code"].int ?? 0
        if status != 0 {
            let message = (json["base_resp"]["status_msg"].string ?? "").lowercased()
            if status == 1004 || message.contains("cookie") || message.contains("login") || message.contains("api key") {
                throw ProviderError.unauthorized("MiniMax rejected this API key.")
            }
            throw ProviderError.parse("MiniMax returned error code \(status).")
        }
        let root = json["model_remains"].exists ? json : json["data"]
        let items = root["model_remains"].array
        guard !items.isEmpty else { throw ProviderError.parse("MiniMax returned no model quotas.") }

        func isText(_ item: JSON) -> Bool {
            let name = (item["model_name"].string ?? "").lowercased()
            return name == "general" || name.contains("minimax-m") || name.hasPrefix("m2.")
        }
        func lane(_ item: JSON, _ prefix: String, id: String, title: String) -> (window: UsageWindow?, unlimited: Bool) {
            let total = item["current_\(prefix)_total_count"].double ?? 0
            let remaining = item["current_\(prefix)_usage_count"].double ?? 0
            let percent = item["current_\(prefix)_remaining_percent"].double
            let laneStatus = item["current_\(prefix)_status"].int
            if laneStatus == 3, total == 0, remaining == 0, (percent ?? 0) >= 100 { return (nil, false) }
            if laneStatus == 3, (percent ?? 0) >= 100 { return (nil, true) }
            let used: Double
            if let percent { used = 100 - percent } else if total > 0 { used = (total - remaining) / total * 100 } else { return (nil, false) }
            let startKey = prefix == "interval" ? "start_time" : "\(prefix)_start_time"
            let endKey = prefix == "interval" ? "end_time" : "\(prefix)_end_time"
            let remainsKey = prefix == "interval" ? "remains_time" : "\(prefix)_remains_time"
            let start = item[startKey].double.flatMap(Fmt.epoch)
            var end = item[endKey].double.flatMap(Fmt.epoch)
            if end.map({ $0 <= now }) ?? true, let left = item[remainsKey].double, left > 0 {
                end = now.addingTimeInterval(left > 1_000_000 ? left / 1000 : left)
            }
            let minutes = start.flatMap { s in end.map { Int($0.timeIntervalSince(s) / 60) } }
            return (UsageWindow(id: id, title: title, usedPercent: used, resetsAt: end, windowMinutes: minutes), false)
        }

        var windows: [UsageWindow] = []
        var rows: [UsageRow] = []
        let text = items.first { ($0["model_name"].string ?? "").lowercased() == "general" }
            ?? items.first(where: isText)
        if let text {
            var interval = lane(text, "interval", id: "session", title: "Session").window
            if let minutes = interval?.windowMinutes, minutes >= 1000 { interval?.id = "daily"; interval?.title = "Today" }
            if let interval { windows.append(interval) }
            let weekly = lane(text, "weekly", id: "weekly", title: "Weekly")
            if var window = weekly.window { window.windowMinutes = window.windowMinutes ?? 10080; windows.append(window) }
            if weekly.unlimited { rows.append(UsageRow("Weekly", "Unlimited")) }
        }
        for item in items {
            guard !isText(item), let name = item["model_name"].string,
                  let used = lane(item, "interval", id: name, title: name).window?.usedPercent else { continue }
            rows.append(UsageRow(name, "\(Int(used.rounded()))% used", progress: used / 100))
        }

        var plan: String?
        for key in ["current_subscribe_title", "plan_name", "combo_title", "current_plan_title", "current_combo_card.title"] {
            if let value = root.at(key).string ?? json.at(key).string { plan = value; break }
        }
        for key in ["points_balance", "point_balance", "credits_balance", "credit_balance", "balance"] {
            if let value = root[key].double ?? json[key].double { rows.append(UsageRow("Points", Fmt.number(value))); break }
        }
        return ProviderUsage(windows: windows, sections: [UsageSection("Services", rows)], plan: plan, fetchedAt: now)
    }
}
