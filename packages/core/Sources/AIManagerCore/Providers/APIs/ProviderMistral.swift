import Foundation

extension ProviderCatalog {
    static let mistral = ProviderSpec(
        id: "mistral", name: "Mistral",
        fields: [.cookie("ory_session_<suffix>=...; csrftoken=... from admin.mistral.ai")],
        dashboard: "https://admin.mistral.ai/organization/usage",
        usage: { credential in
            let cookie = PastedCookie.clean(try credential.require("cookie"))
            guard cookie.contains("ory_session_") else {
                throw ProviderError.missingCredential("The Cookie header needs an ory_session_ cookie from admin.mistral.ai.")
            }
            var headers = ["Cookie": cookie, "Accept": "*/*", "Origin": "https://admin.mistral.ai"]
            if let csrf = Fmt.cookie("csrftoken", in: cookie) { headers["X-CSRFTOKEN"] = csrf }
            let now = Date()
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            let parts = utc.dateComponents([.year, .month], from: now)
            var usageHeaders = headers
            usageHeaders["Referer"] = "https://admin.mistral.ai/organization/usage"
            let usage = try await HTTP.json(
                "https://admin.mistral.ai/api/billing/v2/usage?month=\(parts.month ?? 1)&year=\(parts.year ?? 2026)",
                headers: usageHeaders)
            var creditHeaders = headers
            creditHeaders["Referer"] = "https://admin.mistral.ai/organization/billing"
            let credits = try? await HTTP.json("https://admin.mistral.ai/api/billing/credits", headers: creditHeaders)
            var pageHeaders = headers
            pageHeaders["Accept"] = "text/html"
            pageHeaders["Referer"] = "https://admin.mistral.ai/subscription"
            let page = try? await HTTP.send("https://admin.mistral.ai/subscription", headers: pageHeaders)
            let html = page.flatMap { (200..<300).contains($0.status) ? $0.text : nil }
            // Without a Vibe allowance on the subscription page, ask the console for it.
            var vibe: JSON?
            if let csrf = Fmt.cookie("csrftoken", in: cookie),
               !(html.map { MistralUsage.budgets(html: $0)["vibe_budget"] != nil } ?? false) {
                let sessions = cookie.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("ory_session_") }
                vibe = try? await HTTP.json(MistralUsage.vibeURL, headers: [
                    "Accept": "*/*", "X-CSRFToken": csrf,
                    "Cookie": (["csrftoken=\(csrf)"] + sessions).joined(separator: "; "),
                ])
            }
            return try MistralUsage.map(usage: usage, credits: credits, subscriptionHTML: html, vibeUsage: vibe)
        })
}

enum MistralUsage {
    /// `usage` is the v2 billing JSON; `credits` and `subscriptionHTML` are best effort.
    static let vibeURL = "https://console.mistral.ai/api-ui/trpc/billing.vibeUsage?batch=1&input=%7B%220%22%3A%7B%22json%22%3Anull%2C%22meta%22%3A%7B%22values%22%3A%5B%22undefined%22%5D%2C%22v%22%3A1%7D%7D%7D"

    private struct Tally {
        var cost = 0.0
        var tokens = 0.0
    }

