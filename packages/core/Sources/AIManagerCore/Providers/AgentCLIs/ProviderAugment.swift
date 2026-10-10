import Foundation

extension ProviderCatalog {
    static let agentAugment = ProviderSpec(
        id: "augment", name: "Augment",
        fields: [.cookie("Cookie header from app.augmentcode.com (the session cookie)")],
        dashboard: "https://app.augmentcode.com/account/subscription", statusPage: "https://status.augmentcode.com",
        usage: { credential in
            let headers = ["Cookie": try credential.require("cookie")]
            let credits = try await HTTP.json("https://app.augmentcode.com/api/credits", headers: headers)
            let subscription = try? await HTTP.json("https://app.augmentcode.com/api/subscription", headers: headers)
            return try AugmentUsage.map(credits: credits, subscription: subscription)
        })
}

enum AugmentUsage {
    static func map(credits: JSON, subscription: JSON?) throws -> ProviderUsage {
        let remaining = credits["usageUnitsRemaining"].double
        let consumed = credits["usageUnitsConsumedThisBillingCycle"].double
        let available = credits["usageUnitsAvailable"].double
        guard remaining != nil || consumed != nil || available != nil else {
            throw ProviderError.parse("Augment returned no credit data.")
        }
        let used = consumed ?? 0
        let limit = (available ?? 0) > 0 ? available! : (remaining ?? 0) + used
        let window = UsageWindow.amounts(id: "credits", title: "Credits", used: used, limit: limit,
                                         resetsAt: subscription?["billingPeriodEnd"].date, unit: "credits")
            ?? UsageWindow(id: "credits", title: "Credits", usedPercent: 0, resetsAt: subscription?["billingPeriodEnd"].date)
        return ProviderUsage(windows: [window], plan: subscription?["planName"].string,
                             email: subscription?["email"].string, organization: subscription?["organization"].string)
    }
}
