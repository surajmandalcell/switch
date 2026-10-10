import Foundation

extension ProviderCatalog {
    static let agentAmp = ProviderSpec(
        id: "amp", name: "Amp",
        fields: [CredentialField("token", "Access token", placeholder: "sgamp_...", env: ["AMP_API_KEY"])],
        dashboard: "https://ampcode.com/settings/usage",
        usage: { credential in
            let json = try await HTTP.json(
                "https://ampcode.com/api/internal?userDisplayBalanceInfo",
                headers: HTTP.bearer(try credential.require("token")),
                object: ["method": "userDisplayBalanceInfo", "params": [String: String]()])
            return try AmpUsage.map(json: json, now: Date())
        })
}

enum AmpUsage {
    static func map(json: JSON, now: Date) throws -> ProviderUsage {
        if json["ok"].bool == false {
            if json.at("error.code").string == "auth-required" {
                throw ProviderError.unauthorized("Amp rejected this access token. Create a new one in Amp settings.")
            }
            throw ProviderError.parse("Amp reported an error.")
        }
        guard let text = json.at("result.displayText").string else {
            throw ProviderError.parse("Amp returned no usage text.")
        }
        return try map(displayText: text, now: now)
    }

    /// Parses the free-form text that `amp usage` prints. Several wordings exist, so each is a pattern.
    static func map(displayText: String, now: Date) throws -> ProviderUsage {
        let text = displayText.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
        let amount = #"([0-9][0-9,]*(?:\.[0-9]+)?)"#
        let identity = captures(text, #"(?im)^\s*Signed in as\s+([^\s(]+)(?:\s+\(([^\r\n)]+)\))?\s*$"#)
        var windows: [UsageWindow] = []
        var plan: String?

        let tier = captures(text, #"(?im)^\s*Amp\s+([^\r\n]+?)\s+Tier:\s*agent\s+usage\s+\$"# + amount + #"\s+of\s+\$"# + amount
            + #"\s+remaining\b([^\r\n]*?)resets\s+upon\s+renewal\s+in\s+([0-9][0-9,]*)\s+(days?|months?)\b"#)
        if let tier, let remaining = number(tier[1]), let limit = number(tier[2]), limit > 0 {
            let period = period(in: tier[3])
            let reset = period?.end ?? number(tier[4]).flatMap { renewal(Int($0), tier[5], now) }
            plan = tier[0]
            windows.append(UsageWindow(id: "agent", title: "Agent usage", usedPercent: (limit - remaining) / limit * 100,
                                       resetsAt: reset, windowMinutes: period.map { Int($0.end.timeIntervalSince($0.start) / 60) },
                                       detail: "\(Fmt.money(limit - remaining)) / \(Fmt.money(limit))"))
            if let orb = captures(tier[3], #"(?i)\borb\s+usage\s+"# + amount + #"h\s+of\s+"# + amount + #"h\s+a1\.small\s+orb\s+hours\s+remaining\b"#),
               let orbRemaining = number(orb[0]), let orbLimit = number(orb[1]), orbLimit > 0 {
                windows.append(UsageWindow(id: "orb", title: "Orb usage", usedPercent: (orbLimit - orbRemaining) / orbLimit * 100,
                                           resetsAt: reset, detail: "\(Fmt.number(orbRemaining.rounded(.down)))h of \(Fmt.number(orbLimit))h left"))
            }
        } else {
            let suffix = #"\s*"# + amount + #"\s*%\s+other\s+usage\s+and\s+"# + amount
                + #"\s*%\s+orb\s+usage\s+remaining\s*-\s*resets\s+upon\s+renewal\s+in\s+([0-9][0-9,]*)\s+(days?|months?)"#
            if let sub = captures(text, #"(?im)^\s*Subscription\s+(.+?):"# + suffix)
                ?? captures(text, #"(?im)^\s*Amp\s+(.+?)\s+Subscription:"# + suffix),
               let other = number(sub[1]), let orb = number(sub[2]) {
                let reset = number(sub[3]).flatMap { renewal(Int($0), sub[4], now) }
                plan = sub[0]
                windows.append(UsageWindow(id: "other", title: "Other usage", usedPercent: 100 - other, resetsAt: reset))
                windows.append(UsageWindow(id: "orb", title: "Orb usage", usedPercent: 100 - orb, resetsAt: reset))
            }
        }

        let freeAmount = captures(text, #"(?im)^\s*Amp Free:\s*\$?"# + amount + #"\s*/\s*\$?"# + amount
            + #"\s+remaining(?:\s*\(replenishes\s*\+\$?"# + amount + #"\s*/\s*hour\))?"#)
        let freePercent = captures(text, #"(?im)^\s*Amp Free:\s*"# + amount + #"\s*%\s+remaining(?:\s+today)?(?:\s*(\(resets\s+daily\)))?"#)
        var free: UsageWindow?
        if let freeAmount, let remaining = number(freeAmount[0]), let quota = number(freeAmount[1]), quota > 0 {
            let hourly = number(freeAmount[2]) ?? 0
            let used = max(0, quota - remaining)
            free = UsageWindow(id: "free", title: "Free tier", usedPercent: used / quota * 100,
                               resetsAt: hourly > 0 ? now.addingTimeInterval(used / hourly * 3600) : nil,
                               windowMinutes: hourly > 0 ? Int(max(1, (quota / hourly).rounded()) * 60) : nil,
                               detail: "\(Fmt.money(remaining)) of \(Fmt.money(quota)) left")
        } else if let freePercent, let remaining = number(freePercent[0]) {
            var zone = Calendar(identifier: .gregorian)
            zone.timeZone = TimeZone(identifier: "America/New_York") ?? .current
            free = UsageWindow(id: "free", title: "Free tier", usedPercent: 100 - min(100, max(0, remaining)),
                               resetsAt: freePercent[1].isEmpty ? nil : zone.nextDate(
                                   after: now, matching: DateComponents(hour: 20, minute: 0, second: 0), matchingPolicy: .nextTime),
                               windowMinutes: 1440)
        }
        if let free { windows.append(free) }

        let credits = captures(text, #"(?im)^\s*Individual credits:\s*\$?"# + amount + #"\s+remaining"#).flatMap { number($0[0]) }
        var rows: [UsageRow] = []
        if let regex = try? NSRegularExpression(pattern: #"(?im)^\s*Workspace\s+(.+?):\s*\$?"# + amount + #"\s+remaining"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let found = groups(text, match)
                if let value = number(found[1]) { rows.append(UsageRow("Workspace \(found[0])", Fmt.money(value))) }
            }
        }
        guard !windows.isEmpty || credits != nil || !rows.isEmpty else {
            throw ProviderError.parse("Amp returned usage text that Switch cannot read.")
        }
        return ProviderUsage(windows: windows, cost: credits.map { UsageCost(balance: $0) },
                             sections: [UsageSection("Workspaces", rows)],
                             plan: plan ?? (free != nil ? "Amp Free" : "Amp"),
                             email: identity?[0], organization: identity.flatMap { $0[1].isEmpty ? nil : $0[1] })
    }

    private static func number(_ text: String) -> Double? { Double(text.replacingOccurrences(of: ",", with: "")) }

    private static func captures(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return groups(text, match)
    }

    private static func groups(_ text: String, _ match: NSTextCheckingResult) -> [String] {
        (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) } ?? ""
        }
    }

    private static func period(in text: String) -> (start: Date, end: Date)? {
        guard let dates = captures(text, #"\bperiod\s+(\d{4}-\d{2}-\d{2})\s+to\s+(\d{4}-\d{2}-\d{2})\b"#),
              let start = Fmt.iso(dates[0]), let end = Fmt.iso(dates[1]), end > start else { return nil }
        return (start, end)
    }

    private static func renewal(_ value: Int, _ unit: String, _ now: Date) -> Date? {
        Calendar(identifier: .gregorian).date(byAdding: unit.lowercased().hasPrefix("month") ? .month : .day, value: value, to: now)
    }
}
