import Foundation
import XCTest
@testable import AIManagerCore

final class ConversationCleanupTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var paths: ManagerPaths!
    private let files = FileManager.default

    override func setUpWithError() throws {
        root = files.temporaryDirectory.appending(path: "ConversationCleanupTests-\(UUID().uuidString)")
        home = root.appending(path: "codex")
        paths = .init(applicationSupport: root.appending(path: "support"),
            credentialStore: root.appending(path: "vault"), defaultHome: home, sharedRoot: home,
            orcaAccountsRoot: root.appending(path: "orca"), codexExecutable: URL(fileURLWithPath: "/usr/bin/true"), isolationRoot: root)
        try CoreSupport.privateDirectory(home, fileManager: files)
    }

    override func tearDownWithError() throws {
        if let root { try? files.removeItem(at: root) }
    }

    func testTrashReopenRestorePermanentRemovalAndRetainedActivity() async throws {
        let source = try transcript("sessions/2026/one.jsonl")
        let archived = try transcript("archived_sessions/two.jsonl")
        let auth = home.appending(path: "auth.json")
        try Data("synthetic auth stays intact".utf8).write(to: auth)
        let cache = try CodexUsageStatisticsCache(databaseURL: root.appending(path: "usage.sqlite"),
            activityDatabaseURL: root.appending(path: "daily.sqlite"))
        let index = ChatHistoryIndex(home: home)
        await index.attachActivityCache(cache)
        _ = try await index.refresh()
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let summaries = await index.cleanupSummaries()
        let inventory = try await manager.cleanupInventory(summaries: summaries)
        XCTAssertEqual(inventory.count, 2)
        let plan = try await manager.reviewCleanup(inventory)
        XCTAssertEqual(plan.bytes, inventory.reduce(0) { $0 + $1.bytes })
        let batch = try await manager.moveConversationsToTrash(plan) { sources in
            try await index.preserveActivity(for: sources)
        }
        XCTAssertFalse(CoreSupport.entryExists(source))
        XCTAssertFalse(CoreSupport.entryExists(archived))
        let reopened = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let pending = try await reopened.cleanupTrash()
        XCTAssertEqual(pending.first?.id, batch.id)
        try await reopened.restoreCleanupTrash(batch.id)
        XCTAssertTrue(CoreSupport.entryExists(source))
        XCTAssertTrue(CoreSupport.entryExists(archived))
        let restoredTrash = try await reopened.cleanupTrash()
        XCTAssertTrue(restoredTrash.isEmpty)
        let secondPlan = try await reopened.reviewCleanup(inventory)
        let second = try await reopened.moveConversationsToTrash(secondPlan) { sources in
            try await index.preserveActivity(for: sources)
        }
        try await reopened.permanentlyRemoveCleanupTrash(second.id)
        let emptied = try await reopened.cleanupTrash()
        XCTAssertTrue(emptied.isEmpty)
        XCTAssertEqual(try String(contentsOf: auth, encoding: .utf8), "synthetic auth stays intact")
        let activity = try await cache.projectActivity(on: "2026-09-18")
        XCTAssertEqual(activity.reduce(0) { $0 + $1.tokens }, 246)
    }

    func testChangedFilesUnsafeLinksWritersAndLedgerFailureKeepOriginals() async throws {
        let source = try transcript("sessions/one.jsonl")
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let inventory = try await manager.cleanupInventory()
        let plan = try await manager.reviewCleanup(inventory)
        try Data("different content".utf8).write(to: source)
        do { _ = try await manager.moveConversationsToTrash(plan) { _ in }; XCTFail("Changed file removed") }
        catch { XCTAssertTrue(CoreSupport.entryExists(source)) }
        _ = try transcript("sessions/one.jsonl")
        let valid = try await manager.reviewCleanup(manager.cleanupInventory())
        for state: WriterState in [.active, .unknown] {
            let blocked = try AccountManager(paths: paths, writerCheck: { _ in state })
            do { _ = try await blocked.moveConversationsToTrash(valid) { _ in }; XCTFail("Writer guard skipped") }
            catch { XCTAssertTrue(CoreSupport.entryExists(source)) }
        }
        do {
            _ = try await manager.moveConversationsToTrash(valid) { _ in throw AIManagerError.operationFailed("Ledger failed") }
            XCTFail("Ledger failure removed source")
        } catch { XCTAssertTrue(CoreSupport.entryExists(source)) }
        let linked = home.appending(path: "sessions/linked.jsonl")
        try files.createSymbolicLink(at: linked, withDestinationURL: source)
        let withSymlink = try await manager.cleanupInventory()
        XCTAssertEqual(withSymlink.count, 1)
        try files.removeItem(at: linked)
        try files.linkItem(at: source, to: linked)
        let withHardLinks = try await manager.cleanupInventory()
        XCTAssertEqual(withHardLinks.count, 2)
        XCTAssertTrue(withHardLinks.allSatisfy { $0.exclusionReason != nil })
        do { _ = try await manager.reviewCleanup(withHardLinks); XCTFail("Hard-linked file accepted for removal") }
        catch { XCTAssertTrue(CoreSupport.entryExists(source)) }
    }

    func testInterruptedMoveReconcilesAndRestoreDoesNotOverwrite() throws {
        let first = try transcript("sessions/one.jsonl")
        _ = try transcript("sessions/two.jsonl")
        let cleanup = ConversationCleanup(home: home)
        let plan = try cleanup.review(cleanup.inventory(summaries: []))
        let folder = home.appending(path: ".switch-trash/\(plan.id.uuidString)")
        let batch = ConversationCleanupBatch(id: plan.id, createdAt: Date(), conversations: plan.conversations,
            home: cleanup.home, digests: plan.digests, phase: "moving")
        try CoreSupport.privateDirectory(folder.appending(path: "sessions"), fileManager: files)
        try CoreSupport.atomicWrite(JSONEncoder().encode(batch), to: folder.appending(path: "manifest.json"), fileManager: files)
        try files.moveItem(at: first, to: folder.appending(path: "sessions/one.jsonl"))
        XCTAssertEqual(try cleanup.batches().first?.conversations.count, 1)
        try Data("new source must survive".utf8).write(to: first)
        XCTAssertThrowsError(try cleanup.restore(batch.id))
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "new source must survive")
        try files.removeItem(at: first)
        try cleanup.restore(batch.id)
        XCTAssertEqual(try cleanup.inventory(summaries: []).count, 2)
    }

    func testInventoryIncludesConversationsBeyondTheVisibleHistoryLimit() throws {
        let sessions = home.appending(path: "sessions")
        try CoreSupport.privateDirectory(sessions, fileManager: files)
        for number in 0..<2_001 {
            try Data("{}\n".utf8).write(to: sessions.appending(path: "\(number).jsonl"))
        }
        let protected = home.appending(path: "logs/protected.jsonl")
        try CoreSupport.atomicWrite(Data("protected".utf8), to: protected, fileManager: files)
        let inventory = try ConversationCleanup(home: home).inventory(summaries: [])
        XCTAssertEqual(inventory.count, 2_001)
        XCTAssertFalse(inventory.contains { $0.relativePath.hasPrefix("logs/") })
    }

    private func transcript(_ relative: String) throws -> URL {
        let url = home.appending(path: relative)
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": relative, "cwd": "/Projects/Synthetic"]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Synthetic conversation"]]]],
            ["timestamp": "2026-09-18T12:00:00Z", "type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["total_tokens": 123]]]]
        ]
        var data = Data()
        for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
        try CoreSupport.atomicWrite(data, to: url, fileManager: files)
        return url
    }
}
