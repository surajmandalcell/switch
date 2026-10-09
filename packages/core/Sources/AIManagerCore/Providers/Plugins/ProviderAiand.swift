import Foundation

extension ProviderCatalog {
    static let aiand = ProviderSpec(
        id: "aiand", name: "ai&",
        fields: [.apiKey("AIAND_API_KEY")],
        dashboard: "https://console.aiand.com",
        usage: { credential in
            let headers = HTTP.bearer(try credential.require("apiKey"))
            var pages: [JSON] = []
            var cursor = ""
            for _ in 0..<10 {
                let json = try await HTTP.json("https://api.aiand.com/logs?range=30days&limit=100\(cursor)", headers: headers)
                pages.append(json)
                guard json["has_more"].bool == true, let after = json["next_after"].string,
                      let afterID = json["next_after_id"].string else { break }
                let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))
                cursor = "&after=\(after.addingPercentEncoding(withAllowedCharacters: allowed) ?? after)"
                    + "&after_id=\(afterID.addingPercentEncoding(withAllowedCharacters: allowed) ?? afterID)"
            }
            return try AiandUsage.map(pages)
        })
}

enum AiandUsage {
    /// `pages` are the `/logs` responses in order. The last page must have `has_more` false for an exact total.
    static func map(_ pages: [JSON]) throws -> ProviderUsage {
        var total = Decimal(0)
        var currency: String?
        for page in pages {
            guard page["data"].raw is [Any] else { throw ProviderError.parse("Could not parse ai& usage: invalid logs payload.") }
            for row in page["data"].array {
                guard let raw = row["cost"].string, let cost = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")),
                      let code = row["currency"].string?.trimmingCharacters(in: .whitespaces).uppercased() else { continue }
                if currency == nil { currency = code }
                if code == currency { total += cost }
            }
        }
        guard let currency else { return ProviderUsage() }
        let complete = pages.last?["has_more"].bool != true
        return ProviderUsage(cost: UsageCost(used: NSDecimalNumber(decimal: total).doubleValue, currency: currency,
                                             period: complete ? "Last 30 days" : "Last 30 days (partial)"))
    }
}
