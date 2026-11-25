import Foundation

extension ProviderCatalog {
    /// Reads a file-backed Muse login. Usage also accepts a pasted `dca:` token.
    static let muse = ProviderSpec(
        id: "muse", name: "Muse Code",
        style: .files,
        fields: [CredentialField("token", "Device token (optional)", optional: true, placeholder: "dca:…")],
        files: [LiveFile(".config/muse/auth.json")],
        login: ["muse", "login"],
        // A Keychain-backed login cannot be read unattended, so sign-in writes the token to auth.json.
        loginEnv: ["TBH_CREDENTIAL_BACKEND": "file"],
        dashboard: "https://dev.meta.ai",
        usage: { credential in
            let token = try MuseUsage.token(credential)
            guard token.hasPrefix("dca:") else {
                throw ProviderError.unauthorized("Muse Code needs a device-code login. Open Muse Code and sign in again.")
            }
            let json = try await HTTP.json(
                "https://api.meta.ai/muse-code/key",
                headers: HTTP.bearer(token).merging(["x-api-version": "1.0.0"]) { $1 },
                object: [String: String]())
            return try MuseUsage.map(json)
        })
}

enum MuseUsage {
    static let fileLoginHint = "Run TBH_CREDENTIAL_BACKEND=file muse login, then add the account again."

    /// The pasted token, else the inline token of a file-backed login. A Keychain-backed login gets sign-in guidance.
    static func token(_ credential: ProviderCredential) throws -> String {
        if let token = credential["token"] { return token }
        let auth = credential.json(".config/muse/auth.json")
        if let token = auth?.at("providers.meta.access_token").string, !token.isEmpty { return token }
        if auth != nil {
            throw ProviderError.missingCredential("Muse Code keeps this login in the Keychain. " + fileLoginHint)
        }
        throw ProviderError.missingCredential("Sign in to Muse Code. " + fileLoginHint)
    }

    private static func reset(_ value: JSON) -> Date? {
        guard let seconds = value.double, seconds > 0, seconds <= 64_092_211_200 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func percentLabel(_ value: Double) -> String { "\(Fmt.number(value))%" }

    static func map(_ root: JSON) throws -> ProviderUsage {
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
            // The login response omits quotas while the 5-hour window is idle.
            rows.append(UsageRow("Quota", "Not included in this login response"))
            return ProviderUsage(sections: [UsageSection("Muse Code subscription", rows)], plan: plan ?? "Muse login", email: email)
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
}
