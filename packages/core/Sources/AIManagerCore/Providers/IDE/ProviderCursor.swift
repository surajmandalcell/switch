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
            let fetched = try await IDEAuth.authorized(
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
                    let renewed = try CursorUsage.renewal(response)
                    rows[CursorUsage.accessKey] = renewed.access
                    if let rotated = renewed.refresh { rows[CursorUsage.refreshKey] = rotated }
                    changed = true
                    return renewed.access
                },
                call: { token in try await CursorUsage.load(token: token, membership: rows["cursorAuth/stripeMembershipType"]) })
            let mapped = try CursorUsage.map(
                usage: fetched.usage, plan: fetched.plan, credits: fetched.credits,
                membership: rows["cursorAuth/stripeMembershipType"], email: rows["cursorAuth/cachedEmail"],
                grokBot: fetched.grokBot, stripeCents: fetched.stripeCents, requests: fetched.requests,
                summary: fetched.summary, spend: fetched.spend)
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

    // MARK: Requests

    /// Reads the token endpoint's reply. Only a refused refresh token (`invalid_grant`, or `shouldLogout`) is an
    /// expired sign-in; any other 400, 401 or 403 is a failure the next refresh retries.
    static func renewal(_ response: HTTPResponse) throws -> (access: String, refresh: String?) {
        let body = try? response.json()
        let refused = [400, 401, 403].contains(response.status) && body?["error"].string == "invalid_grant"
        if refused || body?["shouldLogout"].bool == true { throw ProviderError.unauthorized("Sign in to Cursor again.") }
        if [400, 401, 403].contains(response.status) {
            throw ProviderError.http(response.status, "Cursor could not renew this sign-in. Switch will retry later.")
        }
        try HTTP.check(response)
        guard let access = body?["access_token"].string, !access.isEmpty else {
            throw ProviderError.parse("Cursor returned no access token.")
        }
        return (access, body?["refresh_token"].string)
    }

    static func rpc(_ method: String, token: String) async throws -> JSON {
        try await HTTP.json("https://api2.cursor.sh/aiserver.v1.DashboardService/\(method)", method: "POST",
                            headers: HTTP.bearer(token).merging(["Connect-Protocol-Version": "1"]) { $1 },
                            body: Data("{}".utf8))
    }

    /// The cursor.com dashboard takes the user id and access token as one session cookie.
    static func session(_ token: String) -> (userID: String, cookie: String)? {
        guard let subject = Fmt.jwtClaims(token)?["sub"].string else { return nil }
        let parts = subject.split(separator: "|", omittingEmptySubsequences: false)
        let userID = String(parts.count > 1 ? parts[1] : parts[0])
        return userID.isEmpty ? nil : (userID, "WorkosCursorSessionToken=\(userID)%3A%3A\(token)")
    }

    struct Fetched {
        var usage: JSON
        var plan: JSON?, credits: JSON?, grokBot: JSON?
        var stripeCents = 0.0
        var requests: JSON?, summary: JSON?
        var spend: MajorsSpend.Report?
    }

    /// The primary usage call must succeed; every other call only adds rows and may fail alone.
    static func load(token: String, membership: String? = nil) async throws -> Fetched {
        async let plan = try? rpc("GetPlanInfo", token: token)
        async let credits = try? rpc("GetCreditGrantsBalance", token: token)
        async let grokBot = try? rpc("GetSandUsageStatus", token: token)
        let usage = try await rpc("GetCurrentPeriodUsage", token: token)
        var fetched = Fetched(usage: usage, plan: await plan, credits: await credits, grokBot: await grokBot)
        guard let session = session(token) else { return fetched }
        let cookie = ["Cookie": session.cookie]
        async let stripe = try? HTTP.json("https://cursor.com/api/auth/stripe", headers: cookie)
        async let spend = spendSection(cookie: cookie)
        // The summary names the seat's membership (GetPlanInfo can say Pro for a Team or Enterprise seat).
        fetched.summary = try? await HTTP.json("https://cursor.com/api/usage-summary", headers: cookie)
        let planName = fetched.plan?.at("planInfo.planName").string
        let fallback = wantsFallback(
            usage: usage, planName: seatPlan(planName, membership: seatMembership(summary: fetched.summary, local: membership)),
            planInfoUnavailable: fetched.plan == nil)
        if fallback || Facts(usage).wantsGenericRequestFallback {
            fetched.requests = try? await HTTP.json("https://cursor.com/api/usage?user=\(session.userID)", headers: cookie)
        }
        fetched.stripeCents = stripeCents(await stripe)
        fetched.spend = await spend
        return fetched
    }

    /// Prepaid account balance: Cursor stores credit as a negative Stripe customer balance (cents).
    static func stripeCents(_ body: JSON?) -> Double {
        guard let balance = body?["customerBalance"].double, balance < 0 else { return 0 }
        return -balance
    }

    // MARK: Spend history

    struct Event: Equatable {
        var date: Date
        var tokens: Int
        /// API-rate cost in cents that Cursor reports for the event.
        var cents: Double?
    }

    static func parseEvents(_ page: JSON) -> [Event] {
        page["usageEventsDisplay"].array.compactMap { event in
            guard let date = event["timestamp"].date else { return nil }
            let usage = event["tokenUsage"]
            let tokens = ["inputTokens", "outputTokens", "cacheWriteTokens", "cacheReadTokens"]
                .reduce(0.0) { $0 + max(0, usage[$1].double ?? 0) }
            return Event(date: date, tokens: Fmt.clampedInt(tokens, 0...1_000_000_000_000_000), cents: usage["totalCents"].double.flatMap { $0 >= 0 ? $0 : nil })
        }
    }

    /// Today, Yesterday and Last 30 days from the usage events the Cursor dashboard lists, newest first.
    /// ponytail: at most 5 pages of 1000 events; a period the pages do not reach is left out, not guessed.
    /// Page further, or use Cursor's aggregate endpoint, if heavy users see missing days.
    static func spendSection(cookie: [String: String], now: Date = Date()) async -> MajorsSpend.Report? {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
        var all: [Event] = []
        var total = Int.max
        for page in 0..<5 where all.count < total {
            let body: [String: Any] = ["startDate": String(Int(start.timeIntervalSince1970 * 1000)),
                                       "endDate": String(Int(now.timeIntervalSince1970 * 1000)),
                                       "page": page + 1, "pageSize": 1000]
            guard let json = try? await HTTP.json(
                "https://cursor.com/api/dashboard/get-filtered-usage-events", method: "POST",
                headers: cookie.merging(["Origin": "https://cursor.com"]) { $1 }, object: body) else { return nil }
            let batch = parseEvents(json)
            total = json["totalUsageEventsCount"].int ?? batch.count
            all += batch
            if batch.isEmpty { break }
        }
        let complete = all.count >= total
        let oldest = all.map(\.date).min()
        return MajorsSpend.report(
            all.map { MajorsSpend.Entry(date: $0.date, cost: $0.cents.map { $0 / 100 }, tokens: $0.tokens) },
            now: now, completeFrom: complete ? nil : oldest, title: "Spend (API-rate estimate)")
    }

    // MARK: Identity

    /// Account key is the user id in the token subject (`auth0|user_x`), else the cached email.
    static func identity(_ rows: JSON?) -> CredentialIdentity? {
        guard let rows else { return nil }
        let email = rows["cursorAuth/cachedEmail"].string
        let subject = rows[accessKey].string.flatMap(Fmt.jwtClaims)?["sub"].string
        guard let key = subject.map({ String($0.split(separator: "|").last ?? "") }).flatMap({ $0.isEmpty ? nil : $0 })
                ?? email?.lowercased() else { return nil }
        return CredentialIdentity(key: key, email: email, plan: plan(rows["cursorAuth/stripeMembershipType"].string))
    }

    // MARK: Mapping

    /// The few facts of the `GetCurrentPeriodUsage` reply that pick between the plan-usage path and the
    /// request-based fallbacks. Decoded once so the fetch and the mapper cannot disagree.
    struct Facts {
        let enabled: Bool
        let hasPlanUsage: Bool
        let limit: Double?
        let totalPercent: Double?
        let hasPools: Bool
        let teamByShape: Bool

        init(_ usage: JSON) {
            enabled = usage["enabled"].bool != false
            let plan = usage["planUsage"]
            hasPlanUsage = plan.exists
            limit = plan["limit"].double
            totalPercent = plan["totalPercentUsed"].double
            let auto = plan["autoPercentUsed"].double, api = plan["apiPercentUsed"].double
            let spent = plan["totalSpend"].double ?? ((limit ?? 0) - (plan["remaining"].double ?? limit ?? 0))
            if let auto, let api, auto >= 0, api >= 0 {
                hasPools = auto > 0 || api > 0 || spent == 0
            } else {
                hasPools = false
            }
            let spend = usage["spendLimitUsage"]
            teamByShape = spend["limitType"].string?.lowercased() == "team" || (spend["pooledLimit"].double ?? 0) > 0
        }

        var planUsageUnusable: Bool { !hasPlanUsage || (limit == nil && !hasPools) }
        /// An enabled account whose plan usage has neither a limit nor any percentage.
        var wantsGenericRequestFallback: Bool { enabled && hasPlanUsage && limit == nil && totalPercent == nil && !hasPools }
    }

    static let orgMemberships: Set<String> = ["enterprise", "team"]

    /// The seat's membership: usage-summary names it, the local database row is the fallback.
    static func seatMembership(summary: JSON?, local: String?) -> String? {
        (summary?["membershipType"].string ?? local)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The plan name that routes the fetch: an Enterprise or Team membership beats GetPlanInfo's name.
    static func seatPlan(_ planName: String?, membership: String?) -> String? {
        membership.flatMap { orgMemberships.contains($0) ? $0 : nil } ?? planName
    }

    /// The plan shown: an Enterprise or Team membership replaces a missing or Pro plan name; any other name stays.
    static func resolvedPlanName(_ planName: String?, membership: String?) -> String? {
        let name = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if let membership, orgMemberships.contains(membership), ["", "pro", "pro plan"].contains(name) {
            return membership
        }
        return planName ?? membership
    }

    /// True when Enterprise or team accounts must be read from the REST usage and usage-summary calls.
    static func wantsFallback(usage: JSON, planName: String?, planInfoUnavailable: Bool) -> Bool {
        let facts = Facts(usage)
        guard facts.enabled else { return false }
        let name = planName?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if facts.planUsageUnusable && (name == "enterprise" || name == "team") { return true }
        if facts.planUsageUnusable && facts.totalPercent == nil && name.isEmpty && planInfoUnavailable { return true }
        return facts.teamByShape && facts.hasPlanUsage && facts.limit == nil && !facts.hasPools
    }

    /// Pure mapper for the dashboard RPCs (amounts are cents). Merges OpenUsage's credits, total usage,
    /// on-demand spend, per-pool percentages, Grok Bot and request counts, and CodexBar's team fallbacks.
    static func map(usage: JSON, plan planInfo: JSON?, credits: JSON?, membership: String?, email: String?,
                    grokBot: JSON? = nil, stripeCents: Double = 0, requests: JSON? = nil, summary: JSON? = nil,
                    spend: MajorsSpend.Report? = nil) throws -> ProviderUsage {
        let seat = seatMembership(summary: summary, local: membership)
        let routedPlan = seatPlan(planInfo?.at("planInfo.planName").string, membership: seat)
        let routed = wantsFallback(usage: usage, planName: routedPlan, planInfoUnavailable: planInfo == nil)
        guard usage["enabled"].bool != false, usage["planUsage"].exists else {
            // A fallback account can have no plan usage at all; the summary may still read.
            if usage["enabled"].bool != false, requests != nil || (summary != nil && routed) {
                return try fallback(usage: usage, planInfo: planInfo, credits: credits, membership: membership,
                                    email: email, grokBot: grokBot, stripeCents: stripeCents, requests: requests,
                                    summary: summary, spend: spend)
            }
            throw ProviderError.unavailable("No active Cursor subscription.")
        }
        let facts = Facts(usage)
        let name = planInfo?.at("planInfo.planName").string ?? membership
        if routed || (facts.wantsGenericRequestFallback && requests != nil) {
            if let mapped = try? fallback(usage: usage, planInfo: planInfo, credits: credits, membership: membership,
                                          email: email, grokBot: grokBot, stripeCents: stripeCents,
                                          requests: requests, summary: summary, spend: spend) {
                return mapped
            }
        }
        let planUsage = usage["planUsage"], limitUsage = usage["spendLimitUsage"]
        let limit = planUsage["limit"].double
        let auto = planUsage["autoPercentUsed"].double, api = planUsage["apiPercentUsed"].double
        let spent = planUsage["totalSpend"].double ?? ((limit ?? 0) - (planUsage["remaining"].double ?? limit ?? 0))
        let hasPools = facts.hasPools
        let team = name?.lowercased() == "team" || facts.teamByShape

        let (reset, minutes) = cycle(start: usage["billingCycleStart"].double, end: usage["billingCycleEnd"].double)
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
        windows += grokBotWindow(grokBot).map { [$0] } ?? []

        // Spend and cap come from one budget: a personal cap pairs with the member's own spend, the team
        // pool with the pool's. The team pool's spend is never shown against a personal cap.
        let hasTeamSpend = facts.teamByShape || (limitUsage["pooledUsed"].double ?? 0) > 0
        let budget: (limit: Double, spent: [String], remaining: String?)
        if let individualLimit = limitUsage["individualLimit"].double {
            budget = (individualLimit, hasTeamSpend ? ["individualUsed"] : ["individualUsed", "totalSpend"], "individualRemaining")
        } else if let pooled = limitUsage["pooledLimit"].double, pooled > 0 {
            budget = (pooled, ["pooledUsed"], "pooledRemaining")
        } else {
            budget = (0, ["individualUsed", "pooledUsed", "totalSpend"], nil)
        }
        var onDemandLimit = budget.limit
        let reported = budget.spent.compactMap { limitUsage[$0].double }
        var onDemand = reported.first { $0 > 0 }
            ?? budget.remaining.flatMap { limitUsage[$0].double }.map { max(0, onDemandLimit - $0) } ?? 0
        // An Enterprise or Team seat can report no on-demand budget here; usage-summary still has it.
        if onDemandLimit == 0, onDemand == 0, Self.orgMemberships.contains(seat ?? "") || facts.teamByShape,
           let bucket = summaryOnDemand(summary) {
            (onDemand, onDemandLimit) = (bucket.used, bucket.limit ?? 0)
        }
        let credit = creditsCents(credits, stripe: stripeCents)
        return ProviderUsage(
            windows: windows,
            cost: cost(used: onDemand, limit: onDemandLimit, creditCents: credit, reset: reset),
            sections: [spend?.section].compactMap { $0 }, plan: self.plan(resolvedPlanName(name, membership: seat)), email: email,
            charts: [spend?.chart].compactMap { $0 })
    }

    /// Enterprise and team accounts: included requests from `/api/usage` and percentages, dollars and
    /// on-demand spend from `/api/usage-summary`. Neither reply is enough alone.
    private static func fallback(usage: JSON, planInfo: JSON?, credits: JSON?, membership: String?, email: String?,
                                 grokBot: JSON?, stripeCents: Double, requests: JSON?, summary: JSON?,
                                 spend: MajorsSpend.Report?) throws -> ProviderUsage {
        let start = summary?["billingCycleStart"].date, end = summary?["billingCycleEnd"].date
        var reset = end
        var minutes = 43_200
        if let start, let end, end > start {
            minutes = Fmt.int(end.timeIntervalSince(start) / 60) ?? minutes
        } else {
            reset = requests?["startOfMonth"].date.map { $0.addingTimeInterval(43_200 * 60) }
        }
        let individual = summary?["individualUsage"] ?? JSON(nil), team = summary?["teamUsage"] ?? JSON(nil)
        var windows: [UsageWindow] = []
        let requestsLimit = requests?.at("gpt-4.maxRequestUsage").double ?? 0
        if requestsLimit > 0 {
            let used = max(0, requests?.at("gpt-4.numRequests").double ?? requests?.at("gpt-4.numRequestsTotal").double ?? 0)
            if summary != nil, let total = UsageWindow.amounts(id: "total", title: "Total usage", used: used, limit: requestsLimit,
                                                              resetsAt: reset, windowMinutes: minutes, unit: "requests") {
                windows.append(total)
            }
            if let window = UsageWindow.amounts(id: "requests", title: "Requests", used: used, limit: requestsLimit,
                                                resetsAt: reset, windowMinutes: minutes, unit: "requests") {
                windows.append(window)
            }
        } else if summary != nil {
            func money(_ id: String, _ meter: (used: Double, limit: Double)) -> UsageWindow {
                UsageWindow(id: id, title: "Total usage", usedPercent: meter.used / meter.limit * 100, resetsAt: reset,
                            windowMinutes: minutes, detail: "\(Fmt.money(meter.used / 100)) / \(Fmt.money(meter.limit / 100))")
            }
            if summary?["limitType"].string?.lowercased() == "team", let pooled = dollars(team["pooled"]) {
                windows.append(money("total", pooled))
            } else if let percent = individual.at("plan.totalPercentUsed").double {
                windows.append(UsageWindow(id: "total", title: "Total usage", usedPercent: percent, resetsAt: reset, windowMinutes: minutes))
            } else if let overall = dollars(individual["overall"]) {
                windows.append(money("total", overall))
            } else if let pooled = dollars(team["pooled"]) {
                windows.append(money("total", pooled))
            }
        }
        if summary != nil {
            for (key, id, title) in [("autoPercentUsed", "auto", "Cursor models"), ("apiPercentUsed", "api", "Other models")] {
                if let percent = individual.at("plan.\(key)").double {
                    windows.append(UsageWindow(id: id, title: title, usedPercent: percent, resetsAt: reset, windowMinutes: minutes))
                }
            }
        }
        let onDemand = summaryOnDemand(summary)
        windows += grokBotWindow(grokBot).map { [$0] } ?? []
        guard !windows.isEmpty || onDemand != nil else {
            throw ProviderError.unavailable("Cursor request-based usage data unavailable. Try again later.")
        }
        let name = resolvedPlanName(planInfo?.at("planInfo.planName").string,
                                    membership: seatMembership(summary: summary, local: membership))
        return ProviderUsage(
            windows: windows,
            cost: cost(used: onDemand?.used ?? 0, limit: onDemand?.limit ?? 0, creditCents: creditsCents(credits, stripe: stripeCents),
                       reset: reset),
            sections: [spend?.section].compactMap { $0 }, plan: plan(name), email: email,
            charts: [spend?.chart].compactMap { $0 })
    }

    private static func dollars(_ bucket: JSON) -> (used: Double, limit: Double)? {
        guard bucket["enabled"].bool != false, let limit = bucket["limit"].double, limit > 0 else { return nil }
        let used = bucket["used"].double.flatMap { $0 > 0 ? $0 : nil } ?? max(0, limit - (bucket["remaining"].double ?? limit))
        return (max(0, used), limit)
    }

    /// The dashboard's On-Demand card is user scoped; the team bucket is the fallback.
    private static func summaryOnDemand(_ summary: JSON?) -> (used: Double, limit: Double?)? {
        for bucket in [summary?.at("individualUsage.onDemand"), summary?.at("teamUsage.onDemand")].compactMap({ $0 })
        where bucket["enabled"].bool != false {
            if let meter = dollars(bucket) { return (meter.used, meter.limit) }
            if let used = bucket["used"].double, used > 0 { return (used, nil) }
        }
        return nil
    }

    private static func cycle(start: Double?, end: Double?) -> (Date?, Int) {
        let minutes = start.flatMap { s in end.flatMap { Fmt.int(($0 - s) / 60_000) } }.flatMap { $0 > 0 ? $0 : nil } ?? 43_200
        return (end.flatMap(Fmt.epoch), minutes)
    }

    /// On-demand spend (and its cap) plus the remaining prepaid credit, all in cents on input.
    private static func cost(used: Double, limit: Double, creditCents: Double?, reset: Date?) -> UsageCost? {
        let hasOnDemand = limit > 0 || used > 0
        guard hasOnDemand || creditCents != nil else { return nil }
        return UsageCost(used: hasOnDemand ? used / 100 : nil, limit: limit > 0 ? limit / 100 : nil,
                         balance: creditCents.map { $0 / 100 }, period: hasOnDemand ? "On-demand" : nil, resetsAt: reset)
    }

    /// Credit grants left plus the prepaid Stripe balance, or nil when the account holds neither.
    private static func creditsCents(_ credits: JSON?, stripe: Double) -> Double? {
        var total = stripe, used = 0.0
        if let credits, credits["hasCreditGrants"].bool == true, let grant = credits["totalCents"].double, grant > 0 {
            total += grant
            used = credits["usedCents"].double ?? 0
        }
        return total > 0 ? max(0, total - used) : nil
    }

    /// Grok Bot ("Sand") has its own weekly allowance. Pooled enterprise seats and accounts with no
    /// included limit have no personal meter; an unexpired trial still counts but has no recurring reset.
    static func grokBotWindow(_ sand: JSON?, now: Date = Date()) -> UsageWindow? {
        guard let sand, sand["usesPooledEnterpriseAllowance"].bool != true,
              let percent = sand["usagePercent"].double, percent >= 0 else { return nil }
        let included = sand["includedLimitZero"].bool.map { !$0 } ?? sand["hasNonZeroIncludedLimit"].bool
        let trial = included != true && (sand["sandTrialExpiresAt"].date.map { $0 > now } ?? false)
        guard included != false || trial else { return nil }
        let reset = trial ? nil : sand["nextResetTimestampUtc"].date
        return UsageWindow(id: "grok-bot", title: "Grok Bot", usedPercent: percent, resetsAt: reset,
                           windowMinutes: reset == nil ? nil : 10_080)
    }

    private static func plan(_ value: String?) -> String? {
        value.map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
    }
}