    /// `vibeUsage` is the console tRPC reply, used only when the subscription page has no Vibe allowance.
    static func map(usage: JSON, credits: JSON?, subscriptionHTML: String?, vibeUsage: JSON? = nil) throws -> ProviderUsage {
        guard !usage.object.isEmpty else { throw ProviderError.parse("Mistral returned an empty usage reply.") }
        let currency = (usage["currency"].string ?? credits?["currency"].string ?? "USD").uppercased()
        let prices = priceIndex(usage["prices"].array)
        var spend = 0.0
        var tokens = [String: Double]()
        // day -> model -> tally, for the daily and per-model breakdowns.
        var days = [String: [String: Tally]]()
        // Path -> (counts toward the month token totals, counts toward the daily token totals).
        let categories: [(String, Bool, Bool)] = [
            ("completion.models", true, true), ("chat.models", true, true), ("vibe_code.completion.models", true, true),
            ("ocr.models", false, false), ("connectors.models", false, false), ("audio.models", false, false),
            ("libraries_api.pages.models", false, false), ("libraries_api.tokens.models", false, true),
            ("fine_tuning.training", false, false), ("fine_tuning.storage", false, false),
        ]
        for (path, monthTokens, dailyTokens) in categories {
            for (name, model) in usage.at(path).object {
                for lane in ["input", "output", "cached"] {
                    for entry in model[lane].array {
                        let cost = (entry["value_paid"].double ?? entry["value"].double ?? 0) * price(entry, prices)
                        let units = entry["value"].double ?? entry["value_paid"].double ?? 0
                        if cost.isFinite { spend += cost }
                        if monthTokens { tokens[lane, default: 0] += units }
                        guard let stamp = entry["timestamp"].string?.trimmingCharacters(in: .whitespaces), stamp.count >= 10 else { continue }
                        let shown = entry["billing_display_name"].string?.trimmingCharacters(in: .whitespaces)
                        let label = shown.flatMap { $0.isEmpty ? nil : $0 } ?? name.components(separatedBy: "::")[0]
                        if cost.isFinite { days[String(stamp.prefix(10)), default: [:]][label, default: Tally()].cost += cost }
                        if dailyTokens { days[String(stamp.prefix(10)), default: [:]][label, default: Tally()].tokens += units }
                    }
                }
            }
        }
        var balance: Double?
        if let credits, credits["wallet_amount"].exists {
            let wallet = credits["wallet_amount"].double ?? 0
            let notes = credits["credit_notes_amount"].double ?? 0
            let ongoing = credits["ongoing_usage_balance"].double ?? 0
            balance = max(0, wallet + notes - ongoing)
        }
        var windows: [UsageWindow] = []
        let budgets = subscriptionHTML.map(budgets) ?? [:]
        for (key, id, title) in [("api_budget", "api", "Included API"), ("vibe_budget", "vibe", "Monthly Plan")] {
            guard let budget = budgets[key] else { continue }
            let used = budget.limit * budget.percent / 100
            let left = Fmt.money(max(budget.limit - used, 0), currency: budget.currency)
            windows.append(UsageWindow(
                id: id, title: title, usedPercent: budget.percent, resetsAt: budget.resetsAt,
                detail: "\(Fmt.money(used, currency: budget.currency)) / \(Fmt.money(budget.limit, currency: budget.currency)) \u{B7} \(left) left"))
        }
        let console = vibeUsage?[0].at("result.data.json")
        if budgets["vibe_budget"] == nil, let percent = console?["usage_percentage"].double, (0...100).contains(percent) {
            windows.append(UsageWindow(id: "vibe", title: "Monthly Plan", usedPercent: percent,
                                       resetsAt: console?["reset_at"].date))
        }
        var rows = [("input", "Input tokens"), ("output", "Output tokens"), ("cached", "Cached tokens")]
            .compactMap { lane, label in tokens[lane].map { UsageRow(label, Fmt.number($0)) } }
        if let start = usage["start_date"].string?.prefix(10), let end = usage["end_date"].string?.prefix(10) {
            rows.append(UsageRow("Period", "\(start) to \(end)"))
        }
        // API prices are tiny; keep up to 4 decimals like the Mistral dashboard.
        func describe(_ tally: Tally) -> String {
            let cost = Fmt.money(tally.cost, currency: currency, fractionDigits: 4)
            return tally.tokens > 0 ? "\(cost) \u{B7} \(Fmt.number(tally.tokens)) tokens" : cost
        }
        func sum(_ models: [String: Tally]) -> Tally {
            models.values.reduce(Tally()) { Tally(cost: $0.cost + $1.cost, tokens: $0.tokens + $1.tokens) }
        }
        let spendChart = UsageChart.daily(id: "daily-spend", title: "Daily spend (this month)", unit: currency,
                                          values: days.mapValues { sum($0).cost })
        let tokenChart = UsageChart.daily(id: "daily-tokens", title: "Daily tokens (this month)", unit: "tokens",
                                          values: days.mapValues { sum($0).tokens })
        var perModel = [String: Tally]()
        for models in days.values {
            for (name, tally) in models {
                perModel[name, default: Tally()].cost += tally.cost
                perModel[name, default: Tally()].tokens += tally.tokens
            }
        }
        let modelRows = perModel.sorted { ($0.value.tokens, $1.key) > ($1.value.tokens, $0.key) }.prefix(20)
            .map { UsageRow($0.key, describe($0.value)) }
        return ProviderUsage(
            windows: windows,
            // A negative total is a refund adjustment; show zero spend.
            cost: UsageCost(used: max(spend, 0), balance: balance, currency: currency, period: "Month to date"),
            sections: [UsageSection("This month", rows), UsageSection("Models", Array(modelRows))],
            charts: [spendChart, tokenChart].compactMap { $0 }.filter { $0.total > 0 })
    }

