import Foundation

extension ProviderCatalog {
    private static let kiloAuth = LiveFile(".local/share/kilo/auth.json", key: "kilo")

    static let agentKilo = ProviderSpec(
        id: "kilo", name: "Kilo", style: .files,
        files: [kiloAuth],
        dashboard: "https://app.kilo.ai/usage",
        identify: { KiloUsage.identity($0.json(kiloAuth.id)) },
        usage: { credential in
            guard let token = KiloUsage.token(credential.json(kiloAuth.id)) else {
                throw ProviderError.missingCredential("Sign in with kilo auth login, then import the sign-in.")
            }
            let input = #"%7B%220%22%3A%7B%22json%22%3Anull%7D%2C%221%22%3A%7B%22json%22%3Anull%7D%2C%222%22%3A%7B%22json%22%3Anull%7D%7D"#
            let json = try await HTTP.json(
                "https://app.kilo.ai/api/trpc/user.getCreditBlocks,kiloPass.getState,user.getAutoTopUpPaymentMethod?batch=1&input=\(input)",
                headers: HTTP.bearer(token))
            return try KiloUsage.map(json)
        })
}

enum KiloUsage {
    static func token(_ member: JSON?) -> String? { member?["access"].string ?? member?["key"].string }

    static func identity(_ member: JSON?) -> CredentialIdentity? {
        guard let token = token(member) else { return nil }
        return CredentialIdentity(key: member?["accountId"].string ?? AgentCLIsKit.fingerprint(token))
    }

    private static let tiers = ["tier_19": "Starter", "tier_49": "Pro", "tier_199": "Expert"]

    /// tRPC batch reply: [creditBlocks, kiloPass, autoTopUp].
    static func map(_ batch: JSON) throws -> ProviderUsage {
        func data(_ index: Int) throws -> JSON {
            let entry = batch[index]
            if let error = entry.at("error.json.message").string ?? entry.at("error.message").string {
                if error.localizedCaseInsensitiveContains("unauthorized") || error.localizedCaseInsensitiveContains("forbidden") {
                    throw ProviderError.unauthorized("Kilo rejected this sign-in. Run kilo auth login.")
                }
                throw ProviderError.parse("Kilo reported an error.")
            }
            let result = entry.at("result.data")
            return result["json"].exists ? result["json"] : result
        }
        var windows: [UsageWindow] = []
        let blocks = try data(0)
        let blockList = blocks["creditBlocks"].array
        let balance = blocks["totalBalance_mUsd"].double ?? 0
        var total = blockList.reduce(0) { $0 + ($1["amount_mUsd"].double ?? 0) } / 1e6
        var remaining = blockList.reduce(0) { $0 + ($1["balance_mUsd"].double ?? 0) } / 1e6
        if blockList.isEmpty { (total, remaining) = (balance / 1e6, balance / 1e6) }
        // Older replies carry plain used / total / remaining fields instead of micro-dollar blocks.
        func plain(_ keys: [String]) -> Double? { keys.lazy.compactMap { blocks[$0].double }.first }
        if blockList.isEmpty, blocks["totalBalance_mUsd"].double == nil {
            let spent = plain(["used", "usedCredits", "creditsUsed", "consumed", "spent"])
            let cap = plain(["total", "totalCredits", "creditsTotal", "limit"])
            let left = plain(["remaining", "remainingCredits", "creditsRemaining"])
            if let cap = cap ?? ((spent != nil && left != nil) ? spent! + left! : nil) {
                (total, remaining) = (cap, left ?? max(0, cap - (spent ?? 0)))
            }
        }
        let used = max(0, total - remaining)
        windows.append(UsageWindow(id: "credits", title: "Credits", usedPercent: total > 0 ? used / total * 100 : 100,
                                   detail: "\(Fmt.number(used, digits: 2)) / \(Fmt.number(total, digits: 2)) credits"))
        var plan: String?
        // The pass may sit under "subscription" or be the reply itself.
        let passReply = try? data(1)
        let passShape = ["currentPeriodUsageUsd", "currentPeriodBaseCreditsUsd", "currentPeriodBonusCreditsUsd", "tier"]
            .contains { passReply?[$0].exists == true }
        if let pass = passReply.map({ $0["subscription"].exists ? $0["subscription"] : (passShape ? $0 : JSON(nil)) }), pass.exists {
            let base = pass["currentPeriodBaseCreditsUsd"].double ?? 0
            let bonus = pass["currentPeriodBonusCreditsUsd"].double ?? 0
            let spent = pass["currentPeriodUsageUsd"].double ?? 0
            let passTotal = base + bonus
            windows.append(UsageWindow(
                id: "pass", title: "Kilo Pass", usedPercent: passTotal > 0 ? spent / passTotal * 100 : 100,
                resetsAt: ["nextBillingAt", "nextRenewalAt", "renewsAt", "renewAt"].lazy.compactMap { pass[$0].date }.first,
                detail: "\(Fmt.money(spent)) / \(Fmt.money(base))" + (bonus > 0 ? " (+ \(Fmt.money(bonus)) bonus)" : "")))
            plan = pass["tier"].string.map { tiers[$0] ?? $0 } ?? "Kilo Pass"
        }
        var rows: [UsageRow] = []
        if let topUp = try? data(2) {
            let status = ["status"].lazy.compactMap { topUp[$0].string?.lowercased() }.first
            let enabled = ["enabled", "isEnabled", "active"].lazy.compactMap { topUp[$0].bool }.first
                ?? status.flatMap { ["enabled", "active", "on"].contains($0) ? true : (["disabled", "inactive", "off", "none"].contains($0) ? false : nil) }
                ?? blocks["autoTopUpEnabled"].bool
            if let enabled {
                let method = ["paymentMethod", "paymentMethodType", "method", "cardBrand"].lazy.compactMap { topUp[$0].string }.first
                let amount = topUp["amountCents"].double.map { Fmt.money($0 / 100) }
                rows.append(UsageRow("Auto top-up", enabled ? (method ?? amount ?? "On") : "Off"))
            }
        }
        // Credits are US dollars (micro-dollar blocks), so the remaining credit is a balance.
        return ProviderUsage(windows: windows, cost: UsageCost(balance: remaining), sections: [UsageSection(nil, rows)], plan: plan)
    }
}
