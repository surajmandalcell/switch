import Foundation

public enum ChatMessageRole: String, Sendable, Equatable {
    case user
    case assistant
}

public struct ChatMessage: Identifiable, Sendable, Equatable {
    public let id: String
    public let role: ChatMessageRole
    public let text: String
    public let timestamp: Date?

    public init(id: String, role: ChatMessageRole, text: String, timestamp: Date?) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}

public struct ChatThreadSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let threadID: String
    public let title: String
    public let preview: String
    public let workingDirectory: String?
    public let updatedAt: Date
    public let archived: Bool
    public let messageCount: Int
    public let fileByteCount: Int64
    public let source: URL
    public let unreadableRecordCount: Int

    public init(
        id: String,
        threadID: String,
        title: String,
        preview: String,
        workingDirectory: String?,
        updatedAt: Date,
        archived: Bool,
        messageCount: Int,
        fileByteCount: Int64,
        source: URL,
        unreadableRecordCount: Int
    ) {
        self.id = id
        self.threadID = threadID
        self.title = title
        self.preview = preview
        self.workingDirectory = workingDirectory
        self.updatedAt = updatedAt
        self.archived = archived
        self.messageCount = messageCount
        self.fileByteCount = fileByteCount
        self.source = source
        self.unreadableRecordCount = unreadableRecordCount
    }
}

public struct ChatThreadDetail: Sendable, Equatable {
    public let thread: ChatThreadSummary
    public let messages: [ChatMessage]
    public let omittedMessageCount: Int

    public init(
        thread: ChatThreadSummary,
        messages: [ChatMessage],
        omittedMessageCount: Int
    ) {
        self.thread = thread
        self.messages = messages
        self.omittedMessageCount = omittedMessageCount
    }
}

public struct ChatHistorySnapshot: Sendable, Equatable {
    public let threads: [ChatThreadSummary]
    public let totalThreadCount: Int
    public let matchingThreadCount: Int
    public let skippedFileCount: Int
    public let unreadableRecordCount: Int
    public let reparsedFileCount: Int

    public init(
        threads: [ChatThreadSummary] = [],
        totalThreadCount: Int = 0,
        matchingThreadCount: Int = 0,
        skippedFileCount: Int = 0,
        unreadableRecordCount: Int = 0,
        reparsedFileCount: Int = 0
    ) {
        self.threads = threads
        self.totalThreadCount = totalThreadCount
        self.matchingThreadCount = matchingThreadCount
        self.skippedFileCount = skippedFileCount
        self.unreadableRecordCount = unreadableRecordCount
        self.reparsedFileCount = reparsedFileCount
    }
}

