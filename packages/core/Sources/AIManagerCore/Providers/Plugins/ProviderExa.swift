import Foundation

extension ProviderCatalog {
    static let exa = ProviderSpec(
        id: "exa", name: "Exa",
        fields: [.init("apiKey", "Exa service key", env: ["EXA_SERVICE_KEY"]),
                 .init("apiKeyID", "API key ID", secure: false, env: ["EXA_API_KEY_ID"])],
        dashboard: "https://dashboard.exa.ai/api-keys",
        usage: { credential in
            let key = try credential.require("apiKey")
            let id = try credential.require("apiKeyID", "Add the Exa API key ID; it is not the service key.")
            guard id != ".", id != ".." else { throw ProviderError.missingCredential("The Exa API key ID is invalid.") }
            let end = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            let start = utc.date(from: utc.dateComponents([.year, .month], from: end))!
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))
            func encode(_ date: Date) -> String { formatter.string(from: date).addingPercentEncoding(withAllowedCharacters: allowed)! }
            let path = id.addingPercentEncoding(withAllowedCharacters: allowed)!
            let url = "https://admin-api.exa.ai/team-management/api-keys/\(path)/usage?start_date=\(encode(start))&end_date=\(encode(end))"
            return try ExaUsage.map(try await HTTP.json(url, headers: ["x-api-key": key]))
        })
}

enum ExaUsage {
    static func map(_ json: JSON) throws -> ProviderUsage {
        guard let spend = json["total_cost_usd"].double, spend >= 0, json.at("period.start").exists else {
            throw ProviderError.parse("Exa returned an unrecognized API key usage response.")
        }
        return ProviderUsage(cost: UsageCost(used: spend, period: "This month (UTC)"),
                             sections: [.init("API key this month (UTC)", [.init("Spend", Fmt.money(spend))])],
                             plan: "Service key")
    }
}
