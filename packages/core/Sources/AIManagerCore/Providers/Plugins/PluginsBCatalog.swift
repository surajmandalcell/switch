import Foundation

extension ProviderCatalog {
    // museai is skipped: it needs a Next.js server action whose id is scraped from build chunks.
    static let pluginsB: [ProviderSpec] = [
        linkup, litellm, lithosai, llmman, llmproxy, longcat, manus, moonshot, muse, neuralwatt, notion, nous,
        openai, openrouter, perplexity, poe, qoder, raycast, replicate,
    ]
}
