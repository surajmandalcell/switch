import Foundation

extension ProviderCatalog {
    static let ibmbob = ProviderSpec(
        id: "ibmbob", name: "IBM Bob",
        fields: [.apiKey("BOBSHELL_API_KEY")],
        dashboard: "https://bob.ibm.com", statusPage: nil,
        usage: { credential in
            let key = try IBMBobUsage.clean(credential.require("apiKey"))
            let auth = IBMBobUsage.isJWT(key) ? "Bearer \(key)" : "Apikey \(key)"
            let headers = ["Authorization": auth, "Content-Type": "application/json"]
            let profile = try await HTTP.json("https://api.us-east.bob.ibm.com/admin/v1/profile", headers: headers)
            var teams: [String: JSON] = [:]
            for instance in profile["instances"].array {
                guard let user = instance["user_id"].string else { continue }
                let host = try IBMBobUsage.host(instance["region_domain"].string)
                for team in instance["teams"].array {
                    guard let id = team["id"].string else { continue }
                    var extra = headers
                    extra["x-team-id"] = id
                    extra["x-instance-id"] = instance["instance_id"].string
                    do {
                        teams[IBMBobUsage.key(instance, team)] = try await HTTP.json(
                            "https://\(host)/admin/v1/teams/\(id)/users/\(user)", headers: extra)
                    } catch let error as ProviderError where error.needsSignIn {
                        throw error
                    } catch {} // The profile's own team numbers stand in.
                }
            }
            return try IBMBobUsage.map(profile: profile, teams: teams)
        })
}

enum IBMBobUsage {
    /// Drops the quotes an env file may leave around the key, as CodexBar's settings reader does.
    static func clean(_ key: String) throws -> String {
        let cleaned = key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'").union(.whitespacesAndNewlines))
        guard !cleaned.isEmpty else { throw ProviderError.missingCredential("Add the BOBSHELL_API_KEY for this account.") }
        return cleaned
    }

    static func key(_ instance: JSON, _ team: JSON) -> String {
        "\(instance["instance_id"].string ?? "")/\(team["id"].string ?? "")"
    }

    /// A JWT has three parts and a JSON object payload; anything else is an API key.
    static func isJWT(_ token: String) -> Bool {
        token.split(separator: ".", omittingEmptySubsequences: false).count == 3 && Fmt.jwtClaims(token)?.object.isEmpty == false
    }

    /// API host for a region domain; only `bob.ibm.com` hosts may receive the credential.
    static func host(_ regionDomain: String?) throws -> String {
        var host = regionDomain?.lowercased() ?? "us-east.bob.ibm.com"
        if !host.hasPrefix("api.") { host = "api." + host }
        guard host == "api.bob.ibm.com" || host.hasSuffix(".bob.ibm.com"),
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else {
            throw ProviderError.unsupported("IBM Bob returned an unexpected region host.")
        }
        return host
    }

    /// `teams` holds the per-user team replies keyed by `key(instance, team)`.
    static func map(profile: JSON, teams: [String: JSON]) throws -> ProviderUsage {
        guard profile["instances"].exists else { throw ProviderError.parse("IBM Bob returned an unexpected profile.") }
        var used = 0.0
        var limit: Double? = 0
        var refresh: Date?
        var plans: [String] = []
        var rows: [UsageRow] = []
        for instance in profile["instances"].array {
            if let plan = instance["plan_name"].string, !plans.contains(plan) { plans.append(plan) }
            for team in instance["teams"].array where team["id"].string != nil {
                let reply = teams[key(instance, team)]
                guard let usage = reply?["usage"].double ?? team["usage"].double else { continue }
                let cap = (reply?["budget_limit"].double ?? team["budget_limit"].double).flatMap { $0 >= 0 ? $0 : nil }
                used += max(0, usage)
                limit = limit.flatMap { total in cap.map { total + $0 } }
                if let date = instance["refresh_at"].date { refresh = min(refresh ?? date, date) }
                let instanceName = instance["instance_name"].string ?? instance["name"].string ?? instance["instance_id"].string ?? ""
                let teamName = team["name"].string ?? team["id"].string ?? "Team"
                let amount = cap.map { "\(Fmt.number(max(0, usage))) / \(Fmt.number($0)) Bobcoins" }
                    ?? "\(Fmt.number(max(0, usage))) Bobcoins used"
                rows.append(UsageRow(instanceName.isEmpty || instanceName == teamName ? teamName : "\(instanceName) - \(teamName)",
                                     [amount, instance["plan_name"].string].compactMap { $0 }.joined(separator: " · "),
                                     progress: cap.flatMap { $0 > 0 ? usage / $0 : nil }))
            }
        }
        guard !rows.isEmpty else { throw ProviderError.parse("IBM Bob returned no team usage.") }
        let total = limit.flatMap { $0 > 0 ? $0 : nil }
        let window = UsageWindow(
            id: "monthly", title: "Bobcoins", usedPercent: total.map { used / $0 * 100 }, resetsAt: refresh,
            windowMinutes: 30 * 24 * 60,
            detail: total.map { "\(Fmt.number(used)) / \(Fmt.number($0)) Bobcoins" } ?? "\(Fmt.number(used)) Bobcoins used")
        return ProviderUsage(windows: [window], sections: [UsageSection("Teams", rows)],
                             plan: plans.isEmpty ? nil : plans.joined(separator: ", "))
    }
}
