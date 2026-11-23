import Foundation

/// Claude Code sessions for History: `projects/<encoded cwd>/<session>.jsonl` under each Claude config
/// dir, read-only. Every Switch profile links `projects` to the shared `~/.claude/projects`, so a session
/// carries no reliable account; rows are tagged only as Claude Code. Subagent logs
/// (`<session>/subagents/`) are skipped. Parsing is incremental: an unchanged file is never reopened and
/// a grown file resumes at the last full line.
public actor ClaudeChatIndex {
    struct Signature: Codable, Equatable, Sendable {
        var size: Int64
        var modified: Date
    }

    /// Everything the list row needs, plus the byte offset after the last full line read.
    struct State: Codable, Equatable, Sendable {
        var offset: Int64 = 0
        var sessionID: String?
        var cwd: String?
        var model: String?
        var customTitle: String?
        var aiTitle: String?
        var summaryTitle: String?
        var firstPrompt: String?
        var lastResponse: String?
        var lastAt: Date?
        var messages = 0
        var unreadable = 0
    }

    struct Entry: Codable, Sendable {
        var path: String
        var signature: Signature
        var state: State
    }

    private var roots: [URL]
    private let cacheFile: URL?
    private let allowsRead: @Sendable (URL) -> Bool
    private var entries: [String: Entry] = [:]
    private var failedCount = 0
    private var loadedCache = false
    private var revision: UInt64 = 0
    private var ordered: [(summary: ChatThreadSummary, searchText: String)]?
    private var refreshTask: Task<Void, Error>?
    private var detailCache: (path: String, signature: Signature, messages: [ChatMessage])?
    private var clearGeneration = 0
    /// Tests only: runs after a scan reads its files, before it saves them.
    private var willCommitScan: (@Sendable () async -> Void)?

    func setWillCommitScan(_ hook: @escaping @Sendable () async -> Void) { willCommitScan = hook }

    public init(roots: [URL] = ClaudeCostScanner.defaultRoots(), cacheFile: URL? = nil,
                allowsRead: @escaping @Sendable (URL) -> Bool = { _ in true }) {
        self.roots = roots
        self.cacheFile = cacheFile
        self.allowsRead = allowsRead
    }

    /// Adds config dirs (such as each Claude account's profile home); duplicates resolve to one folder.
    public func addRoots(_ more: [URL]) {
        roots += more.filter { !roots.contains($0) }
    }

    public func refresh(
        query: String = "", limit: Int = 1_000, sources: Set<ChatThreadSource> = []
    ) async throws -> ChatHistorySnapshot {
        if let refreshTask {
            try await refreshTask.value
        } else {
            let task = Task(priority: .utility) { try await self.scan() }
            refreshTask = task
            defer { refreshTask = nil }
            try await task.value
        }
        return search(query: query, limit: limit, sources: sources)
    }

    /// `sources` keeps only those apps (empty keeps all), before the limit cuts the list.
    public func search(query: String, limit: Int = 1_000, sources: Set<ChatThreadSource> = []) -> ChatHistorySnapshot {
        if ordered == nil {
            ordered = entries.values.map { entry in
                let summary = Self.summary(entry)
                let text = [summary.title, summary.preview, summary.workingDirectory, summary.threadID]
                    .compactMap { $0 }.joined(separator: "\n").lowercased()
                return (summary, text)
            }.sorted {
                $0.summary.updatedAt != $1.summary.updatedAt
                    ? $0.summary.updatedAt > $1.summary.updatedAt : $0.summary.id < $1.summary.id
            }
        }
        let all = ordered ?? []
        let terms = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        let found = terms.isEmpty ? all : all.filter { row in terms.allSatisfy(row.searchText.contains) }
        let matches = sources.isEmpty || sources.contains(.claude) ? found : []
        var snapshot = ChatHistorySnapshot(
            threads: matches.prefix(min(max(1, limit), 2_000)).map(\.summary),
            libraryRevision: revision,
            totalThreadCount: all.count,
            matchingThreadCount: matches.count,
            skippedFileCount: failedCount,
            unreadableRecordCount: all.reduce(0) { $0 + $1.summary.unreadableRecordCount })
        if !found.isEmpty { snapshot.sourceCounts = [.claude: found.count] }
        if !all.isEmpty { snapshot.librarySourceCounts = [.claude: all.count] }
        return snapshot
    }

    /// One page of a Claude conversation, or nil when `id` is not a Claude session.
    public func detail(
        for id: String, offset: Int = 0, limit: Int = 100, query: String = "", filter: ChatMessageFilter = .all
    ) async throws -> ChatThreadDetail? {
        guard let entry = entries[id], allowsRead(URL(fileURLWithPath: id)) else { return nil }
        let messages: [ChatMessage]
        if let cached = detailCache, cached.path == id, cached.signature == entry.signature {
            messages = cached.messages
        } else {
            let url = URL(fileURLWithPath: id)
            let task = Task.detached(priority: .userInitiated) { try Self.readMessages(url) }
            messages = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            detailCache = (id, entry.signature, messages)
        }
        let result = try await ChatMessageSearch.search(messages, query: query, filter: filter)
        let page = Array(result.messages.dropFirst(max(0, offset)).prefix(min(max(1, limit), 200)))
        let next = max(0, offset) + page.count
        return ChatThreadDetail(thread: Self.summary(entry), messages: page, omittedMessageCount: 0,
            matchingMessageCount: result.matchingMessageCount,
            nextOffset: next < result.matchingMessageCount ? next : nil)
    }

    public func clearCache() {
        clearGeneration &+= 1
        entries = [:]
        ordered = nil
        detailCache = nil
        revision &+= 1
        if let cacheFile { try? FileManager.default.removeItem(at: cacheFile) }
    }

    // MARK: Scan

    private func scan() async throws {
        loadCacheIfNeeded()
        let generation = clearGeneration
        let roots = roots
        let allowsRead = allowsRead
        let found = await Task.detached(priority: .utility) { Self.candidates(roots, allowsRead: allowsRead) }.value
        var next: [String: Entry] = [:]
        var jobs: [(URL, Signature, State?)] = []
        for (url, signature) in found {
            let previous = entries[url.path]
            if let previous, previous.signature == signature {
                next[url.path] = previous
            } else {
                // Claude only appends to a session, so a grown file resumes where the last read ended.
                let resume = previous.flatMap { $0.state.offset <= signature.size ? $0.state : nil }
                jobs.append((url, signature, resume))
            }
        }
        var failed = 0
        try await withThrowingTaskGroup(of: Entry?.self) { group in
            var pending = jobs.makeIterator()
            func add() -> Bool {
                guard let (url, signature, resume) = pending.next() else { return false }
                group.addTask(priority: .utility) {
                    guard let state = try? Self.parse(url, resume: resume) else { return nil }
                    return Entry(path: url.path, signature: signature, state: state)
                }
                return true
            }
            for _ in 0..<4 where add() {}
            while let result = try await group.next() {
                try Task.checkCancellation()
                if let result { next[result.path] = result } else { failed += 1 }
                _ = add()
            }
        }
        await willCommitScan?()
        // A clear during this scan owns the index; the scan's rows are stale.
        guard generation == clearGeneration else { return }
        let changed = !jobs.isEmpty || next.count != entries.count || failed != failedCount
        entries = next
        failedCount = failed
        if changed {
            ordered = nil
            revision &+= 1
            persist()
        }
    }

    /// Each root's `projects/` dir (or the root itself), resolved and deduped. The History watcher
    /// watches these same folders.
    public nonisolated static func projectsFolders(_ roots: [URL], allowsRead: (URL) -> Bool = { _ in true }) -> [URL] {
        var seen = Set<String>()
        return roots.compactMap { root in
            let inner = root.appending(path: "projects", directoryHint: .isDirectory)
            guard let projects = [inner, root].first(where: { allowsRead($0) && isDirectory($0) })?.resolvingSymlinksInPath(),
                  seen.insert(projects.path).inserted else { return nil }
            return projects
        }
    }

    /// Top-level session files of every distinct `projects/` dir, with size and date.
    nonisolated static func candidates(_ roots: [URL], allowsRead: (URL) -> Bool = { _ in true }) -> [(URL, Signature)] {
        let fileManager = FileManager.default
        var found: [(URL, Signature)] = []
        for projects in projectsFolders(roots, allowsRead: allowsRead) {
            guard let folders = try? fileManager.contentsOfDirectory(
                    at: projects, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
            else { continue }
            for folder in folders where allowsRead(folder) && isDirectory(folder) {
                let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
                for file in (try? fileManager.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
                where file.pathExtension == "jsonl" && allowsRead(file) {
                    guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
                    else { continue }
                    found.append((file, Signature(size: Int64(values.fileSize ?? 0),
                        modified: values.contentModificationDate ?? .distantPast)))
                }
            }
        }
        return found
    }

    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    // MARK: Parse

    /// Reads full lines from `resume.offset` (or the start) and folds them into the row state.
    nonisolated static func parse(_ url: URL, resume: State?) throws -> State {
        var state = resume ?? State()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if state.offset > 0 {
            // The resume point must still sit right after a newline, else the file was rewritten.
            try handle.seek(toOffset: UInt64(state.offset - 1))
            if try handle.read(upToCount: 1) != Data([10]) {
                state = State()
                try handle.seek(toOffset: 0)
            }
        }
        try forEachLine(handle) { line in
            state.offset += Int64(line.count + 1)
            fold(line, into: &state)
        }
        return state
    }

    /// Every message of a session, in file order, with its full text: copy actions export it, and the
    /// reader cuts long texts for display itself.
    nonisolated static func readMessages(_ url: URL) throws -> [ChatMessage] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var messages: [ChatMessage] = []
        try forEachLine(handle) { line in
            guard let record = record(line) else { return }
            let when = (record["timestamp"] as? String).flatMap(date)
            let model = (record["message"] as? [String: Any])?["model"] as? String
            for (role, text) in parts(record, includeText: true) {
                messages.append(ChatMessage(id: "\(url.path)#\(messages.count)", role: role, text: text,
                    timestamp: when, model: role == .assistant && model != "<synthetic>" ? model : nil))
            }
        }
        return messages
    }

    /// Calls `body` with each newline-ended line, read in 4 MB chunks. A trailing unfinished line is left
    /// for the next read.
    private nonisolated static func forEachLine(_ handle: FileHandle, _ body: (Data) -> Void) throws {
        var buffer = Data()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            buffer.append(chunk)
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 10) {
                body(buffer.subdata(in: start..<newline))
                start = newline + 1
            }
            buffer = buffer.subdata(in: start..<buffer.endIndex)
        }
    }

    private static let markers = ["\"type\":\"user\"", "\"type\":\"assistant\"", "\"type\":\"summary\"",
                                  "\"type\":\"ai-title\"", "\"type\":\"custom-title\""].map { Data($0.utf8) }

    private nonisolated static func fold(_ line: Data, into state: inout State) {
        // Bookkeeping lines (API requests, attachments, snapshots) are most of the bytes and never feed
        // History, so only lines that name a wanted type are decoded.
        guard markers.contains(where: { line.range(of: $0) != nil }) else { return }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            state.unreadable += 1
            return
        }
        switch object["type"] as? String {
        case "custom-title": state.customTitle = clip(object["customTitle"] as? String, 120) ?? state.customTitle
        case "ai-title": state.aiTitle = clip(object["aiTitle"] as? String, 120) ?? state.aiTitle
        case "summary": state.summaryTitle = clip(object["summary"] as? String, 120) ?? state.summaryTitle
        case "user", "assistant":
            guard object["isSidechain"] as? Bool != true else { return }
            state.sessionID = state.sessionID ?? object["sessionId"] as? String
            state.cwd = state.cwd ?? object["cwd"] as? String
            if let timestamp = object["timestamp"] as? String, let date = date(timestamp) { state.lastAt = date }
            if let model = (object["message"] as? [String: Any])?["model"] as? String, model != "<synthetic>" {
                state.model = model
            }
            for (role, text) in parts(object, includeText: false) {
                state.messages += 1
                if role == .user, state.firstPrompt == nil { state.firstPrompt = clip(text, 200) }
                if role == .assistant, let text = clip(text, 200) { state.lastResponse = text }
            }
        default: break
        }
    }

    private nonisolated static func record(_ line: Data) -> [String: Any]? {
        guard markers.prefix(2).contains(where: { line.range(of: $0) != nil }),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String, type == "user" || type == "assistant",
              object["isSidechain"] as? Bool != true
        else { return nil }
        return object
    }

    /// The messages one record holds: prompts, responses, tool calls and results, and other parts
    /// (thinking, meta and slash-command records). Tool text is only built when `includeText` is set.
    nonisolated static func parts(_ record: [String: Any], includeText: Bool) -> [(ChatMessageRole, String)] {
        guard let message = record["message"] as? [String: Any] else { return [] }
        let isUser = record["type"] as? String == "user"
        let isMeta = record["isMeta"] as? Bool == true
        func userRole(_ text: String) -> ChatMessageRole {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let noise = trimmed.hasPrefix("<command-") || trimmed.hasPrefix("<local-command-")
                || trimmed.hasPrefix("[Request interrupted") || ChatTitlePolicy.isBootstrapContext(trimmed)
            return isMeta || noise ? .other : .user
        }
        if let text = message["content"] as? String {
            return isUser ? [(userRole(text), text)] : [(.assistant, text)]
        }
        var result: [(ChatMessageRole, String)] = []
        for part in message["content"] as? [[String: Any]] ?? [] {
            switch part["type"] as? String {
            case "text":
                let text = part["text"] as? String ?? ""
                result.append(isUser ? (userRole(text), text) : (.assistant, text))
            case "thinking":
                if let text = part["thinking"] as? String, !text.isEmpty { result.append((.other, text)) }
            case "tool_use":
                var text = part["name"] as? String ?? "tool"
                if includeText, let input = part["input"],
                   let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) {
                    text += "\n" + String(decoding: data, as: UTF8.self)
                }
                result.append((.tool, text))
            case "tool_result":
                var text = ""
                if includeText {
                    if let content = part["content"] as? String {
                        text = content
                    } else if let content = part["content"] as? [[String: Any]] {
                        text = content.map { $0["text"] as? String ?? "[\($0["type"] as? String ?? "part")]" }
                            .joined(separator: "\n")
                    }
                }
                result.append((.tool, text))
            case "image": result.append((isUser ? .user : .other, "[image]"))
            default: break
            }
        }
        return result
    }

    private nonisolated static func clip(_ text: String?, _ limit: Int) -> String? {
        ChatTitlePolicy.compact(text, maximumCharacters: limit)
    }

    private nonisolated static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    nonisolated static func summary(_ entry: Entry) -> ChatThreadSummary {
        let state = entry.state
        let url = URL(fileURLWithPath: entry.path)
        return ChatThreadSummary(
            id: entry.path,
            threadID: state.sessionID ?? url.deletingPathExtension().lastPathComponent,
            title: ChatTitlePolicy.resolvedTitle(
                explicitName: state.customTitle, databaseTitle: state.aiTitle ?? state.summaryTitle,
                transcriptTitle: state.firstPrompt, workingDirectory: state.cwd),
            preview: ChatTitlePolicy.compact(state.lastResponse, maximumCharacters: 180) ?? "",
            workingDirectory: state.cwd,
            updatedAt: state.lastAt ?? entry.signature.modified,
            archived: false,
            messageCount: state.messages,
            fileByteCount: entry.signature.size,
            source: url,
            unreadableRecordCount: state.unreadable,
            appSource: .claude,
            model: state.model)
    }

    // MARK: Cache file

    private func loadCacheIfNeeded() {
        guard !loadedCache else { return }
        loadedCache = true
        guard let cacheFile,
              let size = (try? cacheFile.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 32 << 20,
              let data = try? Data(contentsOf: cacheFile),
              let saved = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = Dictionary(saved.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func persist() {
        guard let cacheFile, let data = try? JSONEncoder().encode(Array(entries.values)) else { return }
        let folder = cacheFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard (try? data.write(to: cacheFile, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheFile.path)
    }
}

extension ChatHistorySnapshot {
    /// Codex and Claude rows in one newest-first list, cut to `limit`.
    public static func merging(_ first: ChatHistorySnapshot, _ second: ChatHistorySnapshot,
                               limit: Int = 1_000) -> ChatHistorySnapshot {
        let threads = (first.threads + second.threads).sorted {
            $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id
        }
        var merged = ChatHistorySnapshot(
            threads: Array(threads.prefix(limit)),
            // Both revisions only grow, so the sum changes whenever either library does.
            libraryRevision: first.libraryRevision &+ second.libraryRevision,
            totalThreadCount: first.totalThreadCount + second.totalThreadCount,
            matchingThreadCount: first.matchingThreadCount + second.matchingThreadCount,
            skippedFileCount: first.skippedFileCount + second.skippedFileCount,
            unreadableRecordCount: first.unreadableRecordCount + second.unreadableRecordCount,
            reparsedFileCount: first.reparsedFileCount + second.reparsedFileCount)
        merged.sourceCounts = first.sourceCounts.merging(second.sourceCounts, uniquingKeysWith: +)
        merged.librarySourceCounts = first.librarySourceCounts.merging(second.librarySourceCounts, uniquingKeysWith: +)
        return merged
    }
}
