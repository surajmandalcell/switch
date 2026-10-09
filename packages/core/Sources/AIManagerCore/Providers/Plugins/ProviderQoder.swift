import Foundation

extension ProviderCatalog {
    static let qoder = ProviderSpec(
        id: "qoder", name: "Qoder",
        fields: [
            .cookie("Cookie header from qoder.com"),
            CredentialField("region", "Region", secure: false, optional: true, placeholder: "global or cn"),
        ],
        dashboard: "https://qoder.com/account/usage",
        usage: { credential in
            let cookie = try credential.require("cookie")
            let origin = credential["region"]?.lowercased() == "cn" ? "https://qoder.com.cn" : "https://qoder.com"
            let json = try await HTTP.json(
                "\(origin)/api/v2/me/usages/big_model_credits",
                headers: ["Cookie": cookie, "Origin": origin, "Referer": "\(origin)/account/usage",
                          "X-Requested-With": "XMLHttpRequest", "Bx-V": "2.5.35"])
            return try QoderUsage.map(json)
        })
}

enum QoderUsage {
    private static func field(_ object: JSON, _ camel: String, _ snake: String) -> JSON {
        object[camel].exists ? object[camel] : object[snake]
    }

    private static func quota(_ summary: JSON) throws -> (used: Double, total: Double, remaining: Double, percent: Double?) {
        guard let used = field(summary, "usedValue", "used_value").double,
              let total = field(summary, "limitValue", "limit_value").double else {
            throw ProviderError.parse("Could not parse Qoder usage: invalid quota number.")
        }
        let remaining = field(summary, "remainingValue", "remaining_value").double ?? max(0, total - used)
        guard used >= 0, total >= 0, remaining >= 0 else {
            throw ProviderError.parse("Could not parse Qoder usage: quota values must be nonnegative.")
        }
        return (used, total, remaining, field(summary, "usagePercentage", "usage_percentage").double)
    }

    static func map(_ root: JSON) throws -> ProviderUsage {
        let base = try quota(field(field(root, "totalQuota", "total_quota"), "quotaSummary", "quota_summary"))
        let sharedSummary = field(field(root, "sharedQuota", "shared_quota"), "quotaSummary", "quota_summary")
        let shared = sharedSummary.exists ? try quota(sharedSummary) : nil
        let used = base.used + (shared?.used ?? 0), total = base.total + (shared?.total ?? 0)
        let percent = shared == nil ? base.percent : nil
        let resetsAt = field(root, "nextResetAt", "next_reset_at").date
        let detail = "\(Fmt.number(used)) / \(Fmt.number(total)) credits"
        let window = UsageWindow(id: "credits", title: "Credits",
                                 usedPercent: percent ?? (total > 0 ? used / total * 100 : 100),
                                 resetsAt: resetsAt, detail: detail)
        return ProviderUsage(windows: [window])
    }
}
