import Foundation

extension ProviderCatalog {
    /// Reads the zed.dev web billing page. The editor sign-in lives in the Keychain, which Switch never reads,
    /// so this needs a Cookie header from a signed-in zed.dev browser session.
    static let zed = ProviderSpec(
        id: "zed", name: "Zed",
        fields: [.cookie("Cookie header from zed.dev (zed.session)")],
        dashboard: "https://zed.dev/account",
        usage: { credential in
            let cookie = try credential.require("cookie")
            return try ZedUsage.map(try await HTTP.json("https://cloud.zed.dev/frontend/billing/usage", headers: ["Cookie": cookie]))
        })
}

enum ZedUsage {
    static func map(_ json: JSON) throws -> ProviderUsage {
        guard let plan = json["plan"].string, json["current_usage"].raw is [String: Any] else {
            throw ProviderError.parse("Could not parse Zed usage response. Its format may have changed.")
        }
        let predictions = json.at("current_usage.edit_predictions")
        guard let used = predictions["used"].double else {
            throw ProviderError.parse("Could not parse Zed usage response. Its format may have changed.")
        }
        // The limit is a number, {"limited": n}, "unlimited", or null.
        let limit = predictions["limit"].double ?? predictions.at("limit.limited").double
        var windows: [UsageWindow] = []
        var rows: [UsageRow] = []
        if let limit, limit > 0 {
            windows.append(UsageWindow(id: "predictions", title: "Edit predictions", usedPercent: used / limit * 100,
                                       detail: "\(Fmt.number(min(used, limit))) / \(Fmt.number(limit)) predictions"))
        } else if limit == nil {
            rows.append(UsageRow("Edit predictions", "Unlimited"))
        }
        var cost: UsageCost?
        let spend = json.at("current_usage.token_spend")
        if let cents = spend["spend_in_cents"].double {
            let cap = spend["limit_in_cents"].double.map { $0 / 100 }
            cost = UsageCost(used: cents / 100, limit: cap, period: "Current billing period")
            rows.append(UsageRow("Token spend", Fmt.money(cents / 100)))
            rows.append(UsageRow("Spend limit", cap.map { Fmt.money($0) } ?? "Not reported"))
            if let cap { rows.append(UsageRow("Remaining budget", Fmt.money(max(0, cap - cents / 100)))) }
        }
        let name = plan.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
        return ProviderUsage(windows: windows, cost: cost, sections: [UsageSection("Zed", rows)], plan: name)
    }
}
