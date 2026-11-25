import Foundation

extension ProviderCatalog {
    // museai is skipped: it needs a Next.js server action whose id is scraped from build chunks.
    static let pluginsB: [ProviderSpec] = [
        linkup, litellm, llmman, llmproxy, moonshot, muse, neuralwatt, nous,
        openai, openrouter, poe,
    ]
}
