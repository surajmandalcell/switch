import Foundation

extension ProviderCatalog {
    static let devpass = ProviderSpec(
        id: "devpass", name: "DevPass",
        fields: [.init("apiKey", "DevPass API key", env: ["DEVPASS_API_KEY"])],
        dashboard: "https://devpass.llmgateway.io/dashboard",
        usage: { credential in
            let json = try await HTTP.json("https://api.llmgateway.io/v1/key", headers: HTTP.bearer(try credential.require("apiKey")))
            return try DevpassUsage.map(json)
        })
}

enum DevpassUsage {
    static func map(_ json: JSON) throws -> ProviderUsage {
        let data = json["data"]
        guard let plan = data["devPlan"].string, ["none", "lite", "pro", "max"].contains(plan),
              let keyUsed = data["usage"].double else {
            throw ProviderError.parse("DevPass returned an unrecognized usage response.")
        }
        var keyRows = [UsageRow("All-time key usage", Fmt.money(keyUsed))]
        if let limit = data["limit"].double { keyRows.append(.init("Key spending limit", Fmt.money(limit))) }
        let keySection = UsageSection("API key (all time)", keyRows)
        if plan == "none" { return ProviderUsage(sections: [keySection], plan: "Pay as you go") }
        guard let used = data["devPlanCreditsUsed"].double, let limit = data["devPlanCreditsLimit"].double,
              let remaining = data["devPlanCreditsRemaining"].double,
              let weeklyUsed = data["devPlanPremiumCreditsUsed"].double,
              let weeklyLimit = data["devPlanPremiumWeeklyLimit"].double else {
            throw ProviderError.parse("DevPass returned an unrecognized usage response.")
        }
        var windows: [UsageWindow] = []
        if limit > 0 {
            windows.append(.amounts(id: "credits", title: "Plan credits", used: used, limit: limit)!)
        }
        if weeklyLimit > 0 {
            windows.append(.amounts(id: "weekly", title: "Premium weekly", used: weeklyUsed, limit: weeklyLimit,
                                    resetsAt: data["devPlanPremiumWeekResetsAt"].date, windowMinutes: 10_080)!)
        }
        let credits = UsageSection("DevPass credits", [
            .init("Cycle used", "\(Fmt.money(used)) / \(Fmt.money(limit))"),
            .init("Cycle remaining", Fmt.money(remaining)),
            .init("Premium weekly", "\(Fmt.money(weeklyUsed)) / \(Fmt.money(weeklyLimit))"),
        ])
        return ProviderUsage(windows: windows, sections: [credits, keySection], plan: "DevPass \(plan.capitalized)")
    }
}
