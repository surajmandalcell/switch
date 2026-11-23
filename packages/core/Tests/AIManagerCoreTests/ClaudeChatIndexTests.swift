@testable import AIManagerCore
import Foundation
import XCTest

final class ClaudeChatIndexTests: XCTestCase {
    private func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func record(_ type: String, _ content: Any, at second: Int, extra: [String: Any] = [:]) -> [String: Any] {
        var message: [String: Any] = ["role": type, "content": content]
        if type == "assistant" { message["model"] = "claude-opus-5-5" }
        return ["type": type, "sessionId": "s", "cwd": "/Projects/Switch", "isSidechain": false,
                "timestamp": "2026-11-20T10:00:\(String(format: "%02d", second)).000Z", "message": message]
            .merging(extra) { $1 }
    }

    /// Three synthetic sessions in a temp Claude home: titles, tagging, parts, a malformed line,
    /// incremental append, the cache file, and the merged list beside Codex rows.
    func testIndexesClaudeSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ClaudeChatIndexTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "claude/projects/-Projects-Switch")
        try FileManager.default.createDirectory(at: folder.appending(path: "a/subagents"), withIntermediateDirectories: true)
        let first = folder.appending(path: "a.jsonl")
        let lines = [
            try line(record("user", "<command-name>/clear</command-name>", at: 0)),
            try line(record("user", "Fix the History filter", at: 1)),
            try line(record("assistant", [["type": "thinking", "thinking": "plan"],
                                          ["type": "tool_use", "name": "Read", "input": ["file_path": "x.swift"]]], at: 2)),
            "{\"type\":\"user\", broken",
            try line(record("user", [["type": "tool_result", "content": "file body"]], at: 3)),
            try line(record("assistant", [["type": "text", "text": "Done, the filter works."]], at: 4)),
            try line(["type": "api-request", "sessionId": "s"]),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: first, atomically: true, encoding: .utf8)
        try (try line(record("user", "Sidechain", at: 1)) + "\n")
            .write(to: folder.appending(path: "a/subagents/agent.jsonl"), atomically: true, encoding: .utf8)
        try ([try line(record("user", "First prompt", at: 5)), try line(["type": "ai-title", "aiTitle": "AI title"]),
              try line(["type": "custom-title", "customTitle": "My name"])].joined(separator: "\n") + "\n")
            .write(to: folder.appending(path: "b.jsonl"), atomically: true, encoding: .utf8)
        try ([try line(["type": "summary", "summary": "Old summary"]), try line(record("user", "Hi", at: 6))]
            .joined(separator: "\n") + "\n").write(to: folder.appending(path: "c.jsonl"), atomically: true, encoding: .utf8)

        let cache = root.appending(path: "cache.json")
        let index = ClaudeChatIndex(roots: [root.appending(path: "claude"), folder.deletingLastPathComponent()],
                                    cacheFile: cache)
        let snapshot = try await index.refresh()
        XCTAssertEqual(snapshot.totalThreadCount, 3, "subagent logs and duplicate roots are skipped")
        XCTAssertEqual(Set(snapshot.threads.map(\.title)), ["Fix the History filter", "My name", "Old summary"])
        XCTAssertTrue(snapshot.threads.allSatisfy { $0.appSource == .claude })
        let a = try XCTUnwrap(snapshot.threads.first { $0.source.lastPathComponent == "a.jsonl" })
        XCTAssertEqual(a.unreadableRecordCount, 1)
        XCTAssertEqual(a.model, "claude-opus-5-5")
        XCTAssertEqual(a.workingDirectory, "/Projects/Switch")
        XCTAssertEqual(a.preview, "Done, the filter works.")
        XCTAssertEqual(a.messageCount, 6)

        let detail = try await index.detail(for: a.id)
        XCTAssertEqual(detail?.messages.map(\.role), [.other, .user, .other, .tool, .tool, .assistant])
        XCTAssertEqual(detail?.messages[3].text, "Read\n{\"file_path\":\"x.swift\"}")
        XCTAssertEqual(detail?.messages[4].text, "file body")
        let tools = try await index.detail(for: a.id, filter: .tools)
        XCTAssertEqual(tools?.matchingMessageCount, 2)
        let none = try await index.detail(for: "/not/claude.jsonl")
        XCTAssertNil(none)

        // Appending resumes; a reopened index reads the saved rows without reparsing.
        let handle = try FileHandle(forWritingTo: first)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((try line(record("user", "One more", at: 9)) + "\n").utf8))
        try handle.close()
        let grown = try await index.refresh()
        XCTAssertEqual(grown.threads.first { $0.id == a.id }?.messageCount, 7)
        XCTAssertGreaterThan(grown.libraryRevision, snapshot.libraryRevision)
        let reopened = try await ClaudeChatIndex(roots: [root.appending(path: "claude")], cacheFile: cache).refresh()
        XCTAssertEqual(reopened.threads.map(\.id), grown.threads.map(\.id))

        let filtered = await index.search(query: "my name")
        XCTAssertEqual(filtered.matchingThreadCount, 1)

        let codex = ChatThreadSummary(
            id: "codex", threadID: "codex", title: "Codex chat", preview: "", workingDirectory: nil,
            updatedAt: Date(), archived: false, messageCount: 1, fileByteCount: 1,
            source: URL(fileURLWithPath: "/codex.jsonl"), unreadableRecordCount: 0, appSource: .cli)
        let merged = ChatHistorySnapshot.merging(
            ChatHistorySnapshot(threads: [codex], libraryRevision: 1, totalThreadCount: 1, matchingThreadCount: 1),
            grown)
        XCTAssertEqual(merged.threads.first?.id, "codex", "newest first across providers")
        XCTAssertEqual(merged.totalThreadCount, 4)
        XCTAssertEqual(Dictionary(grouping: merged.threads, by: \.appSource).mapValues(\.count), [.cli: 1, .claude: 3])

        // The app filter runs before the limit: a newer Codex row cannot push the Claude rows out.
        // The Codex side stands for a filtered ChatHistoryIndex: no rows, one hidden Codex chat.
        var codexFiltered = ChatHistorySnapshot(libraryRevision: 1, totalThreadCount: 1, matchingThreadCount: 0)
        codexFiltered.sourceCounts = [.cli: 1]
        let claudeOnly = ChatHistorySnapshot.merging(
            codexFiltered,
            await index.search(query: "", limit: 1, sources: [.claude]), limit: 1)
        XCTAssertEqual(claudeOnly.threads.map(\.appSource), [.claude])
        XCTAssertEqual(claudeOnly.matchingThreadCount, 3)
        XCTAssertEqual(claudeOnly.sourceCounts, [.cli: 1, .claude: 3])
        let codexOnly = await index.search(query: "", sources: [.cli])
        XCTAssertEqual(codexOnly.threads.count, 0)
        XCTAssertEqual(codexOnly.sourceCounts, [.claude: 3], "the filter panel still counts the hidden app")
    }

    /// A scan that was reading when the cache was cleared does not bring its rows back, and a long
    /// response keeps its full text for copying.
    func testClearDuringScanAndFullMessageText() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ClaudeChatIndexTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "projects/-Projects-Switch")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let long = String(repeating: "a", count: 25_000)
        try ([try line(record("user", "Long answer please", at: 0)),
              try line(record("assistant", [["type": "text", "text": long]], at: 1))].joined(separator: "\n") + "\n")
            .write(to: folder.appending(path: "a.jsonl"), atomically: true, encoding: .utf8)
        let cache = root.appending(path: "cache.json")
        let index = ClaudeChatIndex(roots: [root], cacheFile: cache)

        let first = try await index.refresh()
        let id = try XCTUnwrap(first.threads.first?.id)
        let detail = try await index.detail(for: id)
        XCTAssertEqual(detail?.messages.last?.text, long)

        await index.clearCache()
        await index.setWillCommitScan { await index.clearCache() }
        let raced = try await index.refresh()
        XCTAssertEqual(raced.totalThreadCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }
}
