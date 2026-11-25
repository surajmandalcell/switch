import Foundation

extension ProviderCatalog {
    static let groq = ProviderSpec(
        id: "groq", name: "Groq",
        fields: [CredentialField("apiKey", "API key (enterprise metrics)", env: ["GROQ_API_KEY"])],
        dashboard: "https://console.groq.com/dashboard/usage",
        usage: { credential in try await GroqUsage.metrics(apiKey: try credential.require("apiKey")) })
}

enum GroqUsage {
    // MARK: Prometheus metrics (enterprise API keys)

    static func metrics(apiKey: String) async throws -> ProviderUsage {
        func query(_ expression: String) async throws -> Double {
            var parts = URLComponents(string: "https://api.groq.com/v1/metrics/prometheus/api/v1/query")!
            parts.queryItems = [URLQueryItem(name: "query", value: expression)]
            return try scalar(try await HTTP.json(parts.string ?? "", headers: HTTP.bearer(apiKey)))
        }
        async let requests = query("sum(model_project_id_status_code:requests:rate5m)")
        async let input = query("sum(model_project_id:tokens_in:rate5m)")
        async let output = query("sum(model_project_id:tokens_out:rate5m)")
        async let cache = query("sum(model_project_id:prompt_cache_hits:rate5m)")
        return try mapMetrics(requests: await requests, input: await input, output: await output, cache: await cache)
    }

    /// Sums a Prometheus instant vector. A missing, negative, or non-finite sample is an error, never a zero.
    static func scalar(_ json: JSON) throws -> Double {
        guard json["status"].string == "success" else {
            throw ProviderError.parse("Groq metrics error: \(json["error"].string ?? "query failed")")
        }
        guard let result = json.at("data.result").raw as? [Any] else {
            throw ProviderError.parse("Groq metrics reply has no result.")
        }
        return try result.reduce(0) { sum, item in
            let sample = JSON(item)["value"]
            guard sample.array.count == 2, sample[0].double?.isFinite == true,
                  let value = sample[1].double, value >= 0, (sum + value).isFinite else {
                throw ProviderError.parse("Groq metrics returned an invalid sample.")
            }
            return sum + value
        }
    }

    /// Rates are per second; windows show per-minute rates over the 5 minute query window.
    static func mapMetrics(requests: Double, input: Double, output: Double, cache: Double,
                           now: Date = Date()) throws -> ProviderUsage {
        let perMinute = [requests * 60, (input + output) * 60, cache * 60]
        guard perMinute.allSatisfy(\.isFinite) else { throw ProviderError.parse("Groq metrics rates overflow.") }
        func text(_ value: Double) -> String {
            String(format: "%.\(value >= 100 ? 0 : (value >= 10 ? 1 : 2))f", value)
        }
        // No quota exists, so the windows carry only the rate and no used percent.
        var windows = [
            UsageWindow(id: "requests", title: "Requests", usedPercent: nil, windowMinutes: 5, detail: "\(text(perMinute[0])) req/min"),
            UsageWindow(id: "tokens", title: "Tokens", usedPercent: nil, windowMinutes: 5, detail: "\(text(perMinute[1])) tok/min"),
        ]
        if cache > 0 {
            windows.append(UsageWindow(id: "cache", title: "Cache hits", usedPercent: nil, windowMinutes: 5,
                                       detail: "\(text(perMinute[2])) cache/min"))
        }
        return ProviderUsage(windows: windows, plan: "Prometheus metrics", fetchedAt: now)
    }
}
