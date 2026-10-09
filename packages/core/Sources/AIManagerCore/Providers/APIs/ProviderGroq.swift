import Foundation

extension ProviderCatalog {
    static let groq = ProviderSpec(
        id: "groq", name: "Groq",
        fields: [.cookie("stytch_session=...; stytch_session_jwt=... from console.groq.com")],
        dashboard: "https://console.groq.com/dashboard/usage",
        usage: { credential in
            let cookie = try credential.require("cookie")
            let session = Fmt.cookie("stytch_session", in: cookie)
            let direct = Fmt.cookie("stytch_session_jwt", in: cookie)
            guard session != nil || direct != nil else {
                throw ProviderError.missingCredential("The Cookie header needs stytch_session from console.groq.com.")
            }
            var jwt = direct
            if let session {
                do {
                    jwt = try await GroqUsage.refreshJWT(session: session)
                } catch where direct == nil {
                    throw error
                } catch {}
            }
            guard let jwt, let org = GroqUsage.organizationID(jwt: jwt) else {
                throw ProviderError.unauthorized("The Groq session has no organization. Paste a fresh Cookie header.")
            }
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            let end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
            let json = try await HTTP.json(
                "https://api.groq.com/platform/v1/organizations/\(org)/activity?start_date=\(Int(start.timeIntervalSince1970))&end_date=\(Int(end.timeIntervalSince1970))",
                headers: HTTP.bearer(jwt))
            return try GroqUsage.map(json)
        })
}

enum GroqUsage {
    /// Public Stytch token of the Groq console; the console web app sends the same one.
    private static let stytchToken = "public-token-live-58df57a9-a1f5-4066-bc0c-2ff942db684f"

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

    /// `json` is the organization activity reply: one row per model per day. `now` picks "today" (UTC day buckets).
    static func map(_ json: JSON, now: Date = Date()) throws -> ProviderUsage {
        guard json["data"].exists else { throw ProviderError.parse("Groq returned an unexpected activity reply.") }
        let todayStart = Double(Int(now.timeIntervalSince1970) / 86_400 * 86_400)
        var total = (cost: 0.0, requests: 0.0, tokens: 0.0)
        var today = total
        var organization: String?
        for row in json["data"].array {
            organization = organization ?? row["organization_name"].string
            let cost = row["cost"].double ?? 0
            let requests = row["num_requests"].double ?? 0
            let tokens = (row["n_context_tokens_total"].double ?? 0) + (row["n_generated_tokens_total"].double ?? 0)
            total = (total.cost + cost, total.requests + requests, total.tokens + tokens)
            if let stamp = row["timestamp"].double, stamp >= todayStart {
                today = (today.cost + cost, today.requests + requests, today.tokens + tokens)
            }
        }
        return ProviderUsage(
            cost: UsageCost(used: total.cost, period: "Last 30 days"),
            sections: [
                UsageSection("Today", [
                    UsageRow("Cost", Fmt.money(today.cost)),
                    UsageRow("Requests", Fmt.number(today.requests)),
                    UsageRow("Tokens", Fmt.number(today.tokens)),
                ]),
                UsageSection("Last 30 days", [
                    UsageRow("Requests", Fmt.number(total.requests)),
                    UsageRow("Tokens", Fmt.number(total.tokens)),
                ]),
            ],
            organization: organization)
    }
}
