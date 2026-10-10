import Foundation

// Provider incident polling. Three feed kinds, all unauthenticated GETs:
// statuspage.io (`<base>/api/v2/status.json`), incident.io (OpenAI), and the Google
// Workspace incidents feed (Gemini, Antigravity, Vertex AI). Ported from CodexBar's
// ProviderStatusFetcher, trimmed to the overall indicator (no component lists).

public struct ProviderIncident: Codable, Equatable, Sendable {
    public enum Indicator: String, Codable, Sendable {
        case none, maintenance, minor, major, critical, unknown

        /// Worst-first ordering used to pick one indicator from many.
        public var rank: Int {
            switch self {
            case .none: 0
            case .maintenance, .unknown: 1
            case .minor: 2
            case .major: 3
            case .critical: 4
            }
        }
    }

    public var indicator: Indicator
    public var description: String?
    public var updatedAt: Date?

    public init(indicator: Indicator, description: String? = nil, updatedAt: Date? = nil) {
        self.indicator = indicator
        self.description = description
        self.updatedAt = updatedAt
    }
}

public enum ProviderStatusFetcher {
    static let openAIBase = URL(string: "https://status.openai.com")!
    static let googleFeed = "https://www.google.com/appsstatus/dashboard/incidents.json"
    /// Gemini and Antigravity product id in the Google Workspace incidents feed.
    static let googleProductID = "npdyhgECDJ6tB66MxXyo"
    static let googleProviders: Set<String> = ["gemini-cli", "antigravity-cli", "vertexai"]
    static let openAIProviders: Set<String> = ["codex", "openai"]

    /// Statuspage.io bases for providers whose `ProviderSpec.statusPage` is nil.
    static let statusPages: [String: String] = [
        "claude-code": "https://status.claude.com",
        "cursor": "https://status.cursor.com",
        "copilot": "https://www.githubstatus.com",
        "factory": "https://status.factory.ai",
        "augment": "https://status.augmentcode.com",
        "huggingface": "https://status.huggingface.co",
    ]

    /// Current incident for a provider, or nil when it has no feed or the fetch failed.
    /// Callers keep their last good value on nil.
    public static func fetch(_ providerID: ProviderID, statusPage: URL?) async -> ProviderIncident? {
        let id = providerID.rawValue
        if googleProviders.contains(id) {
            guard let data = await get(googleFeed) else { return nil }
            return parseGoogleWorkspace(data, productID: googleProductID)
        }
        if openAIProviders.contains(id) || statusPage?.host == openAIBase.host {
            return await fetchIncidentIO(openAIBase)
        }
        guard let base = statusPage ?? statusPages[id].flatMap(URL.init(string:)) else { return nil }
        return await fetchStatuspage(base)
    }

    // MARK: Fetch

    static func fetchStatuspage(_ base: URL) async -> ProviderIncident? {
        guard let data = await get(base.appendingPathComponent("api/v2/status.json").absoluteString) else {
            return nil
        }
        return parseStatuspage(data)
    }

    /// incident.io proxy feed first (worst Codex/APIs leaf, description and time from
    /// status.json), then the classic summary.json.
    static func fetchIncidentIO(_ base: URL) async -> ProviderIncident? {
        if let host = base.host, let data = await get("https://\(host)/proxy/\(host)"),
           let parsed = parseIncidentIO(data) {
            let overlay = await fetchStatuspage(base)
            return ProviderIncident(indicator: parsed.indicator, description: overlay?.description,
                                    updatedAt: overlay?.updatedAt)
        }
        guard let data = await get(base.appendingPathComponent("api/v2/summary.json").absoluteString) else {
            return nil
        }
        return parseStatuspage(data)
    }

    private static func get(_ url: String) async -> Data? {
        guard let response = try? await HTTP.send(url), (200..<300).contains(response.status) else {
            return nil
        }
        return response.data
    }

    // MARK: Parse

    /// `{"page":{"updated_at"},"status":{"indicator","description"}}`; also reads `summary.json`.
    static func parseStatuspage(_ data: Data) -> ProviderIncident? {
        guard let root = try? JSON(data: data), let raw = root["status"]["indicator"].string else { return nil }
        return ProviderIncident(
            indicator: ProviderIncident.Indicator(rawValue: raw.lowercased()) ?? .unknown,
            description: root["status"]["description"].string,
            updatedAt: root["page"]["updated_at"].date)
    }

