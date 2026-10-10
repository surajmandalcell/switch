import Foundation

extension ProviderCatalog {
    private static let cursorRows = LiveFile(
        sqlite: "Library/Application Support/Cursor/User/globalStorage/state.vscdb", table: "ItemTable",
        keys: CursorUsage.keys)

    static let cursor = ProviderSpec(
        id: "cursor", name: "Cursor", style: .files, files: [cursorRows],
        dashboard: "https://cursor.com/dashboard", statusPage: "https://status.cursor.com",
        identify: { credential in CursorUsage.identity(credential.json(cursorRows.id)) },
        fetch: { credential in
            guard var rows = credential.json(cursorRows.id)?.object.compactMapValues({ $0.string }),
                  rows[CursorUsage.accessKey] != nil || rows[CursorUsage.refreshKey] != nil else {
                throw ProviderError.missingCredential("Sign in to Cursor first.")
            }
            var changed = false
            let (usage, plan, credits) = try await IDEAuth.authorized(
                access: rows[CursorUsage.accessKey],
                expiry: rows[CursorUsage.accessKey].flatMap(Fmt.jwtClaims)?["exp"].double.flatMap(Fmt.epoch),
                live: credential.isLive, hint: "Open Cursor to refresh this sign-in.",
                refresh: {
                    guard let refresh = rows[CursorUsage.refreshKey] else {
                        throw ProviderError.unauthorized("Sign in to Cursor again.")
                    }
                    let response = try await HTTP.send(
                        "https://api2.cursor.sh/oauth/token", method: "POST",
                        body: try JSONSerialization.data(withJSONObject: [
                            "grant_type": "refresh_token", "client_id": CursorUsage.clientID, "refresh_token": refresh]))
                    if (400...401).contains(response.status) { throw ProviderError.unauthorized("Sign in to Cursor again.") }
                    try HTTP.check(response)
                    let json = try response.json()
                    guard let access = json["access_token"].string else {
                        throw ProviderError.parse("Cursor returned no access token.")
                    }
                    rows[CursorUsage.accessKey] = access
                    if let rotated = json["refresh_token"].string { rows[CursorUsage.refreshKey] = rotated }
                    changed = true
                    return access
                },
                call: { token in
                    async let plan = CursorUsage.rpc("GetPlanInfo", token: token)
                    async let credits = CursorUsage.rpc("GetCreditGrantsBalance", token: token)
                    let usage = try await CursorUsage.rpc("GetCurrentPeriodUsage", token: token)
                    return (usage, try? await plan, try? await credits)
                })
            let mapped = try CursorUsage.map(usage: usage, plan: plan, credits: credits,
                                             membership: rows["cursorAuth/stripeMembershipType"],
                                             email: rows["cursorAuth/cachedEmail"])
            guard changed else { return FetchResult(mapped) }
            var updated = credential
            updated.isLive = false
            updated.files[cursorRows.id] = try JSONSerialization.data(withJSONObject: rows)
            return FetchResult(mapped, updated: updated)
        })
}

enum CursorUsage {
    static let accessKey = "cursorAuth/accessToken"
    static let refreshKey = "cursorAuth/refreshToken"
    static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
    static let keys = [accessKey, refreshKey, "cursorAuth/cachedEmail", "cursorAuth/stripeMembershipType",
                       "cursorAuth/cachedSignUpType"]

    static func rpc(_ method: String, token: String) async throws -> JSON {
        try await HTTP.json("https://api2.cursor.sh/aiserver.v1.DashboardService/\(method)", method: "POST",
                            headers: HTTP.bearer(token).merging(["Connect-Protocol-Version": "1"]) { $1 },
                            body: Data("{}".utf8))
    }

    /// Account key is the user id in the token subject (`auth0|user_x`), else the cached email.
    static func identity(_ rows: JSON?) -> CredentialIdentity? {
        guard let rows else { return nil }
        let email = rows["cursorAuth/cachedEmail"].string
        let subject = rows[accessKey].string.flatMap(Fmt.jwtClaims)?["sub"].string
        guard let key = subject.map({ String($0.split(separator: "|").last ?? "") }).flatMap({ $0.isEmpty ? nil : $0 })
                ?? email?.lowercased() else { return nil }
        return CredentialIdentity(key: key, email: email, plan: plan(rows["cursorAuth/stripeMembershipType"].string))
    }

