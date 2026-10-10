import Foundation

extension ProviderCatalog {
    /// OpenAI API spend from the organization Admin API (needs an Admin key); legacy keys fall back to credit grants.
    static let openai = ProviderSpec(
        id: "openai", name: "OpenAI",
        fields: [
            .apiKey("OPENAI_API_KEY"),
            CredentialField("projectID", "Project ID", secure: false, optional: true, placeholder: "proj_…"),
            CredentialField("historyDays", "History days (1-365, default 30)", secure: false, optional: true,
                            env: ["OPENAI_HISTORY_DAYS"]),
        ],
        dashboard: "https://platform.openai.com/usage",
        statusPage: "https://status.openai.com",
        usage: { credential in
            let headers = HTTP.bearer(try credential.require("apiKey"))
            let project = credential["projectID"]
            let days = OpenAIUsage.historyDays(credential["historyDays"])
            let now = Date()
            func pages(_ path: String, groupBy: String) async throws -> [JSON] {
                var buckets: [JSON] = []
                for range in OpenAIUsage.ranges(days: days, now: now) {
                    var page: String?
                    for _ in 0..<100 {
                        var query = "start_time=\(range.start)&end_time=\(range.end)&bucket_width=1d"
                            + "&limit=\(range.limit)&group_by=\(groupBy)"
                        if let project { query += "&project_ids=\(project.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? project)" }
                        if let page { query += "&page=\(page.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? page)" }
                        let body = try await HTTP.json("https://api.openai.com\(path)?\(query)", headers: headers)
                        guard body["data"].raw is [Any] else { throw ProviderError.parse("Failed to parse the OpenAI \(path) page.") }
                        buckets += body["data"].array
                        guard body["has_more"].bool == true, let next = body["next_page"].string, next != page else { break }
                        page = next
                    }
                }
                return buckets
            }
            do {
                let costs = try await pages("/v1/organization/costs", groupBy: "line_item")
                let completions = try await pages("/v1/organization/usage/completions", groupBy: "model")
                return try OpenAIUsage.map(costs: costs, completions: completions, days: days, now: now, projectID: project)
            } catch let error as ProviderError where error.needsSignIn {
                guard let grants = try? await HTTP.json("https://api.openai.com/v1/dashboard/billing/credit_grants",
                                                        headers: headers) else { throw error }
                return try OpenAIUsage.mapCredits(grants, now: now)
            }
        })
}

enum OpenAIUsage {
    /// Whole days from 1 to 365; anything else reads as 30.
    static func historyDays(_ text: String?) -> Int {
        guard let text, let value = Int(text) else { return 30 }
        return max(1, min(365, value))
    }

    /// The Admin API serves at most 31 daily buckets a request, so a long history is split.
    static func ranges(days: Int, now: Date) -> [(start: Int, end: Int, limit: Int)] {
        var cursor = Int(now.timeIntervalSince1970 / 86400) * 86400 - (days - 1) * 86400
        var remaining = days
        var result: [(start: Int, end: Int, limit: Int)] = []
        while remaining > 0 {
            let limit = min(31, remaining)
            result.append((cursor, cursor + limit * 86400, limit))
            cursor += limit * 86400
            remaining -= limit
        }
        return result
    }

    private struct Tally { var requests = 0.0, input = 0.0, cached = 0.0, output = 0.0 }

