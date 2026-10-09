import Foundation

extension ProviderCatalog {
    static let alibabatokenplan = ProviderSpec(
        id: "alibabatokenplan", name: "Alibaba Token Plan",
        fields: [
            .cookie("login_aliyunid_ticket, login_aliyunid_csrf, cna from the usage request"),
            CredentialField("region", "Region", secure: false, optional: true,
                            placeholder: "intl, cn, intl-personal or cn-personal"),
        ],
        dashboard: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=plan#/efm/subscription/token-plan",
        usage: { credential in
            let cookie = try credential.require("cookie")
            let region = (credential["region"] ?? "intl").lowercased()
            return try await AlibabaTokenPlanUsage.fetch(cookie: cookie, cn: region.hasPrefix("cn"),
                                                         personal: region.hasSuffix("personal"))
        })
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

    static func first(_ keys: [String], in node: JSON) -> JSON? { keys.map { node[$0] }.first { $0.exists } }

    static func scrapeToken(_ html: String) -> String? {
        let patterns = [#""secToken"\s*:\s*"([^"]+)""#, #""sec_token"\s*:\s*"([^"]+)""#,
                        #"secToken['"]?\s*[:=]\s*['"]([^'"]+)['"]"#, #"sec_token['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
                        #"csrfToken['"]?\s*[:=]\s*['"]([^'"]+)['"]"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            return String(html[range])
        }
        return nil
    }

    static func secToken(cookie: String, dashboard: String, gateway: String) async -> String? {
        let page = try? await HTTP.send(dashboard, headers: [
            "Accept": "text/html,application/xhtml+xml", "Cookie": cookie, "User-Agent": userAgent,
            "Referer": gateway + "/", "Sec-Fetch-Site": "same-origin", "Sec-Fetch-Mode": "navigate",
            "Sec-Fetch-Dest": "document", "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"])
        if let page, page.status == 200, let token = scrapeToken(page.text) { return token }
        if let token = Fmt.cookie("sec_token", in: cookie) { return token }
        guard let info = try? await HTTP.send(gateway + "/tool/user/info.json", headers: ["Cookie": cookie]),
              info.status == 200, let json = try? info.json() else { return nil }
        let node = find(["secToken", "sec_token", "csrfToken"], in: expand(json.raw))
        return ["secToken", "sec_token", "csrfToken"].lazy.compactMap { JSON(node)[$0].string }.first
    }
}

enum AlibabaTokenPlanUsage {
    private struct Site {
        let gateway: String, dashboard: String, rpc: String, rpcAction: String, region: String
        let team: String, solo: String, domain: String, consoleSite: String
    }

    private static func site(cn: Bool, personal: Bool) -> Site {
        let path = personal ? "/personal" : ""
        return cn
            ? Site(gateway: "https://bailian.console.aliyun.com",
                   dashboard: "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan\(path)",
                   rpc: "https://bailian-cs.console.aliyun.com", rpcAction: "BroadScopeAspnGateway", region: "cn-beijing",
                   team: "sfm_tokenplanteams_dp_cn", solo: "sfm_tokenplansolo_public_cn",
                   domain: "bailian.console.aliyun.com", consoleSite: "BAILIAN_ALIYUN")
            : Site(gateway: "https://modelstudio.console.alibabacloud.com",
                   dashboard: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=plan#/efm/subscription/token-plan\(path)",
                   rpc: "https://bailian-singapore-cs.alibabacloud.com", rpcAction: "IntlBroadScopeAspnGateway",
                   region: "ap-southeast-1", team: "sfm_tokenplanteams_dp_intl", solo: "sfm_tokenplansolo_public_intl",
                   domain: "modelstudio.console.alibabacloud.com", consoleSite: "MODELSTUDIO_ALBABACLOUD")
    }

