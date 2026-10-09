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

private enum Console {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36"

    static func expand(_ value: Any?) -> Any? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
                  let parsed = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) else { return value }
            return expand(parsed)
        case let dict as [String: Any]: return dict.mapValues { expand($0) ?? $0 }
        case let array as [Any]: return array.map { expand($0) ?? $0 }
        default: return value
        }
    }

    static func find(_ keys: [String], in value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if dict.keys.contains(where: keys.contains) { return dict }
            for nested in dict.values { if let found = find(keys, in: nested) { return found } }
        } else if let array = value as? [Any] {
            for nested in array { if let found = find(keys, in: nested) { return found } }
        }
        return nil
    }

    static func scrapeToken(_ html: String) -> String? {
        let patterns = [#""secToken"\s*:\s*"([^"]+)""#, #""sec_token"\s*:\s*"([^"]+)""#,
                        #"secToken['"]?\s*[:=]\s*['"]([^'"]+)['"]"#, #"csrfToken['"]?\s*[:=]\s*['"]([^'"]+)['"]"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            return String(html[range])
        }
        return nil
    }
}

enum QwenCloudUsage {
    private static let home = "https://home.qwencloud.com"
    private static let dashboard = home + "/billing/subscription/token-plan-individual"
    private static let teamProduct = "sfm_tokenplanteams_dp_intl"

    private static func headers(_ cookie: String, referer: String, accept: String) -> [String: String] {
        var headers = ["Content-Type": "application/x-www-form-urlencoded", "Accept": accept, "Cookie": cookie,
                       "Origin": home, "Referer": referer, "X-Requested-With": "XMLHttpRequest", "User-Agent": Console.userAgent]
        if let csrf = Fmt.cookie("login_aliyunid_csrf", in: cookie) ?? Fmt.cookie("csrf", in: cookie) {
            headers["x-xsrf-token"] = csrf
            headers["x-csrf-token"] = csrf
        }
        return headers
    }

    static func fetch(cookie: String) async throws -> ProviderUsage {
        guard let token = await secToken(cookie) else {
            throw ProviderError.unauthorized("QwenCloud sign-in expired. Paste a fresh Cookie header.")
        }
        // A Team plan wins when one is active; any Team failure falls back to the Individual plan.
        if let team = try? await fetchTeam(cookie: cookie, token: token) { return team }
        return try await fetchIndividual(cookie: cookie, token: token)
    }

    /// Dashboard HTML, then the `sec_token` cookie, then the user-info endpoint.
    private static func secToken(_ cookie: String) async -> String? {
        if let page = try? await HTTP.send(dashboard, headers: ["Accept": "text/html,application/xhtml+xml", "Cookie": cookie]),
           page.status == 200, let token = Console.scrapeToken(page.text) { return token }
        if let token = Fmt.cookie("sec_token", in: cookie) { return token }
        guard let info = try? await HTTP.send(home + "/tool/user/info.json", headers: ["Cookie": cookie]),
              info.status == 200, let json = try? info.json() else { return nil }
        return json.at("data.secToken").string ?? json["secToken"].string
    }

    private static func fetchTeam(cookie: String, token: String) async throws -> ProviderUsage {
        let referer = home + "/analytics/token-plan/team"
        func call(_ action: String, product: String, region: String, params: String) async throws -> JSON {
            let form = ["product": product, "action": action, "sec_token": token, "region": region, "language": "zh-CN", "params": params]
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

    /// Individual plan: usage ratios 0...1 under `per5Hour*`, `per1Week*`, `per1Month*`.
    static func mapIndividual(usage: JSON, subscription: JSON?, quotaConfig: JSON?, now: Date = Date()) throws -> ProviderUsage {
        let expanded = Console.expand(usage.raw)
        if let code = JSON(expanded)["code"].string, code.contains("Login") || code == "NO_LOGIN" {
            throw ProviderError.unauthorized("QwenCloud sign-in expired. Paste a fresh Cookie header.")
        }
        guard let node = Console.find(["per5HourPercentage", "per1WeekPercentage", "per1MonthPercentage"], in: expanded) else {
            throw ProviderError.parse("QwenCloud returned no token plan usage.")
        }
        let stats = JSON(node)
        let planNode = Console.find(["specCode"], in: Console.expand(subscription?.raw))
        let code = JSON(planNode)["specCode"].string?.lowercased()
        let totals = code.flatMap { Console.find([$0], in: Console.expand(quotaConfig?.raw)) }.map { JSON($0)[code ?? ""] }
        let slots: [(String, String, String, String, Int)] = [
            ("session", "Session", "per5Hour", "five_hour", 300),
            ("weekly", "Weekly", "per1Week", "weekly", 10080),
            ("monthly", "Monthly", "per1Month", "monthly", 43200),
        ]
        var windows: [UsageWindow] = []
        for (id, title, prefix, totalKey, minutes) in slots {
            guard let ratio = stats[prefix + "Percentage"].double else { continue }
            let clamped = min(max(ratio, 0), 1)
            windows.append(UsageWindow(id: id, title: title, usedPercent: clamped * 100,
                                       resetsAt: stats[prefix + "ResetTime"].date, windowMinutes: minutes,
                                       detail: totals?[totalKey].double.map {
                                           "\(Fmt.number($0 * clamped)) / \(Fmt.number($0)) credits"
                                       }))
        }
        let plan = code.map { ["lite", "standard", "pro", "max"].contains($0) ? $0.capitalized : $0 }
        return ProviderUsage(windows: windows, plan: plan, fetchedAt: now)
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
        guard data.exists, groups.count == 1, data["ProductCode"].string == teamProduct,
              let start = data["StartTime"].date, let end = data["EndTime"].date, start <= now, now < end,
              let equity = groups[0]["EquityList"].array.first(where: { $0["EquityCode"].string == "credit_value" }),
              let total = equity["TotalValue"].double, let left = equity["SurplusValue"].double,
              let window = UsageWindow.amounts(id: "credits", title: "Team credits", used: total - left, limit: total,
                                               resetsAt: groups[0]["NextCycleFlushTime"].date, windowMinutes: 43200,
                                               unit: "credits") else {
            throw ProviderError.parse("QwenCloud has no active Team plan.")
        }
        var rows: [UsageRow] = []
        if let assigned = groups[0]["SubscriptionAssignedNumber"].int, let seats = groups[0]["SubscriptionTotalNumber"].int {
            rows.append(UsageRow("Seats", "\(assigned) / \(seats) assigned"))
        }
        return ProviderUsage(windows: [window], sections: [UsageSection(nil, rows)],
                             plan: groups[0]["SpecType"].string.map { $0.capitalized + " Team" }, fetchedAt: now)
    }
}