public actor ChatHistoryIndex {
    fileprivate struct FileSignature: Sendable, Equatable {
        let byteCount: Int64
        let modifiedAt: Date
    }

    fileprivate struct Candidate: Sendable {
        let url: URL
        let archived: Bool
        let signature: FileSignature
    }

    private struct CachedThread: Sendable {
        let signature: FileSignature
        let summary: ChatThreadSummary
        let searchText: String
    }

    private struct CachedDetail: Sendable {
        let signature: FileSignature
        let detail: ChatThreadDetail
    }

    private enum WorkerResult: Sendable {
        case parsed(Candidate, ParsedTranscript)
        case failed(Candidate)
        case cancelled
    }

    private let home: URL
    private let workerCount: Int
    private var cache: [String: CachedThread] = [:]
    private var failedSignatures: [String: FileSignature] = [:]
    private var detailCache: [String: CachedDetail] = [:]
    private var orderedCache: [CachedThread] = []
    private var cachedUnreadableRecordCount = 0
    private var orderedCacheIsDirty = true

    public init(home: URL, maximumWorkerCount: Int? = nil) {
        self.home = CoreSupport.home(for: home).standardizedFileURL
        let requested = maximumWorkerCount
            ?? max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        workerCount = min(max(1, requested), 6)
    }

    public func refresh(query: String = "", limit: Int = 1_000) async throws -> ChatHistorySnapshot {
        try Task.checkCancellation()
        let candidates = try Self.transcriptCandidates(in: home)
        let currentPaths = Set(candidates.map { $0.url.path })
        if cache.keys.contains(where: { !currentPaths.contains($0) }) {
            orderedCacheIsDirty = true
        }
        cache = cache.filter { currentPaths.contains($0.key) }
        failedSignatures = failedSignatures.filter { currentPaths.contains($0.key) }
        detailCache = detailCache.filter { currentPaths.contains($0.key) }

        let changed = candidates.filter { candidate in
            let path = candidate.url.path
            return cache[path]?.signature != candidate.signature
                && failedSignatures[path] != candidate.signature
        }
        let parsed = await parseConcurrently(changed)
        try Task.checkCancellation()

        for result in parsed {
            switch result {
            case let .parsed(candidate, transcript):
                let path = candidate.url.path
                cache[path] = CachedThread(
                    signature: candidate.signature,
                    summary: transcript.summary,
                    searchText: transcript.searchText)
                orderedCacheIsDirty = true
                failedSignatures[path] = nil
                detailCache[path] = nil
            case let .failed(candidate):
                let path = candidate.url.path
                if cache[path] != nil { orderedCacheIsDirty = true }
                cache[path] = nil
                failedSignatures[path] = candidate.signature
                detailCache[path] = nil
            case .cancelled:
                break
            }
        }

        return makeSnapshot(query: query, limit: limit, reparsedFileCount: changed.count)
    }

    public func search(query: String, limit: Int = 1_000) -> ChatHistorySnapshot {
        makeSnapshot(query: query, limit: limit, reparsedFileCount: 0)
    }

    public func detail(for id: String) async throws -> ChatThreadDetail? {
        guard let cached = cache[id] else { return nil }
        if let detail = detailCache[id], detail.signature == cached.signature {
            return detail.detail
        }
        let candidate = Candidate(
            url: cached.summary.source,
            archived: cached.summary.archived,
            signature: cached.signature)
        let transcript = try await Task.detached(priority: .userInitiated) {
            try TranscriptParser.parse(candidate, includeMessages: true)
        }.value
        try Task.checkCancellation()
        let detail = ChatThreadDetail(
            thread: transcript.summary,
            messages: transcript.messages,
            omittedMessageCount: max(0, transcript.summary.messageCount - transcript.messages.count))
        detailCache[id] = CachedDetail(signature: cached.signature, detail: detail)
        return detail
    }

    private func makeSnapshot(
        query: String,
        limit: Int,
        reparsedFileCount: Int
    ) -> ChatHistorySnapshot {
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased() }
        if orderedCacheIsDirty {
            orderedCache = cache.values.sorted {
                if $0.summary.updatedAt != $1.summary.updatedAt {
                    return $0.summary.updatedAt > $1.summary.updatedAt
                }
                return $0.summary.id < $1.summary.id
            }
            cachedUnreadableRecordCount = orderedCache.reduce(0) {
                $0 + $1.summary.unreadableRecordCount
            }
            orderedCacheIsDirty = false
        }
        let all = orderedCache
        let matches = terms.isEmpty ? all : all.filter { cached in
            terms.allSatisfy { cached.searchText.contains($0) }
        }
        let safeLimit = min(max(1, limit), 2_000)
        return ChatHistorySnapshot(
            threads: Array(matches.prefix(safeLimit)).map(\.summary),
            totalThreadCount: all.count,
            matchingThreadCount: matches.count,
            skippedFileCount: failedSignatures.count,
            unreadableRecordCount: cachedUnreadableRecordCount,
            reparsedFileCount: reparsedFileCount)
    }

    private func parseConcurrently(_ candidates: [Candidate]) async -> [WorkerResult] {
        guard !candidates.isEmpty else { return [] }
        return await withTaskGroup(of: WorkerResult.self, returning: [WorkerResult].self) { group in
            var nextIndex = 0
            var results: [WorkerResult] = []

            func addNext() {
                guard nextIndex < candidates.count else { return }
                let candidate = candidates[nextIndex]
                nextIndex += 1
                group.addTask(priority: .utility) {
                    guard !Task.isCancelled else { return .cancelled }
                    do {
                        return .parsed(
                            candidate,
                            try TranscriptParser.parse(candidate, includeMessages: false))
                    } catch is CancellationError {
                        return .cancelled
                    } catch {
                        return .failed(candidate)
                    }
                }
            }

            for _ in 0..<min(workerCount, candidates.count) { addNext() }
            while let result = await group.next() {
                results.append(result)
                if Task.isCancelled { group.cancelAll() }
                addNext()
            }
            return results
        }
    }

    private static func transcriptCandidates(in home: URL) throws -> [Candidate] {
        let fileManager = FileManager.default
        var candidates: [Candidate] = []
        var visited = 0
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .contentModificationDateKey, .fileSizeKey,
        ]
        for (directory, archived) in [("sessions", false), ("archived_sessions", true)] {
            let root = home.appending(path: directory, directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: root.path) else { continue }
            let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { continue }
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                visited += 1
                guard visited <= 500_000 else {
                    throw AIManagerError.invalidSource(
                        "History exceeds the 500,000-entry inspection limit.")
                }
                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isRegularFile == true, url.pathExtension.lowercased() == "jsonl" else {
                    continue
                }
                candidates.append(Candidate(
                    url: url.standardizedFileURL,
                    archived: archived,
                    signature: FileSignature(
                        byteCount: Int64(values.fileSize ?? 0),
                        modifiedAt: values.contentModificationDate ?? .distantPast)))
            }
        }
        return candidates.sorted { $0.url.path < $1.url.path }
    }
}

