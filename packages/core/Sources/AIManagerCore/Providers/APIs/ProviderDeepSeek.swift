import Foundation

extension ProviderCatalog {
    static let deepseek = ProviderSpec(
        id: "deepseek", name: "DeepSeek",
        fields: [
            CredentialField("apiKey", "API key", optional: true, env: ["DEEPSEEK_API_KEY", "DEEPSEEK_KEY"]),
            CredentialField("token", "Platform session token", optional: true,
                            placeholder: "userToken from platform.deepseek.com (balance without a key, and cost details)",
                            env: ["DEEPSEEK_PLATFORM_TOKEN", "DEEPSEEK_USER_TOKEN"]),
        ],
        dashboard: "https://platform.deepseek.com/usage",
        statusPage: "https://status.deepseek.com",
        usage: { credential in
            let key = credential["apiKey"], token = credential["token"]
            guard key != nil || token != nil else {
                throw ProviderError.missingCredential("Add an API key or a platform session token for DeepSeek.")
            }
            var usage: ProviderUsage
            if let key {
                usage = try DeepSeekUsage.map(try await HTTP.json("https://api.deepseek.com/user/balance",
                                                                  headers: HTTP.bearer(key)))
            } else if let token {
                let response = try await HTTP.send("https://platform.deepseek.com/api/v0/users/get_user_summary",
                                                   headers: DeepSeekUsage.platformHeaders(token))
                try HTTP.check(response)
                usage = try DeepSeekUsage.mapSummary(try response.json())
            } else {
                throw ProviderError.missingCredential("Add an API key or a platform session token for DeepSeek.")
            }
            // Cost and token details come only from the platform session; an API key cannot read them.
            if let token {
                do {
                    let summary = try await DeepSeekUsage.fetchSummary(token: token)
                    usage.sections += DeepSeekUsage.sections(summary)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as ProviderError where error.needsSignIn {
                    // Without a key the token is the only credential, so a rejection is the fetch error.
                    if key == nil { throw error }
                    usage.sections.append(UsageSection(nil, [UsageRow("Detailed usage", "Session token rejected")]))
                } catch {
                    usage.sections.append(UsageSection(nil, [UsageRow("Detailed usage", "Unavailable")]))
                }
            }
            return usage
        })
}

enum DeepSeekUsage {
    static func platformHeaders(_ token: String) -> [String: String] {
        HTTP.bearer(token).merging(["x-client-platform": "web"]) { first, _ in first }
    }

    /// `GET /user/balance`. All amounts are strings.
    static func map(_ json: JSON) throws -> ProviderUsage {
        let infos = json["balance_infos"].array
        guard json["is_available"].exists || !infos.isEmpty else {
            throw ProviderError.parse("DeepSeek returned an unexpected balance shape.")
        }
        let info = infos.first { $0["currency"].string == "USD" && ($0["total_balance"].double ?? 0) > 0 }
            ?? infos.first { ($0["total_balance"].double ?? 0) > 0 }
            ?? infos.first { $0["currency"].string == "USD" } ?? infos.first
        let currency = info?["currency"].string ?? "USD"
        let total = info?["total_balance"].double ?? 0
        return result(total: total, paid: info?["topped_up_balance"].double, granted: info?["granted_balance"].double,
                      currency: currency, available: json["is_available"].bool ?? (total > 0))
    }

    /// Platform `get_user_summary`: wallets with balances as string or number.
    static func mapSummary(_ json: JSON) throws -> ProviderUsage {
        try checkCodes(json)
        let data = json.at("data.biz_data")
        guard data.exists else { throw ProviderError.parse("DeepSeek returned an unexpected summary shape.") }
        func totals(_ wallets: [JSON]) -> [String: Double] {
            wallets.reduce(into: [:]) { $0[$1["currency"].string ?? "USD", default: 0] += $1["balance"].double ?? 0 }
        }
        let paid = totals(data["normal_wallets"].array), granted = totals(data["bonus_wallets"].array)
        let currencies = Set(paid.keys).union(granted.keys).sorted()
        func sum(_ currency: String) -> Double { paid[currency, default: 0] + granted[currency, default: 0] }
        // Same pick as the key endpoint: funded USD, any funded currency, USD, then the first.
        let currency = currencies.first { $0 == "USD" && sum($0) > 0 } ?? currencies.first { sum($0) > 0 }
            ?? currencies.first { $0 == "USD" } ?? currencies.first ?? "USD"
        return result(total: sum(currency), paid: paid[currency, default: 0], granted: granted[currency, default: 0],
                      currency: currency, available: sum(currency) > 0)
    }