/// Today, Yesterday and Last 30 days rows for providers that record spend on this Mac or in the account.
enum MajorsSpend {
    struct Entry: Equatable {
        var date: Date
        /// Dollars, or nil when the record carries no price.
        var cost: Double?
        var tokens: Int
        /// Set by sources that know the model and an id that repeats in copied logs.
        var model: String? = nil
        var key: String? = nil
    }

    /// `completeFrom`: the oldest moment the entries fully cover. A period that starts before it is left out.
    static func section(_ entries: [Entry], now: Date, completeFrom: Date? = nil, calendar: Calendar = .current,
                        title: String = "Spend") -> UsageSection? {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let month = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let periods: [(String, Date, Date)] = [("Today", today, .distantFuture), ("Yesterday", yesterday, today),
                                               ("Last 30 days", month, .distantFuture)]
        let rows = periods.compactMap { label, from, to -> UsageRow? in
            if let completeFrom, from < completeFrom { return nil }
            let inside = entries.filter { $0.date >= from && $0.date < to }
            let tokens = inside.reduce(0) { $0 + $1.tokens }
            // A dollar total is shown only when every record in the period has a price.
            let priced = !inside.isEmpty && inside.allSatisfy { $0.cost != nil }
            let cost = priced ? inside.reduce(0) { $0 + ($1.cost ?? 0) } : 0
            var parts: [String] = []
            if priced, cost > 0 { parts.append(Fmt.money(cost)) }
            if tokens > 0 { parts.append("\(compact(tokens)) tokens") }
            return parts.isEmpty ? nil : UsageRow(label, parts.joined(separator: " \u{00B7} "))
        }
        return rows.isEmpty ? nil : UsageSection(title, rows)
    }

