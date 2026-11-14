import Foundation

extension ProviderCatalog {
    /// Reads the billing overview JSON the web console calls (CodexBar b22cdc2, d1f1f2b; MIT).
    static let typesafe = ProviderSpec(
        id: "typesafe", name: "TypeSafe",
        fields: [.cookie("Cookie header from console.typesafe.ai/billing")],
        dashboard: "https://console.typesafe.ai/usage",
        usage: { try await TypeSafeUsage.fetch(cookie: $0.require("cookie")) })
}

enum TypeSafeUsage {
    typealias Send = @Sendable (String, [String: String]) async throws -> HTTPResponse
    static let liveSend: Send = { try await HTTP.send($0, headers: $1) }

    static let overviewFailure = "TypeSafe billing overview could not be read. Open https://console.typesafe.ai/billing to check access; if the page opens, report the integration failure."
    private static let expired = ProviderError.unauthorized("TypeSafe session expired. Paste a fresh Cookie header.")

    static func fetch(cookie: String, send: Send = liveSend) async throws -> ProviderUsage {
        // Cloudflare blocks the default agent, and the API refuses requests that do not look same-origin.
        let response = try await send("https://console.typesafe.ai/api/billing/overview", [
            "Cookie": cookie, "Accept": "application/json",
            "Origin": "https://console.typesafe.ai", "Referer": "https://console.typesafe.ai/billing",
            "Sec-Fetch-Site": "same-origin", "Sec-Fetch-Mode": "cors", "Sec-Fetch-Dest": "empty",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
        ])
        try check(response)
        // A signed-out console can answer with an HTML login page instead of JSON.
        let body = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("<") {
            if body.range(of: #"login|sign[-\s]?in|\(auth\)"#, options: [.regularExpression, .caseInsensitive]) != nil { throw expired }
            throw ProviderError.http(response.status, overviewFailure)
        }
        guard let json = try? JSON(data: Data(body.utf8)) else { throw ProviderError.parse(overviewFailure) }
        return try map(json)
    }

    /// 401 and 403 mean a signed-out session, except the explicit cross-origin refusal. A redirect means
    /// a signed-out session only when it goes to a login route or off typesafe.ai.
    static func check(_ response: HTTPResponse) throws {
        if response.status == 403, response.text.range(of: "cross-origin request refused", options: .caseInsensitive) != nil {
            throw ProviderError.http(403, overviewFailure)
        }
        if (300..<400).contains(response.status) {
            if loginRedirect(response.headers["location"]) { throw expired }
            throw ProviderError.http(response.status, overviewFailure)
        }
        do { try HTTP.check(response) } catch let error as ProviderError where error.needsSignIn { throw expired }
    }

    static func loginRedirect(_ location: String?) -> Bool {
        guard let target = location?.trimmingCharacters(in: .whitespaces), !target.isEmpty else { return false }
        let login = target.range(of: #"(?:^|[/?#])(?:login|sign-?in|auth|oauth|sso)(?:[/?#]|$)"#,
                                 options: [.regularExpression, .caseInsensitive]) != nil
        guard target.range(of: #"^(?:https?:)?//"#, options: [.regularExpression, .caseInsensitive]) != nil else { return login }
        let host = URL(string: target.hasPrefix("//") ? "https:" + target : target)?.host?.lowercased() ?? ""
        return !(host == "typesafe.ai" || host.hasSuffix(".typesafe.ai")) || login
    }

    static func map(_ json: JSON) throws -> ProviderUsage {
        let billing = json["billing"]
        guard let spent = billing["spent"].double, let balance = billing["balance"].double else {
            throw ProviderError.parse(overviewFailure)
        }
        let cycle = billing["cycleLabel"].string
        let plan = billing["plan"].string.map { $0 == "free_plan" ? "Free" : $0.split(whereSeparator: { "_-".contains($0) }).map(\.capitalized).joined(separator: " ") }
        var rows = [UsageRow(cycle.map { "Spent (\($0))" } ?? "Spent", Fmt.money(spent))]
        // The plan label is the account plan, not a row. At most 24 rows: when credits overflow, the last
        // slot counts the ones left out.
        let slots = 23 - rows.count
        let credits = billing["credits"].array.compactMap { credit -> UsageRow? in
            guard let amount = credit["amount"].double, let left = credit["remaining"].double, left > 0,
                  let expires = credit["expiresAt"].date else { return nil }
            return UsageRow("Credit", "\(Fmt.number(left)) of \(Fmt.number(amount)), expires \(PluginFmt.monthDay(expires))")
        }
        if credits.count > slots {
            rows += credits.prefix(slots - 1)
            rows.append(UsageRow("Additional credits", String(credits.count - (slots - 1))))
        } else {
            rows += credits
        }
        return ProviderUsage(cost: UsageCost(used: spent, balance: balance, period: cycle), sections: [UsageSection("Billing", rows)], plan: plan)
    }
}
