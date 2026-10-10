import Foundation

extension ProviderCatalog {
    static let qwencloud = ProviderSpec(
        id: "qwencloud", name: "QwenCloud",
        fields: [
            .cookie("login_aliyunid_ticket or qwen_sso_ticket, login_aliyunid_csrf, cna from home.qwencloud.com"),
        ],
        dashboard: "https://home.qwencloud.com/billing/subscription/token-plan-individual",
        statusPage: nil,
        usage: { credential in try await QwenCloudUsage.fetch(cookie: try credential.require("cookie")) })
}

enum QwenCloudUsage {
    private static let home = "https://home.qwencloud.com"
    private static let dashboard = home + "/billing/subscription/token-plan-individual"
    private static let teamProduct = "sfm_tokenplanteams_dp_intl"

    private static func headers(_ cookie: String, referer: String, accept: String) -> [String: String] {
        var headers = ["Content-Type": "application/x-www-form-urlencoded", "Accept": accept, "Cookie": cookie,
                       "Origin": home, "Referer": referer, "X-Requested-With": "XMLHttpRequest", "User-Agent": OneConsole.userAgent]
        if let csrf = Fmt.cookie("login_aliyunid_csrf", in: cookie) ?? Fmt.cookie("csrf", in: cookie) {
            headers["x-xsrf-token"] = csrf
            headers["x-csrf-token"] = csrf
        }
        return headers
    }

    static func fetch(cookie: String) async throws -> ProviderUsage {
        guard let token = await OneConsole.secToken(cookie: cookie, dashboard: dashboard, gateway: home, cookieFirst: true,
                                                    infoKeys: ["secToken", "sec_token", "csrfToken", "token"]) else {
            throw ProviderError.unauthorized("QwenCloud sign-in expired. Paste a fresh Cookie header.")
        }
        // A Team plan wins when one is active; any Team failure falls back to the Individual plan.
        if let team = try? await fetchTeam(cookie: cookie, token: token) { return team }
        return try await fetchIndividual(cookie: cookie, token: token)
    }

