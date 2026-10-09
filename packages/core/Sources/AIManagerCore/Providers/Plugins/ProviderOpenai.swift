import Foundation

extension ProviderCatalog {
    /// OpenAI API spend from the organization Admin API (needs an Admin key); legacy keys fall back to credit grants.
    static let openai = ProviderSpec(
        id: "openai", name: "OpenAI",
        fields: [
            .apiKey("OPENAI_API_KEY"),
            CredentialField("projectID", "Project ID", secure: false, optional: true, placeholder: "proj_…"),
        ],
        dashboard: "https://platform.openai.com/usage",
        statusPage: "https://status.openai.com",
        usage: { credential in
            let headers = HTTP.bearer(try credential.require("apiKey"))
            let project = credential["projectID"]
            let days = 30
            let now = Date()
            let start = Int(now.timeIntervalSince1970 / 86400) * 86400 - (days - 1) * 86400
            func pages(_ path: String, groupBy: String) async throws -> [JSON] {
                var buckets: [JSON] = []
                var page: String?
                for _ in 0..<20 {
                    var query = "start_time=\(start)&end_time=\(start + days * 86400)&bucket_width=1d&limit=\(days)&group_by=\(groupBy)"
                    if let project { query += "&project_ids=\(project.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? project)" }
                    if let page { query += "&page=\(page.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? page)" }
                    let body = try await HTTP.json("https://api.openai.com\(path)?\(query)", headers: headers)
                    guard body["data"].raw is [Any] else { throw ProviderError.parse("Failed to parse the OpenAI \(path) page.") }
                    buckets += body["data"].array
                    guard body["has_more"].bool == true, let next = body["next_page"].string, next != page else { break }
                    page = next
                }
                return buckets
            }
            do {
                let costs = try await pages("/v1/organization/costs", groupBy: "line_item")
                let completions = try await pages("/v1/organization/usage/completions", groupBy: "model")
                return try OpenAIUsage.map(costs: costs, completions: completions, days: days, now: now)
            } catch let error as ProviderError where error.needsSignIn {
                guard let grants = try? await HTTP.json("https://api.openai.com/v1/dashboard/billing/credit_grants",
                                                        headers: headers) else { throw error }
                return try OpenAIUsage.mapCredits(grants, now: now)
            }
        })
}

enum OpenAIUsage {
    /// `costs` and `completions` are the daily buckets from the Admin API, already merged across pages.
    static func map(costs: [JSON], completions: [JSON], days: Int = 30, now: Date = Date()) throws -> ProviderUsage {
        struct Day { var start = 0, end = 0; var cost = 0.0, requests = 0.0, input = 0.0, output = 0.0 }
        var daily: [Int: Day] = [:]
        var models: [String: Double] = [:]
        func bucket(_ raw: JSON) throws -> Int {
            guard let start = raw["start_time"].int, let end = raw["end_time"].int, raw["results"].raw is [Any] else {
                throw ProviderError.parse("Failed to parse an OpenAI usage bucket.")
            }
            if daily[start] == nil { daily[start] = Day(start: start, end: end) }
            return start
        }
        for raw in costs {
            let key = try bucket(raw)
            for item in raw["results"].array { daily[key]!.cost += item.at("amount.value").double ?? 0 }
        }
        for raw in completions {
            let key = try bucket(raw)
            for item in raw["results"].array {
                let input = (item["input_tokens"].double ?? 0) + (item["input_audio_tokens"].double ?? 0)
                let output = (item["output_tokens"].double ?? 0) + (item["output_audio_tokens"].double ?? 0)
                daily[key]!.requests += item["num_model_requests"].double ?? 0
                daily[key]!.input += input
                daily[key]!.output += output
                models[item["model"].string ?? "unknown", default: 0] += input + output
            }
        }
        let nowSeconds = Int(now.timeIntervalSince1970)
        let list = daily.values.filter { $0.start <= nowSeconds }.sorted { $0.start < $1.start }.suffix(days)
        let total = list.reduce(0) { $0 + $1.cost }
        var rows: [UsageRow] = []
        if let today = list.first(where: { $0.start <= nowSeconds && nowSeconds < $0.end }) {
            rows.append(UsageRow("Today (UTC)", Fmt.money(today.cost)))
        }
        rows.append(UsageRow("Requests", Fmt.number(list.reduce(0) { $0 + $1.requests })))
        rows.append(UsageRow("Input tokens", Fmt.number(list.reduce(0) { $0 + $1.input })))
        rows.append(UsageRow("Output tokens", Fmt.number(list.reduce(0) { $0 + $1.output })))
        var sections = [UsageSection("Last \(days) days", rows)]
        let top = models.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(3)
        sections.append(UsageSection("Top models", top.map { UsageRow($0.key, "\(Fmt.number($0.value)) tokens") }))
        return ProviderUsage(cost: UsageCost(used: total, period: "Last \(days) days"), sections: sections,
                             plan: "Admin API")
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
                             plan: "API balance")
    }
}
