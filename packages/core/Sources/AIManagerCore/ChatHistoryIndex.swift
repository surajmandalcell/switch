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
    public let totalTokens: Int64?

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
        unreadableRecordCount: Int,
        totalTokens: Int64? = nil
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
        self.totalTokens = totalTokens
    }
}

public struct ChatThreadDetail: Sendable, Equatable {
    public let thread: ChatThreadSummary
    public let messages: [ChatMessage]
    public let omittedMessageCount: Int
    public let matchingMessageCount: Int
    public let nextOffset: Int?

    public init(
        thread: ChatThreadSummary,
        messages: [ChatMessage],
        omittedMessageCount: Int,
        matchingMessageCount: Int? = nil,
        nextOffset: Int? = nil
    ) {
        self.thread = thread
        self.messages = messages
        self.omittedMessageCount = omittedMessageCount
        self.matchingMessageCount = matchingMessageCount ?? messages.count
        self.nextOffset = nextOffset
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
        var activityRecorded = false
    }

    private struct CachedDetail: Sendable {
        let signature: FileSignature
        let references: [ChatMessageReference]
        var matchKey = ""
        var matches: [ChatMessageReference] = []
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
        let totalTokens: Int64?
        let searchText: String
        let activityRecorded: Bool?
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
    private var activityCache: CodexUsageStatisticsCache?
    private var refreshTask: Task<Int, Error>?
    private var isClearingCache = false
    private var refreshGeneration = 0

    public init(home: URL, cacheFile: URL? = nil, maximumWorkerCount: Int? = nil) {
        self.home = CoreSupport.home(for: home).standardizedFileURL
        persistentCacheFile = cacheFile?.standardizedFileURL
        let requested = maximumWorkerCount
            ?? max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        workerCount = min(max(1, requested), 6)
    }

    public func attachActivityCache(_ cache: CodexUsageStatisticsCache) {
        activityCache = cache
    }

    public func refresh(query: String = "", limit: Int = 1_000) async throws -> ChatHistorySnapshot {
        try Task.checkCancellation()
        guard !isClearingCache else { throw CancellationError() }
        let reparsedFileCount: Int
        if let refreshTask {
            reparsedFileCount = try await refreshTask.value
        } else {
            refreshGeneration += 1
            let generation = refreshGeneration
            let task = Task(priority: .utility) { try await self.scan() }
            refreshTask = task
            defer { if generation == refreshGeneration { refreshTask = nil } }
            reparsedFileCount = try await task.value
        }
        try Task.checkCancellation()
        return makeSnapshot(query: query, limit: limit, reparsedFileCount: reparsedFileCount)
    }

    private func scan() async throws -> Int {
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
            return (cache[path]?.signature != candidate.signature
                    || (activityCache != nil && cache[path]?.activityRecorded != true))
                && failedSignatures[path] != candidate.signature
        }
        var libraryChanged = removedCachedFile || removedFailedFile || !changed.isEmpty
        let parsed = await parseConcurrently(changed)
        try Task.checkCancellation()

