import Foundation

extension ProviderCatalog {
    static let llmproxy = ProviderSpec(
        id: "llmproxy", name: "LLM Proxy",
        fields: [
            .apiKey("LLM_PROXY_API_KEY"),
            CredentialField("baseURL", "Base URL", secure: false, placeholder: "https://proxy.example.com"),
        ],
        usage: { credential in
            let key = try credential.require("apiKey")
            var base = try credential.require("baseURL").replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            if !base.hasSuffix("/v1") { base += "/v1" }
            let json = try await HTTP.json("\(base)/quota-stats", headers: HTTP.bearer(key))
            return try LlmproxyUsage.map(json)
        })
}

enum LlmproxyUsage {
    static func map(_ root: JSON, now: Date = Date()) throws -> ProviderUsage {
        guard root["providers"].raw is [String: Any] else {
            throw ProviderError.parse("LLM Proxy parse error: expected a providers object.")
        }
        struct Stats { var name: String; var requests = 0.0; var tokens = 0.0; var cost: Double? }
        var credentials = 0, active = 0
        var remaining: [Double] = [], resets: [Date] = []
        var providers: [Stats] = []
        for (name, stats) in root["providers"].object {
            credentials += stats["credential_count"].int ?? 0
            active += stats["active_count"].int ?? 0
            // Quota groups are best effort and arrive as a list or a keyed object.
            let groups = stats["quota_groups"].raw is [Any] ? stats["quota_groups"].array : Array(stats["quota_groups"].object.values)
            for group in groups {
                if let percent = group["remaining_percent"].double { remaining.append(percent) }
                if let reset = group["reset_time"].date, reset > now { resets.append(reset) }
            }
            let tokens = stats["tokens"]
            providers.append(Stats(
                name: name, requests: stats["total_requests"].double ?? 0,
                tokens: (tokens["input_cached"].double ?? 0) + (tokens["input_uncached"].double ?? 0) + (tokens["output"].double ?? 0),
                cost: stats["approx_cost"].double))
        }
        providers.sort { $0.requests != $1.requests ? $0.requests > $1.requests : $0.name < $1.name }
        let summary = root["summary"]
        let requests = summary["total_requests"].double ?? providers.reduce(0) { $0 + $1.requests }
        let tokens = summary["total_tokens"].double ?? providers.reduce(0) { $0 + $1.tokens }
        let summed = providers.reduce(0) { $0 + ($1.cost ?? 0) }
        let spend = summary["approx_cost"].double ?? (summed > 0 ? summed : nil)
        let reset = resets.min()
        var windows: [UsageWindow] = []
        if let lowest = remaining.min() {
            windows.append(UsageWindow(id: "quota", title: "Quota", usedPercent: 100 - lowest, resetsAt: reset))
        }
        let rows = providers.prefix(6).map { stats -> UsageRow in
            var parts = ["\(Fmt.number(stats.requests)) req", "\(Fmt.number(stats.tokens)) tok"]
            if let cost = stats.cost { parts.append(Fmt.money(cost)) }
            return UsageRow(stats.name, parts.joined(separator: " · "))
        }
        return ProviderUsage(
            windows: windows, cost: spend.map { UsageCost(used: $0, period: "Approx. spend", resetsAt: reset) },
            sections: [UsageSection("Totals", [UsageRow("Requests", Fmt.number(requests)),
                                               UsageRow("Tokens", Fmt.number(tokens))]),
                       UsageSection("Providers", rows)],
            plan: "quota-stats", organization: "\(active)/\(credentials) active keys")
    }
}