    private static func post(_ url: String, cookie: String, site s: Site, accept: String, form: [String: String]) async throws -> JSON {
        let csrf = Fmt.cookie("login_aliyunid_csrf", in: cookie) ?? Fmt.cookie("csrf", in: cookie)
        var headers = ["Content-Type": "application/x-www-form-urlencoded", "Accept": accept, "Cookie": cookie,
                       "X-Requested-With": "XMLHttpRequest", "User-Agent": Console.userAgent,
                       "Origin": s.gateway, "Referer": s.dashboard]
        if let csrf { headers["x-xsrf-token"] = csrf; headers["x-csrf-token"] = csrf }
        return try await HTTP.json(url, method: "POST", headers: headers, body: HTTP.form(form))
    }

    static func fetch(cookie: String, cn: Bool, personal: Bool) async throws -> ProviderUsage {
        let s = site(cn: cn, personal: personal)
        let token = await Console.secToken(cookie: cookie, dashboard: s.dashboard, gateway: s.gateway)
        if token == nil && !personal {
            throw ProviderError.unauthorized("Alibaba sign-in expired. Paste a fresh Cookie header from the console.")
        }
        if !personal {
            let params = String(decoding: try JSONSerialization.data(withJSONObject: ["ProductCode": s.team]), as: UTF8.self)
            return try mapTeam(try await post("\(s.gateway)/data/api.json?action=GetSubscriptionSummary&product=BssOpenAPI-V3&_tag=",
                                              cookie: cookie, site: s, accept: "*/*",
                                              form: ["product": "BssOpenAPI-V3", "action": "GetSubscriptionSummary", "params": params,
                                                     "region": s.region, "sec_token": token ?? ""]))
        }
        func call(_ api: String, _ data: [String: Any]) async throws -> JSON {
            var data = data
            data["cornerstoneParam"] = [
                "feTraceId": UUID().uuidString.lowercased(), "feURL": s.dashboard, "protocol": "V2", "console": "ONE_CONSOLE",
                "productCode": "p_efm", "switchUserType": 3, "domain": s.domain, "consoleSite": s.consoleSite,
                "userNickName": "", "userPrincipalName": "", "xsp_lang": "en-US",
                "X-Anonymous-Id": Fmt.cookie("cna", in: cookie) ?? "",
            ]
            let params = String(decoding: try JSONSerialization.data(withJSONObject: ["Api": api, "V": "1.0", "Data": data]), as: UTF8.self)
            var form = ["product": "sfm_bailian", "action": s.rpcAction, "region": s.region, "language": "en-US", "params": params]
            if let token { form["sec_token"] = token }
            return try await post("\(s.rpc)/data/api.json?action=\(s.rpcAction)&product=sfm_bailian&api=\(api)&_v=undefined",
                                  cookie: cookie, site: s, accept: "application/json, text/plain, */*", form: form)
        }
        let base = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/"
        // The usage call sometimes answers 200 with no windows; retry a few times.
        var usage = try await call(base + "usage", [:])
        for _ in 0..<2 where Console.find(["per5HourPercentage", "per1WeekPercentage", "per1MonthPercentage"], in: Console.expand(usage.raw)) == nil {
            try await Task.sleep(nanoseconds: 400_000_000)
            usage = try await call(base + "usage", [:])
        }
        let subscription = try? await call(base + "subscription", ["commodityCode": s.solo])
        let quotaConfig = try? await call(base + "quota-config", [:])
        return try mapPersonal(usage: usage, subscription: subscription, quotaConfig: quotaConfig)
    }

