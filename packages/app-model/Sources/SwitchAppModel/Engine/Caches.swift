import Foundation
import AIManagerCore

// shortcut: written from AccountViewModel.rebuildableCacheSizes and clearUsageCache beside the Mac copies; delete
// those when the Mac app adopts SwitchAppModel (needs the window gates).
/// The rebuildable caches of Maintenance > Cleanup and the conversation index of History.
public struct CacheSizes: Codable, Equatable, Sendable {
    /// The Codex usage cache (`cache/account-usage.sqlite` with its `-wal` and `-shm` files).
    public var usageBytes: Int64
    /// The conversation index (`cache/chat-history-v1.json`).
    public var conversationBytes: Int64
}

extension AppEngine {
    var usageCacheURL: URL { paths.applicationSupport.appending(path: "cache/account-usage.sqlite") }

    public func cacheSizes() -> CacheSizes {
        func size(_ url: URL) -> Int64 {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return 0 }
            return Int64(values.fileSize ?? 0)
        }
        let usage = ["", "-wal", "-shm"].reduce(Int64(0)) { $0 + size(URL(fileURLWithPath: usageCacheURL.path + $1)) }
        return CacheSizes(usageBytes: codexCache == nil ? 0 : usage,
                          conversationBytes: size(paths.applicationSupport.appending(path: "cache/chat-history-v1.json")))
    }

    /// The Mac `clearUsageCache`: drops every cached Codex usage row; the next refresh reads them again.
    public func clearUsageCache() async throws -> ActionResult {
        try await perform(failure: "Couldn’t clear the usage cache.") {
            try await self.codexCache?.purgeAll()
            await self.reloadAccounts()
            await self.bumpUsageHistoryVersion()
            await self.setNotice("Usage cache cleared.")
            return .done(notice: "Usage cache cleared.")
        }
    }

    /// `history.reindex`: a full refresh of the conversation index.
    public func reindexHistory() async throws -> ActionResult {
        try await perform(failure: "Couldn’t refresh the conversation index.") {
            _ = try await self.chatHistory.refresh(limit: 1)
            await self.bumpHistoryVersion()
            return .done()
        }
    }

    /// `history.clearIndex`: drops the index; the next `history.list` builds it again.
    public func clearHistoryIndex() async throws -> ActionResult {
        try await perform(failure: "Couldn’t clear the conversation index.") {
            try await self.chatHistory.clearCache()
            await self.bumpHistoryVersion()
            await self.setNotice("Conversation index cleared.")
            return .done(notice: "Conversation index cleared.")
        }
    }
}
