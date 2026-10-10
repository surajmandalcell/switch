import Foundation

extension ProviderCatalog {
    /// The Muse CLI keeps its device-code login in ~/.config/muse/auth.json; a pasted `dca:` token also works.
    static let muse = ProviderSpec(
        id: "muse", name: "Muse Code",
        style: .files,
        fields: [CredentialField("token", "Device token (optional)", optional: true, placeholder: "dca:…"),
                 CredentialField("cookie", "dev.meta.ai Cookie header (optional)", optional: true,
                                 placeholder: "Reads the browser team quota when the login omits it"),
                 CredentialField("teamID", "Browser team ID (optional)", secure: false, optional: true,
                                 env: ["MUSE_WEB_TEAM_ID"])],
        files: [LiveFile(".config/muse/auth.json", optional: true)],
        login: ["muse", "login"],
        dashboard: "https://dev.meta.ai",
        usage: { credential in
            guard let token = MuseUsage.token(credential) else {
                throw ProviderError.missingCredential("Run muse login, or paste the dca: device token.")
            }
            guard token.hasPrefix("dca:") else {
                throw ProviderError.unauthorized("Muse Code needs a device-code login. Run muse login again.")
            }
            let json = try await HTTP.json(
                "https://api.meta.ai/muse-code/key",
                headers: HTTP.bearer(token).merging(["x-api-version": "1.0.0"]) { $1 },
                object: [String: String]())
            // The login response omits quotas while the 5-hour window is idle; the dev.meta.ai usage
            // page reads the same subscription quota with a browser session.
            var web: MuseUsage.Web?
            if !json["subs_usage"].exists, let cookie = credential["cookie"] {
                web = await MuseUsage.web(cookie: cookie, email: json["user_email"].string,
                                          plan: json["subs_tier_name"].string, teamID: credential["teamID"])
            }
            return try MuseUsage.map(json, web: web)
        })
}

enum MuseUsage {
    static func token(_ credential: ProviderCredential) -> String? {
        credential["token"] ?? credential.json(".config/muse/auth.json")?.at("providers.meta.access_token").string
    }

