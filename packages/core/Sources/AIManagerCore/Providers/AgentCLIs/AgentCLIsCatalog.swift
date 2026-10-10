import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

extension ProviderCatalog {
    static let agentCLIs: [ProviderSpec] = [
        agentGrok, agentFactory, agentKiro, agentKimi, agentKimiAPI, agentKilo, agentAugment, agentAmp,
        agentCodebuff, agentDevin, agentOpenCodeGo, agentPi, agentOllama,
    ]
}

/// Small helpers shared by the agent CLI providers.
enum AgentCLIsKit {
    /// Short stable id for a credential that carries no readable identity.
    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// A JSON value that a database row stores as text, or that already is an object.
    static func embedded(_ value: JSON) -> JSON {
        guard let text = value.raw as? String, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return value }
        return JSON(object)
    }
}
