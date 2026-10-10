import Foundation

extension ProviderCatalog {
    /// WorkBuddy ties the session to the browser User-Agent, so the field asks for the Chrome major version.
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
            func post(_ path: String, agent: String, body: Data) async throws -> HTTPResponse {
                try await HTTP.send(
                    "https://www.workbuddy.cn\(path)", method: "POST",
                    headers: ["Cookie": cookie, "User-Agent": agent, "Origin": "https://www.workbuddy.cn",
                              "Referer": "https://www.workbuddy.cn/profile/plans-usage"],
                    body: body)
            }
            for (index, agent) in agents.enumerated() {
                let response = try await post("/billing/meter/get-user-resource-summary", agent: agent, body: Data("{}".utf8))
                if response.status == 401, index < agents.count - 1 { continue }
                try HTTP.check(response)
                var usage = try WorkBuddyUsage.map(try response.json())
                // The reset time is optional: a failed package listing keeps the balance.
                var listings: [JSON] = []
                for (path, codes) in [("/billing/meter/get-user-resource-paid-packages", WorkBuddyUsage.paidPackageCodes),
                                      ("/billing/meter/get-user-resource-free-packages", WorkBuddyUsage.freePackageCodes)] {
                    let body: [String: Any] = ["PageNumber": 1, "PageSize": 100, "PackageCodes": codes, "Status": [0, 3]]
                    if let data = try? JSONSerialization.data(withJSONObject: body),
                       let page = try? await post(path, agent: agent, body: data), page.status == 200,
                       let json = try? page.json(), json["code"].int == 0 {
                        listings.append(json["data"])
                    }
                }
                if let reset = WorkBuddyUsage.nextReset(listings), let first = usage.windows.indices.first {
                    usage.windows[first].resetsAt = reset
                }
                return usage
            }
            throw ProviderError.unauthorized("WorkBuddy session expired. Paste a fresh Cookie header.")
        })
}

enum WorkBuddyUsage {
    static func userAgent(major: Int) -> String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36"
    }

    /// Package codes the WorkBuddy client sends for its paid and free listings (WorkBuddy 5.6.2). The listings
    /// reject requests without them.
    static let paidPackageCodes = ["TCACA_code_002_AkiJS3ZHF5", "TCACA_code_005_maRGyrHhw1", "TCACA_code_003_FAnt7lcmRT",
                                   "TCACA_code_023_4xbGhMrE6q", "TCACA_code_026_BaESVICNoi", "TCACA_code_027_0FCGVA6vSa",
                                   "TCACA_code_009_0XmEQc2xOf", "TCACA_code_038_OhvqZtiPKr", "TCACA_code_036_lupO5WgNdG"]
    static let freePackageCodes = ["TCACA_code_001_PqouKr6QWV", "TCACA_code_008_cfWoLwvjU4", "TCACA_code_035_ArVxJcGDsm",
                                   "TCACA_code_006_DbXS0lrypC", "TCACA_code_039_KRcQj7wUat", "TCACA_code_040_mi9rCYg46x",
                                   "TCACA_code_007_nzdH5h4Nl0", "TCACA_code_028_NtpWi0jzXs", "TCACA_code_037_WxOD3MpI2o",
                                   "TCACA_code_029_6wCGEWquYy", "TCACA_code_030_BjSt89qTvr"]

    /// Earliest future `CycleEndTime` of a credits account in the listings' `data`. The times carry no zone: they
    /// are China Standard Time, and the dashboard refreshes one second after the inclusive end.
    static func nextReset(_ listings: [JSON], now: Date = Date()) -> Date? {
        var earliest: Date?
        for page in listings {
            for account in page["Accounts"].array where account["CapacityUnit"].string == "credits" {
                guard let raw = account["CycleEndTime"].string?.trimmingCharacters(in: .whitespaces),
                      raw.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil,
                      let end = Fmt.iso(raw.replacingOccurrences(of: " ", with: "T") + "+08:00") else { continue }
                let reset = end.addingTimeInterval(1)
                if reset > now, earliest.map({ reset < $0 }) ?? true { earliest = reset }
            }
        }
        return earliest
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