    private static func reset(_ value: JSON) -> Date? {
        guard let seconds = value.double, seconds > 0, seconds <= 64_092_211_200 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func percentLabel(_ value: Double) -> String { "\(Fmt.number(value))%" }

    /// The browser quota of the dev.meta.ai team the user chose.
    struct Web {
        var teams: [(id: String, name: String)]
        var note: String?
        var quota: (team: String, primary: UsageWindow, secondary: UsageWindow)?
    }

    static func map(_ root: JSON, web: Web? = nil) throws -> ProviderUsage {
        // The response also holds an api_key and a payment_method; neither is read or kept.
        if root["require_payment"].bool == true {
            throw ProviderError.unauthorized("Muse Code requires a payment method. Finish billing at dev.meta.ai.")
        }
        guard root["is_subs_active"].bool == true else {
            throw ProviderError.unauthorized("No Muse Code subscription is active on this login.")
        }
        let plan = root["subs_tier_name"].string, email = root["user_email"].string
        var rows = plan.map { [UsageRow("Plan", $0)] } ?? []
        let usage = root["subs_usage"]
        guard usage.exists else {
            var windows: [UsageWindow] = []
            var sections: [UsageSection] = []
            if let quota = web?.quota {
                windows = [quota.primary, quota.secondary]
            } else {
                rows.append(UsageRow("Quota", "Not included in this login response"))
            }
            sections.append(UsageSection("Muse Code subscription", rows))
            if let web {
                var teamRows = web.teams.map { UsageRow($0.name, $0.id) }
                if let note = web.note { teamRows.insert(UsageRow("Status", note), at: 0) }
                sections.append(UsageSection("Browser teams", teamRows))
                if let quota = web.quota {
                    sections.append(UsageSection("Browser team quota (dev.meta.ai)", [
                        UsageRow("Team", quota.team),
                        UsageRow("5 hours", percentLabel(quota.primary.usedPercent ?? 0)),
                        UsageRow("Weekly", percentLabel(quota.secondary.usedPercent ?? 0)),
                    ]))
                }
            }
            return ProviderUsage(windows: windows, sections: sections, plan: plan ?? "Muse login", email: email)
        }
        guard let window = usage["window"]["used_percent"].double, let minutes = usage["window"]["window_duration_mins"].int,
              minutes > 0, let weekly = usage["weekly"]["used_percent"].double else {
            throw ProviderError.parse("Could not parse Muse Code subscription usage.")
        }
        let session = UsageWindow(id: "session", title: "5 hours", usedPercent: window,
                                  resetsAt: reset(usage["window"]["resets_at"]), windowMinutes: minutes)
        let weeklyWindow = UsageWindow(id: "weekly", title: "Weekly", usedPercent: weekly,
                                       resetsAt: reset(usage["weekly"]["resets_at"]), windowMinutes: 10080)
        rows.append(UsageRow("5 hours", percentLabel(session.usedPercent ?? 0)))
        rows.append(UsageRow("Weekly", percentLabel(weeklyWindow.usedPercent ?? 0)))
        return ProviderUsage(windows: [session, weeklyWindow], sections: [UsageSection("Muse Code subscription", rows)],
                             plan: plan ?? "Muse login", email: email)
    }

    // MARK: Browser team quota

    private static func amount(_ value: JSON) -> Double? {
        if let text = value.raw as? String {
            return text.range(of: "^[0-9]+$", options: .regularExpression) != nil ? Double(text) : nil
        }
        guard let number = value.double, number.isFinite, number >= 0 else { return nil }
        return number
    }

    private static func numericID(_ value: JSON) -> String? {
        let id = (value.raw as? String)?.trimmingCharacters(in: .whitespaces) ?? value.int.map(String.init) ?? ""
        return id.range(of: "^[0-9]+$", options: .regularExpression) != nil ? id : nil
    }

    /// Weighted token counts arrive as decimal strings. A stale or incomplete quota returns nil.
    static func webQuota(_ quota: JSON, now: Date = Date()) -> (primary: UsageWindow, secondary: UsageWindow)? {
        func percent(_ used: JSON, _ limit: JSON) -> Double? {
            guard let used = amount(used), let limit = amount(limit), limit > 0 else { return nil }
            return min(100, used / limit * 100)
        }
        func resetAt(_ value: JSON) -> Date? {
            guard let seconds = amount(value), seconds > 0, seconds <= 64_092_211_200 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        // A weekly quota without a future reset is stale; show nothing rather than an old reading.
        guard let weekly = percent(quota["weekly_weighted_used"], quota["weekly_weighted_limit"]),
              let weeklyReset = resetAt(quota["weekly_resets_at"]), weeklyReset > now,
              let seconds = amount(quota["window_duration_secs"]), seconds >= 60 else { return nil }
        guard var primary = percent(quota["window_weighted_used"], quota["window_weighted_limit"]) else { return nil }
        let windowReset = resetAt(quota["window_resets_at"])
        let noReset = !quota["window_resets_at"].exists
        if (!noReset && windowReset == nil) || (noReset && primary != 0) { return nil }
        // An idle 5-hour window has no reset time; one whose reset has passed carries no usage forward.
        let active = windowReset.map { $0 > now } ?? false
        if !active { primary = 0 }
        return (UsageWindow(id: "session", title: "5 hours", usedPercent: primary, resetsAt: active ? windowReset : nil,
                            windowMinutes: Int((seconds / 60).rounded())),
                UsageWindow(id: "weekly", title: "Weekly", usedPercent: weekly, resetsAt: weeklyReset,
                            windowMinutes: 10080))
    }

    /// Reads the chosen team's quota from dev.meta.ai. The session must belong to the same Meta account as the
    /// CLI login, so a blank email falls back to the team member list. Any failure returns nil.
    static func web(cookie: String, email: String?, plan: String?, teamID: String?) async -> Web? {
        let expected = (email ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard !expected.isEmpty else { return nil }
        func get(_ path: String) async -> JSON? {
            guard let response = try? await HTTP.send("https://dev.meta.ai\(path)", headers: ["Cookie": cookie]),
                  response.status == 200, let json = try? response.json(), json.raw is [String: Any] else { return nil }
            return json
        }
        guard let me = await get("/api/auth/me") else { return nil }
        let webEmail = (me["email"].string ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        var userID: String?
        if webEmail.isEmpty {
            userID = numericID(me["userId"])
            if userID == nil { return nil }
        } else if webEmail != expected {
            return nil
        }
        guard let listed = await get("/api/portal/teams"), listed["teams"].raw is [Any] else { return nil }
        let teams = listed["teams"].array.compactMap { entry -> (id: String, name: String)? in
            guard let id = numericID(entry["team_id"]) else { return nil }
            let name = entry["team_name"].string?.trimmingCharacters(in: .whitespaces)
            return (id, name?.isEmpty == false ? name! : id)
        }
        let selected = (teamID ?? "").trimmingCharacters(in: .whitespaces)
        let team = teams.first { $0.id == selected }
        if let userID {
            // Accept the session only if a visible team lists its user with the login's email.
            guard let probe = team ?? teams.first,
                  let members = await get("/api/portal/teams/\(probe.id)/members"), members["members"].raw is [Any],
                  let own = members["members"].array.first(where: { numericID($0["user_id"]) == userID }),
                  own["email"].string?.trimmingCharacters(in: .whitespaces).lowercased() == expected else { return nil }
        }
        if selected.isEmpty { return Web(teams: teams, note: "Choose a browser team in Muse Code settings") }
        guard let team else { return Web(teams: teams, note: "The selected browser team is not visible to this session") }
        guard let response = await get("/api/portal/teams/\(team.id)/subscription-quota") else { return nil }
        let quota = response["subscription_quota"]
        guard quota.raw is [String: Any] else {
            return Web(teams: teams, note: "No subscription quota for the selected team")
        }
        // The team's quota must be for the same plan the CLI login reports.
        guard let plan, quota["tier"].string?.trimmingCharacters(in: .whitespaces) == plan else {
            return Web(teams: teams, note: "The selected team's plan differs from the Muse login")
        }
        guard let parsed = webQuota(quota) else { return Web(teams: teams) }
        return Web(teams: teams, quota: (team.name, parsed.primary, parsed.secondary))
    }
}
