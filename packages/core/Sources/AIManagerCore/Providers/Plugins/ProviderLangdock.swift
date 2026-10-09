import Foundation

extension ProviderCatalog {
    static let langdock = ProviderSpec(
        id: "langdock", name: "Langdock",
        fields: [.cookie("Cookie header from app.langdock.com (needs auth_token)")],
        dashboard: "https://app.langdock.com/settings/account/usage",
        usage: { credential in
            let cookie = try credential.require("cookie")
            let input = #"{"0":{"json":null,"meta":{"values":["undefined"],"v":1}}}"#
            let encoded = input.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? input
            let response = try await HTTP.send(
                "https://app.langdock.com/api/trpc/usageSettings.getPersonalUsage?batch=1&input=\(encoded)",
                headers: ["Cookie": cookie, "Referer": "https://app.langdock.com/settings/account/usage"])
            try HTTP.check(response)
            return try LangdockUsage.map(try response.json())
        })
}

enum LangdockUsage {
    static func map(_ raw: JSON) throws -> ProviderUsage {
        let envelope = raw[0]
        guard raw.array.count == 1, envelope.raw is [String: Any] else {
            throw ProviderError.parse("Langdock returned an unexpected personal usage response.")
        }
        if envelope["error"].exists {
            switch envelope.at("error.json.data.code").string {
            case "UNAUTHORIZED": throw ProviderError.unauthorized("Langdock session expired. Paste a fresh Cookie header.")
            case "FORBIDDEN": throw ProviderError.unauthorized("Langdock denied access to personal usage.")
            case "TOO_MANY_REQUESTS": throw ProviderError.rateLimited("Langdock usage requests are rate limited.")
            case "INTERNAL_SERVER_ERROR", "TIMEOUT": throw ProviderError.unavailable("Langdock personal usage is temporarily unavailable.")
            default: throw ProviderError.parse("Langdock rejected the personal usage request.")
            }
        }
        let payload = envelope.at("result.data.json")
        guard payload.raw is [String: Any] else { throw ProviderError.parse("Langdock returned an unexpected personal usage response.") }
        let plan = payload["planUsage"]
        if payload["hasIncludedUsageLimits"].bool == false || !plan.exists {
            return ProviderUsage(sections: [.init("Usage", [.init("Included limits", "No included usage limits available")])])
        }
        guard let sessionEnabled = plan["sessionUsageLimitsEnabled"].bool,
              let weekly = plan["weeklyUsagePercent"].double else {
            throw ProviderError.parse("Langdock returned an unexpected personal usage response.")
        }
        var windows: [UsageWindow] = []
        if sessionEnabled {
            guard let session = plan["sessionUsagePercent"].double else {
                throw ProviderError.parse("Langdock returned an unexpected personal usage response.")
            }
            windows.append(UsageWindow(id: "session", title: "Session", usedPercent: session,
                                       resetsAt: plan["sessionResetsAt"].date, windowMinutes: 300))
        }
        windows.append(UsageWindow(id: "weekly", title: "Weekly", usedPercent: weekly,
                                   resetsAt: plan["weeklyResetsAt"].date, windowMinutes: 10_080))
        return ProviderUsage(windows: windows)
    }
}
