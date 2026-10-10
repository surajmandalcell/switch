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

/// Shared Aliyun OneConsole helpers for Alibaba Coding Plan, Alibaba Token Plan and QwenCloud.
/// Gateway answers nest JSON inside JSON strings and move fields between shapes, so lookups
/// walk the whole tree instead of fixed paths.
enum OneConsole {
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

    /// First value `transform` accepts, checking each dictionary (keys in caller order) before its children.
    static func first<T>(_ keys: [String], in value: Any?, arrays: Bool = true, _ transform: (Any?) -> T?) -> T? {
        if let dict = value as? [String: Any] {
            for key in keys { if let found = transform(dict[key]) { return found } }
            for nested in dict.values { if let found = first(keys, in: nested, arrays: arrays, transform) { return found } }
        } else if arrays, let list = value as? [Any] {
            for nested in list { if let found = first(keys, in: nested, arrays: arrays, transform) { return found } }
        }
        return nil
    }

    /// First dictionary, depth first, that holds any of the keys.
    static func find(_ keys: [String], in value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if dict.keys.contains(where: keys.contains) { return dict }
            for nested in dict.values { if let found = find(keys, in: nested) { return found } }
        } else if let list = value as? [Any] {
            for nested in list { if let found = find(keys, in: nested) { return found } }
        }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    static func dict(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): number.doubleValue
        case let text as String: Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ""))
        default: nil
        }
    }

    static func int(_ value: Any?) -> Int? { double(value).flatMap { $0.isFinite ? Int($0) : nil } }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        case let text as String:
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "active", "valid", "normal": return true
            case "false", "0", "no", "inactive", "invalid", "expired": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// Epoch seconds or milliseconds, ISO-8601, "yyyy-MM-dd", "yyyy-MM-dd HH:mm" and "yyyy-MM-dd HH:mm:ss".
    /// Numbers at or below `floor` are not dates.
    static func date(_ value: Any?, above floor: Double = 0) -> Date? {
        if let number = double(value) { return number > floor ? Fmt.epoch(number) : nil }
        guard let text = value as? String else { return nil }
        if let date = Fmt.iso(text) { return date }
        let minute = DateFormatter()
        minute.locale = Locale(identifier: "en_US_POSIX")
        minute.dateFormat = "yyyy-MM-dd HH:mm"
        return minute.date(from: text)
    }

    static func scrapeToken(_ html: String, csrf: Bool) -> String? {
        var patterns = [#"SEC_TOKEN['"]?\s*[:=]\s*['"]([^'"]+)['"]"#, #""secToken"\s*:\s*"([^"]+)""#, #""sec_token"\s*:\s*"([^"]+)""#,
                        #"secToken['"]?\s*[:=]\s*['"]([^'"]+)['"]"#, #"sec_token['"]?\s*[:=]\s*['"]([^'"]+)['"]"#]
        if csrf { patterns.append(#"csrfToken['"]?\s*[:=]\s*['"]([^'"]+)['"]"#) }
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            return String(html[range])
        }
        return nil
    }

    /// Dashboard HTML first, then the `sec_token` cookie and the user-info endpoint (cookie second
    /// when `cookieFirst`). Nil means the request goes out without a token.
    static func secToken(cookie: String, dashboard: String, gateway: String, cookieFirst: Bool = false, csrf: Bool = true,
                         infoKeys: [String] = ["secToken", "sec_token"]) async -> String? {
        let page = try? await HTTP.send(dashboard, headers: [
            "Accept": "text/html,application/xhtml+xml", "Cookie": cookie, "User-Agent": userAgent,
            "Referer": gateway + "/", "Sec-Fetch-Site": "same-origin", "Sec-Fetch-Mode": "navigate",
            "Sec-Fetch-Dest": "document", "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"])
        if let page, page.status == 200, let token = scrapeToken(page.text, csrf: csrf) { return token }
        let fromCookie = Fmt.cookie("sec_token", in: cookie)
        if cookieFirst, let fromCookie { return fromCookie }
        if let info = try? await HTTP.send(gateway + "/tool/user/info.json", headers: ["Cookie": cookie, "User-Agent": userAgent,
                                                                                         "Referer": gateway + "/"]),
           info.status == 200, let json = try? info.json() {
            let tree = expand(json.raw)
            if let token = infoKeys.lazy.compactMap({ first([$0], in: tree, string) }).first { return token }
        }
        return fromCookie
    }

    // MARK: Error payloads

    static func loginError(_ brand: String) -> ProviderError {
        .unauthorized("\(brand) sign-in expired. Paste a fresh Cookie header from the console.")
    }

    /// Throws for the failure shapes the gateway wraps in a 200 answer (login, token, forbidden, nested failure).
    static func check(_ root: [String: Any], brand: String) throws {
        func str(_ keys: [String], _ scope: Any? = root) -> String? { first(keys, in: scope, string) }
        func classify(_ code: String?, _ message: String?) -> ProviderError? {
            let text = [code, message].compactMap { $0?.lowercased() }.joined(separator: " ")
            if ["needlogin", "login", "postonlyortokenerror", "tokenerror", "request has expired", "refresh page", "请求已经过期"]
                .contains(where: { text.contains($0) }) { return loginError(brand) }
            // Workspace permission failures are not credential failures.
            if text.contains("workspace.notauthorised") || text.contains("workspace.notauthorized") { return nil }
            if ["notauthorised", "notauthorized", "not authorised", "not authorized", "unauthorised", "unauthorized",
                "access denied", "forbidden"].contains(where: { text.contains($0) }) {
                return .unauthorized("\(brand) rejected this credential. Paste a fresh Cookie header.")
            }
            return nil
        }
        let rejected = ProviderError.unauthorized("\(brand) rejected this credential. Paste a fresh Cookie header.")
        let status = first(["statusCode", "status_code", "code"], in: root, int)
        if bool(root["successResponse"]) == false {
            if status == 401 || status == 403 { throw rejected }
            let code = str(["errorCode", "code", "status", "statusCode"])
            let message = str(["errorMsg", "message", "msg", "statusMessage"]) ?? code ?? "request was not successful"
            throw classify(code, message) ?? .unavailable(message)
        }
        if flags(["Success", "success"], in: root).contains(false) {
            // An outer 200 can wrap a nested frame that carries the real error.
            let frame = failingFrame(in: root) ?? root
            let code = str(["errorCode", "Code", "code"], frame) ?? str(["errorCode", "Code", "code"])
            let message = str(["errorMsg", "Message", "message", "msg"], frame)
                ?? str(["errorMsg", "Message", "message", "msg", "Code", "code"]) ?? "request was not successful"
            throw classify(code, message) ?? .unavailable(message)
        }
        if let status, status != 0, status != 200 {
            if status == 401 || status == 403 { throw rejected }
            throw ProviderError.unavailable(str(["statusMessage", "status_msg", "message", "msg"]) ?? "status code \(status)")
        }
        if let error = classify(str(["errorCode", "code", "status", "statusCode"]),
                                str(["errorMsg", "message", "msg", "statusMessage"])) { throw error }
    }

    private static func flags(_ keys: [String], in value: Any?) -> [Bool] {
        if let dict = value as? [String: Any] {
            return keys.compactMap { bool(dict[$0]) } + dict.values.flatMap { flags(keys, in: $0) }
        }
        return (value as? [Any])?.flatMap { flags(keys, in: $0) } ?? []
    }

    private static func failingFrame(in value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if bool(dict["success"]) == false || bool(dict["Success"]) == false { return dict }
            for nested in dict.values { if let found = failingFrame(in: nested) { return found } }
        } else if let list = value as? [Any] {
            for nested in list { if let found = failingFrame(in: nested) { return found } }
        }
        return nil
    }

    // MARK: Personal (Solo, Individual) token plan

    /// Rolling windows from the `personal/api/v2/usage` ratios (0...1), with tier credit totals from
    /// `subscription` and `quota-config`. Nil when the payload holds no window.
    static func personal(usage: Any?, subscription: Any?, quotaConfig: Any?, defaultPlan: String?, now: Date) -> ProviderUsage? {
        guard let stats = find(["per5HourPercentage", "per1WeekPercentage", "per1MonthPercentage"], in: usage) else { return nil }
        let planKeys = ["specCode", "spec_code", "planName", "plan_name"]
        let code = find(planKeys, in: subscription).flatMap { node in
            planKeys.lazy.compactMap { string(node[$0])?.lowercased() }.first
        }
        let totals = code.flatMap { first([$0], in: quotaConfig) { dict($0) } }
        let slots: [(String, String, String, [String], Int)] = [
            ("session", "Session", "per5Hour", ["five_hour", "fiveHour"], 300),
            ("weekly", "Weekly", "per1Week", ["weekly"], 10080),
            ("monthly", "Monthly", "per1Month", ["monthly"], 43200),
        ]
        var windows: [UsageWindow] = []
        for (id, title, prefix, totalKeys, minutes) in slots {
            guard let ratio = double(stats[prefix + "Percentage"]), ratio.isFinite else { continue }
            let used = min(max(ratio, 0), 1)
            let total = totals.flatMap { node in totalKeys.lazy.compactMap { double(node[$0]) }.first }
            windows.append(UsageWindow(id: id, title: title, usedPercent: used * 100, resetsAt: date(stats[prefix + "ResetTime"]),
                                       windowMinutes: minutes,
                                       detail: total.map { "\(Fmt.number($0 * used)) / \(Fmt.number($0)) credits" }))
        }
        guard !windows.isEmpty else { return nil }
        let plan = code.map { ["lite", "standard", "pro", "max"].contains($0) ? $0.capitalized : $0 } ?? defaultPlan
        return ProviderUsage(windows: windows, plan: plan, fetchedAt: now)
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
                       "X-Requested-With": "XMLHttpRequest", "User-Agent": OneConsole.userAgent,
                       "Origin": s.gateway, "Referer": s.dashboard]
        if let csrf { headers["x-xsrf-token"] = csrf; headers["x-csrf-token"] = csrf }
        let response = try await HTTP.send(url, method: "POST", headers: headers, body: HTTP.form(form))
        try HTTP.check(response)
        guard let json = try? response.json() else {
            let page = response.text.lowercased()
            if page.contains("<html"), ["login", "sign in", "signin"].contains(where: { page.contains($0) }) {
                throw OneConsole.loginError("Alibaba")
            }
            throw ProviderError.parse("Alibaba returned data that is not JSON.")
        }
        return json
    }

    static func fetch(cookie: String, cn: Bool, personal: Bool) async throws -> ProviderUsage {
        let s = site(cn: cn, personal: personal)
        // Some accounts get a workspace error without the token, so a missing one is not fatal.
        let token = await OneConsole.secToken(cookie: cookie, dashboard: s.dashboard, gateway: s.gateway)
        if !personal {
            let params = String(decoding: try JSONSerialization.data(withJSONObject: ["ProductCode": s.team]), as: UTF8.self)
            var form = ["product": "BssOpenAPI-V3", "action": "GetSubscriptionSummary", "params": params, "region": s.region]
            if let token { form["sec_token"] = token }
            return try mapTeam(try await post("\(s.gateway)/data/api.json?action=GetSubscriptionSummary&product=BssOpenAPI-V3&_tag=",
                                              cookie: cookie, site: s, accept: "*/*", form: form))
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
        let subscription = try? await call(base + "subscription", ["commodityCode": s.solo])
        let quotaConfig = try? await call(base + "quota-config", [:])
        // The usage call sometimes answers 200 with no windows; retry a few times.
        for attempt in 0...2 {
            do {
                return try mapPersonal(usage: try await call(base + "usage", [:]), subscription: subscription, quotaConfig: quotaConfig)
            } catch ProviderError.unavailable(let message) where message == pending && attempt < 2 {
                try await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        throw ProviderError.unavailable(pending)
    }

    static let pending = "Alibaba token plan usage is temporarily unavailable. It will refresh on the next check."

    private static let usedKeys = ["usedQuota", "used_quota", "usedCredits", "usedCredit", "consumedCredits", "usage", "used", "usedAmount",
                                   "consumeAmount", "usedValue", "UsedValue", "consumedValue", "ConsumedValue"]
    private static let totalKeys = ["totalQuota", "total_quota", "totalCredits", "totalCredit", "quota", "creditLimit", "creditsTotal",
                                    "monthlyTotalQuota", "amount", "totalValue", "TotalValue", "cycleTotalValue", "CycleTotalValue"]
    private static let remainingKeys = ["remainingQuota", "remainQuota", "remainingCredits", "remainingCredit", "availableCredits", "balance",
                                        "remaining", "availableAmount", "remainAmount", "totalSurplusValue", "TotalSurplusValue", "surplusValue",
                                        "SurplusValue", "cycleSurplusValue", "CycleSurplusValue"]
    private static let countKeys = ["totalCount", "TotalCount", "subscriptionTotalNumber", "SubscriptionTotalNumber"]
    private static let resetKeys = ["nextRefreshTime", "resetTime", "periodEndTime", "billingCycleEnd", "billCycleEndTime", "expireTime",
                                    "expirationTime", "endTime", "validEndTime", "instanceEndTime", "EndTime", "cycleEndTime", "CycleEndTime",
                                    "nearestExpireDate", "NearestExpireDate"]
    private static let planKeys = ["planName", "plan_name", "packageName", "package_name", "commodityName", "commodity_name", "specType",
                                   "SpecType", "instanceName", "instance_name", "displayName", "display_name", "ProductName", "productName",
                                   "name", "title", "planType", "plan_type"]

    /// The dictionary that holds the subscription numbers, which a Team answer may nest under an equity list.
    private static func summary(_ root: [String: Any]) -> [String: Any]? {
        let quota = usedKeys + totalKeys + remainingKeys
        if let data = OneConsole.first(["Data", "data", "successResponse", "success_response"], in: root, OneConsole.dict),
           (quota + countKeys).contains(where: { data[$0] != nil }) {
            return quota.contains(where: { data[$0] != nil }) ? data : OneConsole.find(quota, in: data) ?? data
        }
        return OneConsole.find(quota + countKeys, in: root)
    }

    /// `GetSubscriptionSummary` for Team plans (also QwenCloud's older summary shape): one credit pool.
    static func mapTeam(_ json: JSON, now: Date = Date(), brand: String = "Alibaba") throws -> ProviderUsage {
        guard let root = OneConsole.expand(json.raw) as? [String: Any] else {
            throw ProviderError.parse("\(brand) returned an unexpected token plan payload.")
        }
        try OneConsole.check(root, brand: brand)
        let data = summary(root) ?? root
        func number(_ keys: [String]) -> Double? { keys.lazy.compactMap { OneConsole.double(data[$0]) }.first }
        let total = number(totalKeys)
        let remaining = number(remainingKeys)
        let used = number(usedKeys) ?? total.flatMap { total in remaining.map { max(0, total - $0) } }
        func deepDate(_ scope: Any?) -> Date? { OneConsole.first(resetKeys, in: scope) { OneConsole.date($0, above: 1_000_000_000) } }
        let reset = resetKeys.lazy.compactMap { OneConsole.date(data[$0]) }.first ?? deepDate(data) ?? deepDate(root)
        let count = number(countKeys)
        let plan = OneConsole.first(planKeys, in: data, OneConsole.string) ?? ((count ?? 0) > 0 || total != nil ? "TOKEN PLAN" : nil)
        if plan == nil, total == nil, used == nil, remaining == nil, count == nil {
            throw ProviderError.parse("\(brand) returned no token plan data.")
        }
        var windows: [UsageWindow] = []
        if let total, total > 0, let used,
           let window = UsageWindow.amounts(id: "credits", title: "Credits", used: min(max(used, 0), total), limit: total,
                                            resetsAt: reset, windowMinutes: 43200, unit: "credits") {
            windows.append(window)
        }
        return ProviderUsage(windows: windows, plan: plan, fetchedAt: now)
    }

    /// Personal (solo) plan: usage ratios 0...1, plus optional plan code and credit totals.
    static func mapPersonal(usage: JSON, subscription: JSON?, quotaConfig: JSON?, now: Date = Date()) throws -> ProviderUsage {
        let expanded = OneConsole.expand(usage.raw)
        if let root = expanded as? [String: Any] { try OneConsole.check(root, brand: "Alibaba") }
        guard let result = OneConsole.personal(usage: expanded, subscription: OneConsole.expand(subscription?.raw),
                                               quotaConfig: OneConsole.expand(quotaConfig?.raw), defaultPlan: "Personal", now: now) else {
            throw ProviderError.unavailable(pending)
        }
        return result
    }
}
