import CSQLite
import Foundation
import XCTest
@testable import AIManagerCore

final class ChatHistoryIndexTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appending(
            path: "ChatHistoryIndexTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fileManager.removeItem(at: root) }
    }

    func testMessageSearchIsSeparateAndMatchesEveryTerm() async throws {
        let messages = [
            ChatMessage(id: "1", role: .user, text: "Fix the slow chat list", timestamp: nil),
            ChatMessage(id: "2", role: .assistant, text: "The chat list is now virtual", timestamp: nil),
            ChatMessage(id: "3", role: .assistant, text: "Backup checks passed", timestamp: nil),
        ]

        let result = try await ChatMessageSearch.search(messages, query: "CHAT virtual")

        XCTAssertEqual(result.totalMessageCount, 3)
        XCTAssertEqual(result.matchingMessageCount, 1)
        XCTAssertEqual(result.messages.map(\.id), ["2"])
        let emptyQuery = try await ChatMessageSearch.search(messages, query: "  ")
        XCTAssertEqual(emptyQuery.messages, messages)
    }

    func testScrollingPagesReachAllMessagesAndSearchBeyondFirstPage() async throws {
        var records: [[String: Any]] = [["type": "session_meta", "payload": ["id": "paged", "cwd": "/Projects/Paged"]]]
        records += (0..<3_100).map { index in
            ["type": "response_item", "payload": ["type": "message",
                "role": index.isMultiple(of: 3) ? "user" : "assistant",
                "content": [["type": "output_text", "text": "Message \(index) in order"]]]]
        }
        records += [tokenRecord(total: 200, at: "2026-09-15T23:59:00Z"),
                    tokenRecord(total: 400, at: "2026-09-16T00:01:00Z")]
        _ = try transcript(directory: "sessions", filename: "paged.jsonl", records: records)
        let index = ChatHistoryIndex(home: root)
        let snapshot = try await index.refresh()
        let id = try XCTUnwrap(snapshot.threads.first?.id)
        XCTAssertEqual(snapshot.threads.first?.totalTokens, 400)
        var offset = 0
        var messages: [ChatMessage] = []
        repeat {
            let loaded = try await index.detail(for: id, offset: offset)
            let page = try XCTUnwrap(loaded)
            XCTAssertLessThanOrEqual(page.messages.count, 100)
            XCTAssertEqual(page.omittedMessageCount, 0)
            XCTAssertEqual(page.matchingMessageCount, 3_100)
            messages += page.messages
            guard let next = page.nextOffset else { break }
            XCTAssertGreaterThan(next, offset)
            offset = next
        } while true
        XCTAssertEqual(messages.map(\.text), (0..<3_100).map { "Message \($0) in order" })
        XCTAssertEqual(Set(messages.map(\.id)).count, 3_100)
        let search = try await index.detail(for: id, query: "Message 3099", filter: .prompts)
        XCTAssertEqual(search?.messages.map(\.text), ["Message 3099 in order"])
        XCTAssertEqual(search?.matchingMessageCount, 1)
        XCTAssertNil(search?.nextOffset)
        let promptPage = try await index.detail(for: id, offset: 100, filter: .prompts)
        XCTAssertEqual(promptPage?.messages.first?.text, "Message 300 in order")
        XCTAssertEqual(promptPage?.matchingMessageCount, 1_034)
        XCTAssertTrue(ChatTranscriptExport.text(for: promptPage?.messages ?? []).contains("Message 300 in order"))
    }

    func testProjectActivityUsesCumulativeDeltasAndSurvivesArchiveDeletionAndCacheClear() async throws {
        let home = root.appending(path: "codex")
        let source = home.appending(path: "sessions/chat.jsonl")
        let ledger = try CodexUsageStatisticsCache(
            databaseURL: root.appending(path: "cache/usage.sqlite"),
            activityDatabaseURL: root.appending(path: "activity/daily.sqlite"))
        let cacheFile = root.appending(path: "cache/chats.json")
        let index = ChatHistoryIndex(home: home, cacheFile: cacheFile)
        await index.attachActivityCache(ledger)
        var records: [[String: Any]] = [["type": "session_meta", "payload": [
            "id": "usage-thread", "cwd": "/Projects/first"]]]
        records += [tokenRecord(total: 100, at: "2026-09-15T23:59:00Z"),
                    tokenRecord(total: 100, at: "2026-09-15T23:59:30Z"),
                    tokenRecord(total: 140, at: "2026-09-16T00:01:00Z")]
        try writeTranscript(source, records: records)
        _ = try await index.refresh()
        let unchanged = try await index.refresh()
        XCTAssertEqual(unchanged.reparsedFileCount, 0)
        var first = try await ledger.projectActivity(on: "2026-09-15")
        var second = try await ledger.projectActivity(on: "2026-09-16")
        XCTAssertEqual(first.map(\.tokens), [100])
        XCTAssertEqual(second.map(\.tokens), [40])
        records.append(tokenRecord(total: 200, at: "2026-09-16T00:02:00Z"))
        try writeTranscript(source, records: records)
        _ = try await index.refresh()
        second = try await ledger.projectActivity(on: "2026-09-16")
        XCTAssertEqual(second.map(\.tokens), [100])
        let duplicate = home.appending(path: "archived_sessions/copied.jsonl")
        try writeTranscript(duplicate, records: records)
        _ = try await index.refresh()
        try fileManager.removeItem(at: source)
        _ = try await index.refresh()
        try await index.clearCache()
        let reopened = ChatHistoryIndex(home: home, cacheFile: cacheFile)
        await reopened.attachActivityCache(ledger)
        _ = try await reopened.refresh()
        try fileManager.removeItem(at: duplicate)
        _ = try await reopened.refresh()
        first = try await ledger.projectActivity(on: "2026-09-15")
        second = try await ledger.projectActivity(on: "2026-09-16")
        XCTAssertEqual(first.map(\.tokens), [100])
        XCTAssertEqual(second.map(\.tokens), [100])
        XCTAssertEqual(second.first?.project, "/Projects/first")
        XCTAssertEqual(second.first?.isComplete, true)
    }

    func testConcurrentRefreshesShareOneScanAndKeepSeparateSearches() async throws {
        for index in 0..<100 {
            _ = try transcript(directory: "sessions", filename: "\(index).jsonl",
                records: standardRecords(id: "\(index)", prompt: index == 0 ? "one special prompt" : "ordinary"))
        }
        let index = ChatHistoryIndex(home: root, maximumWorkerCount: 1)
        async let all = index.refresh()
        async let filtered = index.refresh(query: "special")
        let results = try await (all, filtered)
        XCTAssertEqual(results.0.libraryRevision, results.1.libraryRevision)
        XCTAssertEqual(results.0.matchingThreadCount, 100)
        XCTAssertEqual(results.1.matchingThreadCount, 1)
        let unchanged = try await index.refresh()
        XCTAssertEqual(unchanged.reparsedFileCount, 0)
    }

    func testProjectActivityRetainsKnownTotalsForTruncationResetAndForkedHistory() async throws {
        let home = root.appending(path: "codex")
        let source = home.appending(path: "sessions/chat.jsonl")
        let ledger = try CodexUsageStatisticsCache(
            databaseURL: root.appending(path: "cache/usage.sqlite"),
            activityDatabaseURL: root.appending(path: "activity/daily.sqlite"))
        let index = ChatHistoryIndex(home: home)
        await index.attachActivityCache(ledger)
        let meta: [String: Any] = ["type": "session_meta", "payload": ["id": "thread", "cwd": "/Project"]]
        let initial = [meta, tokenRecord(total: 100, at: "2026-09-16T01:00:00Z"),
                       tokenRecord(total: 200, at: "2026-09-16T02:00:00Z")]
        try writeTranscript(source, records: initial)
        _ = try await index.refresh()
        try writeTranscript(source, records: Array(initial.prefix(2)))
        _ = try await index.refresh()
        var rows = try await ledger.projectActivity(on: "2026-09-16")
        XCTAssertEqual(rows.map(\.tokens), [200])
        XCTAssertEqual(rows.first?.isComplete, false)
        try writeTranscript(source, records: initial + [tokenRecord(total: 5, at: "2026-09-16T03:00:00Z")])
        _ = try await index.refresh()
        var fork = initial
        fork[0] = ["type": "session_meta", "payload": [
            "id": "child", "cwd": "/Child", "forked_from_id": "thread"]]
        fork.insert(meta, at: 1)
        try writeTranscript(home.appending(path: "sessions/fork.jsonl"), records: fork)
        let forkSnapshot = try await index.refresh()
        XCTAssertEqual(forkSnapshot.threads.first(where: { $0.threadID == "child" })?.workingDirectory, "/Child")
        var bad = try Data(contentsOf: source)
        bad.append(Data("{bad-record\n".utf8))
        try bad.write(to: source)
        _ = try await index.refresh()
        rows = try await ledger.projectActivity(on: "2026-09-16")
        XCTAssertEqual(rows.map(\.tokens), [200])
        XCTAssertEqual(rows.first?.isComplete, false)
    }

    private func tokenRecord(total: Int64, at date: String) -> [String: Any] {
        ["timestamp": date, "type": "event_msg", "payload": [
            "type": "token_count", "info": [
                "total_token_usage": ["total_tokens": total],
                "last_token_usage": ["total_tokens": 99]]]]
    }

    private func writeTranscript(_ url: URL, records: [[String: Any]]) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encodedLines(records).write(to: url)
    }

    func testMessageSearchFiltersRolesBeforeMatchingAndExportPreservesDisplayedOrder() async throws {
        let timestamp = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-09-14T04:00:00Z"))
        let messages = [
            ChatMessage(id: "1", role: .user, text: "Inspect cache", timestamp: timestamp),
            ChatMessage(id: "2", role: .assistant, text: "Cache is valid", timestamp: nil),
            ChatMessage(id: "3", role: .tool, text: "read_file\ncache.json", timestamp: timestamp),
            ChatMessage(id: "4", role: .other, text: "Checked the cache boundary", timestamp: nil),
        ]

        let result = try await ChatMessageSearch.search(
            messages, query: "cache", filter: [.prompts, .tools])

        XCTAssertEqual(result.totalMessageCount, 2)
        XCTAssertEqual(result.matchingMessageCount, 2)
        XCTAssertEqual(result.messages.map(\.id), ["1", "3"])
        XCTAssertEqual(
            ChatTranscriptExport.text(for: result.messages),
            """
            [Prompt | 2026-09-14T04:00:00.000Z]
            Inspect cache

            [Tool | 2026-09-14T04:00:00.000Z]
            read_file
            cache.json
            """)
        let none = try await ChatMessageSearch.search(messages, query: "", filter: [])
        XCTAssertTrue(none.messages.isEmpty)
        XCTAssertEqual(ChatTranscriptExport.text(for: none.messages), "")
    }

    func testPersistentSummaryCacheSkipsUnchangedTranscriptBodies() async throws {
        _ = try transcript(
            directory: "sessions/2026/09/14",
            filename: "cached.jsonl",
            records: standardRecords(id: "cached", prompt: "Reuse the summary cache"))
        let cacheFile = root.appending(path: "manager/cache/chat-history-v1.json")

        let initial = try await ChatHistoryIndex(
            home: root, cacheFile: cacheFile, maximumWorkerCount: 2).refresh()
        XCTAssertEqual(initial.reparsedFileCount, 1)
        XCTAssertTrue(fileManager.fileExists(atPath: cacheFile.path))
        let permissions = try XCTUnwrap(
            try fileManager.attributesOfItem(atPath: cacheFile.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)

        let reopened = try await ChatHistoryIndex(
            home: root, cacheFile: cacheFile, maximumWorkerCount: 2).refresh()
        XCTAssertEqual(reopened.reparsedFileCount, 0)
        XCTAssertEqual(reopened.threads.first?.title, "Reuse the summary cache")

        try Data("not a cache".utf8).write(to: cacheFile)
        let recovered = try await ChatHistoryIndex(
            home: root, cacheFile: cacheFile, maximumWorkerCount: 2).refresh()
        XCTAssertEqual(recovered.reparsedFileCount, 1)
        XCTAssertEqual(recovered.totalThreadCount, 1)
    }

    func testClearCacheRemovesOnlyTheIndexAndRebuildsFromTranscripts() async throws {
        let transcriptURL = try transcript(
            directory: "sessions/2026/09/14",
            filename: "cached.jsonl",
            records: standardRecords(id: "cached", prompt: "Rebuild the conversation index"))
        let cacheFile = root.appending(path: "manager/cache/chat-history-v1.json")
        let index = ChatHistoryIndex(home: root, cacheFile: cacheFile, maximumWorkerCount: 2)

        let initial = try await index.refresh()
        XCTAssertEqual(initial.reparsedFileCount, 1)
        XCTAssertTrue(fileManager.fileExists(atPath: cacheFile.path))

        try await index.clearCache()

        XCTAssertFalse(fileManager.fileExists(atPath: cacheFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: transcriptURL.path))
        let empty = await index.search(query: "")
        XCTAssertEqual(empty.totalThreadCount, 0)
        let rebuilt = try await index.refresh()
        XCTAssertEqual(rebuilt.reparsedFileCount, 1)
        XCTAssertEqual(rebuilt.totalThreadCount, 1)
    }

    func testIndexSearchAndDetailUseCodexMessagesWithoutDuplicates() async throws {
        let active = try transcript(
            directory: "sessions/2026/09/13",
            filename: "active.jsonl",
            records: [
                ["timestamp": "2026-09-13T04:00:00.000Z", "type": "session_meta", "payload": [
                    "id": "thread-active", "cwd": "/Projects/Switch",
                ]],
                ["timestamp": "2026-09-13T04:00:01.000Z", "type": "response_item", "payload": [
                    "type": "message", "role": "user",
                    "content": [["type": "input_text", "text": "Polish the account switcher"]],
                ]],
                ["timestamp": "2026-09-13T04:00:01.010Z", "type": "event_msg", "payload": [
                    "type": "user_message", "message": "Polish the account switcher", "kind": "plain",
                ]],
                ["timestamp": "2026-09-13T04:00:02.000Z", "type": "response_item", "payload": [
                    "type": "message", "role": "assistant",
                    "content": [["type": "output_text", "text": "The layout is ready to review."]],
                ]],
            ])
        _ = active
        _ = try transcript(
            directory: "archived_sessions",
            filename: "archived.jsonl",
            records: [
                ["id": "legacy-thread", "timestamp": "2025-01-03T12:00:00Z"],
                ["type": "message", "role": "user", "content": [
                    ["type": "input_text", "text": "Old deployment notes"],
                ]],
            ])

        let index = ChatHistoryIndex(home: root, maximumWorkerCount: 3)
        let snapshot = try await index.refresh(query: "account switcher")

        XCTAssertEqual(snapshot.totalThreadCount, 2)
        XCTAssertEqual(snapshot.matchingThreadCount, 1)
        XCTAssertEqual(snapshot.reparsedFileCount, 2)
        XCTAssertEqual(snapshot.threads.first?.threadID, "thread-active")
        XCTAssertEqual(snapshot.threads.first?.title, "Polish the account switcher")
        XCTAssertEqual(snapshot.threads.first?.messageCount, 2)
        XCTAssertEqual(snapshot.threads.first?.preview, "The layout is ready to review.")

        let detail = try await index.detail(for: try XCTUnwrap(snapshot.threads.first?.id))
        XCTAssertEqual(detail?.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(detail?.messages.map(\.text), [
            "Polish the account switcher", "The layout is ready to review.",
        ])
        XCTAssertEqual(detail?.omittedMessageCount, 0)
    }

    func testDetailClassifiesVisibleToolRecordsAndOnlyReasoningSummaries() async throws {
        _ = try transcript(
            directory: "sessions/2026/09/14",
            filename: "classified.jsonl",
            records: [
                ["timestamp": "2026-09-14T04:00:00.000Z", "type": "session_meta", "payload": [
                    "id": "classified", "cwd": "/Projects/Switch",
                ]],
                ["timestamp": "2026-09-14T04:00:01.000Z", "type": "event_msg", "payload": [
                    "type": "user_message", "message": "Inspect the account cache",
                ]],
                ["timestamp": "2026-09-14T04:00:02.000Z", "type": "response_item", "payload": [
                    "type": "message", "role": "assistant",
                    "content": [["type": "output_text", "text": "I will inspect it."]],
                ]],
                ["timestamp": "2026-09-14T04:00:03.000Z", "type": "response_item", "payload": [
                    "type": "function_call", "name": "read_file", "arguments": "{\"path\":\"cache.json\"}",
                ]],
                ["timestamp": "2026-09-14T04:00:04.000Z", "type": "response_item", "payload": [
                    "type": "function_call_output", "output": "cache is valid",
                ]],
                ["timestamp": "2026-09-14T04:00:05.000Z", "type": "response_item", "payload": [
                    "type": "custom_tool_call", "name": "review", "input": "account cache",
                ]],
                ["timestamp": "2026-09-14T04:00:06.000Z", "type": "response_item", "payload": [
                    "type": "custom_tool_call_output", "output": "review passed",
                ]],
                ["timestamp": "2026-09-14T04:00:07.000Z", "type": "response_item", "payload": [
                    "type": "local_shell_call", "action": ["command": ["cat", "cache.json"]],
                ]],
                ["timestamp": "2026-09-14T04:00:08.000Z", "type": "response_item", "payload": [
                    "type": "web_search_call", "action": ["query": "Codex cache format"],
                ]],
                ["timestamp": "2026-09-14T04:00:09.000Z", "type": "response_item", "payload": [
                    "type": "reasoning",
                    "summary": [["type": "summary_text", "text": "Checked the visible cache fields."]],
                    "content": [["type": "reasoning_text", "text": "raw-secret"]],
                    "encrypted_content": "encrypted-secret",
                ]],
            ])

        let index = ChatHistoryIndex(home: root)
        let snapshot = try await index.refresh()
        let detailID = try XCTUnwrap(snapshot.threads.first?.id)
        let loadedDetail = try await index.detail(for: detailID)
        let detail = try XCTUnwrap(loadedDetail)

        XCTAssertEqual(
            detail.messages.map(\.role),
            [.user, .assistant, .tool, .tool, .tool, .tool, .tool, .tool, .other])
        XCTAssertEqual(snapshot.threads.first?.messageCount, 9)
        XCTAssertEqual(detail.messages[2].text, "read_file\n{\"path\":\"cache.json\"}")
        XCTAssertEqual(detail.messages[6].text, "Shell command\ncat cache.json")
        XCTAssertEqual(detail.messages[7].text, "Web search\nCodex cache format")
        XCTAssertEqual(detail.messages.last?.text, "Checked the visible cache fields.")
        XCTAssertFalse(detail.messages.contains { $0.text.contains("raw-secret") })
        XCTAssertFalse(detail.messages.contains { $0.text.contains("encrypted-secret") })
    }

    func testCanonicalDatabaseNameOverridesInjectedContextWithoutReparsing() async throws {
        let transcriptURL = try transcript(
            directory: "sessions/2026/09/14",
            filename: "named.jsonl",
            records: [
                ["timestamp": "2026-09-14T04:00:00.000Z", "type": "session_meta", "payload": [
                    "id": "thread-named", "cwd": "/Projects/Old Name",
                ]],
                ["timestamp": "2026-09-14T04:00:01.000Z", "type": "event_msg", "payload": [
                    "type": "user_message",
                    "message": "# AGENTS.md instructions for /Projects/Old Name\n<INSTRUCTIONS>\nBootstrap only",
                ]],
                ["timestamp": "2026-09-14T04:00:02.000Z", "type": "event_msg", "payload": [
                    "type": "user_message", "message": "Make the reader calm and legible",
                ]],
                ["timestamp": "2026-09-14T04:00:03.000Z", "type": "response_item", "payload": [
                    "type": "message", "role": "assistant",
                    "content": [["type": "output_text", "text": "The visual hierarchy is quieter."]],
                ]],
            ])
        try createThreadDatabase(
            threadID: "thread-named",
            rolloutPath: transcriptURL.path,
            name: "Reading comfort pass",
            title: "# AGENTS.md instructions for /Projects/Old Name",
            preview: "The visual hierarchy is quieter.",
            workingDirectory: "/Projects/Switch")
        let index = ChatHistoryIndex(home: root, maximumWorkerCount: 2)

        let initial = try await index.refresh()

        XCTAssertEqual(initial.reparsedFileCount, 1)
        XCTAssertEqual(initial.threads.first?.title, "Reading comfort pass")
        XCTAssertEqual(initial.threads.first?.workingDirectory, "/Projects/Switch")
        XCTAssertEqual(initial.threads.first?.messageCount, 2)
        let detail = try await index.detail(for: try XCTUnwrap(initial.threads.first?.id))
        XCTAssertEqual(detail?.messages.map(\.text), [
            "Make the reader calm and legible", "The visual hierarchy is quieter.",
        ])

        try updateThreadName("Reader typography polish")
        let renamed = try await index.refresh()

        XCTAssertEqual(renamed.reparsedFileCount, 0)
        XCTAssertEqual(renamed.threads.first?.title, "Reader typography polish")
        XCTAssertGreaterThan(renamed.libraryRevision, initial.libraryRevision)

        try deleteThreadMetadata()
        let fallback = try await index.refresh()

        XCTAssertEqual(fallback.reparsedFileCount, 0)
        XCTAssertEqual(fallback.threads.first?.title, "Make the reader calm and legible")
    }

    func testMetadataChangeTouchesOnlyItsThread() async throws {
        let named = try transcript(
            directory: "sessions/2026/09/14", filename: "named-only.jsonl",
            records: standardRecords(id: "named-only", prompt: "Named transcript"))
        _ = try transcript(
            directory: "sessions/2026/09/14", filename: "unchanged.jsonl",
            records: standardRecords(id: "unchanged", prompt: "Unchanged transcript"))
        try createThreadDatabase(
            threadID: "named-only",
            rolloutPath: named.path,
            name: "First name",
            title: "Named transcript",
            preview: "Named preview",
            workingDirectory: "/Projects/Switch")
        let index = ChatHistoryIndex(home: root)
        _ = try await index.refresh()

        try updateThreadName("Second name")
        let updated = try await index.refresh()
        let metrics = await index.refreshMetrics()

        XCTAssertEqual(updated.reparsedFileCount, 0)
        XCTAssertEqual(
            updated.threads.first(where: { $0.threadID == "named-only" })?.title,
            "Second name")
        XCTAssertEqual(metrics.metadataAppliedThreadCount, 1)
        XCTAssertEqual(metrics.parsedByteCount, 0)
    }

    func testLegacyFallbackSkipsBootstrapContext() async throws {
        _ = try transcript(
            directory: "sessions/2026/09/14",
            filename: "legacy-context.jsonl",
            records: [
                ["timestamp": "2026-09-14T05:00:00Z", "type": "session_meta", "payload": [
                    "id": "legacy-context", "cwd": "/Projects/Reader",
                ]],
                ["timestamp": "2026-09-14T05:00:01Z", "type": "event_msg", "payload": [
                    "type": "user_message",
                    "message": "<environment_context>\nprivate bootstrap details\n</environment_context>",
                ]],
                ["timestamp": "2026-09-14T05:00:02Z", "type": "event_msg", "payload": [
                    "type": "user_message", "message": "Use the actual conversation title",
                ]],
            ])
        let index = ChatHistoryIndex(home: root)

        let snapshot = try await index.refresh()
        let detail = try await index.detail(for: try XCTUnwrap(snapshot.threads.first?.id))

        XCTAssertEqual(snapshot.threads.first?.title, "Use the actual conversation title")
        XCTAssertEqual(snapshot.threads.first?.messageCount, 1)
        XCTAssertEqual(detail?.messages.map(\.text), ["Use the actual conversation title"])
    }

    func testOlderCacheReparsesForMessageCategoriesAndAppliesDatabaseName() async throws {
        let transcriptURL = try transcript(
            directory: "sessions/2026/09/14",
            filename: "migration.jsonl",
            records: standardRecords(id: "cache-migration", prompt: "Original transcript title"))
        let cacheFile = root.appending(path: "manager/cache/chat-history-v1.json")
        _ = try await ChatHistoryIndex(home: root, cacheFile: cacheFile).refresh()
        var cacheObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: cacheFile)) as? [String: Any])
        cacheObject["version"] = 1
        let legacyData = try JSONSerialization.data(withJSONObject: cacheObject, options: [.sortedKeys])
        try legacyData.write(to: cacheFile, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheFile.path)
        try createThreadDatabase(
            threadID: "cache-migration",
            rolloutPath: transcriptURL.path,
            name: "Migrated canonical name",
            title: "Original transcript title",
            preview: "Cached preview",
            workingDirectory: "/Projects/Cache")

        let reopened = try await ChatHistoryIndex(home: root, cacheFile: cacheFile).refresh()
        let migratedObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: cacheFile)) as? [String: Any])

        XCTAssertEqual(reopened.reparsedFileCount, 1)
        XCTAssertEqual(reopened.threads.first?.title, "Migrated canonical name")
        XCTAssertEqual(migratedObject["version"] as? Int, 4)
    }

    func testRefreshReparsesOnlyChangedFilesAndSkipsMalformedRecords() async throws {
        let first = try transcript(
            directory: "sessions/2026/09/13", filename: "first.jsonl",
            records: standardRecords(id: "first", prompt: "First chat"))
        _ = try transcript(
            directory: "sessions/2026/09/13", filename: "second.jsonl",
            records: standardRecords(id: "second", prompt: "Second chat"))
        let index = ChatHistoryIndex(home: root, maximumWorkerCount: 2)

        let initial = try await index.refresh()
        let unchanged = try await index.refresh()
        XCTAssertEqual(initial.reparsedFileCount, 2)
        XCTAssertEqual(unchanged.reparsedFileCount, 0)
        XCTAssertEqual(unchanged.libraryRevision, initial.libraryRevision)

        let handle = try FileHandle(forWritingTo: first)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try handle.close()
        let updated = try await index.refresh()

        XCTAssertEqual(updated.reparsedFileCount, 0)
        XCTAssertGreaterThan(updated.libraryRevision, unchanged.libraryRevision)
        XCTAssertEqual(updated.totalThreadCount, 2)
        XCTAssertEqual(updated.unreadableRecordCount, 1)
    }

    func testAppendReadsOnlyNewBytesAndSkipsUnchangedMetadata() async throws {
        let file = try transcript(
            directory: "sessions/2026/09/13", filename: "growing.jsonl",
            records: standardRecords(id: "growing", prompt: "Initial request"))
        let index = ChatHistoryIndex(home: root, maximumWorkerCount: 2)
        _ = try await index.refresh()
        let appended = try encodedLines([[
            "timestamp": "2026-09-13T04:00:02Z",
            "type": "response_item",
            "payload": [
                "type": "message", "role": "assistant",
                "content": [["type": "output_text", "text": "Appended response"]],
            ],
        ]])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: appended)
        try handle.close()

        let updated = try await index.refresh()
        let metrics = await index.refreshMetrics()

        XCTAssertEqual(updated.reparsedFileCount, 0)
        XCTAssertEqual(updated.threads.first?.messageCount, 2)
        XCTAssertEqual(updated.threads.first?.preview, "Appended response")
        XCTAssertEqual(metrics.fullyParsedFileCount, 0)
        XCTAssertEqual(metrics.incrementallyParsedFileCount, 1)
        XCTAssertEqual(metrics.parsedByteCount, Int64(appended.count))
        XCTAssertEqual(metrics.metadataAppliedThreadCount, 0)
    }

    func testPersistentCacheResumesAnAppendAfterRestart() async throws {
        let cacheFile = root.appending(path: "manager/cache/chat-history-v1.json")
        let file = try transcript(
            directory: "sessions/2026/09/13", filename: "restart.jsonl",
            records: standardRecords(id: "restart", prompt: "Before restart"))
        _ = try await ChatHistoryIndex(home: root, cacheFile: cacheFile).refresh()
        let reopened = ChatHistoryIndex(home: root, cacheFile: cacheFile)
        _ = try await reopened.refresh()
        let appended = try encodedLines([[
            "timestamp": "2026-09-13T04:00:02Z",
            "type": "response_item",
            "payload": [
                "type": "message", "role": "assistant",
                "content": [["type": "output_text", "text": "After restart"]],
            ],
        ]])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: appended)
        try handle.close()

        let updated = try await reopened.refresh()
        let metrics = await reopened.refreshMetrics()

        XCTAssertEqual(updated.reparsedFileCount, 0)
        XCTAssertEqual(updated.threads.first?.preview, "After restart")
        XCTAssertEqual(metrics.incrementallyParsedFileCount, 1)
        XCTAssertEqual(metrics.parsedByteCount, Int64(appended.count))
    }

    func testUnsafeAppendBoundaryFallsBackToFullParse() async throws {
        let directory = root.appending(
            path: "sessions/2026/09/13", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "partial.jsonl")
        var initial = try encodedLines(standardRecords(id: "partial", prompt: "Before append"))
        initial.removeLast()
        try initial.write(to: file)
        let index = ChatHistoryIndex(home: root)
        _ = try await index.refresh()
        let appended = try encodedLines([[
            "timestamp": "2026-09-13T04:00:02Z",
            "type": "response_item",
            "payload": [
                "type": "message", "role": "assistant",
                "content": [["type": "output_text", "text": "Safe fallback"]],
            ],
        ]])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x0A]) + appended)
        try handle.close()

        let updated = try await index.refresh()
        let metrics = await index.refreshMetrics()

        XCTAssertEqual(updated.reparsedFileCount, 1)
        XCTAssertEqual(updated.threads.first?.messageCount, 2)
        XCTAssertEqual(metrics.fullyParsedFileCount, 1)
        XCTAssertEqual(metrics.incrementallyParsedFileCount, 0)
    }

    func testIndexNeverFollowsTranscriptSymlinks() async throws {
        let external = root.appending(path: "external", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: external, withIntermediateDirectories: true)
        let externalFile = external.appending(path: "outside.jsonl")
        try encodedLines(standardRecords(id: "outside", prompt: "Outside chat")).write(to: externalFile)
        let sessions = root.appending(path: "sessions", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: sessions.appending(path: "linked"), withDestinationURL: external)
        try fileManager.createSymbolicLink(
            at: sessions.appending(path: "linked-file.jsonl"), withDestinationURL: externalFile)

        let snapshot = try await ChatHistoryIndex(home: root).refresh()

        XCTAssertEqual(snapshot.totalThreadCount, 0)
        XCTAssertEqual(snapshot.skippedFileCount, 0)
    }

    func testOversizedRecordDoesNotBlockVisibleMessages() async throws {
        let file = try transcript(
            directory: "sessions/2026/09/13", filename: "large.jsonl",
            records: standardRecords(id: "large", prompt: "Keep the chat view responsive"))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let oversized = try JSONSerialization.data(withJSONObject: [
            "type": "response_item",
            "payload": [
                "type": "function_call_output",
                "output": String(repeating: "x", count: 5 * 1_024 * 1_024),
            ],
        ])
        try handle.write(contentsOf: oversized)
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()

        let index = ChatHistoryIndex(home: root, maximumWorkerCount: 2)
        let snapshot = try await index.refresh()

        XCTAssertEqual(snapshot.totalThreadCount, 1)
        XCTAssertEqual(snapshot.threads.first?.title, "Keep the chat view responsive")
        XCTAssertEqual(snapshot.unreadableRecordCount, 0)
        let detail = try await index.detail(for: try XCTUnwrap(snapshot.threads.first?.id))
        XCTAssertEqual(detail?.messages.count, 2)
        XCTAssertTrue(detail?.messages.last?.text.hasSuffix(String(repeating: "x", count: 5 * 1_024 * 1_024)) == true)
        XCTAssertEqual(detail?.omittedMessageCount, 0)
    }

    private func standardRecords(id: String, prompt: String) -> [[String: Any]] {
        [
            ["timestamp": "2026-09-13T04:00:00Z", "type": "session_meta", "payload": ["id": id]],
            ["timestamp": "2026-09-13T04:00:01Z", "type": "event_msg", "payload": [
                "type": "user_message", "message": prompt,
            ]],
        ]
    }

    @discardableResult
    private func transcript(
        directory: String,
        filename: String,
        records: [[String: Any]]
    ) throws -> URL {
        let directoryURL = root.appending(path: directory, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let file = directoryURL.appending(path: filename)
        try encodedLines(records).write(to: file)
        return file
    }

    private func encodedLines(_ records: [[String: Any]]) throws -> Data {
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            data.append(0x0A)
        }
        return data
    }

    private func createThreadDatabase(
        threadID: String,
        rolloutPath: String,
        name: String,
        title: String,
        preview: String,
        workingDirectory: String
    ) throws {
        let database = root.appending(path: "state_5.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                database.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                title TEXT,
                name TEXT,
                preview TEXT,
                cwd TEXT,
                updated_at_ms INTEGER,
                archived INTEGER
            )
            """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        let insert = """
            INSERT INTO threads
                (id, rollout_path, title, name, preview, cwd, updated_at_ms, archived)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, 1789362000000, 0)
            """
        XCTAssertEqual(sqlite3_prepare_v2(db, insert, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in [
            threadID, rolloutPath, title, name, preview, workingDirectory,
        ].enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    private func updateThreadName(_ name: String) throws {
        let database = root.appending(path: "state_5.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(db, "UPDATE threads SET name = ?1", -1, &statement, nil),
            SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, name, -1, transient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    private func deleteThreadMetadata() throws {
        let database = root.appending(path: "state_5.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "DELETE FROM threads", nil, nil, nil), SQLITE_OK)
    }
}
