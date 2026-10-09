import Foundation

extension ProviderCatalog {
    /// WorkBuddy ties the session to the browser User-Agent, so the field asks for the Chrome major version.
    /// ponytail: the next-reset lookup needs hardcoded package codes, so it is skipped and the window has no reset time; add the lookup when users ask for the reset date.
    static let workbuddy = ProviderSpec(
        id: "workbuddy", name: "WorkBuddy",
        fields: [.cookie("Cookie header from www.workbuddy.cn/profile/plans-usage"),
                 CredentialField("chromeVersion", "Chrome major version", secure: false, optional: true,
                                 placeholder: "For example 143; match the browser that signed in")],
        dashboard: "https://www.workbuddy.cn/profile/plans-usage",
        usage: { credential in
            let cookie = try credential.require("cookie")
            // The previous major covers a Chrome update that has not relaunched yet.
            let major = credential["chromeVersion"].flatMap(Int.init)
            let agents = major.map { [$0, $0 - 1].map(WorkBuddyUsage.userAgent) } ?? [HTTP.userAgent]
            for (index, agent) in agents.enumerated() {
                let response = try await HTTP.send(
                    "https://www.workbuddy.cn/billing/meter/get-user-resource-summary", method: "POST",
                    headers: ["Cookie": cookie, "User-Agent": agent, "Origin": "https://www.workbuddy.cn",
                              "Referer": "https://www.workbuddy.cn/profile/plans-usage"],
                    body: Data("{}".utf8))
                if response.status == 401, index < agents.count - 1 { continue }
                try HTTP.check(response)
                return try WorkBuddyUsage.map(try response.json())
            }
            throw ProviderError.unauthorized("WorkBuddy session expired. Paste a fresh Cookie header.")
        })
}

enum WorkBuddyUsage {
    static func userAgent(major: Int) -> String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36"
    }

    static func map(_ json: JSON) throws -> ProviderUsage {
        guard json["code"].int == 0, json["data"]["Packages"].raw is [Any] else {
            throw ProviderError.parse("Invalid WorkBuddy billing response.")
        }
        let data = json["data"]
        // Amounts arrive as decimal strings such as "500".
        var total = 0.0, remaining = 0.0, frozen = 0.0
        for item in data["Packages"].array where item["CapacityUnit"].string == "credits" {
            guard let cycleTotal = item["CycleTotalCapacity"].double, let cycleLeft = item["CycleRemainCapacity"].double else {
                throw ProviderError.parse("Invalid WorkBuddy billing response: credit amounts.")
            }
            total += cycleTotal
            remaining += cycleLeft
            frozen += item["CycleFrozenCapacity"].double ?? 0
        }
        var rows: [UsageRow] = []
        if frozen > 0 { rows.append(UsageRow("Reserved", Fmt.number(frozen, digits: 2))) }
        var windows: [UsageWindow] = []
        if total > 0 {
            windows.append(UsageWindow(id: "credits", title: "Credits", usedPercent: max(0, total - remaining) / total * 100,
                                       detail: "\(Fmt.number(remaining, digits: 2)) / \(Fmt.number(total, digits: 2)) credits left"))
        } else {
            rows = [UsageRow("Left", Fmt.number(remaining, digits: 2)), UsageRow("Total", Fmt.number(total, digits: 2))] + rows
        }
        return ProviderUsage(windows: windows, sections: [UsageSection("Credits", rows)], plan: data["SubscriptionPackageName"].string)
    }
}
