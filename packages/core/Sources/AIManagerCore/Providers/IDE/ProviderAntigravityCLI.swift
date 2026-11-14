import Foundation

extension ProviderCatalog {
    /// `agy` keeps this file only when SSH_TTY is set, which selects its file token store.
    private static let antigravityToken = LiveFile(".gemini/antigravity-cli/antigravity-oauth-token")

    static let antigravityCLI = ProviderSpec(
        id: "antigravity-cli", name: "Antigravity CLI", style: .files,
        files: [antigravityToken], login: ["agy"], loginEnv: ["SSH_TTY": "1"],
        dashboard: "https://antigravity.google",
        identify: { credential in AntigravityCLIUsage.identity(credential.json(antigravityToken.id)) },
        fetch: { credential in
            guard let data = credential.files[antigravityToken.id],
                  var file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw ProviderError.missingCredential("Sign in with the agy command first.")
            }
            var changed = false
            let (assist, summary, models) = try await IDEAuth.authorized(
                access: (file["token"] as? [String: Any])?["access_token"] as? String,
                expiry: ((file["token"] as? [String: Any])?["expiry"] as? String).flatMap(Fmt.iso),
                live: credential.isLive, hint: "Open agy to refresh this sign-in.",
                refresh: {
                    var token = file["token"] as? [String: Any] ?? [:]
                    guard let refresh = token["refresh_token"] as? String else {
                        throw ProviderError.unauthorized("Sign in with the agy command again.")
                    }
                    let fresh = try await AntigravityCLIUsage.refresh(refreshToken: refresh)
                    token["access_token"] = fresh.accessToken
                    token["expiry"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(fresh.expiresIn))
                    file["token"] = token
                    if let idToken = fresh.idToken { file["id_token"] = idToken }
                    changed = true
                    return fresh.accessToken
                },
                call: { token -> (JSON, JSON?, JSON?) in
                    let agent = AntigravityCLIUsage.userAgent
                    let assist = try await IDEAuth.cloudCode(
                        "loadCodeAssist", token: token, body: ["metadata": AntigravityCLIUsage.metadata],
                        userAgent: agent)
                    if AntigravityCLIUsage.rejectsClient(assist) {
                        throw ProviderError.unauthorized("Sign in with the agy command again. This sign-in cannot read quota.")
                    }
                    let body: [String: Any] = IDEAuth.project(assist).map { ["project": $0] } ?? [:]
                    let summary = await AntigravityCLIUsage.quotaSummary { host in
                        try await IDEAuth.cloudCode(
                            "retrieveUserQuotaSummary", token: token, body: body, userAgent: agent, host: host)
                    }
                    if let summary, AntigravityCLIUsage.hasMeasured(summary) { return (assist, summary, nil) }
                    // No measured bucket (older build or unmeasured summary): read the per-model quotas.
                    let models = try await IDEAuth.cloudCode(
                        "fetchAvailableModels", token: token, body: body, userAgent: agent)
                    return (assist, summary, models)
                })
            let claims = (file["id_token"] as? String).flatMap(Fmt.jwtClaims)
            let usage = try AntigravityCLIUsage.map(assist: assist, summary: summary, models: models, claims: claims)
            guard changed else { return FetchResult(usage) }
            var updated = credential
            updated.isLive = false
            updated.files[antigravityToken.id] = try JSONSerialization.data(
                withJSONObject: file, options: [.prettyPrinted, .sortedKeys])
            return FetchResult(usage, updated: updated)
        })
}