    private static func result(total: Double, paid: Double?, granted: Double?, currency: String,
                               available: Bool) -> ProviderUsage {
        var rows: [UsageRow] = []
        if let paid { rows.append(UsageRow("Paid", Fmt.money(paid, currency: currency))) }
        if let granted { rows.append(UsageRow("Granted", Fmt.money(granted, currency: currency))) }
        if total <= 0 { rows.append(UsageRow("Status", "Add credits")) }
        else if !available { rows.append(UsageRow("Status", "Balance unavailable for API calls")) }
        return ProviderUsage(cost: UsageCost(balance: total, currency: currency), sections: [UsageSection(nil, rows)])
    }

    // MARK: Detailed usage (platform session only)

    struct Summary {
        var todayTokens = 0, periodTokens = 0, todayRequests = 0, periodRequests = 0
        var todayCost: Double?, periodCost: Double?
        var topModel: String?
        var modelCosts: [(model: String, cost: Double)] = []
        var currency = "CNY"
        var apiKeyCount = 0
        var last30Days = true
    }

    /// 40002 and 40003 mean an expired session, at the top level or inside `data`.
    private static func checkCodes(_ json: JSON) throws {
        let codes = [json["code"].int, json.at("data.biz_code").int]
        if codes.contains(40002) || codes.contains(40003) {
            throw ProviderError.unauthorized("DeepSeek rejected this session token. Paste a new one.")
        }
        if let code = codes.compactMap({ $0 }).first(where: { $0 != 0 }) {
            throw ProviderError.parse("DeepSeek returned error code \(code).")
        }
    }

    private static let categories: Set<String> = ["PROMPT_CACHE_HIT_TOKEN", "PROMPT_CACHE_MISS_TOKEN", "RESPONSE_TOKEN"]

