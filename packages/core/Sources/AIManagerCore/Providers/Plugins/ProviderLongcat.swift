import Foundation

extension ProviderCatalog {
    static let longcat = ProviderSpec(
        id: "longcat", name: "LongCat",
        fields: [.cookie("Cookie header from longcat.chat")],
        dashboard: "https://longcat.chat/platform/usage",
        usage: { credential in
            let headers = ["Cookie": try credential.require("cookie"), "Origin": "https://longcat.chat",
                           "Referer": "https://longcat.chat/platform/usage"]
            func call(_ path: String, post: Bool = false) async throws -> JSON {
                let response = try await HTTP.send("https://longcat.chat\(path)", method: post ? "POST" : "GET",
                                                   headers: headers, body: post ? Data("{}".utf8) : nil)
                guard response.status != 401, response.status != 403, !(300..<400).contains(response.status) else {
                    throw ProviderError.unauthorized("LongCat session is invalid or expired. Paste a fresh Cookie header.")
                }
                try HTTP.check(response)
                return try LongCatUsage.unwrap(try response.json())
            }
            let account = try await call("/api/v1/user-current")
            let summary = try? await call("/api/pay/quota/metering/token-packs/summary", post: true)
            // The token usage endpoint is only needed when there is no active token pack.
            var tokenUsage: JSON?
            if !LongCatUsage.hasActivePack(summary) { tokenUsage = try await call("/api/lc-platform/v1/tokenUsage") }
            let fuel = try? await call("/api/lc-platform/v1/pending-fuel-packages")
            return try LongCatUsage.map(account: account, summary: summary, tokenUsage: tokenUsage, fuel: fuel)
        })
}

enum LongCatUsage {
    /// Strips the `{code, data}` envelope; `code` 0 or 200 means success.
    static func unwrap(_ root: JSON) throws -> JSON {
        guard root.raw is [String: Any] else { throw ProviderError.parse("Invalid LongCat response: not a JSON object.") }
        if root["code"].exists {
            guard let code = root["code"].int else {
                throw ProviderError.parse("Invalid LongCat response: response code was not a valid integer.")
            }
            if code == 401 || code == 403 {
                throw ProviderError.unauthorized("LongCat session is invalid or expired. Paste a fresh Cookie header.")
            }
            if code != 0 && code != 200 {
                throw ProviderError.http(code, root["message"].string ?? root["msg"].string ?? "LongCat code \(code)")
            }
        }
        let data = root["data"].exists ? root["data"] : root
        guard data.raw is [String: Any] else { throw ProviderError.parse("Invalid LongCat response: data was not an object.") }
        return data
    }

    static func hasActivePack(_ summary: JSON?) -> Bool {
        let lot = summary?["currentLot"]
        return lot?["status"].string?.uppercased() == "ACTIVE" && (lot?["totalToken"].double ?? 0) > 0
    }

    static func map(account: JSON, summary: JSON?, tokenUsage: JSON?, fuel: JSON?) throws -> ProviderUsage {
        var total: Double?, used: Double?
        if hasActivePack(summary), let lot = summary?["currentLot"] {
            total = lot["totalToken"].double
            used = lot["consumedToken"].double ?? 0
        } else if let tokenUsage {
            let usage = tokenUsage["usage"].exists ? tokenUsage["usage"] : tokenUsage
            total = usage["totalToken"].double
            guard let total else { throw ProviderError.parse("Invalid LongCat response: tokenUsage was missing totalToken.") }
            used = usage["usedToken"].double ?? total - (usage["availableToken"].double ?? total)
        }
        let fuelTotal = fuel?["totalQuota"].double
        var remaining = 0.0, sawRemaining = false
        var reset: Date?
        for pack in fuel?["list"].array ?? [] {
            if let available = pack["availableToken"].double { remaining += available; sawRemaining = true }
            if let date = pack["expireTime"].date, reset.map({ date < $0 }) ?? true { reset = date }
        }
        if !sawRemaining { remaining = fuelTotal ?? 0 }

        var windows: [UsageWindow] = []
        if let total, let window = UsageWindow.amounts(id: "quota", title: "Quota", used: max(0, used ?? 0), limit: total,
                                                       unit: "tokens") {
            windows.append(window)
        }
        if let fuelTotal, let window = UsageWindow.amounts(id: "fuel", title: "Fuel pack", used: max(0, fuelTotal - remaining),
                                                           limit: fuelTotal, resetsAt: reset, unit: "tokens") {
            windows.append(window)
        }
        guard !windows.isEmpty else { throw ProviderError.parse("LongCat returned no usage quota.") }
        return ProviderUsage(windows: windows, organization: account["name"].string ?? account["nickName"].string)
    }
}
