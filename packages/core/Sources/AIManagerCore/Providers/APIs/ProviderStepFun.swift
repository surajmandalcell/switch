import Foundation

extension ProviderCatalog {
    static let stepfun = ProviderSpec(
        id: "stepfun", name: "StepFun",
        fields: [
            CredentialField("token", "Oasis-Token", optional: true,
                            placeholder: "Oasis-Token value or a Cookie header with Oasis-Token=",
                            env: ["STEPFUN_TOKEN"]),
            CredentialField("username", "Username", secure: false, optional: true, env: ["STEPFUN_USERNAME"]),
            CredentialField("password", "Password", optional: true, env: ["STEPFUN_PASSWORD"]),
        ],
        dashboard: "https://platform.stepfun.com/plan-usage",
        fetch: { credential in
            var token = credential["token"].map(StepFunUsage.normalize)
            let user = credential["username"], password = credential["password"]
            var fresh = false
            if token == nil {
                guard let user, let password else {
                    throw ProviderError.missingCredential("Add an Oasis-Token, or a username and password, for StepFun.")
                }
                token = try await StepFunUsage.login(user: user, password: password)
                fresh = true
            }
            do {
                return FetchResult(try await StepFunUsage.fetch(token: token!), updated: fresh ? StepFunUsage.stored(credential, token!) : nil)
            } catch let error as ProviderError where error.needsSignIn && !fresh {
                // Expired token: sign in again when a password is saved.
                guard let user, let password else { throw error }
                let relogin = try await StepFunUsage.login(user: user, password: password)
                return FetchResult(try await StepFunUsage.fetch(token: relogin), updated: StepFunUsage.stored(credential, relogin))
            }
        })
}

enum StepFunUsage {
    private static let host = "https://platform.stepfun.com"
    private static let defaultWebID = "c8a1002d2c457e758785a9979832217c7c0b884c"

    /// Accepts a bare token, an `access...refresh` pair, or a Cookie header with `Oasis-Token=`.
    static func normalize(_ raw: String) -> String {
        guard let range = raw.range(of: "Oasis-Token=") else { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        return raw[range.upperBound...].prefix { $0 != ";" }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The server requires `Oasis-Webid` to equal the `device_id` claim inside the token.
    static func webID(_ token: String) -> String {
        token.components(separatedBy: "...").reversed().lazy.compactMap { Fmt.jwtClaims($0)?["device_id"].string }.first
            ?? defaultWebID
    }

    fileprivate static func stored(_ credential: ProviderCredential, _ token: String) -> ProviderCredential {
        var copy = credential
        copy.fields["token"] = token
        return copy
    }

    private static func headers(webid: String, cookie: String) -> [String: String] {
        ["oasis-appid": "10300", "oasis-platform": "web", "oasis-webid": webid, "Cookie": cookie]
    }

    private static func post(_ path: String, _ headers: [String: String], _ body: [String: String] = [:]) async throws -> JSON {
        try await HTTP.json(host + path, headers: headers, object: body)
    }

    static func fetch(token: String) async throws -> ProviderUsage {
        let webid = webID(token)
        let head = headers(webid: webid, cookie: "Oasis-Token=\(token); Oasis-Webid=\(webid)")
        let json = try await post("/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit", head)
        let plan = try? await post("/api/step.openapi.devcenter.Dashboard/GetStepPlanStatus", head)
        return try map(json, plan: plan?.at("subscription.name").string)
    }

    /// Anonymous device registration, then password sign-in. Returns an `access...refresh` pair.
    static func login(user: String, password: String) async throws -> String {
        let home = try await HTTP.send(host, headers: headers(webid: defaultWebID, cookie: ""))
        guard let ingress = home.headers["set-cookie"]?.components(separatedBy: "INGRESSCOOKIE=").dropFirst().first?
            .prefix(while: { $0 != ";" && $0 != "," }) else {
            throw ProviderError.unavailable("StepFun sign-in could not start. Try again later.")
        }
        func pair(_ json: JSON) throws -> String {
            guard let access = json.at("accessToken.raw").string else {
                throw ProviderError.unauthorized("StepFun sign-in failed. Check the username and password.")
            }
            return json.at("refreshToken.raw").string.map { "\(access)...\($0)" } ?? access
        }
        let path = "/passport/proto.api.passport.v1.PassportService/"
        let anon = try pair(try await post(path + "RegisterDevice", headers(webid: defaultWebID, cookie: "INGRESSCOOKIE=\(ingress)")))
        let webid = webID(anon)
        return try pair(try await post(path + "SignInByPassword",
                                       headers(webid: webid, cookie: "Oasis-Token=\(anon); Oasis-Webid=\(webid); INGRESSCOOKIE=\(ingress)"),
                                       ["username": user, "password": password]))
    }

    static func map(_ json: JSON, plan: String? = nil, now: Date = Date()) throws -> ProviderUsage {
        guard json["status"].int == 1 else {
            let message = (json["message"].string ?? json["desc"].string ?? "").lowercased()
            if ["unauthorized", "token", "login", "embezzled"].contains(where: message.contains) {
                throw ProviderError.unauthorized("StepFun rejected this token. Paste a new Oasis-Token.")
            }
            throw ProviderError.parse("StepFun returned an error.")
        }
        func epoch(_ key: String, in node: JSON) -> Date? { node[key].double.flatMap(Fmt.epoch) }
        func used(_ left: Double?) -> Double? { left.map { (1 - $0) * 100 } }
        let fiveReset = epoch("five_hour_usage_reset_time", in: json), weekReset = epoch("weekly_usage_reset_time", in: json)
        let credit = json["plan_credit_rate_limit"]
        let creditPool = credit["subscription_credit_left_rate"].exists || credit["topup_credit_left_rate"].exists
            || !credit["credit_buckets"].array.isEmpty
        var windows: [UsageWindow] = []
        if fiveReset == nil && weekReset == nil && (creditPool || json["plan_family"].int == 2) {
            let buckets = credit["credit_buckets"].array
            let sums = buckets.compactMap { b -> (Double, Double)? in
                guard let total = b["credit_total"].double, let rest = b["credit_residual"].double,
                      total > 0, rest >= 0, rest <= total else { return nil }
                return (total, rest)
            }
            let left = !buckets.isEmpty && sums.count == buckets.count
                ? sums.reduce(0) { $0 + $1.1 } / sums.reduce(0) { $0 + $1.0 }
                : credit["subscription_credit_left_rate"].double ?? credit["topup_credit_left_rate"].double
            let reset = epoch("subscription_credit_reset_time", in: credit)
            if let percent = used(left) {
                windows.append(UsageWindow(id: "credits", title: "Credit", usedPercent: percent, resetsAt: reset,
                                           windowMinutes: reset == nil ? nil : 43200))
            }
        } else {
            if let percent = used(json["five_hour_usage_left_rate"].double) {
                windows.append(UsageWindow(id: "session", title: "Session", usedPercent: percent, resetsAt: fiveReset, windowMinutes: 300))
            }
            if let percent = used(json["weekly_usage_left_rate"].double) {
                windows.append(UsageWindow(id: "weekly", title: "Weekly", usedPercent: percent, resetsAt: weekReset, windowMinutes: 10080))
            }
        }
        guard !windows.isEmpty else { throw ProviderError.parse("StepFun returned no usage windows.") }
        return ProviderUsage(windows: windows, plan: plan, fetchedAt: now)
    }
}