        for result in parsed {
            switch result {
            case let .parsed(candidate, transcript):
                let path = candidate.url.path
                if let activityCache {
                    let fallback = CoreSupport.digest(Data(
                        (home.path + "\u{0}" + candidate.url.lastPathComponent).utf8))
                    try await activityCache.recordTranscriptActivity(transcript.activity, fallbackID: fallback)
                }
                cache[path] = CachedThread(
                    signature: candidate.signature,
                    summary: transcript.summary,
                    searchText: transcript.searchText,
                    activityRecorded: activityCache != nil)
                orderedCacheIsDirty = true
                failedSignatures[path] = nil
                detailCache[path] = nil
            case let .failed(candidate):
                let path = candidate.url.path
                if let activityCache, let previous = cache[path] {
                    try await activityCache.recordTranscriptActivity(.init(
                        threadID: previous.summary.threadID, project: previous.summary.workingDirectory,
                        firstEvent: "", eventCount: 0, totalTokens: 0, days: [:], complete: false),
                        fallbackID: "")
                }
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

        return changed.count
    }

    public func search(query: String, limit: Int = 1_000) -> ChatHistorySnapshot {
        makeSnapshot(query: query, limit: limit, reparsedFileCount: 0)
    }

    public func detail(
        for id: String, offset: Int = 0, limit: Int = 100,
        query: String = "", filter: ChatMessageFilter = .all
    ) async throws -> ChatThreadDetail? {
        guard let cached = cache[id] else { return nil }
        let candidate = Candidate(
            url: cached.summary.source,
            archived: cached.summary.archived,
            signature: cached.signature)
        let previous = detailCache[id]
        let terms = query.split(whereSeparator: \.isWhitespace).map { String($0).lowercased() }
        let matchKey = "\(filter.rawValue):\(terms.joined(separator: "\u{0}"))"
        let safeOffset = max(0, offset)
        let safeLimit = min(max(1, limit), 200)
        let parsingTask = Task.detached(priority: .userInitiated) {
            var indexed: CachedDetail
            if let previous, previous.signature == candidate.signature {
                indexed = previous
            } else {
                indexed = CachedDetail(signature: candidate.signature,
                    references: try TranscriptParser.parse(candidate, includeMessages: true).references)
            }
            let handle = try FileHandle(forReadingFrom: candidate.url)
            defer { try? handle.close() }
            if indexed.matchKey != matchKey {
                indexed.matches = []
                for reference in indexed.references where filter.includes(reference.role) {
                    try Task.checkCancellation()
                    if terms.isEmpty {
                        indexed.matches.append(reference)
                    } else if let message = try TranscriptParser.message(reference, handle: handle, path: id),
                              terms.allSatisfy(message.text.lowercased().contains) {
                        indexed.matches.append(reference)
                    }
                }
                indexed.matchKey = matchKey
            }
            var messages: [ChatMessage] = []
            var characters = 0
            for reference in indexed.matches.dropFirst(safeOffset).prefix(safeLimit) {
                try Task.checkCancellation()
                guard let message = try TranscriptParser.message(reference, handle: handle, path: id) else {
                    throw AIManagerError.invalidSource("The conversation changed. Refresh and try again.")
                }
                messages.append(message)
                characters += message.text.utf8.count
                if characters >= 2_000_000 { break }
            }
            let current = try candidate.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard Int64(current.fileSize ?? -1) == candidate.signature.byteCount,
                  current.contentModificationDate == candidate.signature.modifiedAt else {
                throw AIManagerError.invalidSource("The conversation changed. Refresh and try again.")
            }
            return (indexed, messages)
        }
        let (indexed, messages) = try await withTaskCancellationHandler {
            try await parsingTask.value
        } onCancel: {
            parsingTask.cancel()
        }
        try Task.checkCancellation()
        guard cache[id]?.signature == cached.signature else { throw CancellationError() }
        if detailCache.count >= 4, detailCache[id] == nil { detailCache.removeAll() }
        detailCache[id] = indexed
        let next = safeOffset + messages.count
        return ChatThreadDetail(thread: cached.summary, messages: messages, omittedMessageCount: 0,
            matchingMessageCount: indexed.matches.count,
            nextOffset: next < indexed.matches.count ? next : nil)
    }

    public func cleanupSummaries() -> [ChatThreadSummary] {
        cache.values.map(\.summary)
    }

    public func preserveActivity(for sources: [URL]) async throws {
        guard let activityCache else { throw AIManagerError.operationFailed("The activity ledger is unavailable. Conversations were kept.") }
        let candidates = try Self.transcriptCandidates(in: home)
        let byPath = Dictionary(uniqueKeysWithValues: candidates.map { (CoreSupport.canonical($0.url).path, $0) })
        for source in sources {
            guard let candidate = byPath[CoreSupport.canonical(source).path] else { throw AIManagerError.sourceChanged }
            let task = Task.detached(priority: .utility) { try TranscriptParser.parse(candidate, includeMessages: false) }
            let parsed = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard parsed.activity.complete else {
                throw AIManagerError.invalidSource("Activity could not be fully preserved for \(source.lastPathComponent). The conversations were kept.")
            }
            let fallback = CoreSupport.digest(Data((home.path + "\u{0}" + source.lastPathComponent).utf8))
            try await activityCache.recordTranscriptActivity(parsed.activity, fallbackID: fallback)
        }
    }

    public func clearCache() async throws {
        guard !isClearingCache else { throw AIManagerError.operationFailed("The conversation index is already being cleared.") }
        isClearingCache = true
        defer { isClearingCache = false }
        refreshGeneration += 1
        if let task = refreshTask {
            task.cancel()
            _ = try? await task.value
        }
        refreshTask = nil
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
              document.version == 4,
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
                unreadableRecordCount: item.unreadableRecordCount,
                totalTokens: item.totalTokens)
            cache[item.path] = CachedThread(
                signature: signature, summary: summary, searchText: item.searchText,
                activityRecorded: item.activityRecorded ?? false)
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
                totalTokens: summary.totalTokens,
                searchText: cached.searchText, activityRecorded: cached.activityRecorded)
        }
        let failures = failedSignatures.keys.sorted().compactMap { path -> PersistentFailure? in
            guard let signature = failedSignatures[path] else { return nil }
            return PersistentFailure(
                path: path,
                byteCount: signature.byteCount,
                modifiedAt: signature.modifiedAt)
        }
        let document = PersistentDocument(
            version: 4, homePath: home.path, threads: threads, failures: failures)
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
                unreadableRecordCount: current.unreadableRecordCount,
                totalTokens: current.totalTokens)
            let searchText = Self.searchText(for: summary)
            guard summary != current || searchText != cached.searchText else { continue }
            cache[path] = CachedThread(
                signature: cached.signature, summary: summary, searchText: searchText,
                activityRecorded: cached.activityRecorded)
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