    /// `GetSubscriptionSummary` for Team plans: one monthly credit pool.
    static func mapTeam(_ json: JSON, now: Date = Date()) throws -> ProviderUsage {
        let root = JSON(Console.expand(json.raw))
        let code = (root["Code"].string ?? root["errorCode"].string ?? "200").lowercased()
        if root["Success"].bool == false || !["200", "0", "success"].contains(code) {
            if code.contains("login") || code.contains("token") || code.contains("401") {
                throw ProviderError.unauthorized("Alibaba sign-in expired. Paste a fresh Cookie header from the console.")
            }
            throw ProviderError.parse("Alibaba returned an error for the token plan.")
        }
        let data = root["Data"].exists ? root["Data"] : root["data"]
        let count = data["TotalCount"].int
        let total = Console.first(["totalQuota", "total_quota", "totalCredits", "totalCredit", "quota", "creditLimit", "creditsTotal",
                                   "monthlyTotalQuota", "amount", "totalValue", "TotalValue", "cycleTotalValue", "CycleTotalValue"],
                                  in: data)?.double
        let remaining = Console.first(["remainingQuota", "remainQuota", "remainingCredits", "remainingCredit", "availableCredits",
                                       "balance", "remaining", "availableAmount", "remainAmount", "totalSurplusValue", "TotalSurplusValue",
                                       "surplusValue", "SurplusValue", "cycleSurplusValue", "CycleSurplusValue"], in: data)?.double
        let usedKnown = Console.first(["usedQuota", "used_quota", "usedCredits", "usedCredit", "consumedCredits", "usage", "used",
                                       "usedAmount", "consumeAmount", "usedValue", "UsedValue", "consumedValue", "ConsumedValue"],
                                      in: data)?.double
        let reset = Console.first(["nextRefreshTime", "resetTime", "periodEndTime", "billingCycleEnd", "billCycleEndTime", "expireTime",
                                   "expirationTime", "endTime", "validEndTime", "instanceEndTime", "EndTime", "cycleEndTime",
                                   "CycleEndTime", "nearestExpireDate", "NearestExpireDate"], in: data)?.date
        guard let total, total > 0 else {
            if count == 0 { return ProviderUsage(fetchedAt: now) }
            throw ProviderError.parse("Alibaba returned no token plan quota.")
        }
        let used = min(max(usedKnown ?? max(0, total - (remaining ?? total)), 0), total)
        let window = UsageWindow.amounts(id: "credits", title: "Credits", used: used, limit: total, resetsAt: reset,
                                         windowMinutes: 43200, unit: "credits")
        return ProviderUsage(windows: window.map { [$0] } ?? [], plan: "TOKEN PLAN", fetchedAt: now)
    }

    /// Personal (solo) plan: usage ratios 0...1, plus optional plan code and credit totals.
    static func mapPersonal(usage: JSON, subscription: JSON?, quotaConfig: JSON?, now: Date = Date()) throws -> ProviderUsage {
        guard let node = Console.find(["per5HourPercentage", "per1WeekPercentage", "per1MonthPercentage"], in: Console.expand(usage.raw)) else {
            throw ProviderError.parse("Alibaba returned no personal token plan usage.")
        }
        let stats = JSON(node)
        let planNode = Console.find(["specCode", "spec_code", "planName", "plan_name"], in: Console.expand(subscription?.raw))
        let code = ["specCode", "spec_code", "planName", "plan_name"].lazy.compactMap { JSON(planNode)[$0].string }.first?.lowercased()
        let totals = code.flatMap { Console.find([$0], in: Console.expand(quotaConfig?.raw)) }.map { JSON($0)[code ?? ""] }
        let slots: [(String, String, String, [String], Int)] = [
            ("session", "Session", "per5Hour", ["five_hour", "fiveHour"], 300),
            ("weekly", "Weekly", "per1Week", ["weekly"], 10080),
            ("monthly", "Monthly", "per1Month", ["monthly"], 43200),
        ]
        var windows: [UsageWindow] = []
        for (id, title, prefix, totalKeys, minutes) in slots {
            guard let ratio = stats[prefix + "Percentage"].double else { continue }
            let credits = totals.flatMap { Console.first(totalKeys, in: $0)?.double }
            windows.append(UsageWindow(id: id, title: title, usedPercent: min(max(ratio, 0), 1) * 100,
                                       resetsAt: stats[prefix + "ResetTime"].date, windowMinutes: minutes,
                                       detail: credits.map { "\(Fmt.number($0 * min(max(ratio, 0), 1))) / \(Fmt.number($0)) credits" }))
        }
        let plan = code.map { ["lite", "standard", "pro", "max"].contains($0) ? $0.capitalized : $0 } ?? "Personal"
        return ProviderUsage(windows: windows, plan: plan, fetchedAt: now)
    }
}
