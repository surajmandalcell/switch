import Foundation

extension ProviderCatalog {
    private static let geminiCreds = LiveFile(".gemini/oauth_creds.json")
    private static let geminiAccounts = LiveFile(".gemini/google_accounts.json", optional: true)

    static let geminiCLI = ProviderSpec(
        id: "gemini-cli", name: "Gemini CLI", style: .files,
        files: [geminiCreds, geminiAccounts], login: ["gemini"],
        dashboard: "https://gemini.google.com/app",
        identify: { credential in GeminiCLIUsage.identity(credential, creds: geminiCreds.id, accounts: geminiAccounts.id) },
        fetch: { credential in
            guard let data = credential.files[geminiCreds.id],
                  var file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw ProviderError.missingCredential("Sign in with the gemini command first.")
            }
            var changed = false
            let (assist, quota) = try await IDEAuth.authorized(
                access: file["access_token"] as? String,
                expiry: Fmt.epoch(JSON(file["expiry_date"]).double ?? 0),
                live: credential.isLive, hint: "Open Gemini CLI to refresh this sign-in.",
                refresh: {
                    guard let refresh = file["refresh_token"] as? String else {
                        throw ProviderError.unauthorized("Sign in with the gemini command again.")
                    }
                    guard let client = GeminiCLIUsage.oauthClient() else {
                        throw ProviderError.unavailable("Install Gemini CLI or set GEMINI_OAUTH_CLIENT_ID and GEMINI_OAUTH_CLIENT_SECRET so Switch can refresh this sign-in.")
                    }
                    let fresh = try await IDEAuth.googleRefresh(clientID: client.id, clientSecret: client.secret,
                                                                refreshToken: refresh)
                    file["access_token"] = fresh.accessToken
                    file["expiry_date"] = Int(Date().addingTimeInterval(fresh.expiresIn).timeIntervalSince1970 * 1000)
                    if let idToken = fresh.idToken { file["id_token"] = idToken }
                    changed = true
                    return fresh.accessToken
                },
                call: { token in
                    let assist = try await IDEAuth.cloudCode(
                        "loadCodeAssist", token: token,
                        body: ["metadata": ["ideType": "GEMINI_CLI", "pluginType": "GEMINI"]])
                    let project = IDEAuth.project(assist)
                    let quota = try await IDEAuth.cloudCode(
                        "retrieveUserQuota", token: token, body: project.map { ["project": $0] } ?? [:])
                    return (assist, quota)
                })
            let claims = (file["id_token"] as? String).flatMap(Fmt.jwtClaims)
            let usage = try GeminiCLIUsage.map(quota: quota, assist: assist, claims: claims)
            guard changed else { return FetchResult(usage) }
            var updated = credential
            updated.isLive = false
            updated.files[geminiCreds.id] = try JSONSerialization.data(
                withJSONObject: file, options: [.prettyPrinted, .sortedKeys])
            return FetchResult(usage, updated: updated)
        })
}

enum GeminiCLIUsage {
    /// Pure mapper, unit tested with fixture JSON. Each family keeps its lowest remaining fraction.
    static func map(quota: JSON, assist: JSON, claims: JSON?) throws -> ProviderUsage {
        guard quota["buckets"].exists else { throw ProviderError.parse("Gemini returned no quota buckets.") }
        var lowest: [String: (fraction: Double, reset: Date?)] = [:]
        for bucket in quota["buckets"].array {
            guard let model = bucket["modelId"].string?.lowercased(), let fraction = bucket["remainingFraction"].double
            else { continue }
            if let seen = lowest[model], seen.fraction <= fraction { continue }
            lowest[model] = (fraction, bucket["resetTime"].date)
        }
        let families: [(id: String, title: String, match: (String) -> Bool)] = [
            ("pro", "Pro", { $0.contains("pro") }),
            ("flash", "Flash", { $0.contains("flash") && !$0.contains("flash-lite") }),
            ("flash-lite", "Flash Lite", { $0.contains("flash-lite") }),
        ]
        let windows = families.compactMap { family -> UsageWindow? in
            guard let low = lowest.filter({ family.match($0.key) }).values.min(by: { $0.fraction < $1.fraction })
            else { return nil }
            return UsageWindow(id: family.id, title: family.title, usedPercent: (1 - low.fraction) * 100,
                               resetsAt: low.reset, windowMinutes: 1440)
        }
        return ProviderUsage(windows: windows, plan: plan(assist, claims: claims), email: claims?["email"].string)
    }

    static func identity(_ credential: ProviderCredential, creds: String, accounts: String) -> CredentialIdentity? {
        let claims = credential.json(creds).flatMap { Fmt.jwtClaims($0["id_token"].string ?? "") }
        let email = claims?["email"].string ?? credential.json(accounts)?["active"].string
        guard let key = claims?["sub"].string ?? email?.lowercased() else { return nil }
        return CredentialIdentity(key: key, email: email)
    }

    /// Plan label shared with Antigravity: the named paid tier, else the tier id.
    static func plan(_ assist: JSON, claims: JSON?) -> String? {
        if let paid = assist.at("paidTier.name").string { return paid }
        switch assist.at("currentTier.id").string {
        case "standard-tier": return "Paid"
        case "free-tier": return claims?["hd"].string == nil ? "Free" : "Workspace"
        case "legacy-tier": return "Legacy"
        default: return assist.at("currentTier.name").string
        }
    }