private struct ParsedTranscript: Sendable {
    let summary: ChatThreadSummary
    let searchText: String
    let messages: [ChatMessage]
}

private enum TranscriptParser {
    private struct RawMessage {
        let sequence: Int
        let role: ChatMessageRole
        let text: String
        let timestamp: Date?
    }

    private struct MessageStats {
        var count = 0
        var first: RawMessage?
        var last: RawMessage?

        mutating func record(_ message: RawMessage) {
            count += 1
            if first == nil { first = message }
            last = message
        }
    }

    static func parse(
        _ candidate: ChatHistoryIndex.Candidate,
        includeMessages: Bool
    ) throws -> ParsedTranscript {
        let reader = try JSONLReader(url: candidate.url)
        let fractionalDateParser: ISO8601DateFormatter?
        let wholeSecondDateParser: ISO8601DateFormatter?
        if includeMessages {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            fractionalDateParser = fractional
            let wholeSecond = ISO8601DateFormatter()
            wholeSecond.formatOptions = [.withInternetDateTime]
            wholeSecondDateParser = wholeSecond
        } else {
            fractionalDateParser = nil
            wholeSecondDateParser = nil
        }
        var threadID: String?
        var workingDirectory: String?
        var latestDate = candidate.signature.modifiedAt
        var responseUsers = MessageStats()
        var eventUsers = MessageStats()
        var assistants = MessageStats()
        var responseUserMessages: [RawMessage] = []
        var eventUserMessages: [RawMessage] = []
        var assistantMessages: [RawMessage] = []
        var remainingDetailCharacters = 2_000_000
        var unreadableRecords = 0
        var sequence = 0

        while let rawRecord = try reader.next() {
            sequence += 1
            if sequence.isMultiple(of: 64) { try Task.checkCancellation() }
            var record = rawRecord
            if sequence == 1, record.starts(with: [0xEF, 0xBB, 0xBF]) {
                record.removeFirst(3)
            }
            if record.count > 64 * 1_024, !mayContainVisibleMessage(record) { continue }
            guard record.count <= 4 * 1_024 * 1_024,
                  let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any]
            else {
                unreadableRecords += 1
                continue
            }
            let timestamp = parseDate(
                object["timestamp"], fractional: fractionalDateParser,
                wholeSecond: wholeSecondDateParser)
            if let timestamp, timestamp > latestDate { latestDate = timestamp }
            let type = object["type"] as? String

            if type == "session_meta", let payload = object["payload"] as? [String: Any] {
                threadID = nonempty(payload["id"] as? String)
                    ?? nonempty(payload["session_id"] as? String)
                    ?? threadID
                workingDirectory = nonempty(payload["cwd"] as? String) ?? workingDirectory
                continue
            }

            if threadID == nil, sequence == 1 {
                threadID = nonempty(object["id"] as? String)
            }

            if type == "event_msg", let payload = object["payload"] as? [String: Any],
               payload["type"] as? String == "user_message",
               let text = nonempty(payload["message"] as? String)
            {
                let message = RawMessage(
                    sequence: sequence, role: .user, text: text, timestamp: timestamp)
                eventUsers.record(message)
                append(
                    message, to: &eventUserMessages, remainingCharacters: &remainingDetailCharacters,
                    enabled: includeMessages)
                continue
            }

            let messageObject: [String: Any]?
            if type == "response_item" {
                messageObject = object["payload"] as? [String: Any]
            } else if type == "message" {
                messageObject = object
            } else {
                messageObject = nil
            }
            guard let messageObject,
                  messageObject["type"] as? String == "message" || type == "message",
                  let roleName = messageObject["role"] as? String,
                  let role = ChatMessageRole(rawValue: roleName),
                  let text = messageText(messageObject), !text.isEmpty
            else { continue }
            let message = RawMessage(
                sequence: sequence, role: role, text: text, timestamp: timestamp)
            switch role {
            case .user:
                responseUsers.record(message)
                append(
                    message, to: &responseUserMessages,
                    remainingCharacters: &remainingDetailCharacters, enabled: includeMessages)
            case .assistant:
                assistants.record(message)
                append(
                    message, to: &assistantMessages,
                    remainingCharacters: &remainingDetailCharacters, enabled: includeMessages)
            }
        }

