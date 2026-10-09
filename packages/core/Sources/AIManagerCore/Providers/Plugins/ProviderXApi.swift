import Foundation

extension ProviderCatalog {
    static let xapi = ProviderSpec(
        id: "xapi", name: "X API",
        fields: [.cookie("Cookie header from console.x.com with auth_token and ct0")],
        dashboard: "https://console.x.com",
        usage: { credential in
            let cookie = try credential.require("cookie")
            guard let csrf = Fmt.cookie("ct0", in: cookie), Fmt.cookie("auth_token", in: cookie) != nil else {
                throw ProviderError.missingCredential("The Cookie header needs both auth_token and ct0.")
            }
            let headers = ["Cookie": cookie, "X-CSRF-Token": csrf, "Origin": "https://console.x.com"]
            let me = try await HTTP.json("https://console.x.com/api/me", headers: headers)
            let account = try XApiUsage.accountID(me)
            return try XApiUsage.map(try await HTTP.json("https://console.x.com/api/accounts/\(account)/credits", headers: headers))
        })
}

enum XApiUsage {
    static func accountID(_ me: JSON) throws -> String {
        guard let id = me.at("account.id").string,
              id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
            throw ProviderError.parse("X API returned an unrecognized account.")
        }
        return id
    }

    /// The console shows these amounts directly in dollars.
    static func map(_ credits: JSON) throws -> ProviderUsage {
        guard let paid = credits.at("credits.balance").double else {
            throw ProviderError.parse("X API returned an unrecognized dollar balance.")
        }
        let free = credits.at("freeCredits.balance").double ?? 0
        return ProviderUsage(
            cost: UsageCost(balance: paid + free, period: "Prepaid credits"),
            sections: [UsageSection("Credits", [
                UsageRow("Purchased credits", Fmt.money(paid)),
                UsageRow("Free credits", Fmt.money(free)),
            ])])
    }
}
