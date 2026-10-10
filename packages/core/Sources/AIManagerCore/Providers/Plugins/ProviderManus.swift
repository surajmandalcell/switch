import Foundation

extension ProviderCatalog {
    static let manus = ProviderSpec(
        id: "manus", name: "Manus",
        fields: [CredentialField("cookie", "Session cookie or token", placeholder: "session_id=…")],
        dashboard: "https://manus.im",
        usage: { credential in
            let raw = try credential.require("cookie")
            // Accept the whole Cookie header or the bare session token.
            let token = Fmt.cookie("session_id", in: raw) ?? (raw.contains("=") || raw.contains(";") ? "" : raw)
            guard !token.isEmpty else {
                throw ProviderError.missingCredential("Paste the Manus session_id cookie value.")
            }
            let json = try await HTTP.json(
                "https://api.manus.im/user.v1.UserService/GetAvailableCredits",
                headers: HTTP.bearer(token).merging([
                    "Origin": "https://manus.im", "Referer": "https://manus.im/",
                    "Connect-Protocol-Version": "1",
                ]) { $1 },
                object: [String: String]())
            return try ManusUsage.map(json)
        })
}

enum ManusUsage {
    private static let creditKeys = ["totalCredits", "freeCredits", "periodicCredits", "addonCredits",
                                     "refreshCredits", "maxRefreshCredits", "proMonthlyCredits", "eventCredits"]

    static func map(_ root: JSON) throws -> ProviderUsage {
        let data = [root["data"], root["result"], root["response"], root["availableCredits"], root]
            .first { $0.exists } ?? root
        guard creditKeys.contains(where: { data[$0].exists }) else {
            throw ProviderError.parse("Manus response is missing the credits fields.")
        }
        func num(_ key: String) -> Double { data[key].double ?? 0 }
        let total = num("totalCredits"), free = num("freeCredits"), monthly = num("proMonthlyCredits")
        let periodic = num("periodicCredits"), refresh = num("refreshCredits")
        let maxRefresh = num("maxRefreshCredits")
        // Numeric reset times count seconds from 2001-01-01 (Foundation reference date).
        let reset: Date? = data["nextRefreshTime"].double.map { Date(timeIntervalSinceReferenceDate: $0) }
            ?? data["nextRefreshTime"].string.flatMap(Fmt.iso)
        var windows: [UsageWindow] = []
        if let window = UsageWindow.amounts(id: "monthly", title: "Monthly credits", used: monthly - periodic,
                                            limit: monthly, unit: "credits") {
            windows.append(window)
        }
        // The refresh interval ("DAILY") names the window: "Daily: 200 / 300".
        let interval = data["refreshInterval"].string.map { $0.lowercased().capitalized }
        if var window = UsageWindow.amounts(id: "daily", title: interval ?? "Daily refresh", used: maxRefresh - refresh,
                                            limit: maxRefresh, resetsAt: reset, unit: "credits") {
            window.detail = "\(interval.map { "\($0): " } ?? "")\(Fmt.number(refresh.rounded())) / \(Fmt.number(maxRefresh.rounded()))"
            windows.append(window)
        }
        let rows = [UsageRow("Total credits", Fmt.number(total.rounded())),
                    UsageRow("Free credits", Fmt.number(free.rounded()))]
        return ProviderUsage(windows: windows, sections: [UsageSection("Balance", rows)],
                             plan: "Balance: \(Fmt.number(total.rounded())) credits")
    }
}
