import Foundation

extension ProviderCatalog {
    static let zenmux = ProviderSpec(
        id: "zenmux", name: "ZenMux",
        fields: [CredentialField("apiKey", "Management API key", env: ["ZENMUX_MANAGEMENT_API_KEY"])],
        dashboard: "https://zenmux.ai/platform/management",
        usage: { credential in
            let headers = HTTP.bearer(try credential.require("apiKey"))
            let base = "https://zenmux.ai/api/v1/management/"
            let subscription = try await HTTP.json(base + "subscription/detail", headers: headers)
            // The pay-as-you-go balance is optional; only a rejected key stops the fetch.
            let payg: JSON?
            do {
                payg = try await HTTP.json(base + "payg/balance", headers: headers)
            } catch let error as ProviderError where error.needsSignIn {
                throw error
            } catch {
                payg = nil
            }
            return try ZenMuxUsage.map(subscription, payg: payg)
        })
}

enum ZenMuxUsage {
    static func map(_ subscription: JSON, payg: JSON? = nil) throws -> ProviderUsage {
        let data = subscription["data"]
        guard subscription["success"].bool == true, let tier = data.at("plan.tier").string,
              let status = data["account_status"].string else {
            throw ProviderError.parse("Could not parse ZenMux usage: invalid Management API response.")
        }
        func window(_ id: String, _ title: String, _ quota: JSON, minutes: Int) throws -> UsageWindow {
            guard let fraction = quota["usage_percentage"].double, let max = quota["max_flows"].double,
                  let used = quota["used_flows"].double else {
                throw ProviderError.parse("Could not parse ZenMux usage: invalid \(title) quota.")
            }
            return UsageWindow(id: id, title: title, usedPercent: fraction * 100, resetsAt: quota["resets_at"].date,
                               windowMinutes: minutes, detail: "\(Fmt.number(used, digits: 2)) / \(Fmt.number(max)) flows")
        }
        var sections: [UsageSection] = []
        if status.lowercased() != "healthy" { sections.append(UsageSection(nil, [UsageRow("Account status", status.capitalized)])) }
        var cost: UsageCost?
        if let payg, payg["success"].bool == true,
           payg.at("data.currency").string?.lowercased() == "usd", let credits = payg.at("data.total_credits").double {
            cost = UsageCost(balance: credits, period: "ZenMux PAYG balance")
        }
        return ProviderUsage(
            windows: [try window("session", "5-hour quota", data["quota_5_hour"], minutes: 300),
                      try window("weekly", "Weekly quota", data["quota_7_day"], minutes: 10080)],
            cost: cost,
            sections: sections + [PluginFmt.renewal(nil, expires: data.at("plan.expires_at").date)],
            plan: "\(tier.capitalized) plan" + (status.isEmpty || status.lowercased() == "healthy" ? "" : " · \(status.capitalized)"))
    }
}
