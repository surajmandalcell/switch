import Foundation
import AIManagerCore

/// Cleanup (architecture.md 2.9), as the Mac Cleanup page: scan a source, review the selected items into a plan,
/// apply the plan to the trash, then restore or purge a trash batch. The engine keeps the last scan and the last
/// plan, so a client sends ids, never file paths; a replaced id is `stale`.
extension AppEngine {
    /// One scan of a source: file metadata only. Codex also reads its conversation index for titles and dates.
    public func scanCleanup(sourceID: String, progress: (@Sendable (CleanupScanProgress) -> Void)? = nil) async throws
        -> (scanID: UUID, scan: CleanupScan) {
        let source = try await cleanupSource(sourceID)
        var summaries: [ChatThreadSummary] = []
        if source.tool == .codex {
            let index = chatIndex()
            _ = try await index.refresh(query: "")
            summaries = await index.cleanupSummaries()
        }
        let scan = try await Task.detached(priority: .utility) {
            try AccountManager.scanCleanup(source, summaries: summaries) { progress?($0) }
        }.value
        let id = UUID()
        cleanupScan = (id, source, Dictionary(scan.categories.flatMap(\.items).map { ($0.id, $0) }) { first, _ in first })
        cleanupPlan = nil
        return (id, scan)
    }

    /// The selected items of the last scan, checked again on disk. An item that changed fails the review.
    public func reviewCleanup(scanID: UUID, itemIDs: [String]) async throws -> ConversationCleanupPlan {
        guard let scan = cleanupScan, scan.id == scanID else { throw AppEngineError.stale }
        guard !itemIDs.isEmpty, itemIDs.count == Set(itemIDs).count else {
            throw AIManagerError.invalidSource("Select unique items from the scan. No files were changed.")
        }
        let items = try itemIDs.map { id in
            guard let item = scan.items[id] else { throw AIManagerError.sourceChanged }
            return item
        }
        let plan = try await requireManager().reviewCleanup(scan.source, items)
        cleanupPlan = (scan.source, plan)
        return plan
    }

    /// The Mac `applyCleanup`: moves the reviewed plan to the source's trash (Codex keeps its activity first),
    /// clears the chosen usage samples, and clears the conversation index when asked.
    public func applyCleanup(planID: UUID?, sampleIDs: [Int64], clearIndex: Bool) async throws -> ActionResult {
        let reviewed: (source: CleanupSource, plan: ConversationCleanupPlan)?
        if let planID {
            guard let current = cleanupPlan, current.plan.id == planID else { throw AppEngineError.stale }
            reviewed = current
        } else {
            reviewed = nil
        }
        let codexCache = codexCache
        let index = chatIndex()
        return try await perform(failure: "Couldn’t clean up.", recovery: "Scan again, then review the items.") {
            if let codexCache { await index.attachActivityCache(codexCache) }
            if let reviewed {
                _ = try await self.requireManager().moveToCleanupTrash(reviewed.source, reviewed.plan) { sources in
                    guard codexCache != nil else {
                        throw AIManagerError.operationFailed("The activity ledger is unavailable. Conversations were kept.")
                    }
                    try await index.preserveActivity(for: sources)
                }
                await self.clearCleanupState()
            }
            var samples: [CleanupUsageSample] = []
            if !sampleIDs.isEmpty, let codexCache {
                samples = try await codexCache.cleanupSamples().filter { sampleIDs.contains($0.id) }
                try await codexCache.removeCleanupSamples(samples)
            }
            if clearIndex { try await index.clearCache() }
            let notice = Self.cleanupNotice(reviewed?.plan, samples: samples.count, clearIndex: clearIndex)
            await self.setNotice(notice)
            return .done(notice: notice)
        }
    }

    /// Puts a trash batch back. Files changed since stay protected.
    public func restoreCleanup(sourceID: String, batchID: UUID) async throws -> ActionResult {
        let source = try await cleanupBatchSource(sourceID, batchID)
        return try await perform(failure: "Couldn’t restore the items.") {
            try await self.requireManager().restoreCleanupTrash(source, batchID)
            await self.setNotice("Items restored.")
            return .done(notice: "Items restored.")
        }
    }

    /// Deletes a trash batch for good, after the user confirms.
    public func purgeCleanup(sourceID: String, batchID: UUID, confirmed: Set<ConfirmationRequest.Kind>) async throws
        -> ActionResult {
        let source = try await cleanupBatchSource(sourceID, batchID)
        guard confirmed.contains(.purge) else {
            return .confirm(ConfirmationRequest(kind: .purge, title: "Delete these items for good?",
                                                message: "This cannot be undone.", action: "Delete"))
        }
        return try await perform(failure: "Couldn’t delete the items.") {
            try await self.requireManager().permanentlyRemoveCleanupTrash(source, batchID)
            await self.setNotice("Items deleted for good.")
            return .done(notice: "Items deleted for good.")
        }
    }

    private func clearCleanupState() {
        cleanupScan = nil
        cleanupPlan = nil
    }

    private func cleanupSource(_ id: String) async throws -> CleanupSource {
        if status == nil { await reloadAccounts() }
        guard let source = CleanupSources.make(paths: paths, accounts: status?.accounts ?? []).first(where: { $0.id == id }) else {
            throw AppEngineError.notFound("No cleanup source has that ID.")
        }
        return source
    }

    private func cleanupBatchSource(_ sourceID: String, _ batchID: UUID) async throws -> CleanupSource {
        let source = try await cleanupSource(sourceID)
        guard try await requireManager().cleanupTrash(source).contains(where: { $0.id == batchID }) else {
            throw AppEngineError.notFound("That trash batch does not exist for this source.")
        }
        return source
    }

    // shortcut: a fresh index per call that reloads its cache file, as the CLI does; keep one index for the
    // helper's life when the history engine area lands (plan unit G4).
    private func chatIndex() -> ChatHistoryIndex {
        ChatHistoryIndex(home: paths.sharedRoot,
                         cacheFile: paths.applicationSupport.appending(path: "cache/chat-history-v1.json"))
    }

    /// The Mac `cleanupNotice`.
    static func cleanupNotice(_ plan: ConversationCleanupPlan?, samples: Int, clearIndex: Bool) -> String {
        var parts: [String] = []
        if let plan {
            let count = plan.items.count
            parts.append("\(count) \(count == 1 ? "item" : "items") (\(ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file))) moved to the trash")
        }
        if samples > 0 { parts.append("\(samples) usage samples cleared") }
        if clearIndex { parts.append("conversation index cleared") }
        return parts.isEmpty ? "Cleanup finished." : parts.joined(separator: "; ") + "."
    }
}