    /// `costs` and `completions` are the daily buckets from the Admin API, already merged across pages.
    static func map(costs: [JSON], completions: [JSON], days: Int = 30, now: Date = Date(),
                    projectID: String? = nil) throws -> ProviderUsage {
        struct Day {
            var start = 0, end = 0
            var cost = 0.0, tally = Tally()
            var lines: [String: Double] = [:]
        }
        var daily: [Int: Day] = [:]
        var models: [String: Tally] = [:]
        func bucket(_ raw: JSON) throws -> Int {
            guard let start = raw["start_time"].int, let end = raw["end_time"].int, raw["results"].raw is [Any] else {
                throw ProviderError.parse("Failed to parse an OpenAI usage bucket.")
            }
            if daily[start] == nil { daily[start] = Day(start: start, end: end) }
            return start
        }
        for raw in costs {
            let key = try bucket(raw)
            for item in raw["results"].array {
                let amount = item.at("amount.value").double ?? 0
                daily[key]!.cost += amount
                daily[key]!.lines[item["line_item"].string ?? "API", default: 0] += amount
            }
        }
        for raw in completions {
            let key = try bucket(raw)
            for item in raw["results"].array {
                let input = (item["input_tokens"].double ?? 0) + (item["input_audio_tokens"].double ?? 0)
                let output = (item["output_tokens"].double ?? 0) + (item["output_audio_tokens"].double ?? 0)
                let requests = item["num_model_requests"].double ?? 0
                let cached = item["input_cached_tokens"].double ?? 0
                daily[key]!.tally.requests += requests
                daily[key]!.tally.input += input
                daily[key]!.tally.cached += cached
                daily[key]!.tally.output += output
                let name = item["model"].string ?? "unknown"
                models[name, default: Tally()].requests += requests
                models[name, default: Tally()].input += input
                models[name, default: Tally()].cached += cached
                models[name, default: Tally()].output += output
            }
        }
        let nowSeconds = Int(now.timeIntervalSince1970)
        let all = daily.values.filter { $0.start <= nowSeconds }.sorted { $0.start < $1.start }
        // One-day history means the current UTC day only.
        let list = days == 1 ? all.filter { $0.start <= nowSeconds && nowSeconds < $0.end } : Array(all.suffix(days))
        let total = list.reduce(0) { $0 + $1.cost }
        let period = days == 1 ? "Today" : "Last \(days) days"
        var rows: [UsageRow] = []
        if let today = list.first(where: { $0.start <= nowSeconds && nowSeconds < $0.end }) {
            rows.append(UsageRow("Today (UTC)", Fmt.money(today.cost)))
        }
        rows.append(UsageRow("Requests", Fmt.number(list.reduce(0) { $0 + $1.tally.requests })))
        rows.append(UsageRow("Input tokens", Fmt.number(list.reduce(0) { $0 + $1.tally.input })))
        rows.append(UsageRow("Cached input tokens", Fmt.number(list.reduce(0) { $0 + $1.tally.cached })))
        rows.append(UsageRow("Output tokens", Fmt.number(list.reduce(0) { $0 + $1.tally.output })))
        var sections = [UsageSection(period, rows)]
        let top = models.sorted {
            let a = $0.value.input + $0.value.output, b = $1.value.input + $1.value.output
            return a != b ? a > b : $0.key < $1.key
        }.prefix(5)
        sections.append(UsageSection("Top models", top.map {
            PluginFmt.row($0.key, "\(Fmt.number($0.value.input + $0.value.output)) tokens",
                          "\(Fmt.number($0.value.requests)) requests")
        }))
        // The five newest days, newest first, each with its spend and busiest line item.
        sections.append(UsageSection("Latest days", list.suffix(5).reversed().map { day in
            let top = day.lines.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }
            return PluginFmt.row(PluginFmt.day(Date(timeIntervalSince1970: TimeInterval(day.start))), Fmt.money(day.cost),
                                 "\(Fmt.number(day.tally.requests)) requests · "
                                 + "\(Fmt.number(day.tally.input + day.tally.output)) tokens"
                                 + (top.map { " · \($0.key) \(Fmt.money($0.value))" } ?? ""))
        }))
        var lines: [String: Double] = [:]
        for day in list { for (name, cost) in day.lines { lines[name, default: 0] += cost } }
        sections.append(UsageSection("Cost by line item", lines.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }.prefix(5).map { UsageRow($0.key, Fmt.money($0.value)) }))
        return ProviderUsage(cost: UsageCost(used: total, period: period), sections: sections,
                             plan: projectID.map { "Admin API: \($0)" } ?? "Admin API",
                             organization: projectID.map { "Project: \($0)" })
    }

    /// Legacy `/v1/dashboard/billing/credit_grants` balance.
    static func mapCredits(_ json: JSON, now: Date = Date()) throws -> ProviderUsage {
        guard let granted = json["total_granted"].double, let used = json["total_used"].double,
              let available = json["total_available"].double else {
            throw ProviderError.parse("Invalid OpenAI credit balance totals.")
        }
        let expiry = json.at("grants.data").array.compactMap { $0["expires_at"].double }
            .filter { $0 > now.timeIntervalSince1970 }.min().map { Date(timeIntervalSince1970: $0) }
        var window = UsageWindow(id: "credits", title: "API credits",
                                 usedPercent: granted > 0 ? used / granted * 100 : (available > 0 ? 0 : 100),
                                 resetsAt: expiry)
        window.detail = "\(Fmt.money(max(0, available))) available"
        return ProviderUsage(windows: [window],
                             cost: UsageCost(used: max(0, used), limit: max(0, granted), balance: max(0, available),
                                             period: "API credits", resetsAt: expiry),
                             plan: "API balance: \(Fmt.money(max(0, available)))")
    }
}
