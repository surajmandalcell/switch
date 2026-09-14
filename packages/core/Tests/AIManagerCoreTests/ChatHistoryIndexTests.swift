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

        XCTAssertEqual(updated.reparsedFileCount, 1)
        XCTAssertGreaterThan(updated.libraryRevision, unchanged.libraryRevision)
        XCTAssertEqual(updated.totalThreadCount, 2)
        XCTAssertEqual(updated.unreadableRecordCount, 1)
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
        XCTAssertEqual(detail?.messages.count, 1)
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
}
