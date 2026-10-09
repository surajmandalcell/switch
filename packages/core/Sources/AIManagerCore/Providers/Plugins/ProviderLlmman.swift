import Foundation

extension ProviderCatalog {
    static let llmman = ProviderSpec(
        id: "llmman", name: "llmman",
        fields: [
            CredentialField("baseURL", "Base URL", secure: false, placeholder: "http://127.0.0.1:11434"),
            CredentialField("apiKey", "API key", optional: true, env: ["LLMMAN_API_KEY"]),
        ],
        usage: { credential in
            // Accept the OpenAI-style base URL agents are given, too.
            var base = try credential.require("baseURL").replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            if base.hasSuffix("/v1") { base.removeLast(3) }
            let key = credential["apiKey"]
            let headers = key.map(HTTP.bearer) ?? [:]
            let response = try await HTTP.send("\(base)/llmman/node", headers: headers)
            if response.status == 401 || response.status == 403, key == nil {
                throw ProviderError.missingCredential("llmman requires an API key.")
            }
            if response.status == 404 { throw ProviderError.unsupported("\(base) is not an llmman daemon.") }
            try HTTP.check(response)
            // The version is display only; older daemons may answer differently.
            let version = (try? await HTTP.json("\(base)/api/version", headers: headers))?["version"].string
            return try LlmmanUsage.map(try response.json(), version: version, hasKey: key != nil)
        })
}

enum LlmmanUsage {
    /// Decimal units, as llmman's own list and ps print them.
    private static func size(_ value: Double) -> String {
        if value < 1e3 { return "\(Int(value)) B" }
        let (unit, scale) = value >= 1e9 ? ("GB", 1e9) : value >= 1e6 ? ("MB", 1e6) : ("kB", 1e3)
        return String(format: "%.1f %@", value / scale, unit)
    }

    private static func models(_ json: JSON) throws -> [(name: String, bytes: Double)] {
        try json.object.map { name, size in
            guard let bytes = size.double, bytes >= 0 else { throw ProviderError.parse("llmman returned an unrecognized /llmman/node response.") }
            return (name, bytes)
        }.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
    }

    static func map(_ node: JSON, version: String? = nil, hasKey: Bool = false) throws -> ProviderUsage {
        guard let memory = node["memory"].double, memory >= 0 else {
            throw ProviderError.parse("llmman returned an unrecognized /llmman/node response.")
        }
        let loaded = try models(node["loaded"]), stored = try models(node["stored"])
        let inUse = loaded.reduce(0) { $0 + $1.bytes }
        func count(_ list: [(name: String, bytes: Double)]) -> String {
            "\(list.count) · \(size(list.reduce(0) { $0 + $1.bytes }))"
        }
        var summary = [UsageRow("Loaded", count(loaded)), UsageRow("Stored", count(stored))]
        if let version { summary.append(UsageRow("Version", version)) }
        var sections = [UsageSection("Daemon", summary)]
        sections.append(UsageSection("Loaded models", loaded.prefix(24).map {
            UsageRow($0.name, size($0.bytes), progress: memory > 0 ? $0.bytes / memory : nil)
        }))
        var windows: [UsageWindow] = []
        if memory > 0 {
            windows.append(UsageWindow(id: "memory", title: "Memory", usedPercent: inUse / memory * 100,
                                       detail: "\(size(inUse)) of \(size(memory))"))
        }
        return ProviderUsage(windows: windows, sections: sections, plan: hasKey ? "API key" : "Local daemon")
    }
}
