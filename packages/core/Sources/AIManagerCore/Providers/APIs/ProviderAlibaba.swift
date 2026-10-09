import Foundation

extension ProviderCatalog {
    static let alibaba = ProviderSpec(
        id: "alibaba", name: "Alibaba Coding Plan",
        fields: [
            CredentialField("apiKey", "API key", optional: true,
                            placeholder: "Often rejected by the console. Prefer the Cookie header.",
                            env: ["ALIBABA_CODING_PLAN_API_KEY", "ALIBABA_QWEN_API_KEY", "DASHSCOPE_API_KEY"]),
            CredentialField("cookie", "Cookie header", optional: true,
                            placeholder: "login_aliyunid_ticket, login_aliyunid_csrf, cna from the console",
                            env: ["ALIBABA_CODING_PLAN_COOKIE"]),
            CredentialField("region", "Region", secure: false, optional: true, placeholder: "intl or cn"),
        ],
        dashboard: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan#/efm/coding_plan",
        statusPage: nil,
        usage: { credential in
            let cn = credential["region"]?.lowercased() == "cn"
            if let cookie = credential["cookie"] { return try await AlibabaUsage.fetchCookie(cookie, cn: cn) }
            guard let key = credential["apiKey"] else {
                throw ProviderError.missingCredential("Add a console Cookie header or an API key for Alibaba Coding Plan.")
            }
            do {
                return try await AlibabaUsage.fetchKey(key, cn: cn)
            } catch let error as ProviderError where error.needsSignIn && !cn {
                // Some accounts live on the China console.
                if let usage = try? await AlibabaUsage.fetchKey(key, cn: true) { return usage }
                throw error
            }
        })
}

private enum Console {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36"

    /// Replaces every string value that holds JSON with its parsed value.
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

    /// First dictionary, depth first, that holds any of the keys.
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
        let patterns = [#"SEC_TOKEN\s*:\s*"([^"]+)""#, #""secToken"\s*:\s*"([^"]+)""#, #""sec_token"\s*:\s*"([^"]+)""#,
                        #"secToken['"]?\s*[:=]\s*['"]([^'"]+)['"]"#, #"sec_token['"]?\s*[:=]\s*['"]([^'"]+)['"]"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            return String(html[range])
        }
        return nil
    }

    /// Dashboard HTML first, then the `sec_token` cookie, then the user-info endpoint.
    static func secToken(cookie: String, dashboard: String, gateway: String) async -> String? {
        if let page = try? await HTTP.send(dashboard, headers: ["Accept": "text/html,application/xhtml+xml", "Cookie": cookie]),
           page.status == 200, let token = scrapeToken(page.text) { return token }
        if let token = Fmt.cookie("sec_token", in: cookie) { return token }
        guard let info = try? await HTTP.send(gateway + "/tool/user/info.json", headers: ["Cookie": cookie]),
              info.status == 200, let json = try? info.json() else { return nil }
        let node = find(["secToken", "sec_token", "csrfToken"], in: expand(json.raw))
        return ["secToken", "sec_token", "csrfToken"].lazy.compactMap { JSON(node)[$0].string }.first
    }
}

enum AlibabaUsage {
    private struct Site {
        let gateway: String, dashboard: String, rpc: String, rpcAction: String
        let region: String, commodity: String, domain: String, site: String
    }

    private static func site(cn: Bool) -> Site {
        cn ? Site(gateway: "https://bailian.console.aliyun.com",
                  dashboard: "https://bailian.console.aliyun.com/cn-beijing/?tab=model#/efm/coding_plan",
                  rpc: "https://bailian-cs.console.aliyun.com", rpcAction: "BroadScopeAspnGateway",
                  region: "cn-beijing", commodity: "sfm_codingplan_public_cn",
                  domain: "bailian.console.aliyun.com", site: "BAILIAN_ALIYUN")
           : Site(gateway: "https://modelstudio.console.alibabacloud.com",
                  dashboard: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan#/efm/coding_plan",
                  rpc: "https://bailian-singapore-cs.alibabacloud.com", rpcAction: "IntlBroadScopeAspnGateway",
                  region: "ap-southeast-1", commodity: "sfm_codingplan_public_intl",
                  domain: "modelstudio.console.alibabacloud.com", site: "MODELSTUDIO_ALIBABACLOUD")
    }

    private static let api = "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2"

    static func fetchKey(_ key: String, cn: Bool) async throws -> ProviderUsage {
        let s = site(cn: cn)
        let url = "\(s.gateway)/data/api.json?action=\(api)&product=broadscope-bailian&api=queryCodingPlanInstanceInfoV2&currentRegionId=\(s.region)"
        let headers = ["Authorization": "Bearer \(key)", "x-api-key": key, "X-DashScope-API-Key": key,
                       "User-Agent": Console.userAgent, "Origin": s.gateway, "Referer": s.dashboard]
        return try map(try await HTTP.json(url, headers: headers,
                                           object: ["queryCodingPlanInstanceInfoRequest": ["commodityCode": s.commodity]]))
    }

