import Foundation

extension ProviderCatalog {
    static let wayfinder = ProviderSpec(
        id: "wayfinder", name: "Wayfinder",
        fields: [CredentialField("baseURL", "Gateway URL", secure: false, optional: true,
                                 placeholder: "http://127.0.0.1:8088", env: ["WAYFINDER_GATEWAY_URL"])],
        dashboard: "http://127.0.0.1:8088/router",
        usage: { credential in
            var base = credential["baseURL"] ?? "http://127.0.0.1:8088"
            while base.hasSuffix("/") { base.removeLast() }
            guard let parts = URLComponents(string: base), parts.user == nil, parts.password == nil,
                  parts.scheme == "https" || parts.scheme == "http" else {
                throw ProviderError.missingCredential("The Wayfinder gateway URL must be http or https without a login.")
            }
            let health: JSON
            do {
                health = try await HTTP.json(base + "/healthz")
            } catch ProviderError.network {
                throw ProviderError.network("Could not reach the Wayfinder gateway. Start it with `wayfinder-router serve` "
                    + "(default http://127.0.0.1:8088) or fix the Gateway URL.")
            }
            let models = try await HTTP.json(base + "/router/models")
            let savings = try? await HTTP.json(base + "/v1/savings?period=30d")
            let metrics = try? await HTTP.send(base + "/metrics", headers: ["Accept": "text/plain"])
            return WayfinderUsage.map(health: health, models: models, savings: savings,
                                      metrics: metrics.flatMap { (200..<300).contains($0.status) ? $0.text : nil })
        })
}

enum WayfinderUsage {
    static func map(health: JSON, models: JSON, savings: JSON?, metrics: String?) -> ProviderUsage {
        let missing = health["missing_keys"].array.count
        let label: String
        if health["offline"].bool == true {
            label = "Offline mode"
        } else if models["dry_run"].bool == true {
            label = "Dry run"
        } else if health["status"].string == "degraded" {
            label = "Degraded, \(missing) keys missing"
        } else {
            label = "Local gateway"
        }
        let modelCount = models["models"].array.count
        var gateway = [UsageRow("Status", label), UsageRow("Models", Fmt.number(Double(modelCount)))]
        if let metrics, let ms = averageDecisionMilliseconds(metrics) { gateway.append(UsageRow("Avg decision", "\(Fmt.number(ms, digits: 1)) ms")) }
        // Raw health word plus the offline and dry-run markers, as CodexBar's Gateway line.
        let markers = [health["offline"].bool == true ? "offline" : nil, models["dry_run"].bool == true ? "dry run" : nil]
        gateway.append(UsageRow("Gateway", ([health["status"].string ?? "unknown", "\(modelCount) model\(modelCount == 1 ? "" : "s")"]
            + markers.compactMap { $0 }).joined(separator: " · ")))
        var sections = [UsageSection("Gateway", gateway)]
        if let savings {
            let requests = savings["requests"].double ?? 0
            let saved = savings["saved"].double ?? 0
            var rows: [UsageRow] = []
            if requests > 0, saved > 0 {
                let percent = savings["saved_pct"].double.map { "\(Fmt.number($0, digits: 1))% vs highest-cost route" }
                let dollars = savings["priced"].bool == true ? (saved < 0.01 ? "<$0.01" : Fmt.money(saved)) : nil
                rows.append(UsageRow("Saved (30d)", [dollars, percent].compactMap { $0 }.joined(separator: ", ")))
            }
            let routes = savings["by_route"].object.map { ($0.key, $0.value["requests"].double ?? 0) }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(5)
            rows += routes.map { UsageRow($0.0, Fmt.number($0.1)) }
            sections.append(UsageSection("Routes (30d)", rows))
        }
        return ProviderUsage(sections: sections, plan: label, organization: "\(modelCount) model\(modelCount == 1 ? "" : "s") · local gateway")
    }

    /// Mean of the Prometheus router decision latency histogram, in milliseconds.
    private static func averageDecisionMilliseconds(_ text: String) -> Double? {
        func total(_ name: String) -> Double? {
            let values = text.split(separator: "\n").compactMap { line -> Double? in
                guard line.hasPrefix(name), let next = line.dropFirst(name.count).first, next == " " || next == "{" else { return nil }
                return line.split(separator: " ").last.flatMap { Double($0) }
            }
            return values.isEmpty ? nil : values.reduce(0, +)
        }
        guard let sum = total("wayfinder_router_decision_latency_seconds_sum"),
              let count = total("wayfinder_router_decision_latency_seconds_count"), count > 0 else { return nil }
        return sum / count * 1000
    }
}