enum AntigravityCLIUsage {
    /// Public consumer sign-in client of `agy`. Its secret is read from the installed app, never embedded.
    private static let consumerClientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    static let metadata = ["ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]

    /// The hub client identity exposes the separate Argon quota; the IDE identity omits it (OpenUsage e1ffa571).
    static let userAgent: String = {
        #if arch(arm64)
        "antigravity/hub/2.24.0 (aidev_client; os_type=darwin; arch=arm64)"
        #else
        "antigravity/hub/2.24.0 (aidev_client; os_type=darwin; arch=amd64)"
        #endif
    }()

    /// The daily host holds the active counters; production can return untouched windows (OpenUsage ee981593).
    static let quotaHosts = ["https://daily-cloudcode-pa.googleapis.com", "https://cloudcode-pa.googleapis.com"]

    /// Asks the daily host, and production too when the daily answer lacks a pool bucket or fails.
    /// A bucket the daily host reports wins. Nil when no host answered.
    static func quotaSummary(_ fetch: (String) async throws -> JSON) async -> JSON? {
        var answers: [JSON] = []
        for host in quotaHosts {
            guard let answer = try? await fetch(host) else { continue }
            answers.append(answer)
            if isComplete(answer) { break }
        }
        let summaries = answers.filter(hasSummary)
        guard summaries.count > 1 else { return summaries.first ?? answers.first }
        // Keep one Argon group: a second one would make its weekly bucket ambiguous.
        var merged: [Any] = []
        var argonSeen = false
        for summary in summaries {
            let list = groups(summary).array
            merged += list.filter { !(argonSeen && isArgonGroup($0)) }.compactMap(\.raw)
            argonSeen = argonSeen || list.contains(where: isArgonGroup)
        }
        return JSON(["groups": merged])
    }

    private static func isComplete(_ summary: JSON) -> Bool {
        summaryWindows(summary).filter { $0.id != "argon-weekly" }.count == knownBuckets.count
    }

    /// The summary wraps its groups in `response` when read from the local server, and not on Cloud Code.
    private static func groups(_ summary: JSON) -> JSON {
        summary["groups"].exists ? summary["groups"] : summary.at("response.groups")
    }

    static func hasSummary(_ summary: JSON) -> Bool { groups(summary).exists }

    /// True when the summary holds at least one measured pool bucket.
    static func hasMeasured(_ summary: JSON) -> Bool { !summaryWindows(summary).isEmpty }

    /// Pure mapper. A summary with measured buckets wins. One without (an unmeasured or older build) falls
    /// back to the per-model quotas when they are present, and is otherwise reported as empty.
    /// OpenUsage ships fixtures for the four bucket ids; CodexBar reads the same shape.
    static func map(assist: JSON, summary: JSON?, models: JSON?, claims: JSON?) throws -> ProviderUsage {
        var windows = summary.map(summaryWindows) ?? []
        if windows.isEmpty, let models {
            windows = modelWindows(models)
        } else if windows.isEmpty, summary.map(hasSummary) != true {
            throw ProviderError.parse("Antigravity returned no quota.")
        }
        return ProviderUsage(windows: windows, plan: GeminiCLIUsage.plan(assist, claims: claims),
                             email: claims?["email"].string)
    }

    private static let knownBuckets: [(bucket: String, id: String, title: String, minutes: Int)] = [
        ("gemini-5h", "session", "Gemini 5-hour", 300), ("gemini-weekly", "weekly", "Gemini weekly", 10080),
        ("3p-5h", "claude-session", "Claude 5-hour", 300), ("3p-weekly", "claude-weekly", "Claude weekly", 10080),
    ]
    private static let argonGroup = "Gemini 4 Argon"

    private static func isArgonGroup(_ group: JSON) -> Bool { group["displayName"].string == argonGroup }

    private static func fraction(_ bucket: JSON) -> Double? {
        bucket["remainingFraction"].double ?? bucket.at("remaining.remainingFraction").double
    }

    private static func used(_ fraction: Double) -> Double { (1 - min(max(fraction, 0), 1)) * 100 }

    private static func summaryWindows(_ summary: JSON) -> [UsageWindow] {
        let all = groups(summary).array
        var found: [String: JSON] = [:]
        // The Argon group is read below; its bucket must never take a shared pool's id.
        for bucket in all.filter({ !isArgonGroup($0) }).flatMap({ $0["buckets"].array }) {
            // Exact ids only: a new bucket must never join a pool by its display name.
            guard let id = bucket["bucketId"].string ?? bucket["id"].string, found[id] == nil,
                  fraction(bucket) != nil
            else { continue }
            found[id] = bucket
        }
        var windows = knownBuckets.compactMap { entry -> UsageWindow? in
            guard let bucket = found[entry.bucket], let left = fraction(bucket) else { return nil }
            return pool(id: entry.id, title: entry.title, used: used(left),
                        reset: bucket["resetTime"].date, minutes: entry.minutes)
        }
        if let argon = argonWindow(all) { windows.insert(argon, at: windows.firstIndex { $0.id.hasPrefix("claude") } ?? windows.endIndex) }
        return windows
    }

    /// The separate Gemini 4 Argon weekly quota: one unambiguous, enabled weekly bucket with its own id.
    private static func argonWindow(_ groups: [JSON]) -> UsageWindow? {
        let weekly = groups.filter(isArgonGroup).flatMap { $0["buckets"].array }.filter { $0["window"].string == "weekly" }
        guard weekly.count == 1, let bucket = weekly.first,
              let id = (bucket["bucketId"].string ?? bucket["id"].string), !id.isEmpty,
              !knownBuckets.contains(where: { $0.bucket == id }),
              // A malformed flag cannot establish access.
              !(bucket["disabled"].exists && bucket["disabled"].bool == nil), bucket["disabled"].bool != true,
              let left = fraction(bucket) else { return nil }
        return pool(id: "argon-weekly", title: "Gemini 4 Argon weekly", used: used(left),
                    reset: bucket["resetTime"].date, minutes: 10080)
    }

    /// A 5-hour pool with no usage has not started its window yet; the reset then only restates the window.
    private static func pool(id: String, title: String, used: Double, reset: Date?, minutes: Int) -> UsageWindow {
        UsageWindow(id: id, title: title, usedPercent: used, resetsAt: reset, windowMinutes: minutes,
                    detail: minutes == 300 && used == 0 ? "Not started" : nil)
    }

    /// Legacy 5-hour pools from `fetchAvailableModels`; a model without quota info is dropped, never read as empty.
    private static func modelWindows(_ models: JSON) -> [UsageWindow] {
        var pools: [String: (fraction: Double, reset: Date?)] = [:]
        for (key, model) in models["models"].object where model["isInternal"].bool != true {
            guard let fraction = model.at("quotaInfo.remainingFraction").double else { continue }
            let label = (model["displayName"].string ?? model["label"].string ?? key).lowercased()
            // Legacy quota carries no pool or period for Argon; it must not join the Gemini 5-hour pool.
            if key == "MODEL_PLACEHOLDER_M421" || label.hasPrefix("gemini 4 argon") { continue }
            let pool = label.contains("gemini") ? "session" : "claude-session"
            if let seen = pools[pool], seen.fraction <= fraction { continue }
            pools[pool] = (fraction, model.at("quotaInfo.resetTime").date)
        }
        return [("session", "Gemini 5-hour"), ("claude-session", "Claude 5-hour")].compactMap { id, title in
            pools[id].map { pool(id: id, title: title, used: (1 - $0.fraction) * 100, reset: $0.reset, minutes: 300) }
        }
    }

    /// The second bundled client leaves the account unonboarded, so quota would read as 100% left.
    static func rejectsClient(_ assist: JSON) -> Bool {
        !assist["currentTier"].exists && IDEAuth.project(assist) == nil
            && assist["ineligibleTiers"].array.contains { $0["reasonCode"].string == "GOOGLE_TOS_NOT_SUPPORTED_BY_CLIENT" }
    }

    static func identity(_ file: JSON?) -> CredentialIdentity? {
        guard let claims = file.flatMap({ Fmt.jwtClaims($0["id_token"].string ?? "") }) else { return nil }
        let email = claims["email"].string
        guard let key = claims["sub"].string ?? email?.lowercased() else { return nil }
        return CredentialIdentity(key: key, email: email)
    }

    /// Tries the env override, then every OAuth secret found in the installed app or `agy` binary.
    /// The consumer client id is public; the right secret is the one Google accepts.
    static func refresh(refreshToken: String,
                        env: [String: String] = ProcessInfo.processInfo.environment) async throws -> IDEAuth.Refreshed {
        if let id = env["ANTIGRAVITY_OAUTH_CLIENT_ID"], let secret = env["ANTIGRAVITY_OAUTH_CLIENT_SECRET"] {
            return try await IDEAuth.googleRefresh(clientID: id, clientSecret: secret, refreshToken: refreshToken)
        }
        for secret in installedSecrets(env: env).prefix(4) {
            do {
                return try await IDEAuth.googleRefresh(clientID: consumerClientID, clientSecret: secret,
                                                       refreshToken: refreshToken)
            } catch IDEAuth.RefreshFailure.invalidClient {
                continue
            }
        }
        throw ProviderError.unavailable("Install Antigravity or agy, or set ANTIGRAVITY_OAUTH_CLIENT_ID and ANTIGRAVITY_OAUTH_CLIENT_SECRET, so Switch can refresh this sign-in.")
    }

    private static func installedSecrets(env: [String: String]) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = ["/Applications", "\(home)/Applications"].flatMap { root in
            ["Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm",
             "Contents/Resources/app/extensions/antigravity/bin/language_server_macos_x64",
             "Contents/Resources/app/out/main.js", "Contents/Resources/bin/language_server_macos"]
                .map { "\(root)/Antigravity.app/\($0)" }
        }
        paths += [env["ANTIGRAVITY_CLI_PATH"], "\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
            .compactMap { $0 }
        var all: [String] = []
        for path in paths {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard let data = try? Data(contentsOf: resolved, options: .mappedIfSafe) else { continue }
            for secret in secrets(in: data) where !all.contains(secret) { all.append(secret) }
        }
        return all
    }

    static func secrets(in data: Data) -> [String] {
        let marker = Data("GOCSPX-".utf8)
        var found: [String] = []
        var from = data.startIndex
        while let hit = data.range(of: marker, in: from..<data.endIndex) {
            from = hit.upperBound
            guard hit.upperBound + 28 <= data.endIndex,
                  let text = String(data: data[hit.lowerBound..<hit.upperBound + 28], encoding: .ascii),
                  text.range(of: "^GOCSPX-[A-Za-z0-9_-]{28}$", options: .regularExpression) != nil,
                  !found.contains(text) else { continue }
            found.append(text)
        }
        return found
    }
}
