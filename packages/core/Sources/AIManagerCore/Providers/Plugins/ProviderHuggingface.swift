import Foundation

extension ProviderCatalog {
    static let huggingface = ProviderSpec(
        id: "huggingface", name: "Hugging Face",
        fields: [.init("token", "Access token", env: ["HF_TOKEN"]),
                 .init("cookie", "Cookie header (prepaid balance)", optional: true,
                       placeholder: "Optional Cookie header from huggingface.co")],
        dashboard: "https://huggingface.co/settings/billing",
        usage: { credential in
            let headers = HTTP.bearer(try credential.require("token"))
            let now = Date()
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            let start = Int(utc.date(from: utc.dateComponents([.year, .month], from: now))!.timeIntervalSince1970)
            let billing = try await HTTP.json(
                "https://huggingface.co/api/settings/billing/usage-v2?startDate=\(start)&endDate=\(Int(now.timeIntervalSince1970))",
                headers: headers)
            // ZeroGPU quota and the profile are best-effort extras.
            let gpu = try? await HTTP.json("https://huggingface.co/api/spaces/zero-gpu/quota", headers: headers)
            let profile = try? await HTTP.json("https://huggingface.co/api/whoami-v2", headers: headers)
            // The prepaid wallet only exists on the signed-in billing page, so it needs a pasted cookie.
            var balance: Double?
            if let cookie = credential["cookie"], profile?["type"].string == "user",
               let userID = profile?["id"].string {
                balance = try? await HuggingfaceUsage.wallet(cookie: cookie, userID: userID)
            }
            return try HuggingfaceUsage.map(billing, zeroGPU: gpu, profile: profile, balance: balance)
        })
}

enum HuggingfaceUsage {
    /// Prepaid balance from the billing page; nil unless the cookie belongs to the token's user.
    static func wallet(cookie: String, userID: String) async throws -> Double? {
        let page = try await HTTP.send("https://huggingface.co/settings/billing",
                                       headers: ["Cookie": cookie, "Accept": "text/html"])
        try HTTP.check(page)
        guard let balance = walletBalance(html: page.text) else { return nil }
        // The page's display names prove nothing; resolve the same cookie without the bearer token.
        let who = try await HTTP.json("https://huggingface.co/api/whoami-v2", headers: ["Cookie": cookie])
        return who["type"].string == "user" && who["id"].string == userID ? balance : nil
    }

    /// Reads `currentBalanceUsd` (or the legacy `invoiceCreditsCents`) from the page's `data-props` attributes.
    /// Zero or several matches are ambiguous, so they return nil.
    static func walletBalance(html: String) -> Double? {
        var current: [Double] = [], legacy: [Double] = []
        var rest = html[...]
        while let tag = rest.range(of: #"<div\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            defer { rest = rest[tag.upperBound...] }
            let text = String(rest[tag])
            guard let props = text.range(of: #"\bdata-props\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#, options: .regularExpression) else { continue }
            var value = String(text[props].drop { $0 != "=" }.dropFirst()).trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" { value = String(value.dropFirst().dropLast()) }
            guard let payload = try? JSON(data: Data(decode(value).utf8)) else { continue }
            if let balance = payload["entity"]["currentBalanceUsd"].double, payload["entity"]["type"].string == "user" {
                current.append(balance)
            }
            if let cents = payload["invoiceCreditsCents"].double { legacy.append(cents / 100) }
        }
        if !current.isEmpty { return current.count == 1 && current[0] >= 0 ? current[0] : nil }
        return legacy.count == 1 && legacy[0] >= 0 ? legacy[0] : nil
    }

    private static func decode(_ raw: String) -> String {
        var text = raw
        for (entity, char) in [("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", "\u{a0}")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        while let range = text.range(of: #"&#(?:x[0-9a-fA-F]+|[0-9]+);"#, options: .regularExpression) {
            let digits = text[range].dropFirst(2).dropLast()
            let scalar = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            text.replaceSubrange(range, with: scalar.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? "")
        }
        return text.replacingOccurrences(of: "&amp;", with: "&")
    }

    static func map(_ json: JSON, zeroGPU: JSON? = nil, profile: JSON? = nil, balance: Double? = nil) throws -> ProviderUsage {
        let inference = json.at("usage.inferenceProviders")
        guard let usedNano = inference["usedNanoUsd"].double, usedNano >= 0,
              let includedNano = inference["includedNanoUsd"].double, includedNano >= 0 else {
            throw ProviderError.parse("Hugging Face billing response format changed: inferenceProviders")
        }
        let gross = usedNano / 1e9, included = includedNano / 1e9
        let billable = max(0, gross - included)
        let limit = (inference["limitNanoUsd"].double ?? 0) / 1e9
        var rows = [UsageRow("Billable usage", Fmt.money(billable))]
        if included > 0 {
            rows.append(.init("Gross inference usage", Fmt.money(gross)))
            rows.append(.init("Included inference amount", Fmt.money(included)))
        }
        if limit > 0 { rows.append(.init("Spending limit", Fmt.money(limit))) }
        if let requests = inference["numRequests"].int { rows.append(.init("Requests", String(requests))) }
        var sections = [UsageSection("Inference Providers", rows)]
        var windows: [UsageWindow] = []
        if limit > 0 {
            windows.append(.amounts(id: "inference", title: "Inference", used: billable, limit: limit)!)
        }
        if let gpu = zeroGPU, let total = gpu["base"].double, total > 0, let remaining = gpu["current"].double {
            let consumed = max(0, total - remaining)
            windows.append(UsageWindow(id: "zerogpu", title: "ZeroGPU", usedPercent: consumed / total * 100,
                                       resetsAt: gpu["resetsAt"].date, detail: "ZeroGPU quota"))
            func minutes(_ seconds: Double) -> String { "\(Fmt.number(seconds / 60, digits: seconds >= 600 ? 0 : 1)) min" }
            sections.append(.init("ZeroGPU", [.init("GPU time used", minutes(consumed)),
                                              .init("GPU time remaining", minutes(remaining))]))
        }
        if let balance { sections.append(.init("Credits", [.init("Prepaid balance", Fmt.money(balance))])) }
        if let username = profile?["name"].string { sections.append(.init("Account", [.init("Username", username)])) }
        var plan: String?
        if let isPro = profile?["isPro"].bool { plan = isPro ? "PRO" : "Free" }
        return ProviderUsage(windows: windows,
                             cost: UsageCost(used: billable, limit: limit > 0 ? limit : nil, balance: balance,
                                             period: "This month"),
                             sections: sections, plan: plan, email: profile?["email"].string)
    }
}
