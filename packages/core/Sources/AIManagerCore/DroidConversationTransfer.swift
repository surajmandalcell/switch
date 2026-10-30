import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct DroidConversationTransferReport: Codable, Equatable, Sendable {
    public var transferredCount: Int
    public var warnings: [String]

    public init(transferredCount: Int = 0, warnings: [String] = []) {
        self.transferredCount = transferredCount
        self.warnings = warnings
    }
}

/// Copies complete ordinary transcripts into native sessions belonging to the destination account.
public enum DroidConversationTransfer {
    private static let maximumBytes = 32 * 1_024 * 1_024

    public struct Plan: Sendable {
        fileprivate let home: URL
        fileprivate let state: URL
        fileprivate let snapshots: [Snapshot]
        fileprivate let warnings: [String]
        public var count: Int { snapshots.count }

        /// The initializer must stop its native Droid process before returning.
        public func transfer(
            to accountID: UUID,
            initialize: (UUID, URL, String) throws -> Void,
            beforeWrite: () throws -> Void = {}
        ) throws -> DroidConversationTransferReport {
            guard !snapshots.isEmpty else { return .init(warnings: warnings) }
            let lock = try OperationLock(at: state.appendingPathExtension("lock"), fileManager: .default)
            return try lock.withLock {
                var ledger = try Ledger.load(state)
                var report = DroidConversationTransferReport(warnings: warnings)
                for snapshot in snapshots.reversed() {
                    do {
                        if try DroidConversationTransfer.transfer(snapshot, home: home, state: state,
                            ledger: &ledger, accountID: accountID, initialize: initialize, beforeWrite: beforeWrite) {
                            report.transferredCount += 1
                        }
                    } catch {
                        report.warnings.append("Conversation \(snapshot.id): \(failureMessage(error))")
                    }
                }
                return report
            }
        }
    }

    /// Call before changing authentication. No credentials or non-session files are read.
    public static func prepare(
        home: URL, state: URL, sourceAccountID: UUID?, limit: Int = 10
    ) throws -> Plan {
        try rejectLink(home)
        let home = CoreSupport.canonical(home)
        let root = home.appending(path: "sessions")
        try rejectLink(home)
        if CoreSupport.entryExists(root) { try checkPath(root, root: root) }
        let ledger = try Ledger.load(state)
        let inventory = try files(root: root)
        let owners = ledger.conversations.reduce(into: [String: String]()) { result, pair in
            result[pair.key] = pair.key
            for copy in pair.value.copies.values { result[copy.id.uuidString.lowercased()] = pair.key }
        }
        let groups = Dictionary(grouping: inventory) { owners[$0.id] ?? $0.id }
        let organizations = ledger.conversations.values.flatMap { $0.copies.values }.reduce(into: [UUID: String]()) {
            if let organization = $1.organization { $0[$1.id] = organization }
        }
        var snapshots: [Snapshot] = []
        var warnings: [String] = []
        var visited = Set<String>()
        for file in inventory.sorted(by: { ($0.modified, $0.id) > ($1.modified, $1.id) }) {
            guard snapshots.count < max(0, min(limit, 10)) else { break }
            let logicalID = owners[file.id] ?? file.id
            guard visited.insert(logicalID).inserted else { continue }
            do {
                var variants: [Transcript] = []
                for member in groups[logicalID] ?? [] {
                    if let parsed = try transcript(member.url, root: root, home: home), parsed.meaningful {
                        if let expected = organizations[parsed.id], expected != parsed.organization { throw Failure.changed }
                        variants.append(parsed)
                    }
                }
                guard !variants.isEmpty else { continue }
                let preferredID = sourceAccountID.flatMap { ledger.conversations[logicalID]?.copies[$0.uuidString]?.id }
                variants.sort {
                    if $0.body.count != $1.body.count { return $0.body.count > $1.body.count }
                    if $0.modified != $1.modified { return $0.modified > $1.modified }
                    return $0.id == preferredID && $1.id != preferredID
                }
                let newest = variants[0]
                guard variants.allSatisfy({ newest.body.starts(with: $0.body) }) else {
                    throw Failure.diverged
                }
                snapshots.append(.init(id: logicalID, source: newest, observed: variants.map { .init(url: $0.url, digest: $0.digest) }))
            } catch {
                warnings.append("Conversation \(logicalID): \(failureMessage(error))")
            }
        }
        return Plan(home: home, state: state, snapshots: snapshots, warnings: warnings)
    }

