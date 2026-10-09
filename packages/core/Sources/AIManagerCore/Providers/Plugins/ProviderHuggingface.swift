import Foundation

extension ProviderCatalog {
    static let huggingface = ProviderSpec(
        id: "huggingface", name: "Hugging Face",
        fields: [.init("token", "Access token", env: ["HF_TOKEN"])],
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
            return try HuggingfaceUsage.map(billing, zeroGPU: gpu, profile: profile)
        })
}

enum HuggingfaceUsage {
    static func map(_ json: JSON, zeroGPU: JSON? = nil, profile: JSON? = nil) throws -> ProviderUsage {
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
        var plan: String?
        if let isPro = profile?["isPro"].bool { plan = isPro ? "PRO" : "Free" }
        return ProviderUsage(windows: windows,
                             cost: UsageCost(used: billable, limit: limit > 0 ? limit : nil, period: "This month"),
                             sections: sections, plan: plan, email: profile?["email"].string)
    }
}