        let users = eventUsers.count > 0 ? eventUsers : responseUsers
        let chosenUserMessages = eventUsers.count > 0 ? eventUserMessages : responseUserMessages
        let lastMessage = [users.last, assistants.last]
            .compactMap { $0 }
            .max { $0.sequence < $1.sequence }
        let resolvedThreadID = threadID ?? candidate.url.deletingPathExtension().lastPathComponent
        let title = compact(users.first?.text, maximumCharacters: 96) ?? "Untitled chat"
        let preview = compact(lastMessage?.text, maximumCharacters: 180)
            ?? compact(workingDirectory, maximumCharacters: 180)
            ?? resolvedThreadID
        let path = candidate.url.path
        let summary = ChatThreadSummary(
            id: path,
            threadID: resolvedThreadID,
            title: title,
            preview: preview,
            workingDirectory: workingDirectory,
            updatedAt: latestDate,
            archived: candidate.archived,
            messageCount: users.count + assistants.count,
            fileByteCount: candidate.signature.byteCount,
            source: candidate.url,
            unreadableRecordCount: unreadableRecords)
        let messages = (chosenUserMessages + assistantMessages)
            .sorted { $0.sequence < $1.sequence }
            .map {
                ChatMessage(
                    id: "\(path)#\($0.sequence)", role: $0.role,
                    text: $0.text, timestamp: $0.timestamp)
            }
        let searchText = [title, preview, workingDirectory, resolvedThreadID]
            .compactMap { $0 }
            .joined(separator: "\n")
            .lowercased()
        return ParsedTranscript(summary: summary, searchText: searchText, messages: messages)
    }

    private static func append(
        _ message: RawMessage,
        to messages: inout [RawMessage],
        remainingCharacters: inout Int,
        enabled: Bool
    ) {
        guard enabled, messages.count < 2_000, remainingCharacters > 0 else { return }
        let text = String(message.text.prefix(min(32_000, remainingCharacters)))
        remainingCharacters -= text.count
        messages.append(RawMessage(
            sequence: message.sequence, role: message.role, text: text,
            timestamp: message.timestamp))
    }

    private static func messageText(_ object: [String: Any]) -> String? {
        if let text = nonempty(object["content"] as? String) { return text }
        guard let content = object["content"] as? [[String: Any]] else { return nil }
        let pieces = content.compactMap { item -> String? in
            guard let type = item["type"] as? String,
                  type == "input_text" || type == "output_text" || type == "text"
            else { return nil }
            return nonempty(item["text"] as? String)
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
    }

    private static func parseDate(
        _ value: Any?,
        fractional: ISO8601DateFormatter?,
        wholeSecond: ISO8601DateFormatter?
    ) -> Date? {
        guard let value = value as? String else { return nil }
        return fractional?.date(from: value) ?? wholeSecond?.date(from: value)
    }

    private static func mayContainVisibleMessage(_ record: Data) -> Bool {
        let markers = [
            Data(#""type":"session_meta""#.utf8),
            Data(#""type":"user_message""#.utf8),
            Data(#""role":"user""#.utf8),
            Data(#""role":"assistant""#.utf8),
        ]
        return markers.contains { record.range(of: $0) != nil }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func compact(_ value: String?, maximumCharacters: Int) -> String? {
        guard let value = nonempty(value) else { return nil }
        let compacted = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !compacted.isEmpty else { return nil }
        if compacted.count <= maximumCharacters { return compacted }
        return String(compacted.prefix(maximumCharacters - 1)) + "…"
    }
}
