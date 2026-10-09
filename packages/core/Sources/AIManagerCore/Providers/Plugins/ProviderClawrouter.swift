import Foundation

extension ProviderCatalog {
    static let clawrouter = ProviderSpec(
        id: "clawrouter", name: "ClawRouter",
        fields: [.apiKey("CLAWROUTER_API_KEY"),
                 .init("baseURL", "Base URL", secure: false, optional: true,
                       placeholder: "https://clawrouter.openclaw.ai", env: ["CLAWROUTER_BASE_URL"])],
        dashboard: "https://clawrouter.openclaw.ai/dashboard/access",
        usage: { credential in
            var base = credential["baseURL"] ?? "https://clawrouter.openclaw.ai"
            while base.hasSuffix("/") { base.removeLast() }
            if !base.hasSuffix("/v1") { base += "/v1" }
            let json = try await HTTP.json("\(base)/usage", headers: HTTP.bearer(try credential.require("apiKey")))
            return try ClawrouterUsage.map(json)
        })
}

enum ClawrouterUsage {
    private static func micros(_ json: JSON) -> Double? { json.double.map { $0 / 1_000_000 } }

    static func map(_ json: JSON) throws -> ProviderUsage {
        let budget = json["budget"], summary = json.at("usage.summary")
        guard budget.exists, summary.exists, json.at("usage.providers").raw is [Any],
              budget["configured"].bool != nil, let ledger = budget["ledger"].string,
              let requests = summary["requestCount"].int, let success = summary["successCount"].int,
              let errors = summary["errorCount"].int, let input = summary["inputTokens"].int,
              let output = summary["outputTokens"].int, let total = summary["totalTokens"].int,
              let actual = micros(summary["actualCostMicros"]) else {
            throw ProviderError.parse("Could not parse ClawRouter usage: response shape is invalid")
        }
        let limit = micros(budget["limitMicros"]), spent = micros(budget["spentMicros"])
        let remaining = micros(budget["remainingMicros"])
        var resetsAt: Date?
        if let key = budget["windowKey"].string, let match = key.range(of: #"(\d{4})-(\d{2})$"#, options: .regularExpression) {
            let parts = key[match].split(separator: "-").compactMap { Int($0) }
            if parts.count == 2 {
                let next = parts[1] == 12 ? (parts[0] + 1, 1) : (parts[0], parts[1] + 1)
                resetsAt = Fmt.iso(String(format: "%04d-%02d-01T00:00:00Z", next.0, next.1))
            }
        }
        let providers = json.at("usage.providers").array.map {
            (name: $0["provider"].string ?? "Unknown", requests: $0["requestCount"].int ?? 0,
             tokens: $0["totalTokens"].int ?? 0, cost: micros($0["actualCostMicros"]) ?? 0)
        }.sorted { ($0.cost, $0.requests) > ($1.cost, $1.requests) }

        func usd(_ value: Double) -> String { String(format: "$%.6f", value) }
        var rows = [UsageRow("Requests", "\(requests) (\(success) succeeded, \(errors) failed)"),
                    UsageRow("Tokens", "\(total) (\(input) input, \(output) output)"),
                    UsageRow("Actual cost", usd(actual)), UsageRow("Budget ledger", ledger)]
        var windows: [UsageWindow] = []
        var cost: UsageCost?
        if let spent, let limit {
            if limit > 0 {
                windows = [UsageWindow(id: "monthly", title: "Monthly budget", usedPercent: spent / limit * 100,
                                       resetsAt: resetsAt, windowMinutes: nil, detail: "\(usd(spent)) / \(Fmt.money(limit))")]
            }
            cost = UsageCost(used: spent, limit: limit, period: "This month", resetsAt: resetsAt)
            rows.append(.init("Monthly budget", "\(usd(spent)) / \(Fmt.money(limit))" + (remaining.map { " (\(usd($0)) remaining)" } ?? "")))
        } else if actual > 0 {
            cost = UsageCost(used: actual, period: "This month", resetsAt: resetsAt)
        }
        var sections = [UsageSection("Usage", rows)]
        sections.append(.init("Routed providers", providers.prefix(20).map {
            UsageRow($0.name, "\($0.requests) requests, \(usd($0.cost)), \($0.tokens) tokens")
        }))
        return ProviderUsage(windows: windows, cost: cost, sections: sections,
                             plan: budget["configured"].bool == true ? "Managed monthly budget" : "Unmetered",
                             organization: "\(providers.count) routed providers")
    }
}
