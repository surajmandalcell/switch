import Foundation

extension ProviderCatalog {
    static let tinyapi = ProviderSpec(
        id: "tinyapi", name: "TinyApi",
        fields: [.cookie("Cookie header from tinyapi.rest")],
        dashboard: "https://tinyapi.rest/dashboard",
        usage: { credential in
            let cookie = try credential.require("cookie")
            return try TinyApiUsage.map(try await HTTP.json("https://tinyapi.rest/api/user/credits", headers: ["Cookie": cookie]))
        })
}

enum TinyApiUsage {
    static func map(_ json: JSON) throws -> ProviderUsage {
        guard json["success"].bool == true, let balance = json.at("data.totalAvailable").double, balance >= 0 else {
            throw ProviderError.parse("TinyApi credits response is missing a valid available balance.")
        }
        // The balance is in TinyApi credits, not money, so it stays a row instead of a UsageCost.
        return ProviderUsage(sections: [UsageSection("Credits", [UsageRow("Available credits", "\(Fmt.number(balance, digits: 2)) credits")])])
    }
}