    fileprivate struct Snapshot: Sendable {
        let id: String
        let source: Transcript
        let observed: [Observed]
    }

    fileprivate struct Observed: Sendable {
        let url: URL
        let digest: String
    }

    fileprivate struct Transcript: Sendable {
        let url: URL
        let id: UUID
        let header: Data
        let body: Data
        let digest: String
        let cwd: URL
        let title: String
        let organization: String
        let modified: Date
        let meaningful: Bool
    }

    private struct Copy: Codable {
        var id: UUID
        var path: String?
        var organization: String?
        var bodyBytes: Int?
        var bodyDigest: String?
        var pendingBytes: Int?
        var pendingDigest: String?
    }

    private struct Conversation: Codable {
        var copies: [String: Copy] = [:]
    }

    private struct Ledger: Codable {
        var version = 1
        var conversations: [String: Conversation] = [:]

        static func load(_ url: URL) throws -> Self {
            guard CoreSupport.entryExists(url) else { return .init() }
            try rejectLink(url)
            let data = try read(url)
            let result = try JSONDecoder().decode(Self.self, from: data)
            guard result.version == 1 else { throw Failure.invalidState }
            var ids = Set<UUID>()
            let originals = Set(result.conversations.keys.compactMap(UUID.init(uuidString:)))
            for (logicalID, conversation) in result.conversations {
                guard UUID(uuidString: logicalID) != nil else { throw Failure.invalidState }
                for (account, copy) in conversation.copies {
                    guard UUID(uuidString: account) != nil, !originals.contains(copy.id), ids.insert(copy.id).inserted,
                          copy.path.map(CoreSupport.safeRelativePath) ?? true,
                          copy.organization.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true,
                          (copy.bodyBytes == nil) == (copy.bodyDigest == nil),
                          (copy.pendingBytes == nil) == (copy.pendingDigest == nil),
                          (copy.bodyBytes ?? 0) >= 0, (copy.bodyBytes ?? 0) <= maximumBytes,
                          (copy.pendingBytes ?? 0) >= 0, (copy.pendingBytes ?? 0) <= maximumBytes else {
                        throw Failure.invalidState
                    }
                }
            }
            return result
        }

        func save(_ url: URL) throws {
            try rejectLink(url)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try CoreSupport.atomicWrite(encoder.encode(self), to: url, fileManager: .default)
        }
    }

    private struct SessionFile {
        let id: String
        let url: URL
        let modified: Date
    }

    private enum Failure: Error {
        case malformed, unsafe, changed, diverged, invalidState, nativeSessionMissing
    }

    private static func failureMessage(_ error: Error) -> String {
        guard let failure = error as? Failure else { return "The copy failed; the original is unchanged. Retry the account switch." }
        switch failure {
        case .malformed: return "The transcript is incomplete or invalid; it was skipped."
        case .unsafe: return "An unsafe session path was skipped."
        case .changed: return "History changed during the switch; retry when Droid has stopped."
        case .diverged: return "The account copies have different history; neither was overwritten."
        case .invalidState: return "The saved transfer mapping is invalid; no history was overwritten."
        case .nativeSessionMissing: return "Droid did not create a safe native session; retry the account switch."
        }
    }

