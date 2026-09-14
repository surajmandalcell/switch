import Foundation

public enum ChatMessageRole: String, Sendable, Equatable {
    case user
    case assistant
    case tool
    case other

    public var displayName: String {
        switch self {
        case .user: "Prompt"
        case .assistant: "Response"
        case .tool: "Tool"
        case .other: "Other"
        }
    }
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

public struct ChatMessageFilter: OptionSet, Sendable, Equatable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let prompts = ChatMessageFilter(rawValue: 1 << 0)
    public static let responses = ChatMessageFilter(rawValue: 1 << 1)
    public static let tools = ChatMessageFilter(rawValue: 1 << 2)
    public static let other = ChatMessageFilter(rawValue: 1 << 3)
    public static let all: ChatMessageFilter = [.prompts, .responses, .tools, .other]

    public func includes(_ role: ChatMessageRole) -> Bool {
        switch role {
        case .user: contains(.prompts)
        case .assistant: contains(.responses)
        case .tool: contains(.tools)
        case .other: contains(.other)
        }
    }
}

public enum ChatTranscriptExport {
    public static func text(for messages: [ChatMessage]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return messages.map { message in
            let timestamp = message.timestamp.map(formatter.string(from:)) ?? "Unknown time"
            return "[\(message.role.displayName) | \(timestamp)]\n\(message.text)"
        }.joined(separator: "\n\n")
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

public struct ChatMessageSearchResult: Sendable, Equatable {
    public let messages: [ChatMessage]
    public let totalMessageCount: Int
    public let matchingMessageCount: Int

    public init(messages: [ChatMessage], totalMessageCount: Int, matchingMessageCount: Int) {
        self.messages = messages
        self.totalMessageCount = totalMessageCount
        self.matchingMessageCount = matchingMessageCount
    }
}

public enum ChatMessageSearch {
    public static func search(
        _ messages: [ChatMessage], query: String, filter: ChatMessageFilter = .all
    ) async throws -> ChatMessageSearchResult {
        let selected = messages.filter { filter.includes($0.role) }
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }
        guard !terms.isEmpty else {
            return ChatMessageSearchResult(
                messages: selected,
                totalMessageCount: selected.count,
                matchingMessageCount: selected.count)
        }
        let task = Task.detached(priority: .userInitiated) {
            var matches: [ChatMessage] = []
            matches.reserveCapacity(min(selected.count, 128))
            for (index, message) in selected.enumerated() {
                if index.isMultiple(of: 32) { try Task.checkCancellation() }
                let text = message.text.lowercased()
                if terms.allSatisfy(text.contains) { matches.append(message) }
            }
            return ChatMessageSearchResult(
                messages: matches,
                totalMessageCount: selected.count,
                matchingMessageCount: matches.count)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

public struct ChatHistorySnapshot: Sendable, Equatable {
    public let threads: [ChatThreadSummary]
    public let libraryRevision: UInt64
    public let totalThreadCount: Int
    public let matchingThreadCount: Int
    public let skippedFileCount: Int
    public let unreadableRecordCount: Int
    public let reparsedFileCount: Int

    public init(
        threads: [ChatThreadSummary] = [],
        libraryRevision: UInt64 = 0,
        totalThreadCount: Int = 0,
        matchingThreadCount: Int = 0,
        skippedFileCount: Int = 0,
        unreadableRecordCount: Int = 0,
        reparsedFileCount: Int = 0
    ) {
        self.threads = threads
        self.libraryRevision = libraryRevision
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

    private struct ThreadMetadataIndex: Sendable {
        let byPath: [String: SQLiteThreadMetadata]
        let byThreadID: [String: SQLiteThreadMetadata]

        static let empty = ThreadMetadataIndex(byPath: [:], byThreadID: [:])
    }

    private enum WorkerResult: Sendable {
        case parsed(Candidate, ParsedTranscript)
        case failed(Candidate)
        case cancelled
    }

    private struct PersistentDocument: Codable {
        let version: Int
        let homePath: String
        let threads: [PersistentThread]
        let failures: [PersistentFailure]
    }

    private struct PersistentThread: Codable {
        let path: String
        let byteCount: Int64
        let modifiedAt: Date
        let threadID: String
        let title: String
        let preview: String
        let workingDirectory: String?
        let updatedAt: Date
        let archived: Bool
        let messageCount: Int
        let fileByteCount: Int64
        let unreadableRecordCount: Int
        let searchText: String
    }

    private struct PersistentFailure: Codable {
        let path: String
        let byteCount: Int64
        let modifiedAt: Date
    }

    private let home: URL
    private let persistentCacheFile: URL?
    private let workerCount: Int
    private var cache: [String: CachedThread] = [:]
    private var failedSignatures: [String: FileSignature] = [:]
    private var detailCache: [String: CachedDetail] = [:]
    private var orderedCache: [CachedThread] = []
    private var cachedUnreadableRecordCount = 0
    private var orderedCacheIsDirty = true
    private var libraryRevision: UInt64 = 0
    private var loadedPersistentCache = false
    private var persistentCacheNeedsMigration = false

    public init(home: URL, cacheFile: URL? = nil, maximumWorkerCount: Int? = nil) {
        self.home = CoreSupport.home(for: home).standardizedFileURL
        persistentCacheFile = cacheFile?.standardizedFileURL
        let requested = maximumWorkerCount
            ?? max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        workerCount = min(max(1, requested), 6)
    }

    public func refresh(query: String = "", limit: Int = 1_000) async throws -> ChatHistorySnapshot {
        try Task.checkCancellation()
        loadPersistentCacheIfNeeded()
        let metadataTask = Task.detached(priority: .utility) { [home] in
            Self.threadMetadata(in: home)
        }
        let candidates = try Self.transcriptCandidates(in: home)
        let currentPaths = Set(candidates.map { $0.url.path })
        let removedCachedFile = cache.keys.contains(where: { !currentPaths.contains($0) })
        let removedFailedFile = failedSignatures.keys.contains(where: { !currentPaths.contains($0) })
        if removedCachedFile {
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
        var libraryChanged = removedCachedFile || removedFailedFile || !changed.isEmpty
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

        let metadata = await metadataTask.value
        if apply(metadata: metadata) { libraryChanged = true }
        if persistentCacheNeedsMigration { libraryChanged = true }

        if libraryChanged {
            libraryRevision &+= 1
            persistCache()
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
        let parsingTask = Task.detached(priority: .userInitiated) {
            try TranscriptParser.parse(candidate, includeMessages: true)
        }
        let transcript = try await withTaskCancellationHandler {
            try await parsingTask.value
        } onCancel: {
            parsingTask.cancel()
        }
        try Task.checkCancellation()
        let detail = ChatThreadDetail(
            thread: cached.summary,
            messages: transcript.messages,
            omittedMessageCount: max(0, cached.summary.messageCount - transcript.messages.count))
        detailCache[id] = CachedDetail(signature: cached.signature, detail: detail)
        return detail
    }

    public func clearCache() throws {
        cache.removeAll(keepingCapacity: false)
        failedSignatures.removeAll(keepingCapacity: false)
        detailCache.removeAll(keepingCapacity: false)
        orderedCache.removeAll(keepingCapacity: false)
        cachedUnreadableRecordCount = 0
        orderedCacheIsDirty = false
        loadedPersistentCache = true
        persistentCacheNeedsMigration = false
        libraryRevision &+= 1

        guard let persistentCacheFile,
              FileManager.default.fileExists(atPath: persistentCacheFile.path)
        else { return }
        let values = try persistentCacheFile.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw AIManagerError.unsafePath(
                "conversation index is not a regular file: \(persistentCacheFile.path)")
        }
        try FileManager.default.removeItem(at: persistentCacheFile)
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
            libraryRevision: libraryRevision,
            totalThreadCount: all.count,
            matchingThreadCount: matches.count,
            skippedFileCount: failedSignatures.count,
            unreadableRecordCount: cachedUnreadableRecordCount,
            reparsedFileCount: reparsedFileCount)
    }

    private func loadPersistentCacheIfNeeded() {
        guard !loadedPersistentCache else { return }
        loadedPersistentCache = true
        guard let persistentCacheFile,
              let values = try? persistentCacheFile.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize <= 32 * 1_024 * 1_024,
              let permissions = try? FileManager.default.attributesOfItem(
                atPath: persistentCacheFile.path)[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0,
              let data = try? Data(contentsOf: persistentCacheFile),
              let document = try? JSONDecoder().decode(PersistentDocument.self, from: data),
              document.version == 3,
              document.homePath == home.path,
              document.threads.count + document.failures.count <= 500_000
        else { return }

        persistentCacheNeedsMigration = false

        for item in document.threads where validPersistentPath(item.path) {
            guard item.path.count <= 4_096,
                  item.threadID.count <= 1_024,
                  item.title.count <= 1_024,
                  item.preview.count <= 4_096,
                  (item.workingDirectory?.count ?? 0) <= 4_096,
                  item.searchText.count <= 16_384,
                  item.byteCount >= 0,
                  item.fileByteCount >= 0,
                  item.messageCount >= 0,
                  item.unreadableRecordCount >= 0
            else { continue }
            let signature = FileSignature(byteCount: item.byteCount, modifiedAt: item.modifiedAt)
            let summary = ChatThreadSummary(
                id: item.path,
                threadID: item.threadID,
                title: item.title,
                preview: item.preview,
                workingDirectory: item.workingDirectory,
                updatedAt: item.updatedAt,
                archived: item.archived,
                messageCount: item.messageCount,
                fileByteCount: item.fileByteCount,
                source: URL(fileURLWithPath: item.path),
                unreadableRecordCount: item.unreadableRecordCount)
            cache[item.path] = CachedThread(
                signature: signature, summary: summary, searchText: item.searchText)
        }
        for item in document.failures where validPersistentPath(item.path) {
            guard item.path.count <= 4_096, item.byteCount >= 0 else { continue }
            failedSignatures[item.path] = FileSignature(
                byteCount: item.byteCount, modifiedAt: item.modifiedAt)
        }
        if !cache.isEmpty || !failedSignatures.isEmpty {
            orderedCacheIsDirty = true
            libraryRevision = 1
        }
    }

    private func persistCache() {
        guard let persistentCacheFile else { return }
        let threads = cache.keys.sorted().compactMap { path -> PersistentThread? in
            guard let cached = cache[path] else { return nil }
            let summary = cached.summary
            return PersistentThread(
                path: path,
                byteCount: cached.signature.byteCount,
                modifiedAt: cached.signature.modifiedAt,
                threadID: summary.threadID,
                title: summary.title,
                preview: summary.preview,
                workingDirectory: summary.workingDirectory,
                updatedAt: summary.updatedAt,
                archived: summary.archived,
                messageCount: summary.messageCount,
                fileByteCount: summary.fileByteCount,
                unreadableRecordCount: summary.unreadableRecordCount,
                searchText: cached.searchText)
        }
        let failures = failedSignatures.keys.sorted().compactMap { path -> PersistentFailure? in
            guard let signature = failedSignatures[path] else { return nil }
            return PersistentFailure(
                path: path,
                byteCount: signature.byteCount,
                modifiedAt: signature.modifiedAt)
        }
        let document = PersistentDocument(
            version: 3, homePath: home.path, threads: threads, failures: failures)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(document) else { return }
        if (try? CoreSupport.atomicWrite(
            data, to: persistentCacheFile, permissions: 0o600, fileManager: .default)) != nil {
            persistentCacheNeedsMigration = false
        }
    }

    private func apply(metadata index: ThreadMetadataIndex) -> Bool {
        var changed = false
        for path in cache.keys.sorted() {
            guard let cached = cache[path] else { continue }
            let current = cached.summary
            let metadata = index.byPath[path] ?? index.byThreadID[current.threadID]
            let workingDirectory = ChatTitlePolicy.nonempty(metadata?.workingDirectory)
                ?? current.workingDirectory
            let title = ChatTitlePolicy.resolvedTitle(
                explicitName: metadata?.name,
                databaseTitle: metadata?.title,
                transcriptTitle: current.title,
                workingDirectory: workingDirectory)
            let preview = ChatTitlePolicy.meaningfulCompact(metadata?.preview, maximumCharacters: 180)
                ?? ChatTitlePolicy.meaningfulCompact(current.preview, maximumCharacters: 180)
                ?? ChatTitlePolicy.projectLabel(workingDirectory: workingDirectory)
            let summary = ChatThreadSummary(
                id: current.id,
                threadID: metadata?.threadID ?? current.threadID,
                title: title,
                preview: preview,
                workingDirectory: workingDirectory,
                updatedAt: metadata?.updatedAt ?? current.updatedAt,
                archived: metadata?.archived ?? current.archived,
                messageCount: current.messageCount,
                fileByteCount: current.fileByteCount,
                source: current.source,
                unreadableRecordCount: current.unreadableRecordCount)
            let searchText = Self.searchText(for: summary)
            guard summary != current || searchText != cached.searchText else { continue }
            cache[path] = CachedThread(
                signature: cached.signature, summary: summary, searchText: searchText)
            if let detail = detailCache[path] {
                detailCache[path] = CachedDetail(
                    signature: detail.signature,
                    detail: ChatThreadDetail(
                        thread: summary,
                        messages: detail.detail.messages,
                        omittedMessageCount: detail.detail.omittedMessageCount))
            }
            orderedCacheIsDirty = true
            changed = true
        }
        return changed
    }

    private static func searchText(for summary: ChatThreadSummary) -> String {
        [summary.title, summary.preview, summary.workingDirectory, summary.threadID]
            .compactMap { $0 }
            .joined(separator: "\n")
            .lowercased()
    }

    private static func threadMetadata(in home: URL) -> ThreadMetadataIndex {
        let database = home.appending(path: "state_5.sqlite")
        guard let values = try? database.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let rows = try? SQLiteSupport.readThreadMetadata(database: database)
        else { return .empty }
        var byPath: [String: SQLiteThreadMetadata] = [:]
        var byThreadID: [String: SQLiteThreadMetadata] = [:]
        for row in rows {
            let path: String
            if let url = URL(string: row.rolloutPath), url.isFileURL {
                path = url.standardizedFileURL.path
            } else {
                path = URL(fileURLWithPath: row.rolloutPath).standardizedFileURL.path
            }
            byPath[path] = row
            byThreadID[row.threadID] = row
        }
        return ThreadMetadataIndex(byPath: byPath, byThreadID: byThreadID)
    }

    private func validPersistentPath(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized == path else { return false }
        return ["sessions", "archived_sessions"].contains { directory in
            standardized.hasPrefix(home.appending(path: directory, directoryHint: .isDirectory).path + "/")
        }
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
        var meaningfulCount = 0
        var firstMeaningful: RawMessage?
        var lastMeaningful: RawMessage?

        mutating func record(_ message: RawMessage) {
            count += 1
            if first == nil { first = message }
            last = message
            if !ChatTitlePolicy.isBootstrapContext(message.text) {
                meaningfulCount += 1
                if firstMeaningful == nil { firstMeaningful = message }
                lastMeaningful = message
            }
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
        var tools = MessageStats()
        var others = MessageStats()
        var responseUserMessages: [RawMessage] = []
        var eventUserMessages: [RawMessage] = []
        var assistantMessages: [RawMessage] = []
        var toolMessages: [RawMessage] = []
        var otherMessages: [RawMessage] = []
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
            guard record.count <= 4 * 1_024 * 1_024 else { continue }
            if record.count > 64 * 1_024, !mayContainVisibleMessage(record) { continue }
            guard let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any]
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
            guard let messageObject else { continue }
            let itemType = messageObject["type"] as? String ?? type
            if itemType == "message" || type == "message" {
                guard let roleName = messageObject["role"] as? String,
                      let role = ChatMessageRole(rawValue: roleName),
                      role == .user || role == .assistant,
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
                case .tool, .other:
                    break
                }
                continue
            }
            if let text = toolText(messageObject, type: itemType) {
                let message = RawMessage(
                    sequence: sequence, role: .tool, text: text, timestamp: timestamp)
                tools.record(message)
                append(
                    message, to: &toolMessages,
                    remainingCharacters: &remainingDetailCharacters, enabled: includeMessages)
                continue
            }
            if itemType == "reasoning", let text = reasoningSummary(messageObject) {
                let message = RawMessage(
                    sequence: sequence, role: .other, text: text, timestamp: timestamp)
                others.record(message)
                append(
                    message, to: &otherMessages,
                    remainingCharacters: &remainingDetailCharacters, enabled: includeMessages)
            }
        }

        let users = eventUsers.count > 0 ? eventUsers : responseUsers
        let chosenUserMessages = (eventUsers.count > 0 ? eventUserMessages : responseUserMessages)
            .filter { !ChatTitlePolicy.isBootstrapContext($0.text) }
        let lastMessage = [users.lastMeaningful, assistants.last]
            .compactMap { $0 }
            .max { $0.sequence < $1.sequence }
        let resolvedThreadID = threadID ?? candidate.url.deletingPathExtension().lastPathComponent
        let title = ChatTitlePolicy.resolvedTitle(
            explicitName: nil,
            databaseTitle: nil,
            transcriptTitle: users.firstMeaningful?.text,
            workingDirectory: workingDirectory)
        let preview = ChatTitlePolicy.meaningfulCompact(
            lastMessage?.text, maximumCharacters: 180)
            ?? ChatTitlePolicy.projectLabel(workingDirectory: workingDirectory)
        let path = candidate.url.path
        let summary = ChatThreadSummary(
            id: path,
            threadID: resolvedThreadID,
            title: title,
            preview: preview,
            workingDirectory: workingDirectory,
            updatedAt: latestDate,
            archived: candidate.archived,
            messageCount: users.meaningfulCount + assistants.count + tools.count + others.count,
            fileByteCount: candidate.signature.byteCount,
            source: candidate.url,
            unreadableRecordCount: unreadableRecords)
        let messages = (chosenUserMessages + assistantMessages + toolMessages + otherMessages)
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

    private static func toolText(_ object: [String: Any], type: String?) -> String? {
        let title: String
        let body: String?
        switch type {
        case "function_call":
            title = nonempty(object["name"] as? String) ?? "Function call"
            body = nonempty(object["arguments"] as? String)
        case "custom_tool_call":
            title = nonempty(object["name"] as? String) ?? "Tool call"
            body = nonempty(object["input"] as? String)
        case "function_call_output", "custom_tool_call_output":
            title = "Tool result"
            body = nonempty(object["output"] as? String)
        case "local_shell_call":
            title = "Shell command"
            guard let action = object["action"] as? [String: Any] else { return title }
            if let command = nonempty(action["command"] as? String) {
                body = command
            } else if let command = action["command"] as? [String] {
                body = nonempty(command.joined(separator: " "))
            } else {
                body = nil
            }
        case "web_search_call":
            title = "Web search"
            if let action = object["action"] as? [String: Any] {
                body = nonempty(action["query"] as? String)
                    ?? nonempty(action["url"] as? String)
            } else {
                body = nonempty(object["query"] as? String)
            }
        default:
            return nil
        }
        return body.map { "\(title)\n\($0)" } ?? title
    }

    private static func reasoningSummary(_ object: [String: Any]) -> String? {
        guard let summary = object["summary"] as? [[String: Any]] else { return nil }
        let pieces = summary.compactMap { item -> String? in
            guard let type = item["type"] as? String,
                  type == "summary_text" || type == "text"
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
            Data(#""function_call""#.utf8),
            Data(#""custom_tool_call""#.utf8),
            Data(#""local_shell_call""#.utf8),
            Data(#""web_search_call""#.utf8),
            Data(#""reasoning""#.utf8),
        ]
        return markers.contains { record.range(of: $0) != nil }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

}

private enum ChatTitlePolicy {
    static func resolvedTitle(
        explicitName: String?,
        databaseTitle: String?,
        transcriptTitle: String?,
        workingDirectory: String?
    ) -> String {
        if let explicitName = compact(explicitName, maximumCharacters: 96) {
            return explicitName
        }
        return meaningfulCompact(databaseTitle, maximumCharacters: 96)
            ?? meaningfulCompact(transcriptTitle, maximumCharacters: 96)
            ?? projectLabel(workingDirectory: workingDirectory)
    }

    static func meaningfulCompact(_ value: String?, maximumCharacters: Int) -> String? {
        guard let value = nonempty(value), !isBootstrapContext(value) else { return nil }
        return compact(value, maximumCharacters: maximumCharacters)
    }

    static func projectLabel(workingDirectory: String?) -> String {
        guard let workingDirectory = nonempty(workingDirectory) else { return "Untitled chat" }
        let project = URL(fileURLWithPath: workingDirectory).lastPathComponent
        guard !project.isEmpty, project != "/" else { return "Untitled chat" }
        return "Conversation in \(project)"
    }

    static func isBootstrapContext(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefixes = [
            "# agents.md instructions for ",
            "<instructions>",
            "# global codex instructions",
            "<environment_context>",
            "<skills_instructions>",
            "<permissions instructions>",
        ]
        if prefixes.contains(where: normalized.hasPrefix) { return true }
        return normalized.hasPrefix("you are codex")
            && normalized.contains("system, developer, and direct user instructions")
    }

    static func nonempty(_ value: String?) -> String? {
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
