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
                    let summary = try? await IDEAuth.cloudCode(
                        "retrieveUserQuotaSummary", token: token, body: body, userAgent: agent)
                    if let summary, AntigravityCLIUsage.hasSummary(summary) { return (assist, summary, nil) }
                    let models = try await IDEAuth.cloudCode(
                        "fetchAvailableModels", token: token, body: body, userAgent: agent)
                    return (assist, nil, models)
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

    /// Quota needs the Hub client family (CodexBar).
    static let userAgent: String = {
        #if arch(arm64)
        "antigravity/hub/2.9.1 darwin/arm64"
        #else
        "antigravity/hub/2.9.1 darwin/amd64"
        #endif
    }()

    /// The summary wraps its groups in `response` when read from the local server, and not on Cloud Code.
    private static func groups(_ summary: JSON) -> JSON {
        summary["groups"].exists ? summary["groups"] : summary.at("response.groups")
    }

    static func hasSummary(_ summary: JSON) -> Bool { groups(summary).exists }

    /// Pure mapper. A parsed quota summary is authoritative even when it holds no known bucket; the
    /// per-model fallback runs only when the response has no summary. Follows OpenUsage, which ships
    /// fixtures for the four bucket ids; CodexBar reads the same shape.
    static func map(assist: JSON, summary: JSON?, models: JSON?, claims: JSON?) throws -> ProviderUsage {
        let windows: [UsageWindow]
        if let summary, hasSummary(summary) {
            windows = summaryWindows(summary)
        } else if let models {
            windows = modelWindows(models)
        } else {
            throw ProviderError.parse("Antigravity returned no quota.")
        }
        return ProviderUsage(windows: windows, plan: GeminiCLIUsage.plan(assist, claims: claims),
                             email: claims?["email"].string)
    }

    private static func summaryWindows(_ summary: JSON) -> [UsageWindow] {
        let known: [(bucket: String, id: String, title: String, minutes: Int)] = [
            ("gemini-5h", "session", "Gemini 5-hour", 300), ("gemini-weekly", "weekly", "Gemini weekly", 10080),
            ("3p-5h", "claude-session", "Claude 5-hour", 300), ("3p-weekly", "claude-weekly", "Claude weekly", 10080),
        ]
        var found: [String: JSON] = [:]
        for bucket in groups(summary).array.flatMap({ $0["buckets"].array }) {
            // Exact ids only: a new bucket must never join a pool by its display name.
            guard let id = bucket["bucketId"].string ?? bucket["id"].string, found[id] == nil,
                  (bucket["remainingFraction"].double ?? bucket.at("remaining.remainingFraction").double) != nil
            else { continue }
            found[id] = bucket
        }
        return known.compactMap { entry in
            guard let bucket = found[entry.bucket],
                  let fraction = bucket["remainingFraction"].double ?? bucket.at("remaining.remainingFraction").double
            else { return nil }
            return UsageWindow(id: entry.id, title: entry.title, usedPercent: ((1 - min(max(fraction, 0), 1)) * 100).rounded(),
                               resetsAt: bucket["resetTime"].date, windowMinutes: entry.minutes)
        }
    }

    /// Legacy 5-hour pools from `fetchAvailableModels`; a model without quota info is dropped, never read as empty.
    private static func modelWindows(_ models: JSON) -> [UsageWindow] {
        var pools: [String: (fraction: Double, reset: Date?)] = [:]
        for (key, model) in models["models"].object where model["isInternal"].bool != true {
            guard let fraction = model.at("quotaInfo.remainingFraction").double else { continue }
            let label = (model["displayName"].string ?? model["label"].string ?? key).lowercased()
            let pool = label.contains("gemini") ? "session" : "claude-session"
            if let seen = pools[pool], seen.fraction <= fraction { continue }
            pools[pool] = (fraction, model.at("quotaInfo.resetTime").date)
        }
        return [("session", "Gemini 5-hour"), ("claude-session", "Claude 5-hour")].compactMap { id, title in
            pools[id].map { UsageWindow(id: id, title: title, usedPercent: (1 - $0.fraction) * 100,
                                        resetsAt: $0.reset, windowMinutes: 300) }
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