private struct ChatMessageReference: Sendable {
    let sequence: Int
    let offset: UInt64
    let byteCount: Int
    let role: ChatMessageRole
    let timestamp: Date?
}

private struct ParsedTranscript: Sendable {
    let summary: ChatThreadSummary
    let searchText: String
    let references: [ChatMessageReference]
    let activity: CodexTranscriptActivity
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
        var references: [ChatMessageReference] = []

        mutating func record(_ message: RawMessage, offset: UInt64, byteCount: Int, indexed: Bool) {
            count += 1
            if first == nil { first = message }
            last = message
            if !ChatTitlePolicy.isBootstrapContext(message.text) {
                meaningfulCount += 1
                if firstMeaningful == nil { firstMeaningful = message }
                lastMeaningful = message
            }
            if indexed, message.role != .user || !ChatTitlePolicy.isBootstrapContext(message.text) {
                references.append(ChatMessageReference(sequence: message.sequence, offset: offset,
                    byteCount: byteCount, role: message.role, timestamp: message.timestamp))
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
        do {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            fractionalDateParser = fractional
            let wholeSecond = ISO8601DateFormatter()
            wholeSecond.formatOptions = [.withInternetDateTime]
            wholeSecondDateParser = wholeSecond
        }
        let dayParser = ISO8601DateFormatter()
        dayParser.formatOptions = [.withFullDate]
        dayParser.timeZone = TimeZone(secondsFromGMT: 0)
        var activityDays: [String: Int64] = [:]
        var previousTokens: Int64 = 0
        var activityEventCount = 0
        var firstActivityEvent = ""
        var activityComplete = true
        var inheritedHistory = false
        var hasSessionMetadata = false
        var threadID: String?
        var workingDirectory: String?
        var latestDate = candidate.signature.modifiedAt
        var responseUsers = MessageStats()
        var eventUsers = MessageStats()
        var assistants = MessageStats()
        var tools = MessageStats()
        var others = MessageStats()
        var unreadableRecords = 0
        var sequence = 0

        while let rawRecord = try reader.next() {
            sequence += 1
            if sequence.isMultiple(of: 64) { try Task.checkCancellation() }
            var record = rawRecord
            if sequence == 1, record.starts(with: [0xEF, 0xBB, 0xBF]) {
                record.removeFirst(3)
            }
            guard record.count <= 64 * 1_024 * 1_024 else {
                activityComplete = false
                continue
            }
            if record.count > 64 * 1_024, !mayContainVisibleMessage(record) { continue }
            guard let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any]
            else {
                unreadableRecords += 1
                continue
            }
            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any]
            let tokenEvent = type == "event_msg" && payload?["type"] as? String == "token_count"
            let timestamp = includeMessages || tokenEvent ? parseDate(
                object["timestamp"], fractional: fractionalDateParser,
                wholeSecond: wholeSecondDateParser) : nil
            if let timestamp, timestamp > latestDate { latestDate = timestamp }
            if type == "session_meta", let payload = object["payload"] as? [String: Any] {
                guard !hasSessionMetadata else { continue }
                hasSessionMetadata = true
                threadID = nonempty(payload["id"] as? String)
                    ?? nonempty(payload["session_id"] as? String)
                    ?? threadID
                workingDirectory = nonempty(payload["cwd"] as? String) ?? workingDirectory
                inheritedHistory = payload["forked_from_id"] is String
                    || payload["history_base"] is [String: Any]
                    || payload["subagent_history_start_ordinal"] is NSNumber
                continue
            }

            if tokenEvent {
                guard let info = payload?["info"] as? [String: Any] else { continue }
                guard let usage = info["total_token_usage"] as? [String: Any],
                      let number = usage["total_tokens"] as? NSNumber,
                      String(cString: number.objCType) != "c",
                      let total = Int64(number.stringValue), total >= 0 else {
                    activityComplete = false
                    continue
                }
                activityEventCount += 1
                if firstActivityEvent.isEmpty {
                    firstActivityEvent = "\(object["timestamp"] as? String ?? ""):\(total)"
                }
                guard !inheritedHistory, total >= previousTokens else {
                    activityComplete = false
                    continue
                }
                let delta = total - previousTokens
                previousTokens = total
                guard let timestamp else { activityComplete = false; continue }
                guard activityComplete else { continue }
                let day = dayParser.string(from: timestamp)
                let (sum, overflow) = activityDays[day, default: 0].addingReportingOverflow(delta)
                if overflow { activityComplete = false } else { activityDays[day] = sum }
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
                eventUsers.record(message, offset: reader.lastRecordOffset,
                    byteCount: rawRecord.count, indexed: includeMessages)
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
                    responseUsers.record(message, offset: reader.lastRecordOffset,
                        byteCount: rawRecord.count, indexed: includeMessages)
                case .assistant:
                    assistants.record(message, offset: reader.lastRecordOffset,
                        byteCount: rawRecord.count, indexed: includeMessages)
                case .tool, .other:
                    break
                }
                continue
            }
            if let text = toolText(messageObject, type: itemType) {
                let message = RawMessage(
                    sequence: sequence, role: .tool, text: text, timestamp: timestamp)
                tools.record(message, offset: reader.lastRecordOffset,
                    byteCount: rawRecord.count, indexed: includeMessages)
                continue
            }
            if itemType == "reasoning", let text = reasoningSummary(messageObject) {
                let message = RawMessage(
                    sequence: sequence, role: .other, text: text, timestamp: timestamp)
                others.record(message, offset: reader.lastRecordOffset,
                    byteCount: rawRecord.count, indexed: includeMessages)
            }
        }

        let users = eventUsers.count > 0 ? eventUsers : responseUsers
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
            unreadableRecordCount: unreadableRecords,
            totalTokens: activityEventCount > 0 && activityComplete && !inheritedHistory ? previousTokens : nil)
        let references = (users.references + assistants.references + tools.references + others.references)
            .sorted { $0.sequence < $1.sequence }
        let searchText = [title, preview, workingDirectory, resolvedThreadID]
            .compactMap { $0 }
            .joined(separator: "\n")
            .lowercased()
        let current = try? candidate.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let unchanged = Int64(current?.fileSize ?? -1) == candidate.signature.byteCount
            && current?.contentModificationDate == candidate.signature.modifiedAt
        return ParsedTranscript(
            summary: summary, searchText: searchText, references: references,
            activity: CodexTranscriptActivity(
                threadID: threadID, project: workingDirectory, firstEvent: firstActivityEvent,
                eventCount: activityEventCount, totalTokens: previousTokens, days: activityDays,
                complete: activityComplete && !inheritedHistory && unreadableRecords == 0 && unchanged))
    }

    static func message(_ reference: ChatMessageReference, handle: FileHandle, path: String) throws -> ChatMessage? {
        try handle.seek(toOffset: reference.offset)
        guard var data = try handle.read(upToCount: reference.byteCount), data.count == reference.byteCount else {
            return nil
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = object["payload"] as? [String: Any]
        let messageObject = object["type"] as? String == "response_item" ? payload : object
        let text: String?
        if object["type"] as? String == "event_msg", reference.role == .user {
            text = payload?["message"] as? String
        } else if let messageObject {
            switch reference.role {
            case .user, .assistant: text = messageText(messageObject)
            case .tool: text = toolText(messageObject, type: messageObject["type"] as? String)
            case .other: text = reasoningSummary(messageObject)
            }
        } else { text = nil }
        guard let text else { return nil }
        return ChatMessage(id: "\(path)#\(reference.sequence)", role: reference.role,
            text: text, timestamp: reference.timestamp)
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
        let markers = ["session_meta", "user_message", "user", "assistant",
            "function_call", "function_call_output", "custom_tool_call", "custom_tool_call_output",
            "local_shell_call", "web_search_call", "reasoning"].map { Data("\"\($0)\"".utf8) }
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
