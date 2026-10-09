import Foundation

extension ProviderCatalog {
    static let abacus = ProviderSpec(
        id: "abacus", name: "Abacus AI",
        fields: [.cookie("Cookie header from apps.abacus.ai")],
        dashboard: "https://apps.abacus.ai/chatllm/admin/compute-points-usage",
        usage: { credential in
            let headers = ["Cookie": try credential.require("cookie")]
            let points = try await HTTP.json("https://apps.abacus.ai/api/_getOrganizationComputePoints", headers: headers)
            // Billing is optional: a failure keeps the credits without a reset date or plan.
            let billing = try? await HTTP.json("https://apps.abacus.ai/api/_getBillingInfo", method: "POST",
                                               headers: headers, object: [String: String]())
            return try AbacusUsage.map(points, billing: billing)
        })
}

enum AbacusUsage {
    static func map(_ points: JSON, billing: JSON? = nil) throws -> ProviderUsage {
        let result = try unwrap(points)
        guard let total = result["totalComputePoints"].double, let left = result["computePointsLeft"].double else {
            throw ProviderError.parse("Could not parse Abacus AI usage: missing credit fields.")
        }
        let info = (try? billing.map(unwrap)) ?? nil
        let resetsAt = info?["nextBillingDate"].date
        var minutes = 30 * 24 * 60
        if let resetsAt, let start = Calendar.current.date(byAdding: .month, value: -1, to: resetsAt) {
            minutes = max(1, Int(resetsAt.timeIntervalSince(start) / 60))
        }
        let used = total - left
        let window = UsageWindow(id: "credits", title: "Credits", usedPercent: total > 0 ? used / total * 100 : 0,
                                 resetsAt: resetsAt, windowMinutes: minutes,
                                 detail: "\(credits(used)) / \(credits(total)) credits")
        return ProviderUsage(windows: [window], plan: info?["currentTier"].string)
    }

    private static func unwrap(_ root: JSON) throws -> JSON {
        guard root["success"].bool == true, root["result"].object.isEmpty == false else {
            let message = root["error"].string?.lowercased() ?? ""
            if message.range(of: "expired|session|login|authenticate|unauthorized|unauthenticated|forbidden",
                             options: .regularExpression) != nil {
                throw ProviderError.unauthorized("Abacus AI session expired. Paste a fresh Cookie header.")
            }
            throw ProviderError.parse("Could not parse Abacus AI usage.")
        }
        return root["result"]
    }

    private static func credits(_ value: Double) -> String {
        Fmt.number(value >= 1000 ? value.rounded() : (value * 10).rounded() / 10, digits: 1)
    }
}
