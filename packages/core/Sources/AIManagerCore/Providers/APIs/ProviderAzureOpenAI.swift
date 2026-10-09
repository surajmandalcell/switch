import Foundation

extension ProviderCatalog {
    // Validates the key with a free, non-billable GET; Azure OpenAI has no usage API.
    static let azureopenai = ProviderSpec(
        id: "azureopenai", name: "Azure OpenAI",
        fields: [
            .apiKey("AZURE_OPENAI_API_KEY"),
            CredentialField("baseURL", "Endpoint", secure: false, placeholder: "https://<resource>.openai.azure.com",
                            env: ["AZURE_OPENAI_ENDPOINT"]),
            CredentialField("apiVersion", "API version", secure: false, optional: true, placeholder: "2024-10-21",
                            env: ["AZURE_OPENAI_API_VERSION"]),
        ],
        dashboard: "https://ai.azure.com", statusPage: nil,
        usage: { credential in
            let key = try credential.require("apiKey")
            let endpoint = try AzureOpenAIUsage.endpoint(try credential.require("baseURL"))
            let version = credential["apiVersion"] ?? "2024-10-21"
            let headers = ["api-key": key]
            var models = false
            var response = try await HTTP.send("\(endpoint)/openai/deployments?api-version=\(version)", headers: headers)
            // Newer API versions dropped the data-plane deployment list; the model list still works.
            if response.status == 404 {
                models = true
                response = try await HTTP.send("\(endpoint)/openai/models?api-version=\(version)", headers: headers)
            }
            try HTTP.check(response)
            return try AzureOpenAIUsage.map(try response.json(), models: models, host: URL(string: endpoint)?.host)
        })
}

enum AzureOpenAIUsage {
    /// Normalizes the endpoint to `https://host` and drops a trailing `/openai` or `/openai/v1`.
    static func endpoint(_ raw: String) throws -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let parts = URLComponents(string: text), parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else {
            throw ProviderError.missingCredential("The Azure OpenAI endpoint must be an https address without a login.")
        }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/openai/v1", "/openai"] where path.hasSuffix(suffix) { path.removeLast(suffix.count) }
        return "https://" + host + (parts.port.map { ":\($0)" } ?? "") + path
    }

    static func map(_ json: JSON, models: Bool, host: String?) throws -> ProviderUsage {
        guard json["data"].exists else { throw ProviderError.parse("Azure OpenAI returned an unexpected reply.") }
        let items = json["data"].array
        var rows = [UsageRow(models ? "Models available" : "Deployments", Fmt.number(Double(items.count)))]
        rows += items.prefix(5).compactMap { item in
            item["id"].string.map { UsageRow($0, item["status"].string ?? item["model"].string ?? "available") }
        }
        return ProviderUsage(sections: [UsageSection(models ? "Models" : "Deployments", rows)], organization: host)
    }
}