    /// Pure mapper for the dashboard RPCs (amounts are cents). Merges OpenUsage's credits, total usage,
    /// on-demand spend and per-pool percentages. The legacy request-based fallback is not ported.
    static func map(usage: JSON, plan planInfo: JSON?, credits: JSON?, membership: String?, email: String?) throws -> ProviderUsage {
        guard usage["enabled"].bool != false, usage["planUsage"].exists else {
            throw ProviderError.unavailable("No active Cursor subscription.")
        }
        let planUsage = usage["planUsage"], spend = usage["spendLimitUsage"]
        let limit = planUsage["limit"].double
        let auto = planUsage["autoPercentUsed"].double, api = planUsage["apiPercentUsed"].double
        let spent = planUsage["totalSpend"].double ?? ((limit ?? 0) - (planUsage["remaining"].double ?? limit ?? 0))
        let hasPools = auto != nil && api != nil && ((auto ?? 0) > 0 || (api ?? 0) > 0 || spent == 0)
        let name = planInfo?.at("planInfo.planName").string ?? membership
        let team = name?.lowercased() == "team" || spend["limitType"].string?.lowercased() == "team"
            || (spend["pooledLimit"].double ?? 0) > 0

        let start = usage["billingCycleStart"].double, end = usage["billingCycleEnd"].double
        let reset = end.flatMap(Fmt.epoch)
        let minutes = start.flatMap { s in end.map { Int(($0 - s) / 60_000) } }.flatMap { $0 > 0 ? $0 : nil } ?? 43_200
        func window(_ id: String, _ title: String, _ percent: Double, detail: String? = nil) -> UsageWindow {
            UsageWindow(id: id, title: title, usedPercent: percent, resetsAt: reset, windowMinutes: minutes, detail: detail)
        }

        var windows: [UsageWindow] = []
        if team && !hasPools {
            // Team seats without model pools report dollars only.
            guard let limit, limit > 0 else { throw ProviderError.unavailable("Cursor usage data is unavailable. Try again later.") }
            windows.append(window("total", "Total usage", spent / limit * 100,
                                  detail: "\(Fmt.money(spent / 100)) / \(Fmt.money(limit / 100))"))
        } else if let percent = planUsage["totalPercentUsed"].double ?? (team ? nil : limit.flatMap { Fmt.percent(spent, of: $0) }) {
            windows.append(window("total", "Total usage", percent))
        } else if !hasPools {
            throw ProviderError.unavailable("Cursor returned no usage limit.")
        }
        if let auto { windows.append(window("auto", "Cursor models", auto)) }
        if let api { windows.append(window("api", "Other models", api)) }

        var cost: UsageCost?
        let onDemandLimit = spend["individualLimit"].double ?? spend["pooledLimit"].double ?? 0
        let onDemandLeft = spend["individualRemaining"].double ?? spend["pooledRemaining"].double ?? 0
        let reported = ["individualUsed", "pooledUsed", "totalSpend"].compactMap { spend[$0].double }
        let onDemand = reported.first { $0 > 0 } ?? max(0, onDemandLimit - onDemandLeft)
        let hasOnDemand = onDemandLimit > 0 || onDemand > 0
        let balance = creditsLeft(credits)
        if hasOnDemand || balance != nil {
            cost = UsageCost(used: hasOnDemand ? onDemand / 100 : nil, limit: onDemandLimit > 0 ? onDemandLimit / 100 : nil,
                             balance: balance.map { $0 / 100 }, period: hasOnDemand ? "On-demand" : nil, resetsAt: reset)
        }
        return ProviderUsage(windows: windows, cost: cost, plan: self.plan(name), email: email)
    }

    private static func creditsLeft(_ credits: JSON?) -> Double? {
        guard let credits, credits["hasCreditGrants"].bool == true, let total = credits["totalCents"].double, total > 0
        else { return nil }
        return max(0, total - (credits["usedCents"].double ?? 0))
    }

    private static func plan(_ value: String?) -> String? {
        value.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
    }
}
