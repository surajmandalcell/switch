import Foundation

extension ProviderCatalog {
    fileprivate static let grokAuthFile = LiveFile(".grok/auth.json", homeEnv: "GROK_HOME")

    /// Reads the Grok CLI sign-in. A live credential belongs to the Grok CLI and is never refreshed;
    /// only a saved vault copy, which Switch alone holds, is refreshed.
    static let agentGrok = ProviderSpec(
        id: "grok-build", name: "Grok Build", style: .files,
        files: [grokAuthFile],
        dashboard: "https://grok.com/?_s=usage",
        identify: { GrokBuildUsage.identity($0.json(grokAuthFile.id)) },
        fetch: { try await GrokBuildUsage.fetch($0, fileID: grokAuthFile.id) })
}

enum GrokBuildUsage {
    static let refreshMessage = "Open Grok to refresh this sign-in."
    static let defaultClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let tokenURL = "https://auth.x.ai/oauth2/token"

    /// (url, method, headers, body) -> response. Tests replace it so nothing touches the network.
    typealias Send = @Sendable (String, String, [String: String], Data?) async throws -> HTTPResponse
    static let liveSend: Send = { try await HTTP.send($0, method: $1, headers: $2, body: $3) }

    static func fetch(_ credential: ProviderCredential, fileID: String, now: Date = Date(),
                      send: Send = liveSend) async throws -> FetchResult {
        if credential.isLive {
            let auth = try token(credential.json(fileID), now: now)
            return FetchResult(try await usage(token: auth.token, email: auth.email, send: send))
        }
        guard let data = credential.files[fileID],
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let key = entryKey(JSON(root)), var entry = root[key] as? [String: Any],
              let access = entry["key"] as? String else {
            throw ProviderError.missingCredential("Sign in to Grok first, then import the sign-in.")
        }
        var refreshed = false
        let email = entry["email"] as? String
        let result = try await IDEAuth.authorized(
            access: access, expiry: expiry(JSON(entry), token: access), live: false, hint: refreshMessage,
            refresh: {
                let fresh = try await refresh(key: key, entry: entry, now: now, send: send)
                entry = fresh.entry
                root[key] = entry
                refreshed = true
                return fresh.token
            },
            call: { try await usage(token: $0, email: email, send: send) })
        guard refreshed else { return FetchResult(result) }
        var updated = credential
        updated.files[fileID] = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return FetchResult(result, updated: updated)
    }

