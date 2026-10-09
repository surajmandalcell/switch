import Foundation

extension ProviderCatalog {
    static let clinepass = ProviderSpec(
        id: "clinepass", name: "ClinePass",
        fields: [.apiKey("CLINE_API_KEY")],
        dashboard: "https://app.cline.bot/dashboard/subscription?personal=true",
        usage: { credential in
            let json = try await HTTP.json("https://api.cline.bot/api/v1/users/me/plan/usage-limits",
                                           headers: HTTP.bearer(try credential.require("apiKey")))
            return try ClinepassUsage.map(json)
        })
}

enum ClinepassUsage {
    static func map(_ json: JSON) throws -> ProviderUsage {
        guard json["success"].bool == true, json["data"].raw is [String: Any], json.at("data.limits").raw is [Any] else {
            throw ProviderError.parse("Failed to parse ClinePass response: unexpected shape.")
        }
        // Order matters: the 5-hour window feeds the menu bar.
        let kinds: [(String, String, Int)] = [("five_hour", "5-hour", 300), ("weekly", "Weekly", 10_080),
                                              ("monthly", "Monthly", 43_200)]
        var windows: [UsageWindow] = []
        for (type, title, minutes) in kinds {
            guard let limit = json.at("data.limits").array.first(where: { $0["type"].string == type }) else { continue }
            guard let percent = limit["percentUsed"].double else {
                throw ProviderError.parse("Failed to parse ClinePass response: percentUsed must be a number for \(type).")
            }
            windows.append(UsageWindow(id: type, title: title, usedPercent: percent, resetsAt: limit["resetsAt"].date,
                                       windowMinutes: minutes))
        }
        return ProviderUsage(windows: windows)
    }
}
