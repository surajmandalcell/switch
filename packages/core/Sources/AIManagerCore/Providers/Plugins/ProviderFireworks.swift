import Foundation

extension ProviderCatalog {
    static let fireworks = ProviderSpec(
        id: "fireworks", name: "Fireworks",
        fields: [.apiKey("FIREWORKS_API_KEY"),
                 .init("accountSlug", "Account slug", secure: false, optional: true,
                       placeholder: "Blank to auto-discover", env: ["FIREWORKS_ACCOUNT_SLUG"])],
        dashboard: "https://app.fireworks.ai",
        fetch: { credential in
            let headers = HTTP.bearer(try credential.require("apiKey"))
            let configured = credential["accountSlug"]
            var slug = configured
            if slug == nil { slug = try FireworksUsage.choose(try await accounts(headers)) }
            guard let chosen = slug, FireworksUsage.validSlug(chosen) else {
                throw ProviderError.unsupported("Invalid Fireworks account slug. Check the account slug.")
            }
            let end = Date()
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            let range = "startTime=\(iso.string(from: end.addingTimeInterval(-30 * 86_400)).replacingOccurrences(of: ":", with: "%3A"))"
                + "&endTime=\(iso.string(from: end).replacingOccurrences(of: ":", with: "%3A"))"
            let json = try await HTTP.json("https://api.fireworks.ai/v1/accounts/\(chosen)/billing/summary?\(range)", headers: headers)
            var updated: ProviderCredential?
            if configured == nil {
                var next = credential
                next.fields["accountSlug"] = chosen
                updated = next
            }
            return FetchResult(try FireworksUsage.map(json), updated: updated)
        })
}

private func accounts(_ headers: [String: String]) async throws -> [String] {
    var slugs = Set<String>()
    var token = ""
    for _ in 0..<100 {
        let suffix = token.isEmpty ? "" : "?pageToken=\(token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token)"
        let json = try await HTTP.json("https://api.fireworks.ai/v1/accounts\(suffix)", headers: headers)
        slugs.formUnion(FireworksUsage.slugs(json))
        token = json["nextPageToken"].string ?? ""
        if token.isEmpty { break }
    }
    return slugs.sorted()
}

enum FireworksUsage {
    static func validSlug(_ slug: String) -> Bool {
        slug != "." && slug != ".." && slug.count <= 256 && slug.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    /// Account slugs from one `/v1/accounts` page.
    static func slugs(_ page: JSON) -> [String] {
        page["accounts"].array.compactMap { account in
            let name = ["accountId", "id", "name"].compactMap { account[$0].string }.first
            return name?.split(separator: "/").last.map(String.init).flatMap { validSlug($0) ? $0 : nil }
        }
    }

    static func choose(_ slugs: [String]) throws -> String {
        guard let first = slugs.first else {
            throw ProviderError.unsupported("No Fireworks accounts are visible to this API key. Check the key in app.fireworks.ai.")
        }
        guard slugs.count == 1 else {
            throw ProviderError.unsupported("This Fireworks API key can access multiple accounts: \(slugs.joined(separator: ", ")). Set the account slug.")
        }
        return first
    }

    static func map(_ json: JSON) throws -> ProviderUsage {
        guard json["lineItems"].raw == nil || json["lineItems"].raw is [Any] else {
            throw ProviderError.parse("Could not parse Fireworks usage: invalid billing summary")
        }
        var currency: String?
        var total = 0.0
        for item in json["lineItems"].array {
            let cost = item["totalCost"]
            guard let units = cost["units"].double, let nanos = cost["nanos"].double,
                  let code = cost["currencyCode"].string?.trimmingCharacters(in: .whitespaces) else { continue }
            if currency == nil { currency = code }
            if code == currency { total += units + nanos / 1e9 }
        }
        guard let currency else { return ProviderUsage() }
        return ProviderUsage(cost: UsageCost(used: total, currency: currency, period: "Last 30 days"))
    }
}
