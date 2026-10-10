import Foundation

extension ProviderCatalog {
    static let deepgram = ProviderSpec(
        id: "deepgram", name: "Deepgram",
        fields: [.apiKey("DEEPGRAM_API_KEY"),
                 .init("projectID", "Project ID", secure: false, optional: true, env: ["DEEPGRAM_PROJECT_ID"]),
                 .init("baseURL", "API URL", secure: false, optional: true,
                       placeholder: "https://api.deepgram.com/v1", env: ["DEEPGRAM_API_URL"])],
        dashboard: "https://console.deepgram.com/project/",
        usage: { credential in
            let headers = ["Authorization": "Token \(try credential.require("apiKey"))"]
            var base = credential["baseURL"] ?? "https://api.deepgram.com/v1"
            while base.hasSuffix("/") { base.removeLast() }
            var projects: [(id: String, name: String?)]
            if let id = credential["projectID"] {
                projects = [(id, nil)]
            } else {
                let list = try await HTTP.json("\(base)/projects", headers: headers)
                projects = list["projects"].array.compactMap { item in item["project_id"].string.map { ($0, item["name"].string) } }
            }
            guard !projects.isEmpty else {
                throw ProviderError.unsupported("Deepgram project ID is invalid or no projects were returned for this API key.")
            }
            var breakdowns: [JSON] = []
            for project in projects {
                let id = project.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? project.id
                breakdowns.append(try await HTTP.json("\(base)/projects/\(id)/usage/breakdown", headers: headers))
            }
            return try DeepgramUsage.map(breakdowns, projects: projects.map { $0.name ?? $0.id })
        })
}

enum DeepgramUsage {
    /// `breakdowns` are the per-project `usage/breakdown` responses; `projects` are display names.
    static func map(_ breakdowns: [JSON], projects: [String]) throws -> ProviderUsage {
        var totals: [String: Double] = [:]
        var start: String?, end: String?
        for payload in breakdowns {
            guard payload["results"].raw is [Any] else { throw ProviderError.parse("Deepgram parse error: usage results must be an array") }
            if let s = payload["start"].string, start == nil || s < start! { start = s }
            if let e = payload["end"].string, end == nil || e > end! { end = e }
            for row in payload["results"].array {
                for key in ["hours", "total_hours", "agent_hours", "tokens_in", "tokens_out", "tts_characters", "requests"] {
                    totals[key, default: 0] += row[key].double ?? 0
                }
            }
        }
        func t(_ key: String) -> Double { totals[key] ?? 0 }
        func decimal(_ v: Double) -> String { Fmt.number(v, digits: 1) }
        var rows = [UsageRow("Requests", Fmt.number(t("requests")))]
        if t("hours") > 0 || t("total_hours") > 0 {
            rows.append(.init("Audio", "\(decimal(t("hours"))) hours (\(decimal(t("total_hours"))) billable)"))
        }
        if t("agent_hours") > 0 { rows.append(.init("Agent hours", decimal(t("agent_hours")))) }
        if t("tokens_in") > 0 || t("tokens_out") > 0 { rows.append(.init("Tokens", Fmt.number(t("tokens_in") + t("tokens_out")))) }
        if t("tts_characters") > 0 { rows.append(.init("TTS characters", Fmt.number(t("tts_characters")))) }
        if let start, let end { rows.append(.init("Period", "\(start) to \(end)")) }
        return ProviderUsage(sections: [.init("Usage summary", rows)],
                             plan: projects.count > 1 ? "\(projects.count) projects" : projects.first.map { "Project: \($0)" },
                             organization: projects.count > 1 ? "\(projects.count) projects" : projects.first)
    }
}