    /// Statuspage component status text to an indicator.
    static func indicator(forComponentStatus status: String?) -> ProviderIncident.Indicator {
        switch status?.lowercased() {
        case "operational", nil: .none
        case "degraded_performance": .minor
        case "partial_outage": .major
        case "major_outage", "full_outage": .critical
        case "under_maintenance": .maintenance
        default: .unknown
        }
    }

    /// incident.io `/proxy/<host>`: indicator is the worst leaf of the "Codex" and "APIs" groups
    /// (all leaves when neither exists). Components absent from `affected_components` are
    /// operational. Carries no description or time; the caller overlays status.json.
    static func parseIncidentIO(_ data: Data) -> ProviderIncident? {
        guard let root = try? JSON(data: data) else { return nil }
        let summary = root["summary"]
        let items = summary["structure"]["items"].array
        guard !items.isEmpty else { return nil }

        var statusByID: [String: String] = [:]
        for affected in summary["affected_components"].array {
            if let id = affected["component_id"].string { statusByID[id] = affected["status"].string }
        }
        func leaf(_ component: JSON) -> ProviderIncident.Indicator? {
            guard component["hidden"].bool != true, let id = component["component_id"].string else { return nil }
            return indicator(forComponentStatus: statusByID[id])
        }

        let wanted: Set<String> = ["codex", "apis"]
        var selected: [ProviderIncident.Indicator] = []
        var all: [ProviderIncident.Indicator] = []
        for item in items {
            let group = item["group"], single = item["component"]
            let children: [JSON] = group.exists
                ? (group["hidden"].bool == true ? [] : group["components"].array) : [single]
            let name = (group.exists ? group["name"] : single["name"]).string?.lowercased()
            let leaves = children.compactMap(leaf)
            all += leaves
            if let name, wanted.contains(name) { selected += leaves }
        }
        let pool = selected.isEmpty ? all : selected
        return ProviderIncident(indicator: pool.max { $0.rank < $1.rank } ?? .none)
    }

    /// Google Workspace feed: active incidents (no `end`) that affect `productID`; the worst by
    /// rank wins. Status comes from the latest update, else `status_impact`, else `severity`.
    static func parseGoogleWorkspace(_ data: Data, productID: String) -> ProviderIncident? {
        guard let root = try? JSON(data: data), root.raw is [Any] else { return nil }
        var best: (indicator: ProviderIncident.Indicator, incident: JSON, update: JSON)?
        for incident in root.array where !incident["end"].exists {
            let current = incident["currently_affected_products"]
            let products = current.raw is [Any] ? current : incident["affected_products"]
            guard products.array.contains(where: { $0["id"].string == productID }) else { continue }
            var update = incident["most_recent_update"]
            if !update.exists { update = incident["updates"].array.last ?? JSON(nil) }
            let indicator = googleIndicator(status: update["status"].string ?? incident["status_impact"].string,
                                            severity: incident["severity"].string)
            if best == nil || indicator.rank > best!.indicator.rank { best = (indicator, incident, update) }
        }
        guard let best else { return ProviderIncident(indicator: .none) }
        return ProviderIncident(
            indicator: best.indicator,
            description: googleSummary(best.update["text"].string ?? best.incident["external_desc"].string),
            updatedAt: best.update["when"].date ?? best.incident["modified"].date ?? best.incident["begin"].date)
    }

    private static func googleIndicator(status: String?, severity: String?) -> ProviderIncident.Indicator {
        switch status?.uppercased() {
        case "AVAILABLE": return .none
        case "SERVICE_INFORMATION": return .minor
        case "SERVICE_DISRUPTION": return .major
        case "SERVICE_OUTAGE": return .critical
        case "SERVICE_MAINTENANCE", "SCHEDULED_MAINTENANCE": return .maintenance
        default: break
        }
        switch severity?.lowercased() {
        case "medium": return .major
        case "high": return .critical
        default: return .minor
        }
    }

    /// First useful line of a markdown body: skips "**Summary" headings, strips bold and links.
    private static func googleSummary(_ text: String?) -> String? {
        guard let text else { return nil }
        for line in text.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            if trimmed.isEmpty || lower.hasPrefix("**summary") || lower.hasPrefix("**description")
                || lower == "summary" { continue }
            var cleaned = trimmed.replacingOccurrences(of: "**", with: "")
            cleaned = cleaned.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1",
                                                   options: .regularExpression)
            if cleaned.hasPrefix("- ") { cleaned.removeFirst(2) }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }
}
