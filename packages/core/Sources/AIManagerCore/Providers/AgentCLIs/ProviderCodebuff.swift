import Foundation

extension ProviderCatalog {
    private static let codebuffFile = LiveFile(".config/manicode/credentials.json", key: "default")

    static let agentCodebuff = ProviderSpec(
        id: "codebuff", name: "Codebuff", style: .files,
        files: [codebuffFile],
        dashboard: "https://www.codebuff.com/usage",
        identify: { credential in
            let member = credential.json(codebuffFile.id)
            return (member?["id"].string ?? member?["email"].string).map {
                CredentialIdentity(key: $0, email: member?["email"].string)
            }
        },
        usage: { credential in
            let member = credential.json(codebuffFile.id)
            guard let token = member?["authToken"].string else {
                if member?["tokenStore"].string == "keychain" {
                    throw ProviderError.missingCredential(
                        "Codebuff keeps this token in the macOS Keychain, which Switch never reads. Sign in again with file storage.")
                }
                throw ProviderError.missingCredential("Sign in with codebuff login, then import the sign-in.")
            }
            let headers = HTTP.bearer(token)
            async let subscription = try? HTTP.json("https://www.codebuff.com/api/user/subscription", headers: headers)
            let usage = try await HTTP.json("https://www.codebuff.com/api/v1/usage", headers: headers,
                                            object: ["fingerprintId": "switch-usage"])
            return try CodebuffUsage.map(usage: usage, subscription: await subscription,
                                         email: member?["email"].string)
        })
}

enum CodebuffUsage {
    static func map(usage: JSON, subscription: JSON?, email: String? = nil) throws -> ProviderUsage {
        func first(_ json: JSON, _ keys: String...) -> Double? { keys.lazy.compactMap { json[$0].double }.first }
        var windows: [UsageWindow] = []
        let used = first(usage, "usage", "used")
        let quota = first(usage, "quota", "limit")
        let balance = first(usage, "remainingBalance", "remaining")
        if used != nil || quota != nil || balance != nil {
            let total = quota ?? ((used ?? 0) + (balance ?? 0))
            let spent = used ?? (total - (balance ?? 0))
            windows.append(UsageWindow(
                id: "credits", title: "Credits", usedPercent: total > 0 ? spent / total * 100 : 100,
                resetsAt: usage["next_quota_reset"].date,
                detail: total > 0 ? "\(Fmt.number(spent)) / \(Fmt.number(total)) credits" : nil))
        }
        var plan: String?
        if let subscription, subscription["hasSubscription"].bool != false {
            let sub = subscription["subscription"]
            plan = [sub["displayName"], subscription["displayName"], sub["tier"], subscription["tier"], sub["scheduledTier"]]
                .lazy.compactMap { $0.string }.first?.capitalized
            let weekly = subscription["rateLimit"]
            if let limit = weekly["weeklyLimit"].double ?? weekly["limit"].double, limit > 0 {
                windows.append(.amounts(id: "weekly", title: "Weekly",
                                        used: weekly["weeklyUsed"].double ?? weekly["used"].double ?? 0, limit: limit,
                                        resetsAt: weekly["weeklyResetsAt"].date, windowMinutes: 10080, unit: "credits")!)
            }
        }
        guard !windows.isEmpty else { throw ProviderError.parse("Codebuff returned no credit data.") }
        let topUp = (usage["autoTopupEnabled"].bool ?? usage["auto_topup_enabled"].bool).map {
            UsageRow("Auto top-up", $0 ? "On" : "Off")
        }
        return ProviderUsage(windows: windows, sections: [UsageSection(nil, topUp.map { [$0] } ?? [])], plan: plan,
                             email: email ?? subscription?["email"].string ?? subscription?.at("user.email").string)
    }
}