    /// Reads the OAuth client from the installed gemini-cli package, as CodexBar does. Nothing is embedded.
    static func oauthClient(env: [String: String] = ProcessInfo.processInfo.environment,
                            home: String = FileManager.default.homeDirectoryForCurrentUser.path)
        -> (id: String, secret: String)? {
        if let id = env["GEMINI_OAUTH_CLIENT_ID"], let secret = env["GEMINI_OAUTH_CLIENT_SECRET"],
           !id.isEmpty, !secret.isEmpty { return (id, secret) }
        if let path = env["GEMINI_OAUTH2_JS_PATH"],
           let text = try? String(contentsOfFile: path, encoding: .utf8), let client = parseClient(js: text) {
            return client
        }
        var roots: [String] = []
        let bins = (env["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.local/bin"]
        for dir in bins {
            let bin = URL(fileURLWithPath: dir).appendingPathComponent("gemini").resolvingSymlinksInPath()
            if FileManager.default.fileExists(atPath: bin.path), let root = packageRoot(above: bin) { roots.append(root) }
        }
        for prefix in ["/opt/homebrew", "/usr/local", "\(home)/.npm-global"] {
            roots.append("\(prefix)/lib/node_modules/@google/gemini-cli")
            roots.append("\(prefix)/opt/gemini-cli/libexec/lib/node_modules/@google/gemini-cli")
        }
        return roots.lazy.compactMap { client(inPackage: $0) }.first
    }

    static func parseClient(js: String) -> (id: String, secret: String)? {
        func match(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let hit = regex.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
                  let range = Range(hit.range(at: 1), in: js) else { return nil }
            return String(js[range])
        }
        guard let id = match(#"OAUTH_CLIENT_ID\s*=\s*['"]([\w\-\.]+)['"]\s*;"#),
              let secret = match(#"OAUTH_CLIENT_SECRET\s*=\s*['"]([\w\-]+)['"]\s*;"#) else { return nil }
        return (id, secret)
    }

    private static func packageRoot(above file: URL) -> String? {
        var url = file
        for _ in 0...8 {
            let manifest = url.appendingPathComponent("package.json")
            if let data = try? Data(contentsOf: manifest),
               (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["name"] as? String == "@google/gemini-cli" {
                return url.path
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private static func client(inPackage root: String) -> (id: String, secret: String)? {
        let core = "dist/src/code_assist/oauth2.js"
        for path in ["\(root)/\(core)", "\(root)/node_modules/@google/gemini-cli-core/\(core)", "\(root)/../gemini-cli-core/\(core)"] {
            if let text = try? String(contentsOfFile: path, encoding: .utf8), let client = parseClient(js: text) { return client }
        }
        // Bundled installs inline the file into bundle/*.js.
        let bundle = "\(root)/bundle"
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: bundle)) ?? []).sorted() where name.hasSuffix(".js") {
            if let text = try? String(contentsOfFile: "\(bundle)/\(name)", encoding: .utf8),
               let client = parseClient(js: text) { return client }
        }
        return nil
    }
}

/// Helpers shared by the IDE providers in this group: token lifecycle, Google refresh, Cloud Code calls.
enum IDEAuth {
    struct Refreshed { let accessToken: String; let idToken: String?; let expiresIn: TimeInterval }
    enum RefreshFailure: Error { case invalidClient }

    /// Runs `call` with a valid access token. A live credential is read only: when it is expired the
    /// official tool must refresh it. A vault copy refreshes before the call, or once after a 401.
    static func authorized<T>(access: String?, expiry: Date?, live: Bool, hint: String,
                              refresh: () async throws -> String,
                              call: (String) async throws -> T) async throws -> T {
        var token = access
        var refreshed = false
        if token == nil || expiry.map({ $0 <= Date().addingTimeInterval(live ? 0 : 60) }) == true {
            guard !live else { throw ProviderError.unauthorized(hint) }
            token = try await refresh()
            refreshed = true
        }
        do {
            return try await call(token ?? "")
        } catch ProviderError.unauthorized where !live && !refreshed {
            return try await call(try await refresh())
        }
    }

    /// Google OAuth refresh. Google does not rotate refresh tokens, so the old one stays valid.
    static func googleRefresh(clientID: String, clientSecret: String, refreshToken: String) async throws -> Refreshed {
        let response = try await HTTP.send(
            "https://oauth2.googleapis.com/token", method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: HTTP.form(["client_id": clientID, "client_secret": clientSecret,
                             "refresh_token": refreshToken, "grant_type": "refresh_token"]))
        if (400...401).contains(response.status) {
            if (try? response.json())?["error"].string == "invalid_client" { throw RefreshFailure.invalidClient }
            throw ProviderError.unauthorized("This Google sign-in expired. Sign in again.")
        }
        try HTTP.check(response)
        let json = try response.json()
        guard let access = json["access_token"].string else { throw ProviderError.parse("Google returned no access token.") }
        return Refreshed(accessToken: access, idToken: json["id_token"].string, expiresIn: json["expires_in"].double ?? 3600)
    }

    static func cloudCode(_ method: String, token: String, body: [String: Any],
                          userAgent: String? = nil) async throws -> JSON {
        var headers = HTTP.bearer(token)
        if let userAgent { headers["User-Agent"] = userAgent }
        let response = try await HTTP.send("https://cloudcode-pa.googleapis.com/v1internal:\(method)", method: "POST",
                                           headers: headers, body: try JSONSerialization.data(withJSONObject: body))
        if response.status == 403, response.text.contains("UNSUPPORTED_CLIENT") || response.text.contains("SUBSCRIPTION_REQUIRED") {
            throw ProviderError.unavailable("Google does not serve this client for this account. Use Antigravity for personal accounts.")
        }
        try HTTP.check(response)
        return try response.json()
    }

    /// `cloudaicompanionProject` is a string or an object with `id` or `projectId`.
    static func project(_ assist: JSON) -> String? {
        let value = assist["cloudaicompanionProject"]
        return value.string ?? value["id"].string ?? value["projectId"].string
    }
}