    private static func key(_ item: JSON) -> String {
        ["event_type", "billing_metric", "billing_group", "api_zone", "service_tier"]
            .map { item[$0].string ?? "" }.joined(separator: "|")
    }

    private static func priceIndex(_ prices: [JSON]) -> [String: Double] {
        var index: [String: Double] = [:]
        for item in prices {
            if let value = item["price"].double { index[key(item)] = value }
        }
        return index
    }

    private static func price(_ entry: JSON, _ prices: [String: Double]) -> Double {
        let zoneless = ["event_type", "billing_metric", "billing_group"].map { entry[$0].string ?? "" }
            .joined(separator: "|") + "||"
        let value = prices[key(entry)] ?? prices[zoneless] ?? 0
        return value.isFinite ? value : 0
    }

    struct Budget {
        let percent: Double
        let limit: Double
        let currency: String
        let resetsAt: Date?
    }

    /// Reads `api_budget` and `vibe_budget` objects out of the Next.js flight data on the subscription page.
    /// ponytail: first match wins and byte-counted flight rows are not skipped; add a strict parser if Mistral changes the page.
    static func budgets(html: String) -> [String: Budget] {
        guard let regex = try? NSRegularExpression(pattern: #"self\.__next_f\.push\(\[1,"((?:[^"\\]|\\.)*)"\]\)"#) else { return [:] }
        let source = html as NSString
        let stream = regex.matches(in: html, range: NSRange(location: 0, length: source.length)).compactMap { match -> String? in
            let literal = "\"" + source.substring(with: match.range(at: 1)) + "\""
            return (try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: [.fragmentsAllowed])) as? String
        }.joined()
        var found: [String: Budget] = [:]
        for name in ["api_budget", "vibe_budget"] {
            guard let marker = stream.range(of: "\"\(name)\":{"),
                  let end = objectEnd(stream, from: stream.index(before: marker.upperBound)),
                  let object = try? JSONSerialization.jsonObject(with: Data(stream[stream.index(before: marker.upperBound)..<end].utf8))
            else { continue }
            let json = JSON(object)
            guard let percent = json["usage_percentage"].double, percent >= 0,
                  let limit = json["initial_budget"].double, limit > 0,
                  let currency = json["currency"].string else { continue }
            found[name] = Budget(percent: percent, limit: limit, currency: currency.uppercased(),
                                 resetsAt: json["reset_at"].date)
        }
        return found
    }

    /// Index just after the `}` that closes the object starting at `start`.
    private static func objectEnd(_ text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let char = text[index]
            if inString {
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { inString = false }
            } else if char == "\"" {
                inString = true
            } else if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 { return text.index(after: index) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