    private static func dayKey(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// A model total is dropped when any part is missing, negative, or not finite.
    private struct ModelCosts {
        var totals: [String: Double] = [:]
        var bad: Set<String> = []
        mutating func add(_ amount: Double?, _ raw: String?) {
            guard let model = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty,
                  !bad.contains(model) else { return }
            if let amount, amount.isFinite, amount >= 0 { totals[model, default: 0] += amount; return }
            bad.insert(model)
            totals[model] = nil
        }
        var sorted: [(model: String, cost: Double)] {
            totals.map { (model: $0.key, cost: $0.value) }.sorted { $0.cost == $1.cost ? $0.model < $1.model : $0.cost > $1.cost }
        }
    }

    private static func topModel(_ tokens: [String: Int]) -> String? {
        tokens.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    /// Per-key daily buckets from `usage/by_api_key/amount` and `.../cost`, last 30 days.
    static func mapByAPIKey(amount: JSON, cost: JSON, now: Date, calendar: Calendar,
                            start: Date? = nil, end: Date? = nil) throws -> Summary {
        try checkCodes(amount)
        try checkCodes(cost)
        guard amount.at("data.biz_data").exists else { throw ProviderError.parse("DeepSeek amount data is missing.") }
        guard cost.at("data.biz_data").exists else { throw ProviderError.parse("DeepSeek cost data is missing.") }
        let today = calendar.startOfDay(for: now)
        let from = Int((start ?? calendar.date(byAdding: .day, value: -29, to: today) ?? now).timeIntervalSince1970)
        let to = Int((end ?? calendar.date(byAdding: .day, value: 1, to: today) ?? now).timeIntervalSince1970)

        func keyID(_ key: JSON) -> String {
            let id = key.string ?? key["tracking_id"].string ?? key["name"].string
            return id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "unknown"
        }
        var keys = Set<String>()
        var dayTokens: [String: Int] = [:], dayRequests: [String: Int] = [:], modelTokens: [String: Int] = [:]
        for series in amount.at("data.biz_data.series").array {
            if series["api_key"].exists { keys.insert(keyID(series["api_key"])) }
            let model = series["model"].string ?? "unknown"
            for bucket in series["buckets"].array {
                guard let time = bucket["time"].int, time >= from, time < to else { continue }
                let day = dayKey(Date(timeIntervalSince1970: TimeInterval(time)), calendar)
                for (type, scalar) in bucket["usage"].object {
                    let value = Int(scalar.double ?? 0)
                    if type.uppercased() == "REQUEST" { dayRequests[day, default: 0] += value }
                    else if categories.contains(type.uppercased()) {
                        dayTokens[day, default: 0] += value
                        modelTokens[model, default: 0] += value
                    }
                }
            }
        }

        let blocks = cost.at("data.biz_data.data").array
        func spend(_ block: JSON) -> Double {
            block["series"].array.reduce(0) { $0 + $1["buckets"].array.reduce(0) { $0 + ($1["cost"].double ?? 0) } }
        }
        let block = blocks.first { $0["currency"].string == "USD" && spend($0) > 0 }
            ?? blocks.first { spend($0) > 0 } ?? blocks.first { $0["currency"].string == "USD" } ?? blocks.first
        var dayCosts: [String: Double] = [:]
        var models = ModelCosts()
        for series in block?["series"].array ?? [] {
            if series["api_key"].exists { keys.insert(keyID(series["api_key"])) }
            let buckets = series["buckets"]
            guard buckets.exists else { models.add(nil, series["model"].string); continue }
            for bucket in buckets.array {
                guard let time = bucket["time"].int, time >= from, time < to else { continue }
                let day = dayKey(Date(timeIntervalSince1970: TimeInterval(time)), calendar)
                let value = bucket["cost"].double
                dayCosts[day, default: 0] += value ?? 0
                models.add(value, series["model"].string)
            }
        }
        let todayKey = dayKey(now, calendar)
        return Summary(todayTokens: dayTokens[todayKey] ?? 0, periodTokens: dayTokens.values.reduce(0, +),
                       todayRequests: dayRequests[todayKey] ?? 0, periodRequests: dayRequests.values.reduce(0, +),
                       todayCost: dayCosts[todayKey], periodCost: dayCosts.values.reduce(0, +),
                       topModel: topModel(modelTokens), modelCosts: models.sorted,
                       currency: block?["currency"].string?.nilIfEmpty ?? "CNY", apiKeyCount: keys.count)
    }

    /// Fallback `usage/amount` and `usage/cost` for the current month.
    static func mapMonthly(amount: JSON, cost: JSON, now: Date, calendar: Calendar) throws -> Summary {
        try checkCodes(amount)
        try checkCodes(cost)
        let bizAmount = amount.at("data.biz_data")
        guard bizAmount.exists else { throw ProviderError.parse("DeepSeek amount data is missing.") }
        let bizCost = cost.at("data.biz_data")[0]
        let todayKey = dayKey(now, calendar)
        var monthStart = calendar.dateComponents([.year, .month], from: now)
        monthStart.day = 1
        let startOfMonth = calendar.date(from: monthStart) ?? now
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = calendar
        parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyy-MM-dd"

        func tokens(_ day: JSON, requests: Bool) -> Int {
            day["data"].array.flatMap { $0["usage"].array }.reduce(0) { sum, item in
                let type = (item["type"].string ?? "").uppercased()
                let isRequest = type == "REQUEST"
                guard isRequest == requests, isRequest || categories.contains(type) else { return sum }
                return sum + (item["amount"].string.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0)
            }
        }
        func dayCost(_ day: JSON) -> Double? {
            var total: Double?
            for item in day["data"].array.flatMap({ $0["usage"].array }) {
                let type = (item["type"].string ?? "").uppercased()
                guard categories.contains(type) else { continue }
                total = (total ?? 0) + (item["amount"].double ?? 0)
            }
            return total
        }
        let amountDays: [String: JSON] = Dictionary(bizAmount["days"].array.compactMap { d -> (String, JSON)? in d["date"].string.map { ($0, d) } },
                                    uniquingKeysWith: { first, _ in first })
        let costDays: [String: JSON] = Dictionary(bizCost["days"].array.compactMap { d -> (String, JSON)? in d["date"].string.map { ($0, d) } },
                                  uniquingKeysWith: { first, _ in first })
        var summary = Summary(currency: bizCost["currency"].string ?? "CNY", last30Days: false)
        summary.todayTokens = amountDays[todayKey].map { tokens($0, requests: false) } ?? 0
        summary.todayRequests = amountDays[todayKey].map { tokens($0, requests: true) } ?? 0
        summary.todayCost = costDays[todayKey].flatMap(dayCost)
        for date in Set(amountDays.keys).union(costDays.keys) {
            guard let parsed = parser.date(from: date), parsed >= startOfMonth, parsed <= now else { continue }
            if let day = amountDays[date] {
                summary.periodTokens += tokens(day, requests: false)
                summary.periodRequests += tokens(day, requests: true)
            }
            if let value = costDays[date].flatMap(dayCost) { summary.periodCost = (summary.periodCost ?? 0) + value }
        }
        var modelTokens: [String: Int] = [:]
        for item in bizAmount["total"].array {
            guard let model = item["model"].string else { continue }
            modelTokens[model] = item["usage"].array.reduce(0) { sum, usage in
                let type = (usage["type"].string ?? "").uppercased()
                guard categories.contains(type) else { return sum }
                return sum + (usage["amount"].string.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0)
            }
        }
        summary.topModel = topModel(modelTokens)
        var models = ModelCosts()
        for item in bizCost["total"].array {
            guard let model = item["model"].string else { continue }
            guard item["usage"].exists else { models.add(nil, model); continue }
            for usage in item["usage"].array {
                let type = (usage["type"].string ?? "").uppercased()
                guard type == "REQUEST" || categories.contains(type) else { models.add(nil, model); continue }
                if type != "REQUEST" { models.add(usage["amount"].double, model) }
            }
        }
        summary.modelCosts = models.sorted
        return summary
    }

    /// 30 days by key (fixed UTC offset, as the dashboard uses), else this month in UTC.
    static func fetchSummary(token: String, now: Date = Date()) async throws -> Summary {
        let headers = platformHeaders(token)
        let base = "https://platform.deepseek.com/api/v0/usage"
        var local = Calendar(identifier: .gregorian)
        let offset = TimeZone.current.secondsFromGMT(for: now)
        local.timeZone = TimeZone(secondsFromGMT: offset) ?? .current
        let today = local.startOfDay(for: now)
        let start = local.date(byAdding: .day, value: -29, to: today) ?? today
        let end = local.date(byAdding: .day, value: 1, to: today) ?? now
        let query = "start=\(Int(start.timeIntervalSince1970))&end=\(Int(end.timeIntervalSince1970))&tz=\(offset)"
        do {
            async let amount = HTTP.json("\(base)/by_api_key/amount?\(query)", headers: headers)
            async let cost = HTTP.json("\(base)/by_api_key/cost?\(query)", headers: headers)
            return try mapByAPIKey(amount: try await amount, cost: try await cost, now: now, calendar: local,
                                   start: start, end: end)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC") ?? .current
            let parts = utc.dateComponents([.year, .month], from: now)
            let month = "month=\(parts.month ?? 1)&year=\(parts.year ?? 2026)"
            async let amount = HTTP.json("\(base)/amount?\(month)", headers: headers)
            async let cost = HTTP.json("\(base)/cost?\(month)", headers: headers)
            return try mapMonthly(amount: try await amount, cost: try await cost, now: now, calendar: utc)
        }
    }

    /// "Usage" rows and per-model "Spend" rows. The daily token and cost charts have no home in the contract.
    static func sections(_ summary: Summary) -> [UsageSection] {
        let symbol = summary.currency == "CNY" ? "\u{00A5}" : "$"
        func money(_ value: Double?) -> String { value.map { "\(symbol)\(String(format: "%.4f", max(0, $0)))" } ?? "\u{2014}" }
        var rows = [
            UsageRow("Today", "\(money(summary.todayCost)) \u{00B7} \(Fmt.number(Double(summary.todayTokens))) tokens"),
            UsageRow(summary.last30Days ? "Last 30 days" : "This month",
                     "\(money(summary.periodCost)) \u{00B7} \(Fmt.number(Double(summary.periodTokens))) tokens"),
            UsageRow("Requests", "\(summary.periodRequests)"),
        ]
        if summary.apiKeyCount > 0 { rows.append(UsageRow("API keys", "\(summary.apiKeyCount)")) }
        if let top = summary.topModel { rows.append(UsageRow("Top model", top)) }
        return [UsageSection("Usage", rows),
                UsageSection("Spend", summary.modelCosts.map { UsageRow($0.model, money($0.cost)) })]
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
