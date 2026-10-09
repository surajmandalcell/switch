import Foundation

extension ProviderCatalog {
    static let mimo = ProviderSpec(
        id: "mimo", name: "Xiaomi MiMo",
        fields: [.cookie("api-platform_serviceToken and userId from platform.xiaomimimo.com")],
        dashboard: "https://platform.xiaomimimo.com/#/console/balance",
        usage: { credential in
            let cookie = try MiMoUsage.cookie(try credential.require("cookie"))
            let headers = [
                "Accept": "application/json, text/plain, */*", "Cookie": cookie,
                "Accept-Language": "en-US,en;q=0.9", "x-timeZone": "UTC+01:00",
                "Origin": "https://platform.xiaomimimo.com",
                "Referer": "https://platform.xiaomimimo.com/#/console/balance",
            ]
            let base = "https://platform.xiaomimimo.com/api/v1"
            async let balance = HTTP.send(base + "/balance", headers: headers)
            async let detail = try? HTTP.send(base + "/tokenPlan/detail", headers: headers)
            async let usage = try? HTTP.send(base + "/tokenPlan/usage", headers: headers)
            let balanceResponse = try await balance
            try HTTP.check(balanceResponse)
            guard let balanceJSON = try? balanceResponse.json() else {
                throw ProviderError.unauthorized("MiMo session expired. Paste a new Cookie header.")
            }
            return try MiMoUsage.map(balance: balanceJSON,
                                     detail: await detail.flatMap { try? $0.json() },
                                     usage: await usage.flatMap { try? $0.json() })
        })
}

enum MiMoUsage {
    /// Keeps only the cookies MiMo reads; both `api-platform_serviceToken` and `userId` are required.
    static func cookie(_ header: String) throws -> String {
        let keep = ["api-platform_serviceToken", "userId", "api-platform_ph", "api-platform_slh"]
        let pairs = keep.sorted().compactMap { name in Fmt.cookie(name, in: header).map { "\(name)=\($0)" } }
        guard pairs.contains(where: { $0.hasPrefix("api-platform_serviceToken=") }),
              pairs.contains(where: { $0.hasPrefix("userId=") }) else {
            throw ProviderError.missingCredential("The Cookie header needs api-platform_serviceToken and userId.")
        }
        return pairs.joined(separator: "; ")
    }

    private static func check(_ json: JSON) throws {
        guard let code = json["code"].int, code != 0 else { return }
        if code == 401 || code == 403 { throw ProviderError.unauthorized("MiMo rejected this session. Paste a new Cookie header.") }
        throw ProviderError.parse("MiMo returned error code \(code).")
    }

    static func map(balance: JSON, detail: JSON?, usage: JSON?, now: Date = Date()) throws -> ProviderUsage {
        try check(balance)
        let data = balance["data"]
        guard let amount = data["balance"].double, let currency = data["currency"].string else {
            throw ProviderError.parse("MiMo returned an unexpected balance shape.")
        }
        var rows: [UsageRow] = []
        if let cash = data["cashBalance"].double { rows.append(UsageRow("Paid", Fmt.money(cash, currency: currency))) }
        if let gift = data["giftBalance"].double { rows.append(UsageRow("Granted", Fmt.money(gift, currency: currency))) }
        var plan: String?
        var periodEnd: Date?
        if let detail, (try? check(detail)) != nil {
            plan = detail["data"]["planCode"].string?.capitalized
            periodEnd = detail["data"]["currentPeriodEnd"].date
        }
        var windows: [UsageWindow] = []
        if let usage, (try? check(usage)) != nil {
            let month = usage["data"]["monthUsage"]
            let item = month["items"][0]
            if let limit = item["limit"].double, limit > 0 {
                let used = item["used"].double ?? 0
                let percent = (item["percent"].double ?? month["percent"].double).map { $0 * 100 } ?? used / limit * 100
                windows.append(UsageWindow(id: "monthly", title: "Credits", usedPercent: percent, resetsAt: periodEnd,
                                           windowMinutes: periodEnd == nil ? nil : 43200,
                                           detail: "\(Fmt.number(used)) / \(Fmt.number(limit)) Credits"))
            }
        }
        return ProviderUsage(windows: windows, cost: UsageCost(balance: amount, currency: currency),
                             sections: [UsageSection(nil, rows)], plan: plan, fetchedAt: now)
    }
}
