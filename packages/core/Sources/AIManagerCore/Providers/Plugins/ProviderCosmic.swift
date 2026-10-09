import Foundation

extension ProviderCatalog {
    static let cosmic = ProviderSpec(
        id: "cosmic", name: "Cosmic AI",
        fields: [.init("token", "Personal Access Token", env: ["COSMIC_TOKEN"]),
                 .init("projectID", "Project ID", secure: false, env: ["COSMIC_PROJECT_ID"])],
        dashboard: "https://app.cosmicjs.com",
        usage: { credential in
            let token = try credential.require("token")
            let project = try credential.require("projectID", "Set a Cosmic Project ID for this account.")
            let id = project.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? project
            var headers = HTTP.bearer(token)
            headers["Origin"] = "https://app.cosmicjs.com"
            return try CosmicUsage.map(try await HTTP.json("https://dapi.cosmicjs.com/v3/projects/usage?project_id=\(id)", headers: headers))
        })
}

enum CosmicUsage {
    private static func limit(_ json: JSON) -> (value: Double?, text: String?) {
        if let text = json.raw as? String {
            let t = text.trimmingCharacters(in: .whitespaces).lowercased()
            if let match = t.range(of: #"^(\d+(?:\.\d+)?)\s*([km]?)$"#, options: .regularExpression) {
                let number = t[match].filter { $0.isNumber || $0 == "." }
                let scale: Double = t.hasSuffix("m") ? 1_000_000 : t.hasSuffix("k") ? 1000 : 1
                return ((Double(number) ?? 0) * scale, nil)
            }
            return (nil, t == "unlimited" ? "Unlimited" : t.isEmpty ? nil : "Not reported")
        }
        return (json.double, nil)
    }

    static func map(_ json: JSON) throws -> ProviderUsage {
        var sections: [UsageSection] = []
        func window(_ id: String, _ name: String, _ usedJSON: JSON, _ limitJSON: JSON) -> UsageWindow? {
            let used = usedJSON.double
            let (total, note) = limit(limitJSON)
            var rows: [UsageRow] = []
            if let used { rows.append(.init("Used", Fmt.number(used))) }
            if let total { rows.append(.init("Allowance", Fmt.number(total))) } else if let note { rows.append(.init("Allowance", note)) }
            if let used, let total {
                rows.append(.init("Remaining", Fmt.number(max(0, total - used))))
                if used > total { rows.append(.init("Above allowance", Fmt.number(used - total))) }
            }
            if !rows.isEmpty { sections.append(.init(name, rows)) }
            guard let used, let total else { return nil }
            return .amounts(id: id, title: name, used: used, limit: total, unit: "tokens")
        }
        let windows = [window("input", "Input tokens", json.at("usage.ai.input_tokens"), json.at("plan_info.ai_tokens.max_input")),
                       window("output", "Output tokens", json.at("usage.ai.output_tokens"), json.at("plan_info.ai_tokens.max_output"))]
        guard !sections.isEmpty else {
            throw ProviderError.parse("Cosmic AI returned an unrecognized project AI-token usage response.")
        }
        return ProviderUsage(windows: windows.compactMap { $0 }, sections: sections)
    }
}
