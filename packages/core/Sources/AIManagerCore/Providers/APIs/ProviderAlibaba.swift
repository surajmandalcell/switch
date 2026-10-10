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
            let cookie = credential["cookie"]
            guard cookie != nil || credential["apiKey"] != nil else {
                throw ProviderError.missingCredential("Add a console Cookie header or an API key for Alibaba Coding Plan.")
            }
            func run(_ cn: Bool) async throws -> ProviderUsage {
                if let cookie { return try await AlibabaUsage.fetchCookie(cookie, cn: cn) }
                return try await AlibabaUsage.fetchKey(credential["apiKey"] ?? "", cn: cn)
            }
            if credential["region"]?.lowercased() == "cn" { return try await run(true) }
            do {
                return try await run(false)
            } catch where AlibabaUsage.retryOnChina(error) {
                // Some accounts live on the China console.
                return try await run(true)
            }
        })
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

    /// Credential, host, or empty-plan failures on the international console that the China console may still answer.
    static func retryOnChina(_ error: Error) -> Bool {
        switch error as? ProviderError {
        case .unauthorized, .parse: true
        case .http(let code, _): code == 404
        default: false
        }
    }

    static func fetchKey(_ key: String, cn: Bool) async throws -> ProviderUsage {
        let s = site(cn: cn)
        let url = "\(s.gateway)/data/api.json?action=\(api)&product=broadscope-bailian&api=queryCodingPlanInstanceInfoV2&currentRegionId=\(s.region)"
        let headers = ["Authorization": "Bearer \(key)", "x-api-key": key, "X-DashScope-API-Key": key,
                       "User-Agent": OneConsole.userAgent, "Origin": s.gateway, "Referer": s.dashboard]
        return try map(try await HTTP.json(url, headers: headers,
                                           object: ["queryCodingPlanInstanceInfoRequest": ["commodityCode": s.commodity]]),
                       apiKey: true)
    }

    static func fetchCookie(_ cookie: String, cn: Bool) async throws -> ProviderUsage {
        let s = site(cn: cn)
        guard let token = await OneConsole.secToken(cookie: cookie, dashboard: s.dashboard, gateway: s.gateway, csrf: false) else {
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
                       "X-Requested-With": "XMLHttpRequest", "User-Agent": OneConsole.userAgent,
                       "Origin": s.gateway, "Referer": s.dashboard]
        if let csrf { headers["x-xsrf-token"] = csrf; headers["x-csrf-token"] = csrf }
        let url = "\(s.rpc)/data/api.json?action=\(s.rpcAction)&product=sfm_bailian&api=\(api)&_v=undefined"
        let body = HTTP.form(["params": paramsText, "region": s.region, "sec_token": token])
        return try map(try await HTTP.json(url, method: "POST", headers: headers, body: body))
    }

    private static let instanceKeys = ["codingPlanInstanceInfos", "coding_plan_instance_infos"]
    private static let quotaKeys = ["codingPlanQuotaInfo", "coding_plan_quota_info"]

    /// Maps the instance-info response; embedded JSON strings are expanded first. The active
    /// instance wins, its quota is never borrowed from another one, and a plan that is provably
    /// active but exposes no counters still shows its name.
    static func map(_ json: JSON, now: Date = Date(), apiKey: Bool = false) throws -> ProviderUsage {
        guard let root = OneConsole.expand(json.raw) as? [String: Any] else {
            throw ProviderError.parse("Alibaba returned an unexpected payload.")
        }
        try check(root, apiKey: apiKey)

        let instances = (OneConsole.first(instanceKeys, in: root) { $0 as? [Any] } ?? []).compactMap { $0 as? [String: Any] }
        var best: [String: Any]?
        var bestScore = Int.min
        for item in instances where score(item, now) > bestScore {
            best = item
            bestScore = score(item, now)
        }
        let active = bestScore > 0 ? best : instances.first
        let scoped = instances.count > 1 && (active.map { score($0, now) > 0 } ?? false)
        let own = active.flatMap { findQuota($0) }
        let quota = scoped ? own : (own ?? findQuota(root))
        let plan = active.flatMap { planName(in: $0) } ?? planName(in: root)

        /// Plan name alone, when the payload proves the plan is active.
        func planOnly(_ failure: String) throws -> ProviderUsage {
            let source = active ?? root
            let proof = instances.isEmpty ? score(source, now) > 0 || score(root, now) > 0 : score(source, now) > 0
            guard proof, let name = planName(in: source) ?? planName(in: root) else { throw ProviderError.parse(failure) }
            return ProviderUsage(plan: name, fetchedAt: now)
        }
        guard let quota else { return try planOnly("Alibaba returned no coding plan quota.") }

        let slots: [(String, String, [String], Int)] = [
            ("session", "Session", ["per5Hour", "perFiveHour"], 300),
            ("weekly", "Weekly", ["perWeek"], 10080),
            ("monthly", "Monthly", ["perBillMonth", "perMonth"], 43200),
        ]
        func read(_ prefixes: [String], _ suffix: String) -> Any? { prefixes.lazy.compactMap { quota[$0 + suffix] }.first }
        guard slots.contains(where: { OneConsole.int(read($0.2, "TotalQuota")) != nil }) else {
            return try planOnly("Alibaba returned no coding plan quota windows.")
        }
        var windows: [UsageWindow] = []
        for (id, title, prefixes, minutes) in slots {
            guard let total = OneConsole.int(read(prefixes, "TotalQuota")).map(Double.init), total > 0 else { continue }
            var reset = OneConsole.date(read(prefixes, "QuotaNextRefreshTime"))
            if id == "session", var date = reset, date.timeIntervalSince(now) < 60 {
                date = date.addingTimeInterval(18000)
                reset = date.timeIntervalSince(now) < 60 ? now.addingTimeInterval(18000) : date
            }
            let used = min(max(Double(OneConsole.int(read(prefixes, "UsedQuota")) ?? 0), 0), total)
            windows.append(UsageWindow(id: id, title: title, usedPercent: used / total * 100, resetsAt: reset,
                                       windowMinutes: minutes, detail: "\(Fmt.number(used)) / \(Fmt.number(total)) requests"))
        }
        return ProviderUsage(windows: windows, plan: plan, fetchedAt: now)
    }

    /// Error shapes the console wraps in a 200 answer.
    private static func check(_ root: [String: Any], apiKey: Bool) throws {
        func str(_ keys: [String]) -> String? { OneConsole.first(keys, in: root, OneConsole.string) }
        if let status = OneConsole.first(["statusCode", "status_code", "code"], in: root, OneConsole.int), status != 0, status != 200 {
            let message = str(["statusMessage", "status_msg", "message", "msg"]) ?? "status code \(status)"
            let lower = message.lowercased()
            if status == 401 || status == 403 || lower.contains("api key") || lower.contains("unauthorized") {
                throw ProviderError.unauthorized("Alibaba rejected this credential. Paste a fresh Cookie header or key.")
            }
            throw ProviderError.http(status, "Alibaba returned an error: \(message)")
        }
        let consoleOnly: ProviderError = apiKey
            ? .unsupported("Alibaba Coding Plan quota is not available through API keys for this account or region. Paste a console Cookie header instead.")
            : .unauthorized("Alibaba Coding Plan console login is required. Paste a fresh Cookie header from the console.")
        if str(["code", "status", "statusCode"])?.lowercased().contains("login") == true { throw consoleOnly }
        if let message = str(["message", "msg", "statusMessage"])?.lowercased() {
            if message.contains("log in") || message.contains("login") { throw consoleOnly }
            if apiKey, message.contains("console session") || message.contains("api key mode may be unavailable") { throw consoleOnly }
        }
    }

    /// The named quota object (dictionaries only), else the first object that holds a quota counter.
    private static func findQuota(_ value: Any?) -> [String: Any]? {
        OneConsole.first(quotaKeys, in: value, arrays: false, OneConsole.dict)
            ?? OneConsole.find(["per5HourUsedQuota", "per5HourTotalQuota", "perWeekUsedQuota", "perWeekTotalQuota",
                                "perBillMonthUsedQuota", "perBillMonthTotalQuota"], in: value)
    }

    private static func planName(in payload: Any?) -> String? {
        if let infos = OneConsole.first(instanceKeys, in: payload, { $0 as? [Any] }) {
            for case let info as [String: Any] in infos {
                let keys = ["planName", "plan_name", "instanceName", "instance_name", "packageName", "package_name"]
                if let name = keys.lazy.compactMap({ OneConsole.string(info[$0]) }).first { return name }
            }
        }
        return OneConsole.first(["planName", "plan_name", "packageName", "package_name"], in: payload, OneConsole.string)
    }

    /// Ranks plan instances so the live one wins when several are returned.
    private static func score(_ item: [String: Any], _ now: Date) -> Int {
        let status = ["status", "instanceStatus"].lazy.compactMap { OneConsole.string(item[$0]) }.first?.uppercased() ?? ""
        if ["VALID", "ACTIVE"].contains(status) { return 3 }
        if ["EXPIRED", "INVALID", "INACTIVE", "DISABLED", "TERMINATED", "STOPPED"].contains(status) { return -1 }
        if let active = ["isActive", "active"].lazy.compactMap({ OneConsole.bool(item[$0]) }).first { return active ? 3 : -1 }
        let end = ["endTime", "periodEndTime", "expireTime", "expirationTime"].lazy.compactMap { OneConsole.date(item[$0]) }.first
        return end.map { $0 > now ? 1 : 0 } ?? 0
    }
}
