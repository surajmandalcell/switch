import Foundation

extension ProviderCatalog {
    static let deepinfra = ProviderSpec(
        id: "deepinfra", name: "DeepInfra",
        fields: [.apiKey("DEEPINFRA_API_KEY")],
        dashboard: "https://deepinfra.com/dash",
        usage: { credential in
            let headers = HTTP.bearer(try credential.require("apiKey"))
            let checklist = try await HTTP.json("https://api.deepinfra.com/payment/checklist?compute_owed=true", headers: headers)
            let usage = try await HTTP.json("https://api.deepinfra.com/payment/usage?from=current", headers: headers)
            return try DeepinfraUsage.map(checklist: checklist, usage: usage)
        })
}

enum DeepinfraUsage {
    static func map(checklist: JSON, usage: JSON) throws -> ProviderUsage {
        guard let recentRaw = checklist["recent"].double, let stripe = checklist["stripe_balance"].double,
              usage["months"].raw is [Any] else {
            throw ProviderError.parse("Failed to parse DeepInfra response: invalid billing data.")
        }
        let recent = max(0, recentRaw)
        let balance = stripe + recent
        // Checklist amounts are USD; the usage endpoint's total_cost is cents.
        let monthCost = usage["months"].array.last.flatMap { $0["total_cost"].double }.map { max(0, $0 / 100) } ?? recent
        let suspended = checklist["suspended"].bool == true
        var rows = [UsageRow(balance > 0 ? "Owed" : "Available", Fmt.money(abs(balance))),
                    UsageRow("Spent this month", Fmt.money(monthCost))]
        if suspended {
            rows.insert(.init("Status", "Suspended" + (checklist["suspend_reason"].string.map { ": \($0)" } ?? "")), at: 0)
        }
        let limit = checklist["limit"].double
        // The plugin's only window: full when suspended or money is owed, empty when the balance is credit.
        let reason = checklist["suspend_reason"].string?.trimmingCharacters(in: .whitespaces) ?? ""
        let status = suspended ? (reason.isEmpty ? "Suspended · " : "Suspended: \(reason) · ") : ""
        let balanceText = balance > 0 ? "\(Fmt.money(balance)) owed" : "\(Fmt.money(max(0, -balance))) available"
        let window = UsageWindow(id: "balance", title: "Balance", usedPercent: suspended || balance >= 0 ? 100 : 0,
                                 detail: "\(status)\(balanceText) · \(Fmt.money(monthCost)) spent this month")
        return ProviderUsage(
            windows: [window],
            cost: UsageCost(used: recent, limit: (limit ?? 0) > 0 ? limit : nil, balance: balance <= 0 ? -balance : nil,
                            period: "Billing cycle"),
            sections: [.init("Balance", rows)])
    }
}
