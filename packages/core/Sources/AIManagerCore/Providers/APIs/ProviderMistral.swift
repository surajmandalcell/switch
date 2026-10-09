import Foundation

extension ProviderCatalog {
    static let mistral = ProviderSpec(
        id: "mistral", name: "Mistral",
        fields: [.cookie("ory_session_<suffix>=...; csrftoken=... from admin.mistral.ai")],
        dashboard: "https://admin.mistral.ai/organization/usage",
        usage: { credential in
            let cookie = try credential.require("cookie")
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
            return try MistralUsage.map(usage: usage, credits: credits, subscriptionHTML: html)
        })
}

enum MistralUsage {
    /// `usage` is the v2 billing JSON; `credits` and `subscriptionHTML` are best effort.
    static func map(usage: JSON, credits: JSON?, subscriptionHTML: String?) throws -> ProviderUsage {
        guard !usage.object.isEmpty else { throw ProviderError.parse("Mistral returned an empty usage reply.") }
        let currency = (usage["currency"].string ?? credits?["currency"].string ?? "USD").uppercased()
        let prices = priceIndex(usage["prices"].array)
        var spend = 0.0
        var tokens = [String: Double]()
        // Path -> whether its tokens count toward the month totals.
        let categories: [(String, Bool)] = [
            ("completion.models", true), ("chat.models", true), ("vibe_code.completion.models", true),
            ("ocr.models", false), ("connectors.models", false), ("audio.models", false),
            ("libraries_api.pages.models", false), ("libraries_api.tokens.models", false),
            ("fine_tuning.training", false), ("fine_tuning.storage", false),
        ]
        for (path, countsTokens) in categories {
            for model in usage.at(path).object.values {
                for lane in ["input", "output", "cached"] {
                    for entry in model[lane].array {
                        spend += (entry["value_paid"].double ?? entry["value"].double ?? 0) * price(entry, prices)
                        if countsTokens { tokens[lane, default: 0] += entry["value"].double ?? entry["value_paid"].double ?? 0 }
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
            windows.append(UsageWindow(
                id: id, title: title, usedPercent: budget.percent, resetsAt: budget.resetsAt,
                detail: "\(Fmt.money(used, currency: budget.currency)) / \(Fmt.money(budget.limit, currency: budget.currency))"))
        }
        let rows = [("input", "Input tokens"), ("output", "Output tokens"), ("cached", "Cached tokens")]
            .compactMap { lane, label in tokens[lane].map { UsageRow(label, Fmt.number($0)) } }
        return ProviderUsage(
            windows: windows,
            cost: UsageCost(used: spend, balance: balance, currency: currency, period: "Month to date"),
            sections: [UsageSection("This month", rows)])
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

    private struct Budget {
        let percent: Double
        let limit: Double
        let currency: String
        let resetsAt: Date?
    }

    /// Reads `api_budget` and `vibe_budget` objects out of the Next.js flight data on the subscription page.
    /// ponytail: first match wins and byte-counted flight rows are not skipped; add a strict parser if Mistral changes the page.
    private static func budgets(html: String) -> [String: Budget] {
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
