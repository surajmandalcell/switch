import Foundation

/// Every generic provider. Codex CLI and Grok Build switching stay in `AccountManager`;
/// their extra usage specs live here too but are not offered in Add Account twice.
public enum ProviderCatalog {
    public static let all: [ProviderSpec] = {
        let specs = agentCLIs + ide + apisA + apisB + pluginsA + pluginsB + pluginsC
        var seen = Set<ProviderID>()
        return specs.filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    private static let byID: [ProviderID: ProviderSpec] =
        Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    public static func spec(_ id: ProviderID) -> ProviderSpec? { byID[id] }

    /// Providers that Add Account offers through the generic store.
    public static var addable: [ProviderSpec] {
        all.filter { ![ProviderID.codex, .grokBuild, .claudeCode].contains($0.id) }
    }
}