    private static func transfer(
        _ snapshot: Snapshot, home: URL, state: URL, ledger: inout Ledger, accountID: UUID,
        initialize: (UUID, URL, String) throws -> Void, beforeWrite: () throws -> Void
    ) throws -> Bool {
        let root = home.appending(path: "sessions")
        try unchanged(snapshot, root: root)
        var conversation = ledger.conversations[snapshot.id] ?? .init()
        let key = accountID.uuidString
        var copy = conversation.copies[key] ?? Copy(id: UUID())
        // Save the destination ID before Droid creates it, so a crashed retry adopts the same session.
        if conversation.copies[key] == nil {
            copy.pendingBytes = snapshot.source.body.count
            copy.pendingDigest = CoreSupport.digest(snapshot.source.body)
            conversation.copies[key] = copy
            ledger.conversations[snapshot.id] = conversation
            try ledger.save(state)
        }
        var candidates = try files(root: root).filter { $0.id == copy.id.uuidString.lowercased() }
        if candidates.isEmpty {
            guard copy.path == nil, copy.bodyDigest == nil else { throw Failure.nativeSessionMissing }
            try initialize(copy.id, snapshot.source.cwd, snapshot.source.title)
            candidates = try files(root: root).filter { $0.id == copy.id.uuidString.lowercased() }
        }
        guard candidates.count == 1,
              let target = try transcript(candidates[0].url, root: root, home: home),
              target.id == copy.id,
              CoreSupport.sameLocation(target.cwd, snapshot.source.cwd) else { throw Failure.nativeSessionMissing }
        let relative = target.url.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
        guard copy.path == nil || copy.path == relative else { throw Failure.unsafe }
        guard copy.organization == nil || copy.organization == target.organization else { throw Failure.changed }
        copy.organization = target.organization
        let desired = snapshot.source.body
        guard target.header.count + desired.count <= maximumBytes else { throw Failure.malformed }
        let targetDigest = CoreSupport.digest(target.body)
        let alreadyImported = target.body == desired
        if !alreadyImported {
            if let bytes = copy.bodyBytes, let digest = copy.bodyDigest {
                let matchesLastImport = target.body.count >= bytes && CoreSupport.digest(Data(target.body.prefix(bytes))) == digest
                let matchesPendingImport = copy.pendingBytes.map { bytes in
                    target.body.count >= bytes && CoreSupport.digest(Data(target.body.prefix(bytes))) == copy.pendingDigest
                } ?? false
                guard matchesLastImport || matchesPendingImport,
                      desired.starts(with: target.body) else {
                    throw Failure.diverged
                }
            } else if target.meaningful {
                // A publish can finish before its mapping update. Adopt only that exact journaled body.
                guard target.body.count == copy.pendingBytes, targetDigest == copy.pendingDigest,
                      desired.starts(with: target.body) else { throw Failure.diverged }
            }
        }
        copy.path = relative
        copy.pendingBytes = desired.count
        copy.pendingDigest = CoreSupport.digest(desired)
        conversation.copies[key] = copy
        ledger.conversations[snapshot.id] = conversation
        try ledger.save(state)
        try beforeWrite()
        try unchanged(snapshot, root: root)
        try checkPath(target.url, root: root)
        guard CoreSupport.digest(try read(target.url)) == target.digest else { throw Failure.changed }
        if !alreadyImported {
            try CoreSupport.atomicWrite(target.header + desired, to: target.url, fileManager: .default)
        }
        try FileManager.default.setAttributes([.modificationDate: snapshot.source.modified], ofItemAtPath: target.url.path)
        copy.bodyBytes = desired.count
        copy.bodyDigest = copy.pendingDigest
        copy.pendingBytes = nil
        copy.pendingDigest = nil
        conversation.copies[key] = copy
        ledger.conversations[snapshot.id] = conversation
        try ledger.save(state)
        return !alreadyImported
    }

    private static func unchanged(_ snapshot: Snapshot, root: URL) throws {
        for observed in snapshot.observed {
            try checkPath(observed.url, root: root)
            guard CoreSupport.digest(try read(observed.url)) == observed.digest else { throw Failure.changed }
        }
        try checkWorkingDirectory(snapshot.source.cwd)
    }

