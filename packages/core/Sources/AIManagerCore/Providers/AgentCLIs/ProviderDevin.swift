import Foundation

extension ProviderCatalog {
    private static let devinFile = LiveFile(".local/share/devin/credentials.toml")

    static let agentDevin = ProviderSpec(
        id: "devin", name: "Devin", style: .files,
        files: [devinFile],
        dashboard: "https://app.devin.ai/settings/plans",
        identify: { credential in
            // The file holds no email, so the key itself names the account.
            credential.files[devinFile.id].flatMap { DevinUsage.credentials(String(decoding: $0, as: UTF8.self)) }
                .map { CredentialIdentity(key: AgentCLIsKit.fingerprint($0.apiKey)) }
        },
        usage: { credential in
            guard let auth = credential.files[devinFile.id].flatMap({ DevinUsage.credentials(String(decoding: $0, as: UTF8.self)) }) else {
                throw ProviderError.missingCredential("Run devin auth login, then import the sign-in.")
            }
            let metadata: [String: Any] = [
                "apiKey": auth.apiKey, "ideName": "devin", "ideVersion": "1.108.2",
                "extensionName": "devin", "extensionVersion": "1.108.2", "locale": "en",
            ]
            let json = try await HTTP.json(
                "\(auth.server)/exa.seat_management_pb.SeatManagementService/GetUserStatus",
                headers: ["Connect-Protocol-Version": "1"], object: ["metadata": metadata])
            return try DevinUsage.map(json)
        })
}

enum DevinUsage {
    static func credentials(_ toml: String) -> (apiKey: String, server: String)? {
        guard let key = tomlString(toml, key: "windsurf_api_key") else { return nil }
        var server = tomlString(toml, key: "api_server_url") ?? ""
        while server.hasSuffix("/") { server.removeLast() }
        return (key, server.hasPrefix("https://") ? server : "https://server.codeium.com")
    }

    /// Reads one top-level `key = "value"` line. Handles quotes and trailing comments only.
    static func tomlString(_ text: String, key: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                let body = value.dropFirst()
                guard let end = body.firstIndex(of: quote) else { return nil }
                let text = body[..<end].trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : text
            }
            let bare = value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            return bare.isEmpty ? nil : bare
        }
        return nil
    }

    /// `userStatus` is proto3 JSON: zero values are missing, and quotas are percent REMAINING.
    static func map(_ json: JSON) throws -> ProviderUsage {
        let plan = json.at("userStatus.planStatus")
        guard plan.exists else { throw ProviderError.parse("Devin returned no plan status.") }
        let hideDaily = plan.at("planInfo.hideDailyQuota").bool == true
        func window(_ id: String, _ title: String, _ remaining: String, _ reset: String, _ minutes: Int) throws -> UsageWindow? {
            let left = plan[remaining]
            if left.exists, left.double == nil { throw ProviderError.parse("Devin returned an unreadable quota.") }
            let resetsAt = plan[reset].date
            guard left.exists || resetsAt != nil else { return nil }
            return UsageWindow(id: id, title: title, usedPercent: 100 - (left.double ?? 0), resetsAt: resetsAt, windowMinutes: minutes)
        }
        let daily = hideDaily ? nil : try window("daily", "Daily", "dailyQuotaRemainingPercent", "dailyQuotaResetAtUnix", 1440)
        var weekly = try window("weekly", "Weekly", "weeklyQuotaRemainingPercent", "weeklyQuotaResetAtUnix", 10080)
        if weekly == nil, hideDaily, plan["dailyQuotaRemainingPercent"].exists {
            weekly = try window("weekly", "Weekly", "dailyQuotaRemainingPercent", "dailyQuotaResetAtUnix", 1440)
        }
        let windows = [daily, weekly].compactMap { $0 }
        let micros = plan["overageBalanceMicros"].double
        guard !windows.isEmpty || micros != nil else { throw ProviderError.parse("Devin quota is unavailable.") }
        return ProviderUsage(windows: windows, cost: micros.map { UsageCost(balance: max(0, $0) / 1_000_000) },
                             plan: plan.at("planInfo.planName").string)
    }
}
