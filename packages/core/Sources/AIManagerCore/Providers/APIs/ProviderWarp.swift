import Foundation

extension ProviderCatalog {
    static let warp = ProviderSpec(
        id: "warp", name: "Warp",
        fields: [CredentialField("apiKey", "API key", placeholder: "wk-...", env: ["WARP_API_KEY", "WARP_TOKEN"])],
        dashboard: "https://app.warp.dev",
        usage: { credential in
            let key = try credential.require("apiKey")
            let version = ProcessInfo.processInfo.operatingSystemVersion
            let os = ["category": "macOS", "name": "macOS", "version": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"]
            let json = try await HTTP.json(
                "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo",
                headers: HTTP.bearer(key).merging([
                    "User-Agent": "Warp/1.0", "x-warp-client-id": "warp-app", "x-warp-os-category": os["category"]!,
                    "x-warp-os-name": os["name"]!, "x-warp-os-version": os["version"]!,
                ]) { $1 },
                object: [
                    "query": WarpUsage.query, "operationName": "GetRequestLimitInfo",
                    "variables": ["requestContext": ["clientContext": [String: String](), "osContext": os]],
                ])
            return try WarpUsage.map(json)
        })
}

enum WarpUsage {
    static let query = """
    query GetRequestLimitInfo($requestContext: RequestContext!) { user(requestContext: $requestContext) { __typename \
    ... on UserOutput { user { requestLimitInfo { isUnlimited nextRefreshTime requestLimit requestsUsedSinceLastRefresh } \
    bonusGrants { requestCreditsGranted requestCreditsRemaining expiration } \
    workspaces { bonusGrantsInfo { grants { requestCreditsGranted requestCreditsRemaining expiration } } } } } } }
    """

    static func map(_ json: JSON) throws -> ProviderUsage {
        if let message = json["errors"].array.first?["message"].string {
            throw ProviderError.parse("Warp reported an error: \(message.prefix(120))")
        }
        let user = json.at("data.user.user")
        guard user.exists else { throw ProviderError.parse("Warp returned an unexpected reply.") }
        var windows: [UsageWindow] = []
        let info = user["requestLimitInfo"]
        if info.exists {
            let limit = info["requestLimit"].double ?? 0
            let used = info["requestsUsedSinceLastRefresh"].double ?? 0
            if info["isUnlimited"].bool == true {
                windows.append(UsageWindow(id: "credits", title: "Credits", usedPercent: 0, detail: "Unlimited"))
            } else if limit > 0 {
                windows.append(UsageWindow(id: "credits", title: "Credits", usedPercent: used / limit * 100,
                                           resetsAt: info["nextRefreshTime"].date,
                                           detail: "\(Fmt.number(used)) / \(Fmt.number(limit)) credits"))
            }
        }
        let grants = user["bonusGrants"].array + user["workspaces"].array.flatMap { $0.at("bonusGrantsInfo.grants").array }
        let total = grants.reduce(0) { $0 + ($1["requestCreditsGranted"].double ?? 0) }
        let remaining = grants.reduce(0) { $0 + ($1["requestCreditsRemaining"].double ?? 0) }
        let live = grants.filter { ($0["requestCreditsRemaining"].double ?? 0) > 0 }
        let expiry = live.compactMap { $0["expiration"].date }.min()
        if total > 0 || remaining > 0 || expiry != nil {
            let atExpiry = live.filter { $0["expiration"].date == expiry }
                .reduce(0) { $0 + ($1["requestCreditsRemaining"].double ?? 0) }
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US")
            day.dateStyle = .medium
            day.timeStyle = .none
            day.timeZone = TimeZone(identifier: "UTC")
            let used = total > 0 ? (total - remaining) / total * 100 : (remaining > 0 ? 0 : 100)
            windows.append(UsageWindow(
                id: "addon", title: "Add-on credits", usedPercent: used,
                detail: expiry.map { "\(Fmt.number(atExpiry)) credits expires on \(day.string(from: $0))" }
                    ?? "\(Fmt.number(remaining)) credits left"))
        }
        return ProviderUsage(windows: windows)
    }
}