    private static func fetchTeam(cookie: String, token: String) async throws -> ProviderUsage {
        let referer = home + "/analytics/token-plan/team"
        func call(_ action: String, product: String, region: String, params: String) async throws -> JSON {
            var form = ["product": product, "action": action, "sec_token": token, "region": region, "params": params]
            if action == "GetSeatSubscriptionSummary" { form["language"] = "zh-CN" }
            return try await HTTP.json("\(home)/data/api.json?product=\(product)&action=\(action)", method: "POST",
                                       headers: headers(cookie, referer: referer, accept: "application/json"), body: HTTP.form(form))
        }
        var params: [String: String] = ["productCode": teamProduct]
        if let human = try? await call("LoadHumanInfo", product: "ea-service", region: "ap-southeast-1", params: "{}"),
           let nbid = human.at("data.Data.SellerInfoDto.Nbid").string { params["Nbid"] = nbid }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self)
        return try mapTeam(try await call("GetSeatSubscriptionSummary", product: "BssOpenAPI-V3", region: "cn-hangzhou", params: text))
    }

    private static func fetchIndividual(cookie: String, token: String) async throws -> ProviderUsage {
        func call(_ api: String, _ data: [String: Any]) async throws -> JSON {
            var data = data
            data["cornerstoneParam"] = [
                "feTraceId": UUID().uuidString.lowercased(), "feURL": dashboard, "protocol": "V2", "console": "ONE_CONSOLE",
                "productCode": "p_efm", "domain": "home.qwencloud.com", "consoleSite": "QWENCLOUD", "userNickName": "",
                "userPrincipalName": "", "xsp_lang": "en-US", "X-Anonymous-Id": Fmt.cookie("cna", in: cookie) ?? "",
            ]
            let params = String(decoding: try JSONSerialization.data(withJSONObject: ["Api": api, "V": "1.0", "Data": data]), as: UTF8.self)
            let form = ["product": "sfm_bailian", "action": "IntlBroadScopeAspnGateway", "sec_token": token,
                        "region": "ap-southeast-1", "language": "en-US", "params": params]
            return try await HTTP.json("https://cs-data.qwencloud.com/data/api.json?action=IntlBroadScopeAspnGateway&product=sfm_bailian&api=\(api)&_v=undefined",
                                       method: "POST", headers: headers(cookie, referer: dashboard, accept: "application/json, text/plain, */*"),
                                       body: HTTP.form(form))
        }
        let base = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/"
        let usage = try await call(base + "usage", [:])
        let subscription = try? await call(base + "subscription", ["commodityCode": "sfm_tokenplansolo_public_intl"])
        let quotaConfig = try? await call(base + "quota-config", [:])
        return try mapIndividual(usage: usage, subscription: subscription, quotaConfig: quotaConfig)
    }

    /// Individual plan: usage ratios 0...1 under `per5Hour*`, `per1Week*`, `per1Month*`. An older
    /// subscription-summary answer (one credit pool) is read when no window is present.
    static func mapIndividual(usage: JSON, subscription: JSON?, quotaConfig: JSON?, now: Date = Date()) throws -> ProviderUsage {
        if let result = OneConsole.personal(usage: OneConsole.expand(usage.raw), subscription: OneConsole.expand(subscription?.raw),
                                            quotaConfig: OneConsole.expand(quotaConfig?.raw), defaultPlan: nil, now: now) {
            return result
        }
        return try AlibabaTokenPlanUsage.mapTeam(usage, now: now, brand: "QwenCloud")
    }

    /// Team plan: one active seat subscription group holding a `credit_value` equity.
    static func mapTeam(_ json: JSON, now: Date = Date()) throws -> ProviderUsage {
        let code = json["code"].string
        if let code, ["ConsoleNeedLogin", "BailianGateway.Login.NotLogined", "NO_LOGIN"].contains(code) {
            throw ProviderError.unauthorized("QwenCloud sign-in expired. Paste a fresh Cookie header.")
        }
        guard json["successResponse"].bool == true || code == "200", json["data"]["Success"].bool != false else {
            throw ProviderError.parse("QwenCloud returned an error for the Team plan.")
        }
        let data = json.at("data.Data")
        let groups = data["SubscriptionGroupList"].array
        let equities = groups.first?["EquityList"].array.filter { $0["EquityCode"].string == "credit_value" } ?? []
        guard data.exists, groups.count == 1, data["ProductCode"].string == teamProduct,
              let start = data["StartTime"].date, let end = data["EndTime"].date, start <= now, now < end,
              equities.count == 1, let total = equities[0]["TotalValue"].double, let left = equities[0]["SurplusValue"].double,
              left >= 0, left <= total,
              let window = UsageWindow.amounts(id: "credits", title: "Team credits", used: total - left, limit: total,
                                               resetsAt: groups[0]["NextCycleFlushTime"].date, windowMinutes: 43200,
                                               unit: "credits") else {
            throw ProviderError.parse("QwenCloud has no active Team plan.")
        }
        let group = groups[0]
        var rows: [UsageRow] = []
        if let assigned = group["SubscriptionAssignedNumber"].int, let seats = group["SubscriptionTotalNumber"].int,
           assigned >= 0, seats >= assigned {
            rows.append(UsageRow("Seats", "\(assigned) / \(seats) assigned"))
        }
        rows.append(UsageRow("Credits", "\(Fmt.number(total - left)) / \(Fmt.number(total)) credits used", progress: (total - left) / total))
        rows.append(UsageRow("Remaining", "\(Fmt.number(left)) credits"))
        let spec = group["SpecType"].string
        let plan = spec.flatMap { $0.range(of: #"^[a-z][a-z0-9_-]{0,39}$"#, options: .regularExpression) != nil ? $0.prefix(1).uppercased() + $0.dropFirst() + " Team" : nil }
        return ProviderUsage(windows: [window], sections: [UsageSection("Team Token Plan", rows)],
                             plan: plan ?? "Team Token Plan", fetchedAt: now)
    }
}
