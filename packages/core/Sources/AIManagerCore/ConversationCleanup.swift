import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct CleanupConversation: Identifiable, Codable, Sendable, Equatable {
    public var id: String { relativePath }
    public let relativePath: String
    public let title: String
    public let project: String
    public let archived: Bool
    public let updatedAt: Date
    public let bytes: Int64
    let inode: UInt64
    let device: UInt64
    let modifiedAt: Date
}

public struct ConversationCleanupPlan: Sendable {
    public let id: UUID
    public let conversations: [CleanupConversation]
    public var bytes: Int64 { conversations.reduce(0) { $0 + $1.bytes } }
    let home: URL
    let digests: [String: String]
}

public struct ConversationCleanupBatch: Identifiable, Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var conversations: [CleanupConversation]
    public var bytes: Int64 { conversations.reduce(0) { $0 + $1.bytes } }
    var home: URL
    var digests: [String: String]
    var phase: String
}

/// Only transcript files in the two explicit conversation roots enter Cleanup.
struct ConversationCleanup {
    let home: URL
    private let files = FileManager.default
    private var trash: URL { home.appending(path: ".switch-trash") }

    init(home: URL) { self.home = CoreSupport.canonical(home) }

    func inventory(summaries: [ChatThreadSummary]) throws -> [CleanupConversation] {
        let known = Dictionary(summaries.map { (CoreSupport.canonical($0.source).path, $0) },
                               uniquingKeysWith: { first, _ in first })
        var result: [CleanupConversation] = []
        var visited = 0
        for name in ["sessions", "archived_sessions"] {
            let root = home.appending(path: name)
            guard CoreSupport.entryExists(root) else { continue }
            try validateAncestors(root, within: home)
            var scanError: Error?
            guard let iterator = files.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                    scanError = error
                    return false
                }) else { throw AIManagerError.operationFailed("Could not read the conversation folders.") }
            for case let rawURL as URL in iterator {
                let url = rawURL.standardizedFileURL
                try Task.checkCancellation()
                visited += 1
                guard visited <= 500_000 else { throw AIManagerError.operationFailed("The conversation inventory is too large.") }
                if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    iterator.skipDescendants()
                    continue
                }
                guard url.pathExtension.lowercased() == "jsonl" else { continue }
                let info = try regularFile(url, within: home)
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
                guard let modified = values.contentModificationDate else { throw AIManagerError.sourceChanged }
                let summary = known[url.path]
                result.append(CleanupConversation(relativePath: String(url.path.dropFirst(home.path.count + 1)),
                    title: summary?.title ?? url.deletingPathExtension().lastPathComponent,
                    project: summary?.workingDirectory ?? "Unknown project", archived: name == "archived_sessions",
                    updatedAt: summary?.updatedAt ?? modified, bytes: Int64(info.st_size),
                    inode: UInt64(info.st_ino), device: UInt64(info.st_dev), modifiedAt: modified))
            }
            if let scanError { throw scanError }
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    func review(_ selected: [CleanupConversation]) throws -> ConversationCleanupPlan {
        guard Set(selected.map(\.id)).count == selected.count else { throw AIManagerError.sourceChanged }
        var digests: [String: String] = [:]
        for item in selected {
            try Task.checkCancellation()
            let source = try sourceURL(item)
            try validate(item, at: source, within: home)
            digests[item.id] = try CoreSupport.digest(file: source)
            try validate(item, at: source, within: home)
        }
        return .init(id: UUID(), conversations: selected, home: home, digests: digests)
    }

    func validate(_ plan: ConversationCleanupPlan) throws {
        guard plan.home == home else { throw AIManagerError.sourceChanged }
        for item in plan.conversations {
            let source = try sourceURL(item)
            try validate(item, at: source, within: home)
            guard try CoreSupport.digest(file: source) == plan.digests[item.id] else { throw AIManagerError.sourceChanged }
            try validate(item, at: source, within: home)
        }
    }

    func moveToTrash(_ plan: ConversationCleanupPlan) throws -> ConversationCleanupBatch {
        try validate(plan)
        guard !plan.conversations.isEmpty else { throw AIManagerError.operationFailed("Select conversations before reviewing Cleanup.") }
        var batch = ConversationCleanupBatch(id: plan.id, createdAt: Date(), conversations: plan.conversations,
            home: home, digests: plan.digests, phase: "moving")
        try prepareDirectory(trash)
        let folder = batchFolder(batch.id)
        guard !CoreSupport.entryExists(folder) else { throw AIManagerError.sourceChanged }
        try prepareDirectory(folder)
        try save(batch)
        for item in batch.conversations {
            try Task.checkCancellation()
            let source = try sourceURL(item)
            let target = folder.appending(path: item.relativePath)
            try prepareDirectory(target.deletingLastPathComponent())
            let targetDevice = try directoryStat(target.deletingLastPathComponent()).st_dev
            guard UInt64(targetDevice) == item.device else {
                throw AIManagerError.operationFailed("Cleanup trash must be on the same disk as its conversations.")
            }
            try validate(item, at: source, within: home)
            guard try CoreSupport.digest(file: source) == batch.digests[item.id] else { throw AIManagerError.sourceChanged }
            try files.moveItem(at: source, to: target)
        }
        batch.phase = "trashed"
        try save(batch)
        return batch
    }

    // Existence on each side reconciles an interrupted move without replaying deletion.
    func batches() throws -> [ConversationCleanupBatch] {
        guard CoreSupport.entryExists(trash) else { return [] }
        try validateAncestors(trash, within: home)
        return try files.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil).compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
            var batch = try load(id)
            guard batch.phase != "finished" else { return nil }
            batch.conversations = try batch.conversations.filter { item in
                let target = folder.appending(path: item.relativePath)
                guard CoreSupport.entryExists(target) else { return false }
                try validate(item, at: target, within: folder)
                guard try CoreSupport.digest(file: target) == batch.digests[item.id] else { throw AIManagerError.sourceChanged }
                return true
            }
            return batch.conversations.isEmpty ? nil : batch
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func restore(_ id: UUID) throws {
        var batch = try load(id)
        let folder = batchFolder(id)
        let present = batch.conversations.filter { CoreSupport.entryExists(folder.appending(path: $0.relativePath)) }
        // Check every collision before restoring anything.
        for item in present {
            let source = folder.appending(path: item.relativePath)
            try validate(item, at: source, within: folder)
            guard try CoreSupport.digest(file: source) == batch.digests[item.id],
                  !CoreSupport.entryExists(try sourceURL(item)) else { throw AIManagerError.sourceChanged }
            try validateAncestors(try sourceURL(item).deletingLastPathComponent(), within: home)
        }
        batch.phase = "restoring"
        try save(batch)
        for item in present {
            let source = folder.appending(path: item.relativePath)
            let destination = try sourceURL(item)
            try validate(item, at: source, within: folder)
            try prepareDirectory(destination.deletingLastPathComponent())
            try files.moveItem(at: source, to: destination)
        }
        try finish(&batch)
    }

    func permanentlyRemove(_ id: UUID) throws {
        var batch = try load(id)
        let folder = batchFolder(id)
        for item in batch.conversations {
            let target = folder.appending(path: item.relativePath)
            guard CoreSupport.entryExists(target) else { continue }
            try validate(item, at: target, within: folder)
            guard try CoreSupport.digest(file: target) == batch.digests[item.id] else { throw AIManagerError.sourceChanged }
        }
        batch.phase = "removing"
        try save(batch)
        for item in batch.conversations {
            let target = folder.appending(path: item.relativePath)
            guard CoreSupport.entryExists(target) else { continue }
            try validate(item, at: target, within: folder)
            try files.removeItem(at: target)
        }
        try finish(&batch)
    }

    private func finish(_ batch: inout ConversationCleanupBatch) throws {
        batch.phase = "finished"
        batch.conversations = []
        batch.digests = [:]
        try save(batch)
    }

    private func batchFolder(_ id: UUID) -> URL { trash.appending(path: id.uuidString) }

    private func load(_ id: UUID) throws -> ConversationCleanupBatch {
        let folder = batchFolder(id)
        let manifest = folder.appending(path: "manifest.json")
        _ = try regularFile(manifest, within: home)
        let batch = try JSONDecoder().decode(ConversationCleanupBatch.self, from: Data(contentsOf: manifest))
        guard batch.id == id, batch.home == home,
              Set(batch.conversations.map(\.id)).count == batch.conversations.count,
              batch.conversations.allSatisfy({ validRelativePath($0.relativePath) }) else { throw AIManagerError.sourceChanged }
        return batch
    }

    private func save(_ batch: ConversationCleanupBatch) throws {
        let folder = batchFolder(batch.id)
        try validateAncestors(folder, within: home)
        try CoreSupport.atomicWrite(JSONEncoder().encode(batch), to: folder.appending(path: "manifest.json"), fileManager: files)
    }

    private func sourceURL(_ item: CleanupConversation) throws -> URL {
        guard validRelativePath(item.relativePath) else { throw AIManagerError.unsafePath("Cleanup only accepts conversation files.") }
        return home.appending(path: item.relativePath)
    }

    private func validRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count >= 2 && ["sessions", "archived_sessions"].contains(String(parts[0]))
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
            && path.hasSuffix(".jsonl")
    }

    private func validate(_ item: CleanupConversation, at url: URL, within root: URL) throws {
        let info = try regularFile(url, within: root)
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard UInt64(info.st_ino) == item.inode, UInt64(info.st_dev) == item.device,
              Int64(info.st_size) == item.bytes, modified == item.modifiedAt else { throw AIManagerError.sourceChanged }
    }

    private func regularFile(_ url: URL, within root: URL) throws -> stat {
        try validateAncestors(url.deletingLastPathComponent(), within: root)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else {
            throw AIManagerError.unsafePath("Cleanup found a linked or unsafe file: \(url.lastPathComponent)")
        }
        return info
    }

    private func directoryStat(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else { throw AIManagerError.unsafePath("Cleanup found an unsafe folder.") }
        return info
    }

    private func validateAncestors(_ url: URL, within root: URL) throws {
        let url = url.standardizedFileURL
        let root = root.standardizedFileURL
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else {
            throw AIManagerError.unsafePath("Cleanup path is outside its root: \(url.path) (\(root.path))")
        }
        var cursor = url
        while true {
            if CoreSupport.entryExists(cursor) { _ = try directoryStat(cursor) }
            if cursor.path == root.path { break }
            cursor.deleteLastPathComponent()
        }
    }

    private func prepareDirectory(_ url: URL) throws {
        try validateAncestors(url, within: home)
        try CoreSupport.privateDirectory(url, fileManager: files)
        try validateAncestors(url, within: home)
    }
}
