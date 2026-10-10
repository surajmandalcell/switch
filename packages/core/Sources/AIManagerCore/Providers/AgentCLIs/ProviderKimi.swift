import Foundation

extension ProviderCatalog {
    // KIMI_CODE_HOME replaces ~/.kimi-code, not the credentials folder, so LiveFile.homeEnv does not fit.
    private static let kimiFile = LiveFile(".kimi-code/credentials/kimi-code.json")

    /// Kimi Code CLI sign-in. Never refreshes: the refresh endpoint and client id are not confirmed
    /// in the sources, and the refresh token rotates.
    static let agentKimi = ProviderSpec(
        id: "kimi", name: "Kimi Code", style: .files,
        files: [kimiFile],
        dashboard: "https://www.kimi.com/code/console",
        identify: { credential in
            let claims = credential.json(kimiFile.id)?["access_token"].string.flatMap(Fmt.jwtClaims)
            return (claims?["sub"].string ?? claims?["device_id"].string).map { CredentialIdentity(key: $0) }
        },
        usage: { credential in
            let file = credential.json(kimiFile.id)
            guard let token = file?["access_token"].string else {
                throw ProviderError.missingCredential("Sign in with the kimi command, then import the sign-in.")
            }
            if let expiry = file?["expires_at"].date, expiry <= Date().addingTimeInterval(60) {
                throw ProviderError.unauthorized("Open Kimi Code to refresh this sign-in.")
            }
            var headers = HTTP.bearer(token).merging(["X-Msh-Platform": "kimi_code_cli"]) { $1 }
            let deviceFile = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".kimi-code/device_id")
            if let device = (try? String(contentsOf: deviceFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines), !device.isEmpty {
                headers["X-Msh-Device-Id"] = device
            }
            return try await KimiUsage.fetch(headers: headers)
        })

    /// Same usage call with a pasted Kimi Code API key.
    static let agentKimiAPI = ProviderSpec(
        id: "kimi-api", name: "Kimi Code (API key)",
        fields: [CredentialField("apiKey", "API key", env: ["KIMI_CODE_API_KEY"])],
        dashboard: "https://www.kimi.com/code/console",
        usage: { credential in
            try await KimiUsage.fetch(headers: HTTP.bearer(try credential.require("apiKey")))
        })
}

enum KimiUsage {
    /// China host first, then the international host, because the sign-in file names neither.
    static func fetch(headers: [String: String]) async throws -> ProviderUsage {
        var failure: ProviderError?
        for host in ["https://api.kimi.com", "https://api.kimi.ai"] {
            do {
                return try map(try await HTTP.json("\(host)/coding/v1/usages", headers: headers))
            } catch let error as ProviderError where error.needsSignIn {
                failure = error
            }
        }
        throw failure ?? ProviderError.unauthorized("Kimi rejected this credential.")
    }

    private static let levels = [
        "LEVEL_FREE": "Adagio", "LEVEL_TRIAL": "Andante", "LEVEL_BASIC": "Moderato",
        "LEVEL_INTERMEDIATE": "Allegretto", "LEVEL_ADVANCED": "Allegro",
    ]
    /// A calendar-month stand-in, the same sentinel CodexBar uses for the monthly pool.
    private static let monthMinutes = 30 * 24 * 60

    private static func reset(_ json: JSON) -> Date? {
        ["resetTime", "resetAt", "reset_time", "reset_at"].lazy.compactMap { json[$0].date }.first
    }

    /// Request counts of one window. A count without a valid `used` or `remaining` reads as 0% and
    /// carries no window length, so a broken counter cannot create pace.
    private static func counts(_ id: String, _ title: String, _ json: JSON, minutes: Int?, rate: Bool = false) -> UsageWindow? {
        guard let limit = json["limit"].double, limit > 0 else { return nil }
        var used = 0.0, reliable = false
        if let value = json["used"].double, value >= 0 {
            (used, reliable) = (value, true)
        } else if let left = json["remaining"].double, (0...limit).contains(left) {
            (used, reliable) = (limit - left, true)
        }
        let length = reliable ? minutes : nil
        var window = UsageWindow(id: id, title: title, usedPercent: min(100, used / limit * 100), resetsAt: reset(json),
                                 windowMinutes: length, detail: "\(Fmt.number(used)) / \(Fmt.number(limit)) requests")
        if rate {
            let per = length.map { $0 % 60 == 0 ? " per \($0 / 60) \($0 / 60 == 1 ? "hour" : "hours")" : " per \($0) minutes" } ?? ""
            window.detail = "Rate: \(Fmt.number(used))/\(Fmt.number(limit))\(per)"
        }
        return window
    }

    /// A ratio pool. Negative or missing ratios are not usable, so they never hide the count window.
    private static func ratio(_ id: String, _ title: String, _ json: JSON, minutes: Int?) -> UsageWindow? {
        guard let value = json["used_ratio"].double, value.isFinite, value >= 0 else { return nil }
        return UsageWindow(id: id, title: title, usedPercent: min(1, value) * 100, resetsAt: reset(json), windowMinutes: minutes)
    }

    /// Prefers the ratio pool. When counts describe the same period (same length, reset within two
    /// seconds) and show more use, the counts win, as in CodexBar.
    private static func resolved(_ pool: UsageWindow?, counts: UsageWindow?) -> UsageWindow? {
        guard let pool else { return counts }
        if let counts, counts.windowMinutes != nil, counts.windowMinutes == pool.windowMinutes,
           let countReset = counts.resetsAt, let poolReset = pool.resetsAt, abs(countReset.timeIntervalSince(poolReset)) <= 2,
           (counts.usedPercent ?? 0) > (pool.usedPercent ?? 0) {
            return counts
        }
        return pool
    }

    static func map(_ json: JSON) throws -> ProviderUsage {
        let pools = json["usages"]
        let weekly = resolved(ratio("weekly", "7-day usage", pools["limit_7d"], minutes: 10080),
                              counts: counts("weekly", "7-day usage", json["usage"], minutes: 10080))
        let first = json["limits"].array.first
        let unit = ["TIME_UNIT_MINUTE": 1, "TIME_UNIT_HOUR": 60, "TIME_UNIT_DAY": 1440][first?.at("window.timeUnit").string ?? ""]
        let rateMinutes = first.flatMap { $0.at("window.duration").int }.flatMap { d in unit.map { $0 * d } }
        let rate = first.flatMap { counts("session", "5-hour usage", $0["detail"], minutes: rateMinutes ?? 300, rate: true) }
        let session = resolved(ratio("session", "5-hour usage", pools["limit_5h"], minutes: 300), counts: rate)
        let monthly = ratio("monthly", "Total usage", pools["limit_month_total"], minutes: monthMinutes)
        let windows = [weekly, session, monthly].compactMap { $0 }
        guard !windows.isEmpty else { throw ProviderError.parse("Kimi returned no supported usage windows.") }
        let level = json.at("user.membership.level").string
        return ProviderUsage(windows: windows,
                             plan: level.flatMap { $0 == "LEVEL_UNSPECIFIED" ? nil : levels[$0] ?? $0 })
    }
}
