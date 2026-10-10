import Foundation

extension ProviderCatalog {
    /// Either a Cookie header (exchanged for a short-lived token) or a captured Authorization token works.
    static let zoommate = ProviderSpec(
        id: "zoommate", name: "ZoomMate",
        fields: [CredentialField("cookie", "Cookie header", optional: true, placeholder: "Cookie header from zoommate.zoom.us"),
                 CredentialField("token", "Authorization token", optional: true, placeholder: "Bearer token from a credits/status request")],
        dashboard: "https://zoommate.zoom.us/#/?settings=credit-usage",
        statusPage: "https://www.zoomstatus.com",
        usage: { credential in
            let cookie = credential["cookie"]
            guard cookie != nil || credential["token"] != nil else {
                throw ProviderError.missingCredential("Add a Cookie header or an Authorization token for ZoomMate.")
            }
            func get(_ path: String, token: String?) async throws -> JSON {
                var headers = [
                    "Accept": "application/json, text/plain, */*",
                    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
                    "Origin": "https://zoommate.zoom.us", "Referer": "https://zoommate.zoom.us",
                ]
                if let cookie { headers["Cookie"] = cookie }
                if let token { headers["Authorization"] = ZoomMateUsage.bearer(token) }
                var failure: Error = ProviderError.network("ZoomMate could not be reached.")
                // Both hosts serve the same API; an authentication failure is final.
                for host in ["ai.zoom.us", "zoommate.zoom.us"] {
                    do { return try await HTTP.json("https://\(host)/ai-computer/api/v1/\(path)", headers: headers) }
                    catch let error as ProviderError where error.needsSignIn { throw error }
                    catch { failure = error }
                }
                throw failure
            }
            var token = credential["token"], email: String?
            if token == nil {
                let login = try await get("login/?continue=https%3A%2F%2Fzoommate.zoom.us%2F", token: nil)
                token = login.at("data.nak").string
                email = login.at("data.user_profile.email").string
                guard token != nil else { throw ProviderError.parse("Could not parse ZoomMate usage: missing nak in login response.") }
            }
            let now = Date()
            // The 30-day history is optional: a failure keeps the credit balance.
            var records: [JSON]?
            do {
                let start = now.addingTimeInterval(-30 * 86_400)
                let stamp = PluginFmt.iso(start).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                let end = PluginFmt.iso(now).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                var all: [JSON] = []
                for page in 0..<20 {
                    let data = try await get("credits/history?app_id=demo_app&limit=50&page=\(page)&sort_by=time"
                                             + "&sort_order=desc&start_time=\(stamp)&end_time=\(end)", token: token)["data"]
                    let rows = data["records"].array
                    all += rows
                    let total = data["total"].int ?? all.count
                    if rows.isEmpty || (page + 1) * 50 >= total
                        || rows.allSatisfy({ ($0["time"].date ?? now) < start }) { break }
                }
                records = all
            } catch {}
            var usage = try ZoomMateUsage.map(try await get("credits/status", token: token), history: records, now: now)
            usage.email = email
            usage.plan = email == nil ? nil : "Cookie"
            return usage
        })
}

enum ZoomMateUsage {
    static func bearer(_ token: String) -> String {
        token.lowercased().hasPrefix("bearer ") ? token : "Bearer \(token)"
    }

    /// "Credit history": today's and 30-day credits from `credits/history` records, and the pace against the cycle.
    static func historySection(_ records: [JSON], status: JSON, unlimited: Bool, usedPercent: Double,
                               now: Date) -> UsageSection {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        func day(_ date: Date) -> String {
            let parts = local.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
        let since = local.startOfDay(for: local.date(byAdding: .day, value: -29, to: now) ?? now)
        var totals: [String: Double] = [:]
        for record in records {
            guard record["is_deleted"].bool != true, let cost = record["cost"].double, cost >= 0,
                  let date = record["time"].date, date >= since else { continue }
            totals[day(date), default: 0] += cost
        }
        var rows = [UsageRow("Today", Fmt.number(totals[day(now)] ?? 0, digits: 2)),
                    UsageRow("30d credits", Fmt.number(totals.values.reduce(0, +), digits: 2))]
        if !unlimited, let start = status["cycle_start_date"].double, let end = status["cycle_end_date"].double,
           start > 0, end > start {
            let duration = ((end - start) / 60_000).rounded(.towardZero) * 60_000
            let remaining = end - now.timeIntervalSince1970 * 1000
            if duration > 0, remaining > 0, remaining <= duration, !(remaining == duration && usedPercent > 0) {
                let delta = usedPercent - (1 - remaining / duration) * 100
                let amount = Int(abs(delta).rounded())
                rows.append(UsageRow("Pace", abs(delta) <= 2 ? "On track"
                                     : delta > 0 ? "\(amount)% ahead of budget" : "\(amount)% behind budget"))
            }
        }
        return UsageSection("Credit history", rows)
    }

    static func map(_ json: JSON, history: [JSON]? = nil, now: Date = Date()) throws -> ProviderUsage {
        let status = json.at("data.credit_status")
        guard status.raw is [String: Any] else { throw ProviderError.parse("Could not parse ZoomMate usage: missing credit_status object.") }
        let cap = status["budget_cap"].double ?? 0, used = status["used_credit"].double ?? 0
        let unlimited = status["is_unlimited"].bool == true || cap <= 0
        let historyRows = history.map {
            [historySection($0, status: status, unlimited: unlimited, usedPercent: unlimited ? 0 : used / cap * 100, now: now)]
        } ?? []
        guard !unlimited else {
            return ProviderUsage(sections: [UsageSection("Credits", [UsageRow("Credits", "Unlimited")])] + historyRows)
        }
        var rows = [UsageRow("Credits used", "\(Fmt.number(used, digits: 2)) / \(Fmt.number(cap, digits: 2))")]
        if let overage = status["overage_credit"].double, overage > 0 { rows.append(UsageRow("Overage credits", Fmt.number(overage, digits: 2))) }
        return ProviderUsage(
            windows: [UsageWindow(id: "credits", title: "Credits", usedPercent: used / cap * 100,
                                  resetsAt: status["cycle_end_date"].date, detail: "\(Fmt.number(used, digits: 2)) / \(Fmt.number(cap, digits: 2)) credits")],
            sections: [UsageSection("Credits", rows)] + historyRows)
    }
}
