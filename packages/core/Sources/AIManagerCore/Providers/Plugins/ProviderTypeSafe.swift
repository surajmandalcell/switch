import Foundation

extension ProviderCatalog {
    /// Reads the billing page through the same Next.js server action the web console calls.
    /// ponytail: the action id is scraped from the page's JS chunks, so a console redeploy can break it; swap in a billing API if TypeSafe publishes one.
    /// It is cached in the credential and rediscovered once on a 404.
    static let typesafe = ProviderSpec(
        id: "typesafe", name: "TypeSafe",
        fields: [.cookie("Cookie header from console.typesafe.ai/settings/billing"),
                 CredentialField("actionID", "Billing action id", optional: true, placeholder: "Found automatically")],
        dashboard: "https://console.typesafe.ai/usage",
        fetch: { credential in
            let cookie = try credential.require("cookie")
            let url = "https://console.typesafe.ai/settings/billing"
            func post(_ id: String) async throws -> HTTPResponse {
                try await HTTP.send(url, method: "POST", headers: [
                    "Cookie": cookie, "Origin": "https://console.typesafe.ai", "Next-Action": id, "Accept": "text/x-component",
                ], body: Data("[]".utf8))
            }
            func discover() async throws -> String {
                let page = try await HTTP.send(url, headers: ["Cookie": cookie, "Accept": "text/html"])
                try TypeSafeUsage.check(page)
                for chunk in TypeSafeUsage.chunkURLs(page.text) {
                    guard let script = try? await HTTP.send(chunk), script.status == 200,
                          let id = TypeSafeUsage.actionID(script.text) else { continue }
                    return id
                }
                throw ProviderError.parse("TypeSafe billing page format changed: action id not found.")
            }
            var updated = credential
            var id = credential["actionID"]
            if id == nil { id = try await discover() }
            var response = try await post(id!)
            if response.status == 404, response.headers["x-nextjs-action-not-found"] == "1" {
                id = try await discover()
                response = try await post(id!)
            }
            try TypeSafeUsage.check(response)
            updated.fields["actionID"] = id
            return FetchResult(try TypeSafeUsage.map(rsc: response.text), updated: updated)
        })
}

enum TypeSafeUsage {
    /// A redirect or the login page means the session expired.
    static func check(_ response: HTTPResponse) throws {
        try HTTP.check(response)
        if response.text.range(of: #"\\?"\(auth\)\\?",\{\\?"children\\?":\[\\?"login"#, options: .regularExpression) != nil {
            throw ProviderError.unauthorized("TypeSafe session expired. Paste a fresh Cookie header.")
        }
    }

    static func chunkURLs(_ html: String) -> [String] {
        let origin = "https://console.typesafe.ai"
        var urls: [String] = []
        for source in matches(#"<script\b[^>]*\bsrc=["']([^"']+)["']"#, html) {
            let full = source.hasPrefix("/") ? origin + source : source
            if full.hasPrefix(origin + "/"), full.range(of: #"\.js(?:$|\?)"#, options: .regularExpression) != nil, !urls.contains(full) {
                urls.append(full)
            }
        }
        return Array(urls.prefix(60))
    }

    static func actionID(_ script: String) -> String? {
        matches(#""([0-9a-f]{40,})"[^)]{0,150}"getBillingOverviewResult""#, script).first
    }

    /// The server action answers with React Server Component lines such as `1:{"ok":true,...}`.
    static func map(rsc: String) throws -> ProviderUsage {
        let result = rsc.split(whereSeparator: \.isNewline).lazy.compactMap { line -> JSON? in
            guard let colon = line.firstIndex(of: ":"),
                  let json = try? JSON(data: Data(line[line.index(after: colon)...].utf8)), json["ok"].exists else { return nil }
            return json
        }.first
        guard let result else { throw ProviderError.parse("TypeSafe billing response format changed: missing result.") }
        guard result["ok"].bool == true else { throw ProviderError.http(0, "TypeSafe billing request failed.") }
        let billing = result.at("data.billing")
        guard let spent = billing["spent"].double, let balance = billing["balance"].double else {
            throw ProviderError.parse("TypeSafe billing response format changed: missing billing numbers.")
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

    private static func matches(_ pattern: String, _ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
