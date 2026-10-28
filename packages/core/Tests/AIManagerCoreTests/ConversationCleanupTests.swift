import Foundation
import XCTest
@testable import AIManagerCore

final class ConversationCleanupTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var user: URL!
    private var paths: ManagerPaths!
    private let files = FileManager.default
    /// Files made a moment ago count as in use; scan as if an hour passed.
    private var later: Date { Date().addingTimeInterval(3_600) }

    override func setUpWithError() throws {
        root = files.temporaryDirectory.appending(path: "ConversationCleanupTests-\(UUID().uuidString)")
        home = root.appending(path: "codex")
        user = root.appending(path: "user")
        paths = .init(applicationSupport: root.appending(path: "support"),
            credentialStore: root.appending(path: "vault"), defaultHome: home, sharedRoot: home,
            orcaAccountsRoot: root.appending(path: "orca"), codexExecutable: URL(fileURLWithPath: "/usr/bin/true"), isolationRoot: root)
        try CoreSupport.privateDirectory(home, fileManager: files)
        try CoreSupport.privateDirectory(user, fileManager: files)
    }

    override func tearDownWithError() throws {
        if let root { try? files.removeItem(at: root) }
    }

    private func source(_ tool: CleanupTool = .codex, home: URL? = nil, account: UUID? = nil) -> CleanupSource {
        CleanupSource(id: tool.rawValue, tool: tool, title: tool.rawValue, detail: "", providerID: .codex,
            accountID: account, home: home ?? self.home, userHome: user)
    }

    private func scan(_ tool: CleanupTool = .codex, home: URL? = nil, summaries: [ChatThreadSummary] = []) throws -> CleanupScan {
        try CleanupScanner(source: source(tool, home: home), summaries: summaries, now: later).scan()
    }

    private func category(_ scan: CleanupScan, _ id: String) -> CleanupCategory? { scan.categories.first { $0.id == id } }

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
        let items = try scan(summaries: summaries).categories.flatMap(\.selectable)
        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(items.contains { $0.path.contains("auth") })
        let plan = try await manager.reviewCleanup(self.source(), items)
        XCTAssertEqual(plan.bytes, items.reduce(0) { $0 + $1.bytes })
        let batch = try await manager.moveToCleanupTrash(self.source(), plan) { sources in
            try await index.preserveActivity(for: sources)
        }
        XCTAssertFalse(CoreSupport.entryExists(source))
        XCTAssertFalse(CoreSupport.entryExists(archived))
        let reopened = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let pending = try await reopened.cleanupTrash(self.source())
        XCTAssertEqual(pending.first?.id, batch.id)
        try await reopened.restoreCleanupTrash(self.source(), batch.id)
        XCTAssertTrue(CoreSupport.entryExists(source))
        XCTAssertTrue(CoreSupport.entryExists(archived))
        let restoredTrash = try await reopened.cleanupTrash(self.source())
        XCTAssertTrue(restoredTrash.isEmpty)
        let secondPlan = try await reopened.reviewCleanup(self.source(), items)
        let second = try await reopened.moveToCleanupTrash(self.source(), secondPlan) { sources in
            try await index.preserveActivity(for: sources)
        }
        try await reopened.permanentlyRemoveCleanupTrash(self.source(), second.id)
        let emptied = try await reopened.cleanupTrash(self.source())
        XCTAssertTrue(emptied.isEmpty)
        XCTAssertEqual(try String(contentsOf: auth, encoding: .utf8), "synthetic auth stays intact")
        let activity = try await cache.projectActivity(on: "2026-09-18")
        XCTAssertEqual(activity.reduce(0) { $0 + $1.tokens }, 246)
    }

    func testChangedFilesUnsafeLinksWritersAndLedgerFailureKeepOriginals() async throws {
        let original = try transcript("sessions/one.jsonl")
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let items = try scan().categories.flatMap(\.selectable)
        let plan = try await manager.reviewCleanup(source(), items)
        try Data("different content".utf8).write(to: original)
        do { _ = try await manager.moveToCleanupTrash(source(), plan) { _ in }; XCTFail("Changed file removed") }
        catch { XCTAssertTrue(CoreSupport.entryExists(original)) }
        _ = try transcript("sessions/one.jsonl")
        let valid = try await manager.reviewCleanup(source(), try scan().categories.flatMap(\.selectable))
        for state: WriterState in [.active, .unknown] {
            let blocked = try AccountManager(paths: paths, writerCheck: { _ in state })
            do { _ = try await blocked.moveToCleanupTrash(source(), valid) { _ in }; XCTFail("Writer guard skipped") }
            catch { XCTAssertTrue(CoreSupport.entryExists(original)) }
        }
        do {
            _ = try await manager.moveToCleanupTrash(source(), valid) { _ in throw AIManagerError.operationFailed("Ledger failed") }
            XCTFail("Ledger failure removed source")
        } catch { XCTAssertTrue(CoreSupport.entryExists(original)) }
        let linked = home.appending(path: "sessions/linked.jsonl")
        try files.createSymbolicLink(at: linked, withDestinationURL: original)
        XCTAssertEqual(try scan().categories.flatMap(\.items).count, 1, "A symbolic link must not be listed")
        try files.removeItem(at: linked)
        try files.linkItem(at: original, to: linked)
        let hardLinked = try scan().categories.flatMap(\.items)
        XCTAssertEqual(hardLinked.count, 2)
        XCTAssertTrue(hardLinked.allSatisfy { $0.protectedReason != nil })
        do { _ = try await manager.reviewCleanup(source(), hardLinked); XCTFail("Hard-linked file accepted for removal") }
        catch { XCTAssertTrue(CoreSupport.entryExists(original)) }
    }

    /// Regression: the old page listed every Codex transcript as a chat, including the review and
    /// sub-agent sessions Codex starts itself, and counted files another app links as choices.
    func testAgentSessionsAndAppLinkedFilesStayApartFromConversations() throws {
        _ = try transcript("sessions/2026/chat.jsonl")
        _ = try transcript("sessions/2026/review.jsonl", source: ["subagent": ["other": "guardian"]])
        let spawned = try transcript("sessions/2026/spawned.jsonl", source: ["subagent": ["thread_spawn": ["depth": 1]]])
        let shared = try transcript("sessions/2026/shared.jsonl")
        try files.linkItem(at: shared, to: root.appending(path: "other-app-link.jsonl"))
        let result = try scan()
        let chats = try XCTUnwrap(category(result, "conversations"))
        let agents = try XCTUnwrap(category(result, "agents"))
        func stems(_ items: [CleanupItem]) -> [String] { items.map { (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension } }
        XCTAssertEqual(stems(chats.selectable), ["chat"])
        XCTAssertEqual(stems(chats.protectedItems), ["shared"])
        XCTAssertEqual(result.untouchedText, "1 item stays untouched: linked by another app.")
        XCTAssertEqual(Set(stems(agents.items)), ["review", "spawned"])
        XCTAssertEqual(chats.items.first?.title, "Synthetic conversation")
        XCTAssertEqual(chats.items.first?.project, "/Projects/Synthetic")
        XCTAssertEqual(spawned.lastPathComponent, "spawned.jsonl")
    }

    func testInterruptedMoveReconcilesAndRestoreDoesNotOverwrite() throws {
        let first = try transcript("sessions/one.jsonl")
        _ = try transcript("sessions/two.jsonl")
        let cleanup = ConversationCleanup(home: home, userHome: user)
        let items = try scan().categories.flatMap(\.selectable)
        XCTAssertEqual(items.count, 2)
        let plan = try cleanup.review(items)
        let folder = home.appending(path: ".switch-trash/\(plan.id.uuidString)")
        let batch = ConversationCleanupBatch(id: plan.id, createdAt: Date(), items: plan.items,
            home: cleanup.home, userHome: cleanup.userHome, digests: plan.digests, phase: "moving")
        try CoreSupport.privateDirectory(folder.appending(path: "0/sessions"), fileManager: files)
        try CoreSupport.atomicWrite(JSONEncoder().encode(batch), to: folder.appending(path: "manifest.json"), fileManager: files)
        try files.moveItem(at: first, to: folder.appending(path: "0/sessions/one.jsonl"))
        XCTAssertEqual(try cleanup.batches().first?.items.count, 1)
        try Data("new source must survive".utf8).write(to: first)
        XCTAssertThrowsError(try cleanup.restore(batch.id))
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "new source must survive")
        try files.removeItem(at: first)
        try cleanup.restore(batch.id)
        XCTAssertEqual(try scan().categories.flatMap(\.items).count, 2)
    }

    func testScanIncludesConversationsBeyondTheVisibleHistoryLimit() throws {
        let sessions = home.appending(path: "sessions")
        try CoreSupport.privateDirectory(sessions, fileManager: files)
        for number in 0..<2_001 { try Data("{}\n".utf8).write(to: sessions.appending(path: "\(number).jsonl")) }
        try CoreSupport.atomicWrite(Data("protected".utf8), to: home.appending(path: "logs/protected.jsonl"), fileManager: files)
        let all = try scan().categories.flatMap(\.items)
        XCTAssertEqual(all.filter { $0.path.hasPrefix("sessions/") }.count, 2_001)
        XCTAssertFalse(all.contains { $0.path.hasPrefix("logs/") })
    }

    /// Every tool's scan lists its clutter with real sizes and never lists sign-in files, settings, memory, or databases.
    func testEveryToolScanNeverListsProtectedFiles() throws {
        func put(_ base: URL, _ path: String, _ text: String = "x") throws {
            try CoreSupport.atomicWrite(Data(text.utf8), to: base.appending(path: path), fileManager: files)
        }
        let claude = root.appending(path: "claude")
        for path in ["projects/-Tmp-app/s1.jsonl", "projects/-Tmp-app/s1/subagents/a.jsonl", "projects/-Tmp-app/memory/MEMORY.md",
                     "debug/d1.txt", "file-history/f1/v1", "cache/changelog.md", "settings.json", ".credentials.json",
                     "history.jsonl", "backups/b1", "backups/b2", "backups/b3", "backups/b4", "backups/b5", "backups/b6"] {
            try put(claude, path, "claude \(path)")
        }
        let scanned = try scan(.claude, home: claude)
        let listed = scanned.categories.flatMap(\.items)
        XCTAssertEqual(category(scanned, "conversations")?.items.first?.bytes,
                       Int64("claude projects/-Tmp-app/s1.jsonl".utf8.count + "claude projects/-Tmp-app/s1/subagents/a.jsonl".utf8.count),
                       "A session counts its companion folder")
        XCTAssertEqual(category(scanned, "backups")?.items.count, 1, "The five newest backups stay")
        for forbidden in ["settings.json", ".credentials.json", "MEMORY.md", "memory"] {
            XCTAssertFalse(listed.contains { $0.allPaths.contains { $0.contains(forbidden) } }, forbidden)
        }
        XCTAssertEqual(category(scanned, "caches")?.preselected, true)
        XCTAssertEqual(category(scanned, "conversations")?.preselected, false)

        let droid = root.appending(path: "droid")
        for path in ["sessions/-Tmp-app/a.jsonl", "sessions/-Tmp-app/a.json", "sessions/-Tmp-app/a.settings.json", "logs/droid.log",
                     "auth.v2.file", "auth.v2.key", "auth.v2.loginkeychain", "settings.json"] {
            try put(droid, path)
        }
        let droidScan = try scan(.droid, home: droid)
        let droidPaths = droidScan.categories.flatMap(\.items).flatMap(\.allPaths)
        XCTAssertTrue(droidPaths.contains("sessions/-Tmp-app/a.json"))
        XCTAssertFalse(droidPaths.contains { $0.hasPrefix("auth.") || $0 == "settings.json" })

        let grok = root.appending(path: "grok")
        try put(grok, "sessions/%2FTmp%2Fapp/one/summary.json")
        try put(grok, "sessions/session_search.sqlite")
        try put(grok, "auth.json")
        let grokItems = try scan(.grok, home: grok).categories.flatMap(\.items)
        XCTAssertEqual(grokItems.map(\.project), ["/Tmp/app"])
        XCTAssertFalse(grokItems.contains { $0.path.contains("sqlite") || $0.path.contains("auth") })

        let opencode = root.appending(path: "opencode")
        try put(opencode, "opencode.db")
        try put(opencode, "auth.json")
        try put(opencode, "log/opencode.log")
        let opencodePaths = try scan(.opencode, home: opencode).categories.flatMap(\.items).map(\.path)
        XCTAssertEqual(opencodePaths, ["log/opencode.log"])
    }

    func testAnAccountsOwnClaudeHomeListsOnlyItsOwnFiles() throws {
        let shared = root.appending(path: "shared")
        let profile = root.appending(path: "profile")
        try CoreSupport.atomicWrite(Data("chat".utf8), to: shared.appending(path: "projects/-Tmp-app/s.jsonl"), fileManager: files)
        try CoreSupport.atomicWrite(Data("b".utf8), to: profile.appending(path: "cache/old"), fileManager: files)
        try files.createSymbolicLink(at: profile.appending(path: "projects"), withDestinationURL: shared.appending(path: "projects"))
        let result = try scan(.claude, home: profile)
        XCTAssertNil(category(result, "conversations"), "Conversations are shared data, not the account's")
        XCTAssertEqual(category(result, "caches")?.items.count, 1)
    }

    func testConversationRowsShowTheFirstPromptNotTheFileName() throws {
        func write(_ path: String, _ lines: [[String: Any]], in base: URL) throws {
            let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
            try CoreSupport.atomicWrite(Data(text.utf8), to: base.appending(path: path), fileManager: files)
        }
        let claude = root.appending(path: "claude")
        try write("projects/-Tmp-app/abc.jsonl", [
            ["type": "user", "isMeta": true, "message": ["role": "user", "content": "Caveat: ignore"]],
            ["type": "user", "message": ["role": "user", "content": "<command-name>/init</command-name>"]],
            ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": "Fix the popover   separators\nthen test"]]]],
        ], in: claude)
        XCTAssertEqual(category(try scan(.claude, home: claude), "conversations")?.items.first?.title, "Fix the popover separators")
        try write("sessions/2026/09/18/rollout-x.jsonl", [
            ["type": "session_meta", "payload": ["cwd": "/Projects/Synthetic"]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": String(repeating: "long ", count: 40)]],
        ], in: home)
        let title = try XCTUnwrap(category(try scan(), "conversations")?.items.first?.title)
        XCTAssertTrue(title.hasSuffix("…") && title.count == 80)
        let grok = root.appending(path: "grok")
        try CoreSupport.atomicWrite(Data("{\"generated_title\":\"Rename the exports\"}".utf8), to: grok.appending(path: "sessions/%2FTmp%2Fapp/s1/summary.json"), fileManager: files)
        try CoreSupport.atomicWrite(Data("{}".utf8), to: grok.appending(path: "sessions/%2FTmp%2Fapp/prompt_history.jsonl"), fileManager: files)
        XCTAssertEqual(category(try scan(.grok, home: grok), "conversations")?.items.map(\.title), ["Rename the exports"])
        let copilot = root.appending(path: "copilot")
        try CoreSupport.atomicWrite(Data("id: x\nname: |\n  Port the settings page\n  more\nuser_named: false\n".utf8),
            to: copilot.appending(path: "session-state/x/workspace.yaml"), fileManager: files)
        XCTAssertEqual(category(try scan(.copilot, home: copilot), "conversations")?.items.map(\.title), ["Port the settings page"])
    }

    /// Grok keeps the older rule: the launcher's build and the newest other build stay.
    func testGrokOldVersionsKeepTheLauncherBuildAndTheNewestOther() throws {
        let grok = root.appending(path: "grok")
        let releases = grok.appending(path: "downloads")
        for (index, name) in ["0.1", "0.2", "0.3", "0.4"].enumerated() {
            let folder = releases.appending(path: name)
            try CoreSupport.atomicWrite(Data(name.utf8), to: folder.appending(path: "bin"), fileManager: files)
            for url in [folder, folder.appending(path: "bin")] {
                try files.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 1_000)], ofItemAtPath: url.path)
            }
        }
        try files.createDirectory(at: grok.appending(path: "bin"), withIntermediateDirectories: true)
        try files.createSymbolicLink(at: grok.appending(path: "bin/grok"), withDestinationURL: releases.appending(path: "0.3"))
        let old = try scan(.grok, home: grok).categories.first { $0.id == "versions" }?.items.map(\.title).sorted()
        XCTAssertEqual(old, ["0.1", "0.2"], "0.3 runs and 0.4 is the newest other build")
    }

    func testCodexOldVersionsListEveryReleaseButTheCurrentOne() throws {
        let releases = home.appending(path: "packages/standalone/releases")
        for (index, name) in ["0.1", "0.2", "0.3", "0.4"].enumerated() {
            let folder = releases.appending(path: name)
            try CoreSupport.atomicWrite(Data(name.utf8), to: folder.appending(path: "bin"), fileManager: files)
            try files.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 1_000)], ofItemAtPath: folder.path)
            try files.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 1_000)],
                                    ofItemAtPath: folder.appending(path: "bin").path)
        }
        try files.createSymbolicLink(at: home.appending(path: "packages/standalone/current"), withDestinationURL: releases.appending(path: "0.3"))
        let old = try CleanupScanner(source: source(), now: later, processes: []).scan()
            .categories.first { $0.id == "versions" }?.items.map(\.title).sorted()
        XCTAssertEqual(old, ["Standalone 0.1", "Standalone 0.2", "Standalone 0.4"], "Only the current release stays")
    }

    func testFoldersOutsideTheHomeMoveWithCompanionsAndRestore() throws {
        let claude = root.appending(path: "claude")
        for path in ["projects/-Tmp-app/s1.jsonl", "projects/-Tmp-app/s1/tool-results/r"] {
            try CoreSupport.atomicWrite(Data(path.utf8), to: claude.appending(path: path), fileManager: files)
        }
        try CoreSupport.atomicWrite(Data("cache".utf8), to: user.appending(path: "Library/Caches/claude-cli-nodejs/c"), fileManager: files)
        let items = try scan(.claude, home: claude).categories.flatMap(\.selectable)
        XCTAssertEqual(items.count, 2)
        let cleanup = ConversationCleanup(home: claude, userHome: user)
        let plan = try cleanup.review(items)
        let batch = try cleanup.moveToTrash(plan)
        XCTAssertFalse(CoreSupport.entryExists(claude.appending(path: "projects/-Tmp-app/s1.jsonl")))
        XCTAssertFalse(CoreSupport.entryExists(claude.appending(path: "projects/-Tmp-app/s1")))
        XCTAssertFalse(CoreSupport.entryExists(user.appending(path: "Library/Caches/claude-cli-nodejs")))
        XCTAssertEqual(try cleanup.batches().first?.id, batch.id)
        try cleanup.restore(batch.id)
        XCTAssertTrue(CoreSupport.entryExists(claude.appending(path: "projects/-Tmp-app/s1/tool-results/r")))
        XCTAssertTrue(CoreSupport.entryExists(user.appending(path: "Library/Caches/claude-cli-nodejs/c")))
    }

    func testSourcesListSharedHomesAndFoundTools() throws {
        for folder in [".claude", ".gemini", ".copilot"] { try CoreSupport.privateDirectory(user.appending(path: folder), fileManager: files) }
        let profileHome = root.appending(path: "profile")
        try CoreSupport.privateDirectory(profileHome, fileManager: files)
        func account(_ provider: ProviderID, home: URL, email: String) -> AccountRecord {
            AccountRecord(id: UUID(), identity: AccountIdentity(providerID: provider, email: email, authMode: .oauth), home: home,
                source: home, importedAt: Date(), verification: .init(state: .verifiedLocally, checkedAt: Date(), detail: ""), credentialDigest: "d")
        }
        var userPaths = paths!
        userPaths.defaultHome = user.appending(path: ".codex")
        let sources = CleanupSources.make(paths: userPaths, accounts: [
            account(.codex, home: home, email: "a@x.test"), account(.codex, home: home, email: "b@x.test"),
            account(.claudeCode, home: profileHome, email: "c@x.test"),
        ])
        XCTAssertEqual(sources.map(\.id).prefix(2), ["codex", "claude"])
        XCTAssertEqual(sources.map(\.id).prefix(3).map { $0.hasPrefix("claude") }, [false, true, true], "Both Claude Code entries sit together")
        XCTAssertEqual(sources.first?.detail, "2 accounts")
        XCTAssertEqual(sources.first { $0.id == "claude" }?.extraHomes.map { CoreSupport.canonical($0) }, [CoreSupport.canonical(profileHome)])
        XCTAssertEqual(sources.filter { !$0.isClaudeProfile && $0.tool == .claude }.count, 1)
        XCTAssertTrue(sources.contains { $0.accountEmail == "c@x.test" && $0.home == profileHome && $0.tool == .claude })
        XCTAssertEqual(sources.suffix(2).map(\.id), ["gemini", "copilot"])
        XCTAssertEqual(sources.last?.backupService, .copilot)
    }

    private func transcript(_ relative: String, source: Any = "cli") throws -> URL {
        let url = home.appending(path: relative)
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": relative, "cwd": "/Projects/Synthetic", "source": source]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Synthetic conversation"]]]],
            ["timestamp": "2026-09-18T12:00:00Z", "type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["total_tokens": 123]]]]
        ]
        var data = Data()
        for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
        try CoreSupport.atomicWrite(data, to: url, fileManager: files)
        return url
    }
}
