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

/// How one Codex request bills against standard list rates: its service tier and long context.
/// Rules follow OpenAI's API pricing page, as CodexBar applies them.
public enum CodexRequestPricing {
    /// A prompt above this many input tokens bills the whole request at long-context rates.
    public static let longContextInputTokens: Int64 = 272_000
    /// The GPT-6.2 Ultrafast promotion (3x) ends at midnight Pacific on March 1, 2027 (08:00 UTC).
    public static let ultrafastPromotionEnd = Date(timeIntervalSince1970: 1_803_888_000)

    /// Published per-million list rates, used when the LiteLLM catalog lacks a model.
    static let listPrices: [String: (input: Double, cached: Double, output: Double)] = [
        "gpt-6-astra": (10, 1, 50), "gpt-6.1-sol": (2, 0.1, 10), "gpt-6.1-terra": (1, 0.05, 5),
        "gpt-6-sol": (2, 0.2, 10), "gpt-6-luna": (0.1, 0.01, 0.5),
        "gpt-6.2-astra": (8, 0.4, 40), "gpt-6.2-sol": (2, 0.1, 10),
    ]

    private static let longContextModels: Set<String> = [
        "gpt-5.4", "gpt-5.4-pro", "gpt-5.5", "gpt-5.5-pro", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
        "gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-luna", "gpt-6.2-astra", "gpt-6.2-sol",
    ]
    /// Models whose Fast (priority) rates also cover long-context requests.
    private static let longContextFastModels: Set<String> = [
        "gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna", "gpt-6.2-astra", "gpt-6.2-sol",
    ]

    /// `gpt-6.1-terra` from `openai/GPT-6.1-Terra-2026-10-01`.
    public static func normalized(_ model: String) -> String {
        var name = model.lowercased()
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        return name.replacingOccurrences(of: #"-\d{4}-\d{2}-\d{2}$"#, with: "", options: .regularExpression)
    }

    public static func listPrice(_ model: String) -> CodexAPIPrice? {
        listPrices[normalized(model)].map {
            CodexAPIPrice(model: model, inputPerMillion: $0.input, cachedInputPerMillion: $0.cached,
                          outputPerMillion: $0.output)
        }
    }

    /// Factors on the standard uncached-input, cached-input and output rates for one request.
    /// `tier` is the transcript's `service_tier`; `input` is the request's input tokens.
    public static func multipliers(model: String, tier: String?, date: Date, input: Int64)
        -> (input: Double, cached: Double, output: Double) {
        let name = normalized(model)
        let long = input > longContextInputTokens && longContextModels.contains(name)
        let scale: Double
        switch tier {
        case "priority", "fast":
            // shortcut: Fast on an unlisted model, or long context without published Fast rates,
            // bills as standard; add the rate here when OpenAI publishes it.
            scale = long && !longContextFastModels.contains(name) ? 1 : fastMultiplier(name) ?? 1
        case "ultrafast":
            // shortcut: Ultrafast on an unlisted model bills as standard; add it when published.
            scale = ultrafastMultiplier(name, date: date) ?? 1
        default:
            scale = 1
        }
        return long ? (2 * scale, 2 * scale, 1.5 * scale) : (scale, scale, scale)
    }

    static func fastMultiplier(_ name: String) -> Double? {
        switch name {
        case "gpt-5.4", "gpt-5.4-mini", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
             "gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna", "gpt-6.2-astra", "gpt-6.2-sol": 2
        case "gpt-5.5": 2.5
        default: nil
        }
    }

    static func ultrafastMultiplier(_ name: String, date: Date) -> Double? {
        switch name {
        case "gpt-6-astra", "gpt-6.1-sol": 6
        case "gpt-6.2-astra", "gpt-6.2-sol": date < ultrafastPromotionEnd ? 3 : 6
        default: nil
        }
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
            guard let price = Self.price(in: data, model: model) else { return CodexRequestPricing.listPrice(model) }
            try? store(data)
            return price
        } catch {
            if let cached, let price = Self.price(in: cached, model: model) { return price }
            if let price = CodexRequestPricing.listPrice(model) { return price }
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
#if os(Windows)
        try CoreSupport.atomicWrite(data, to: cacheURL, fileManager: .default)
#else
        let directory = cacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: cacheURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
#endif
    }
}
