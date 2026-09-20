import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CodexAPIPrice: Sendable, Equatable {
    public let model: String
    public let inputPerMillion: Double
    public let cachedInputPerMillion: Double?
    public let outputPerMillion: Double

    public init(
        model: String,
        inputPerMillion: Double,
        cachedInputPerMillion: Double?,
        outputPerMillion: Double
    ) {
        self.model = model
        self.inputPerMillion = inputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
        self.outputPerMillion = outputPerMillion
    }

    public func inputEquivalent(for tokens: Int64) -> Double {
        equivalent(tokens, rate: inputPerMillion)
    }

    public func cachedInputEquivalent(for tokens: Int64) -> Double? {
        cachedInputPerMillion.map { equivalent(tokens, rate: $0) }
    }

    public func outputEquivalent(for tokens: Int64) -> Double {
        equivalent(tokens, rate: outputPerMillion)
    }

    private func equivalent(_ tokens: Int64, rate: Double) -> Double {
        guard tokens > 0, rate.isFinite, rate >= 0 else { return 0 }
        return Double(tokens) * rate / 1_000_000
    }
}

public actor CodexAPIPricingResolver {
    public static let cacheTTL: TimeInterval = 24 * 60 * 60
    public static let catalogURL = URL(
        string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    public typealias Fetch = @Sendable (URL) async throws -> Data

    private let cacheURL: URL
    private let now: @Sendable () -> Date
    private let fetch: Fetch

    public init(
        cacheURL: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        fetch: @escaping Fetch = { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return data
        }
    ) {
        self.cacheURL = cacheURL
        self.now = now
        self.fetch = fetch
    }

    public func price(for model: String) async throws -> CodexAPIPrice? {
        let cached = try? Data(contentsOf: cacheURL, options: [.mappedIfSafe])
        let modified = try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        if let cached, let modified,
           now().timeIntervalSince(modified) < Self.cacheTTL,
           let price = Self.price(in: cached, model: model) {
            return price
        }
        do {
            let data = try await fetch(Self.catalogURL)
            guard let price = Self.price(in: data, model: model) else { return nil }
            try? store(data)
            return price
        } catch {
            if let cached, let price = Self.price(in: cached, model: model) { return price }
            throw error
        }
    }

    public nonisolated static func configuredModel(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \Character.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "model" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value.first == "\"", let end = value.dropFirst().firstIndex(of: "\"") else {
                return nil
            }
            let model = String(value[value.index(after: value.startIndex)..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return model.isEmpty ? nil : model
        }
        return nil
    }

    private nonisolated static func price(in data: Data, model: String) -> CodexAPIPrice? {
        guard !model.isEmpty, data.count <= 32 * 1_024 * 1_024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let candidates = [model, "openai/\(model)"] + root.keys.filter {
            $0.hasSuffix("/\(model)")
                && (root[$0] as? [String: Any])?["litellm_provider"] as? String == "openai"
        }
        for key in candidates {
            guard let raw = root[key] as? [String: Any],
                  let input = finitePositive(raw["input_cost_per_token"]),
                  let output = finitePositive(raw["output_cost_per_token"]) else { continue }
            let cached = finitePositive(raw["cache_read_input_token_cost"])
            return CodexAPIPrice(
                model: model,
                inputPerMillion: input * 1_000_000,
                cachedInputPerMillion: cached.map { $0 * 1_000_000 },
                outputPerMillion: output * 1_000_000)
        }
        return nil
    }

    private nonisolated static func finitePositive(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite && result > 0 ? result : nil
    }

    private func store(_ data: Data) throws {
        let directory = cacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: cacheURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }
}