    /// The summary rows plus the 30-day daily chart of the same entries.
    struct Report {
        var section: UsageSection?
        var chart: UsageChart?
    }

    static func report(_ entries: [Entry], now: Date, completeFrom: Date? = nil, calendar: Calendar = .current,
                       title: String = "Spend") -> Report? {
        let report = Report(section: section(entries, now: now, completeFrom: completeFrom, calendar: calendar, title: title),
                            chart: chart(entries, now: now, completeFrom: completeFrom, calendar: calendar))
        return report.section == nil && report.chart == nil ? nil : report
    }

    /// 30 calendar days ending today, zero-filled. Dollars when every record carries a price, else tokens.
    /// Days that start before `completeFrom` are left out, as in the rows.
    static func chart(_ entries: [Entry], now: Date, completeFrom: Date? = nil, calendar: Calendar = .current) -> UsageChart? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: now)
        let starts = (0..<30).compactMap { calendar.date(byAdding: .day, value: -29 + $0, to: today) }
            .filter { completeFrom == nil || $0 >= completeFrom! }
        let first = starts.first ?? today
        let inside = entries.filter { $0.date >= first && $0.date < (calendar.date(byAdding: .day, value: 1, to: today) ?? now) }
        let priced = !inside.isEmpty && inside.allSatisfy { $0.cost != nil } && inside.contains { ($0.cost ?? 0) > 0 }
        var byDay: [String: Double] = [:]
        for entry in inside {
            byDay[formatter.string(from: entry.date), default: 0] += priced ? (entry.cost ?? 0) : Double(entry.tokens)
        }
        guard byDay.values.contains(where: { $0 > 0 }) else { return nil }
        for start in starts { byDay[formatter.string(from: start), default: 0] += 0 }
        return UsageChart.daily(id: "spend-daily", title: priced ? "Daily spend" : "Daily tokens", unit: priced ? "USD" : "tokens",
                                values: byDay)
    }

    static func compact(_ value: Int) -> String {
        let number = Double(value)
        for (size, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] where number >= size {
            let scaled = number / size
            let text = scaled >= 100 ? String(format: "%.0f", scaled) : String(format: "%.1f", scaled)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
        }
        return String(value)
    }
}