    static func fetchCookie(_ cookie: String, cn: Bool) async throws -> ProviderUsage {
        let s = site(cn: cn)
        guard let token = await Console.secToken(cookie: cookie, dashboard: s.dashboard, gateway: s.gateway) else {
            throw ProviderError.unauthorized("Alibaba sign-in expired. Paste a fresh Cookie header from the console.")
        }
        let params: [String: Any] = [
            "Api": api, "V": "1.0",
            "Data": [
                "queryCodingPlanInstanceInfoRequest": ["commodityCode": s.commodity, "onlyLatestOne": true],
                "cornerstoneParam": [
                    "feTraceId": UUID().uuidString.lowercased(), "feURL": s.dashboard, "protocol": "V2",
                    "console": "ONE_CONSOLE", "productCode": "p_efm", "domain": s.domain, "consoleSite": s.site,
                    "userNickName": "", "userPrincipalName": "", "xsp_lang": "en-US",
                    "X-Anonymous-Id": Fmt.cookie("cna", in: cookie) ?? "",
                ],
            ],
        ]
        let paramsText = String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self)
        let csrf = Fmt.cookie("login_aliyunid_csrf", in: cookie) ?? Fmt.cookie("csrf", in: cookie)
        var headers = ["Content-Type": "application/x-www-form-urlencoded", "Accept": "*/*", "Cookie": cookie,
                       "X-Requested-With": "XMLHttpRequest", "User-Agent": Console.userAgent,
                       "Origin": s.gateway, "Referer": s.dashboard]
        if let csrf { headers["x-xsrf-token"] = csrf; headers["x-csrf-token"] = csrf }
        let url = "\(s.rpc)/data/api.json?action=\(s.rpcAction)&product=sfm_bailian&api=\(api)&_v=undefined"
        let body = HTTP.form(["params": paramsText, "region": s.region, "sec_token": token])
        return try map(try await HTTP.json(url, method: "POST", headers: headers, body: body))
    }

    /// Maps the instance-info response; embedded JSON strings are expanded first.
    static func map(_ json: JSON, now: Date = Date()) throws -> ProviderUsage {
        let root = JSON(Console.expand(json.raw))
        for key in ["statusCode", "status_code", "code"] {
            guard let code = root[key].string, !["0", "200"].contains(code) else { continue }
            let lower = code.lowercased() + " " + (root["message"].string ?? "").lowercased()
            if lower.contains("login") || lower.contains("401") || lower.contains("403") || lower.contains("unauthorized")
                || lower.contains("api key") {
                throw ProviderError.unauthorized("Alibaba rejected this credential. Paste a fresh Cookie header or key.")
            }
            throw ProviderError.parse("Alibaba returned error code \(code).")
        }
        let instances = Console.find(["codingPlanInstanceInfos"], in: root.raw)?["codingPlanInstanceInfos"] as? [Any] ?? []
        let active = instances.max { score($0, now) < score($1, now) }
        let scope = active.flatMap { Console.find(["codingPlanQuotaInfo", "coding_plan_quota_info"], in: $0) }
        let found = scope ?? Console.find(["codingPlanQuotaInfo", "coding_plan_quota_info"], in: root.raw)
        let quota = (found?["codingPlanQuotaInfo"] ?? found?["coding_plan_quota_info"]).map { JSON($0) }
            ?? Console.find(["per5HourUsedQuota", "perFiveHourUsedQuota", "perWeekUsedQuota", "perBillMonthUsedQuota",
                             "perMonthUsedQuota", "per5HourTotalQuota", "perWeekTotalQuota", "perBillMonthTotalQuota"],
                            in: root.raw).map { JSON($0) }

        var plan: String?
        for item in (active.map { [$0] } ?? []) + instances {
            plan = ["planName", "plan_name", "instanceName", "instance_name", "packageName", "package_name"]
                .lazy.compactMap { JSON(item)[$0].string }.first
            if plan != nil { break }
        }
        plan = plan ?? root.at("data.planName").string ?? root.at("data.packageName").string ?? root["planName"].string

        var windows: [UsageWindow] = []
        if let quota {
            let slots: [(String, String, [String], Int)] = [
                ("session", "Session", ["per5Hour", "perFiveHour"], 300),
                ("weekly", "Weekly", ["perWeek"], 10080),
                ("monthly", "Monthly", ["perBillMonth", "perMonth"], 43200),
            ]
            for (id, title, prefixes, minutes) in slots {
                func read(_ suffix: String) -> JSON { prefixes.map { quota[$0 + suffix] }.first { $0.exists } ?? JSON(nil) }
                guard let total = read("TotalQuota").double, total > 0 else { continue }
                var reset = read("QuotaNextRefreshTime").date
                if id == "session", var date = reset, date.timeIntervalSince(now) < 60 {
                    date = date.addingTimeInterval(18000)
                    reset = date.timeIntervalSince(now) < 60 ? now.addingTimeInterval(18000) : date
                }
                let used = min(read("UsedQuota").double ?? 0, total)
                windows.append(UsageWindow(id: id, title: title, usedPercent: used / total * 100, resetsAt: reset,
                                           windowMinutes: minutes, detail: "\(Fmt.number(used)) / \(Fmt.number(total)) requests"))
            }
        }
        guard !windows.isEmpty || plan != nil else { throw ProviderError.parse("Alibaba returned no coding plan quota.") }
        return ProviderUsage(windows: windows, plan: plan, fetchedAt: now)
    }

    /// Ranks plan instances so the live one wins when several are returned.
    private static func score(_ instance: Any, _ now: Date) -> Int {
        let item = JSON(instance)
        var score = 0
        switch (item["status"].string ?? "").uppercased() {
        case "VALID", "ACTIVE": score += 3
        case "EXPIRED", "INVALID", "INACTIVE", "CLOSED", "RELEASED": score -= 1
        default: break
        }
        if item["isActive"].bool == true || item["active"].bool == true { score += 1 }
        let end = ["endTime", "periodEndTime", "expireTime", "expirationTime"].lazy.compactMap { item[$0].date }.first
        if let end, end > now { score += 1 }
        return score
    }
}
