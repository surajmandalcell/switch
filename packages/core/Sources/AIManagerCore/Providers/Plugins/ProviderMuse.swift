import Foundation

extension ProviderCatalog {
    /// The Muse CLI keeps its device-code login in ~/.config/muse/auth.json; a pasted `dca:` token also works.
    static let muse = ProviderSpec(
        id: "muse", name: "Muse Code",
        style: .files,
        fields: [CredentialField("token", "Device token (optional)", optional: true, placeholder: "dca:…")],
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
            return try MuseUsage.map(json)
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

    static func map(_ root: JSON) throws -> ProviderUsage {
        // The response also holds an api_key and a payment_method; neither is read or kept.
        if root["require_payment"].bool == true {
            throw ProviderError.unauthorized("Muse Code requires a payment method. Finish billing at dev.meta.ai.")
        }
        guard root["is_subs_active"].bool == true else {
            throw ProviderError.unauthorized("No Muse Code subscription is active on this login.")
        }
        let plan = root["subs_tier_name"].string, email = root["user_email"].string
        let usage = root["subs_usage"]
        guard usage.exists else {
            // The login response omits quotas while the 5-hour window is idle.
            return ProviderUsage(sections: [UsageSection("Muse Code", [UsageRow("Quota", "Not included in this login response")])],
                                 plan: plan, email: email)
        }
        guard let window = usage["window"]["used_percent"].double, let minutes = usage["window"]["window_duration_mins"].int,
              minutes > 0, let weekly = usage["weekly"]["used_percent"].double else {
            throw ProviderError.parse("Could not parse Muse Code subscription usage.")
        }
        return ProviderUsage(
            windows: [UsageWindow(id: "session", title: "5 hours", usedPercent: window,
                                  resetsAt: reset(usage["window"]["resets_at"]), windowMinutes: minutes),
                      UsageWindow(id: "weekly", title: "Weekly", usedPercent: weekly,
                                  resetsAt: reset(usage["weekly"]["resets_at"]), windowMinutes: 10080)],
            plan: plan, email: email)
    }
}
