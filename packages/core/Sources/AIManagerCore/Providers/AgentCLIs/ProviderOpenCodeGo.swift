import Foundation

extension ProviderCatalog {
    private static let openCodeAuth = LiveFile(".local/share/opencode/auth.json", key: "opencode-go")

    // OpenCode Zen (id "opencode") is not ported: its balance needs a browser cookie, and no key endpoint exists.
    static let agentOpenCodeGo = ProviderSpec(
        id: "opencodego", name: "OpenCode Go", style: .files,
        files: [openCodeAuth],
        dashboard: "https://opencode.ai/auth",
        identify: { credential in
            credential.json(openCodeAuth.id)?["key"].string.map { CredentialIdentity(key: AgentCLIsKit.fingerprint($0), plan: "Go") }
        },
        usage: { credential in
            guard let key = credential.json(openCodeAuth.id)?["key"].string else {
                throw ProviderError.missingCredential("Sign in with opencode auth login, then import the sign-in.")
            }
            let response = try await HTTP.send("https://opencode.ai/zen/go/v1/usage", headers: HTTP.bearer(key))
            if response.status == 403, response.text.contains("EntitlementError") {
                throw ProviderError.unauthorized("This OpenCode account has no Go subscription.")
            }
            try HTTP.check(response)
            return try OpenCodeGoUsage.map(response.json(), serverDate: OpenCodeGoUsage.httpDate(response.headers["date"]))
        })
}

enum OpenCodeGoUsage {
    static func httpDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    static func map(_ json: JSON, serverDate: Date? = nil) throws -> ProviderUsage {
        let usage = json["usage"]
        var windows: [UsageWindow] = []
        for (id, source, title, minutes) in [("session", "rolling", "Session", 300), ("weekly", "weekly", "Weekly", 10080),
                                              ("monthly", "monthly", "Monthly", 43200)] {
            let entry = usage[source]
            guard let percent = entry["percent"].double else { continue }
            let reset = entry["resetsAt"].date
            // A 5-hour window that has not started yet reports a reset exactly 5 hours after the server time.
            if id == "session", percent == 0, let reset, let serverDate,
               abs(reset.timeIntervalSince(serverDate.addingTimeInterval(5 * 3600))) <= 2 {
                windows.append(UsageWindow(id: id, title: title, usedPercent: 0, windowMinutes: minutes, detail: "Not started"))
                continue
            }
            windows.append(UsageWindow(id: id, title: title, usedPercent: percent, resetsAt: reset, windowMinutes: minutes))
        }
        guard !windows.isEmpty else { throw ProviderError.parse("OpenCode Go returned no usage windows.") }
        return ProviderUsage(windows: windows, plan: "Go")
    }
}