    private static func files(root: URL) throws -> [SessionFile] {
        guard CoreSupport.entryExists(root) else { return [] }
        try checkPath(root, root: root)
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { throw Failure.unsafe }
        var result: [SessionFile] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, url.pathExtension == "jsonl",
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            try checkPath(url, root: root)
            result.append(.init(id: id.uuidString.lowercased(), url: url, modified: values.contentModificationDate ?? .distantPast))
        }
        return result
    }

    private static func transcript(_ url: URL, root: URL, home: URL) throws -> Transcript? {
        try checkPath(url, root: root)
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        let data = try read(url)
        guard data.last == 10, let newline = data.firstIndex(of: 10),
              let header = try JSONSerialization.jsonObject(with: data.prefix(upTo: newline)) as? [String: Any],
              header["type"] as? String == "session_start",
              let rawID = header["id"] as? String, let id = UUID(uuidString: rawID),
              UUID(uuidString: url.deletingPathExtension().lastPathComponent) == id,
              let organization = header["organizationId"] as? String,
              !organization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let directory = header["cwd"] as? String, directory.hasPrefix("/") else { throw Failure.malformed }
        for key in ["callingSessionId", "parentSessionId", "decompMissionId", "missionId", "decompSessionType"] {
            if let value = header[key], !(value is NSNull), String(describing: value) != "" { return nil }
        }
        if let tags = header["tags"] as? [Any] {
            if tags.contains(where: isMissionTag) { return nil }
        } else if let tag = header["tags"], isMissionTag(tag) { return nil }
        if CoreSupport.entryExists(home.appending(path: "missions/\(rawID)")) { return nil }
        let cwd = URL(fileURLWithPath: directory)
        try checkWorkingDirectory(cwd)
        let body = Data(data.suffix(from: data.index(after: newline)))
        var meaningful = false
        for line in body.split(separator: 10, omittingEmptySubsequences: false).dropLast() {
            guard !line.isEmpty,
                  let event = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw Failure.malformed }
            guard event["type"] as? String == "message", let message = event["message"] as? [String: Any] else { continue }
            let role = message["role"] as? String
            if role == "assistant" || role == "user" {
                if let content = message["content"] as? String {
                    meaningful = meaningful || meaningfulText(content)
                } else if let content = message["content"] as? [[String: Any]] {
                    meaningful = meaningful || content.contains { block in
                        if let text = block["text"] as? String { return meaningfulText(text) }
                        return block["type"] as? String != "text"
                    }
                }
            }
        }
        let title = (header["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .init(url: url, id: id, header: Data(data.prefix(through: newline)), body: body,
            digest: CoreSupport.digest(data), cwd: cwd,
            title: String((title.isEmpty ? "Conversation in \(cwd.lastPathComponent)" : title).prefix(200)),
            organization: organization, modified: modified, meaningful: meaningful)
    }

    private static func isMissionTag(_ tag: Any) -> Bool {
        let named = tag as? [String: Any]
        if let name = (tag as? String) ?? (named?["name"] as? String), ["mission-session", "mission"].contains(name) { return true }
        guard let metadata = named?["metadata"] as? [String: Any] else { return false }
        return ["missionId", "decompMissionId", "callingSessionId"].contains { key in
            guard let value = metadata[key], !(value is NSNull) else { return false }
            return String(describing: value) != ""
        }
    }

    private static func meaningfulText(_ text: String) -> Bool {
        let stripped = text.replacingOccurrences(of: "(?s)<system-reminder>.*?</system-reminder>",
            with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return !stripped.isEmpty && !ChatTitlePolicy.isBootstrapContext(stripped)
    }

    private static func checkWorkingDirectory(_ url: URL) throws {
        let path = url.path
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              CoreSupport.canonical(url).pathComponents == url.standardizedFileURL.pathComponents,
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw Failure.unsafe }
    }

    private static func rejectLink(_ url: URL) throws {
        if CoreSupport.entryExists(url), (try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw Failure.unsafe
        }
    }

    private static func checkPath(_ url: URL, root: URL) throws {
        guard CoreSupport.isContained(url, by: root),
              CoreSupport.canonical(url).pathComponents == url.standardizedFileURL.pathComponents else { throw Failure.unsafe }
        try rejectLink(root)
        var current = url.standardizedFileURL
        let steps = current.pathComponents.count - root.standardizedFileURL.pathComponents.count
        guard steps >= 0 else { throw Failure.unsafe }
        for _ in 0..<steps {
            try rejectLink(current)
            current.deleteLastPathComponent()
        }
        guard CoreSupport.sameLocation(current, root) else { throw Failure.unsafe }
    }

    private static func read(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unsafe }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else { throw Failure.malformed }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count == Int(info.st_size) else { throw Failure.changed }
        return data
    }
}