    /// Grok CLI OAuth refresh. Only the token fields change; every other key of the entry is kept.
    private static func refresh(key: String, entry: [String: Any], now: Date,
                                send: Send) async throws -> (token: String, entry: [String: Any]) {
        func text(_ name: String) -> String? {
            (entry[name] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        guard let refreshToken = text("refresh_token") ?? text("refresh") else {
            throw ProviderError.unauthorized(refreshMessage)
        }
        let suffix = key.contains("::") ? key.components(separatedBy: "::").last?.nonEmpty : nil
        let client = text("oidc_client_id") ?? suffix ?? defaultClientID
        let response = try await send(
            tokenURL, "POST", ["Content-Type": "application/x-www-form-urlencoded"],
            HTTP.form(["grant_type": "refresh_token", "client_id": client, "refresh_token": refreshToken]))
        if (400...403).contains(response.status) {
            throw ProviderError.unauthorized("This Grok sign-in expired. Sign in again.")
        }
        try HTTP.check(response)
        let json = try response.json()
        guard let access = json["access_token"].string?.nonEmpty else {
            throw ProviderError.parse("Grok returned no access token.")
        }
        var fresh = entry
        fresh["key"] = access
        if let rotated = json["refresh_token"].string?.nonEmpty {
            fresh[entry["refresh_token"] == nil && entry["refresh"] != nil ? "refresh" : "refresh_token"] = rotated
        }
        if let idToken = json["id_token"].string?.nonEmpty, entry["id_token"] != nil {
            fresh["id_token"] = idToken
        }
        let lifetime = json["expires_in"].double.map { now.addingTimeInterval($0) }
            ?? Fmt.jwtClaims(access)?["exp"].date ?? now.addingTimeInterval(3600)
        fresh[entry["expires_at"] == nil && entry["expires"] != nil ? "expires" : "expires_at"] =
            ISO8601DateFormatter().string(from: lifetime)
        return (access, fresh)
    }

    private static func usage(token: String, email: String?, send: Send) async throws -> ProviderUsage {
        let headers = headers(token)
        async let settings = try? send("https://cli-chat-proxy.grok.com/v1/settings", "GET", headers, nil)
        let response = try await send("https://cli-chat-proxy.grok.com/v1/billing?format=credits", "GET", headers, nil)
        let plan = await settings.flatMap { (200..<300).contains($0.status) ? try? $0.json() : nil }?["subscription_tier_display"].string
        if response.status == 401 || response.status == 403 {
            throw ProviderError.unauthorized(refreshMessage)
        }
        if isTeamResponse(status: response.status, body: response.text) {
            return teamOnly(plan: plan, email: email)
        }
        try HTTP.check(response)
        return try map(billing: response.json(), plan: plan, email: email)
    }

    /// Earliest of the file's expiry field and the access token's `exp`.
    private static func expiry(_ entry: JSON, token: String) -> Date? {
        [(entry["expires_at"].date ?? entry["expires"].date), Fmt.jwtClaims(token)?["exp"].date]
            .compactMap { $0 }.min()
    }

    /// Key of the login record Grok itself would use: OIDC entry first, then the legacy session entry.
    private static func entryKey(_ file: JSON?) -> String? {
        let entries = (file?.object ?? [:]).filter { $0.value["key"].string != nil }
        let ordered = entries.sorted { $0.key < $1.key }
        return (ordered.first { $0.key.hasPrefix("https://auth.x.ai::") }
            ?? ordered.first { $0.key.contains("/sign-in") } ?? ordered.first)?.key
    }

    private static func entry(_ file: JSON?) -> JSON? {
        entryKey(file).flatMap { file?.object[$0] }
    }

    static func identity(_ file: JSON?) -> CredentialIdentity? {
        guard let entry = entry(file),
              let key = entry["user_id"].string ?? entry["email"].string else { return nil }
        return CredentialIdentity(key: key, email: entry["email"].string)
    }

    static func token(_ file: JSON?, now: Date) throws -> (token: String, email: String?) {
        guard let entry = entry(file), let token = entry["key"].string else {
            throw ProviderError.missingCredential("Sign in to Grok first, then import the sign-in.")
        }
        let expiry = (entry["expires_at"].date ?? entry["expires"].date)
            ?? Fmt.jwtClaims(token)?["exp"].date
        if let expiry, expiry <= now { throw ProviderError.unauthorized(refreshMessage) }
        return (token, entry["email"].string)
    }

    static func headers(_ token: String) -> [String: String] {
        HTTP.bearer(token).merging(["X-XAI-Token-Auth": "xai-grok-cli"]) { $1 }
    }

    /// HTTP 412 "no personal team": the sign-in is fine, but a team has no personal quota.
    static func isTeamResponse(status: Int, body: String) -> Bool {
        status == 412 && body.localizedCaseInsensitiveContains("no personal team")
    }

    static func teamOnly(plan: String?, email: String?) -> ProviderUsage {
        ProviderUsage(sections: [UsageSection(nil, [UsageRow("Weekly limit", "Team accounts have no personal quota")])],
                      plan: plan, email: email)
    }

    /// `GET /v1/billing?format=credits`. Proto3 JSON drops zero values, so a missing percent means 0.
    static func map(billing: JSON, plan: String? = nil, email: String? = nil) throws -> ProviderUsage {
        let config = billing["config"]
        guard config.exists else { throw ProviderError.parse("Grok returned an unexpected billing reply.") }
        var windows: [UsageWindow] = []
        let period = config["currentPeriod"]
        if let start = period["start"].date, let end = period["end"].date, end > start {
            let type = period["type"].string ?? ""
            let title = type.hasSuffix("WEEKLY") ? "Weekly" : type.hasSuffix("MONTHLY") ? "Monthly" : nil
            if let title {
                windows.append(UsageWindow(
                    id: title.lowercased(), title: title, usedPercent: config["creditUsagePercent"].double ?? 0,
                    resetsAt: end, windowMinutes: Int(end.timeIntervalSince(start) / 60)))
            }
        }
        let cap = config.at("onDemandCap.val").double ?? 0
        var rows = [UsageRow("Pay as you go", cap > 0 ? "\(Fmt.number(cap)) credit cap" : "Disabled")]
        if cap > 0, let used = config.at("onDemandUsed.val").double {
            rows.append(UsageRow("On-demand used", Fmt.number(used), progress: used / cap))
        }
        let prepaid = config.at("prepaidBalance.val").double ?? 0
        return ProviderUsage(windows: windows, cost: prepaid > 0 ? UsageCost(balance: prepaid / 100) : nil,
                             sections: [UsageSection(nil, rows)],
                             plan: plan ?? config["subscriptionTier"].string, email: email)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
