import Foundation

extension ProviderCatalog {
    static let groq = ProviderSpec(
        id: "groq", name: "Groq",
        fields: [
            CredentialField("cookie", "Cookie header", optional: true,
                            placeholder: "stytch_session=...; stytch_session_jwt=... from console.groq.com"),
            CredentialField("apiKey", "API key (enterprise metrics)", optional: true, env: ["GROQ_API_KEY"]),
        ],
        dashboard: "https://console.groq.com/dashboard/usage",
        usage: { credential in
            let apiKey = credential["apiKey"]
            if let cookie = credential["cookie"] {
                do {
                    return try await GroqUsage.console(cookie: PastedCookie.clean(cookie))
                } catch let error as ProviderError where apiKey != nil && error.needsSignIn {
                    // No usable console session: fall back to the Prometheus metrics of the API key.
                }
            }
            guard let apiKey else {
                throw ProviderError.missingCredential("Add a Cookie header from console.groq.com, or a Groq API key.")
            }
            return try await GroqUsage.metrics(apiKey: apiKey)
        })
}

enum GroqUsage {
    /// Public Stytch token of the Groq console; the console web app sends the same one.
    private static let stytchToken = "public-token-live-58df57a9-a1f5-4066-bc0c-2ff942db684f"

    /// Spend, requests, and tokens from the console platform API, using the Stytch session cookies.
    static func console(cookie: String) async throws -> ProviderUsage {
        let session = Fmt.cookie("stytch_session", in: cookie)
        let direct = Fmt.cookie("stytch_session_jwt", in: cookie)
        guard session != nil || direct != nil else {
            throw ProviderError.missingCredential("The Cookie header needs stytch_session from console.groq.com.")
        }
        var jwt = direct
        if let session {
            do {
                jwt = try await refreshJWT(session: session)
            } catch where direct == nil {
                throw error
            } catch {}
        }
        guard let jwt, let org = organizationID(jwt: jwt) else {
            throw ProviderError.unauthorized("The Groq session has no organization. Paste a fresh Cookie header.")
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let json = try await HTTP.json(
            "https://api.groq.com/platform/v1/organizations/\(org)/activity?start_date=\(Int(start.timeIntervalSince1970))&end_date=\(Int(end.timeIntervalSince1970))",
            headers: HTTP.bearer(jwt))
        return try map(json)
    }

    /// Trades the long-lived `stytch_session` cookie for a fresh short-lived session JWT.
    static func refreshJWT(session: String) async throws -> String {
        let client = #"{"app":{"identifier":"console.groq.com"},"sdk":{"identifier":"Stytch.js Javascript SDK","version":"5.43.0"}}"#
        let json = try await HTTP.json(
            "https://api.stytchb2b.groq.com/sdk/v1/b2b/sessions/authenticate",
            headers: [
                "Authorization": "Basic " + Data("\(stytchToken):\(session)".utf8).base64EncodedString(),
                "Origin": "https://console.groq.com",
                "X-SDK-Parent-Host": "https://console.groq.com",
                "X-SDK-Client": Data(client.utf8).base64EncodedString(),
            ],
            object: ["session_token": session, "session_duration_minutes": 30])
        guard let jwt = json.at("data.session_jwt").string else {
            throw ProviderError.parse("Groq did not return a session token.")
        }
        return jwt
    }

    /// Organization id from the JWT claims; letters, digits, dash and underscore only, since it goes into a URL path.
    static func organizationID(jwt: String) -> String? {
        guard let claims = Fmt.jwtClaims(jwt) else { return nil }
        let id = claims["https://groq.com/organization"]["id"].string
            ?? claims["https://stytch.com/organization"]["slug"].string
        return id.flatMap { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } ? $0 : nil }
    }

    private struct Tally {
        var cost = 0.0
        var requests = 0.0
        var tokens = 0.0
    }

    /// `json` is the organization activity reply: one row per model per day. `now` picks "today" (UTC day buckets).
    static func map(_ json: JSON, now: Date = Date()) throws -> ProviderUsage {
        guard json["data"].exists else { throw ProviderError.parse("Groq returned an unexpected activity reply.") }
        let todayStart = Double(Int(now.timeIntervalSince1970) / 86_400 * 86_400)
        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.timeZone = TimeZone(identifier: "UTC")
        dayFormat.dateFormat = "yyyy-MM-dd"
        var total = Tally()
        var today = Tally()
        var cached = 0.0
        var organization: String?
        var days = [String: Tally]()
        var models = [String: Tally]()
        for row in json["data"].array {
            organization = organization ?? row["organization_name"].string
            let context = row["n_context_tokens_total"].double ?? 0
            let line = Tally(cost: row["cost"].double ?? 0, requests: row["num_requests"].double ?? 0,
                             tokens: context + (row["n_generated_tokens_total"].double ?? 0))
            func add(_ sum: inout Tally) {
                sum = Tally(cost: sum.cost + line.cost, requests: sum.requests + line.requests, tokens: sum.tokens + line.tokens)
            }
            add(&total)
            add(&models[row["model"].string ?? "unknown", default: Tally()])
            cached += max(0, context - (row["n_non_cached_context_tokens_total"].double ?? context))
            if let stamp = row["timestamp"].double {
                add(&days[dayFormat.string(from: Date(timeIntervalSince1970: stamp)), default: Tally()])
                if stamp >= todayStart { add(&today) }
            }
        }
        var month = [UsageRow("Requests", Fmt.number(total.requests)), UsageRow("Tokens", Fmt.number(total.tokens))]
        if cached > 0 { month.append(UsageRow("Cached input", Fmt.number(cached))) }
        let modelRows = models.sorted { ($0.value.tokens, $1.key) > ($1.value.tokens, $0.key) }.prefix(20).map {
            UsageRow($0.key, "\(Fmt.number($0.value.tokens)) tokens \u{B7} \(Fmt.number($0.value.requests)) requests")
        }
        let charts = [UsageChart.daily(id: "daily-cost", title: "Daily spend", unit: "USD", values: days.mapValues(\.cost), fill: (30, now)),
                      UsageChart.daily(id: "daily-tokens", title: "Daily tokens", unit: "tokens", values: days.mapValues(\.tokens), fill: (30, now)),
                      UsageChart.daily(id: "daily-requests", title: "Daily requests", unit: "requests", values: days.mapValues(\.requests), fill: (30, now))]
            .compactMap { $0 }.filter { $0.total > 0 }
        return ProviderUsage(
            cost: UsageCost(used: total.cost, period: "Last 30 days"),
            sections: [
                UsageSection("Today", [
                    UsageRow("Cost", Fmt.money(today.cost)),
                    UsageRow("Requests", Fmt.number(today.requests)),
                    UsageRow("Tokens", Fmt.number(today.tokens)),
                ]),
                UsageSection("Last 30 days", month),
                UsageSection("Models", Array(modelRows)),
            ],
            plan: "Console",
            organization: organization,
            charts: charts)
    }

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
