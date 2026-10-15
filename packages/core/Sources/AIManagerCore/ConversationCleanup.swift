import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One removable thing: a transcript with its companions, a log, a cache folder, an old version.
/// `root` 0 is the source home; 1 is the user home (for example `~/Library/Caches`).
public struct CleanupItem: Identifiable, Codable, Sendable, Hashable {
    /// A rewrite shares its path with the transcript's own row, so it gets its own id.
    public var id: String { "\(root):\(path)" + (isRewrite ? "#images" : "") }
    public let root: Int
    public let path: String
    public let companions: [String]
    public let title: String
    public let project: String?
    public let updatedAt: Date
    /// Bytes the move frees; for a rewrite, the bytes the rewrite saves.
    public let bytes: Int64
    public let isDirectory: Bool
    public let protectedReason: String?
    let inode: UInt64
    let device: UInt64
    let modifiedAt: Double
    /// True for a transcript whose pasted pictures shrink in place. The original goes to the trash.
    let rewrite: Bool?

    var allPaths: [String] { [path] + companions }
    public var isRewrite: Bool { rewrite == true }

    func protecting(_ reason: String) -> CleanupItem {
        CleanupItem(root: root, path: path, companions: companions, title: title, project: project, updatedAt: updatedAt,
            bytes: bytes, isDirectory: isDirectory, protectedReason: protectedReason ?? reason, inode: inode, device: device,
            modifiedAt: modifiedAt, rewrite: rewrite)
    }
}

public struct ConversationCleanupPlan: Sendable {
    public let id: UUID
    public let items: [CleanupItem]
    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    let home: URL
    let userHome: URL
    let digests: [String: String]
}

public struct ConversationCleanupBatch: Identifiable, Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var items: [CleanupItem]
    public var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var home: URL
    var userHome: URL
    var digests: [String: String]
    var phase: String
}

/// Moves reviewed items into a private trash inside the source home, with a journal.
/// Every path is checked: no link ancestors, no changed files, the same disk, no protected names.
public struct ConversationCleanup {
    public let home: URL
    public let userHome: URL
    private let files = FileManager.default
    /// A chat written this recently may still be in use, so its images stay.
    static let rewriteQuietPeriod: TimeInterval = 3_600
    private var trash: URL { home.appending(path: ".switch-trash") }

    public init(home: URL, userHome: URL? = nil) {
        self.home = CoreSupport.canonical(home)
        self.userHome = CoreSupport.canonical(userHome ?? FileManager.default.homeDirectoryForCurrentUser)
    }

    public func review(_ selected: [CleanupItem]) throws -> ConversationCleanupPlan {
        guard Set(selected.map(\.id)).count == selected.count else { throw AIManagerError.sourceChanged }
        let removed = selected.filter { !$0.isRewrite }.flatMap(\.allPaths)
        guard !selected.contains(where: { item in
            item.isRewrite && removed.contains { item.path == $0 || item.path.hasPrefix($0 + "/") }
        }) else { throw AIManagerError.operationFailed("A chat cannot be removed and have its pasted images removed in one cleanup.") }
        var digests: [String: String] = [:]
        for item in selected {
            try Task.checkCancellation()
            try validate(item, in: .live)
            digests[item.id] = try fingerprint(item, in: .live)
        }
        return .init(id: UUID(), items: selected, home: home, userHome: userHome, digests: digests)
    }

    public func validate(_ plan: ConversationCleanupPlan) throws {
        guard plan.home == home, plan.userHome == userHome else { throw AIManagerError.sourceChanged }
        for item in plan.items {
            try validate(item, in: .live)
            guard try fingerprint(item, in: .live) == plan.digests[item.id] else { throw AIManagerError.sourceChanged }
        }
    }

    public func moveToTrash(_ plan: ConversationCleanupPlan) throws -> ConversationCleanupBatch {
        try validate(plan)
        guard !plan.items.isEmpty else { throw AIManagerError.operationFailed("Select items before reviewing Cleanup.") }
        var batch = ConversationCleanupBatch(id: plan.id, createdAt: Date(), items: plan.items,
            home: home, userHome: userHome, digests: plan.digests, phase: "moving")
        try prepareDirectory(trash)
        let folder = batchFolder(batch.id)
        guard !CoreSupport.entryExists(folder) else { throw AIManagerError.sourceChanged }
        try prepareDirectory(folder)
        try save(batch)
        for item in batch.items {
            try Task.checkCancellation()
            try validate(item, in: .live)
            guard try fingerprint(item, in: .live) == batch.digests[item.id] else { throw AIManagerError.sourceChanged }
            if item.isRewrite {
                try rewrite(item, in: folder, batch: &batch)
                continue
            }
            // Companions move first and the item last, so an item in the trash is always complete.
            for path in item.allPaths.reversed() {
                guard CoreSupport.entryExists(try url(item.root, path)) else { continue }
                try moveAside(item, path, into: folder)
            }
        }
        batch.phase = "trashed"
        try save(batch)
        return batch
    }

    private func moveAside(_ item: CleanupItem, _ path: String, into folder: URL) throws {
        let source = try url(item.root, path)
        let target = folder.appending(path: "\(item.root)/\(path)")
        try prepareDirectory(target.deletingLastPathComponent())
        var info = stat()
        guard lstat(target.deletingLastPathComponent().path, &info) == 0, UInt64(info.st_dev) == item.device else {
            throw AIManagerError.operationFailed("Cleanup trash must be on the same disk as the items.")
        }
        try files.moveItem(at: source, to: target)
    }

    /// Writes the shrunk transcript beside the original, moves the original to the trash, then renames the
    /// copy into place. Restore puts the original back over the copy.
    private func rewrite(_ item: CleanupItem, in folder: URL, batch: inout ConversationCleanupBatch) throws {
        let source = try url(item.root, item.path)
        let temporary = source.deletingLastPathComponent().appending(path: ".\(source.lastPathComponent).switch-tmp")
        if CoreSupport.entryExists(temporary) { try files.removeItem(at: temporary) }
        let saved = try ImageStripper.rewrite(source, to: temporary)
        do {
            guard saved > 0 else { throw CancellationError() }
            // The chat must not change while the copy is written.
            guard try fingerprint(item, in: .live) == batch.digests[item.id] else { throw AIManagerError.sourceChanged }
            try moveAside(item, item.path, into: folder)
        } catch {
            try? files.removeItem(at: temporary)
            if error is CancellationError { return }
            throw error
        }
        guard rename(temporary.path, source.path) == 0 else {
            let code = errno
            try? files.moveItem(at: folder.appending(path: "\(item.root)/\(item.path)"), to: source)
            try? files.removeItem(at: temporary)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        batch.digests[item.id + "@after"] = try fingerprint(item, in: .live)
        try save(batch)
    }

    // Existence on each side reconciles an interrupted move without replaying deletion.
    public func batches() throws -> [ConversationCleanupBatch] {
        guard CoreSupport.entryExists(trash) else { return [] }
        try validateAncestors(trash, within: home)
        return try files.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil).compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
            var batch = try load(id)
            guard batch.phase != "finished" else { return nil }
            batch.items = try batch.items.filter { item in
                guard CoreSupport.entryExists(folder.appending(path: "\(item.root)/\(item.path)")) else { return false }
                try validate(item, in: .trash(folder))
                guard try batch.phase == "restoring" || fingerprint(item, in: .trash(folder)) == batch.digests[item.id] else { throw AIManagerError.sourceChanged }
                return true
            }
            return batch.items.isEmpty ? nil : batch
        }.sorted { $0.createdAt > $1.createdAt }
    }

    public func restore(_ id: UUID) throws {
        var batch = try load(id)
        let folder = batchFolder(id)
        let present = batch.items.filter { CoreSupport.entryExists(folder.appending(path: "\($0.root)/\($0.path)")) }
        // Check every collision before restoring anything.
        for item in present {
            try validate(item, in: .trash(folder))
            guard try batch.phase == "restoring" || fingerprint(item, in: .trash(folder)) == batch.digests[item.id] else { throw AIManagerError.sourceChanged }
            for path in item.allPaths where CoreSupport.entryExists(folder.appending(path: "\(item.root)/\(path)")) {
                let destination = try url(item.root, path)
                if CoreSupport.entryExists(destination) {
                    // A shrunk chat gives way to its original, but only while it is still the copy Switch made.
                    guard item.isRewrite, path == item.path, let after = batch.digests[item.id + "@after"],
                          try fingerprint(item, in: .live) == after else { throw AIManagerError.sourceChanged }
                }
                try validateAncestors(destination.deletingLastPathComponent(), within: root(item.root))
            }
        }
        batch.phase = "restoring"
        try save(batch)
        for item in present {
            for path in item.allPaths.reversed() {
                let source = folder.appending(path: "\(item.root)/\(path)")
                guard CoreSupport.entryExists(source) else { continue }
                let destination = try url(item.root, path)
                try prepareDirectory(destination.deletingLastPathComponent(), within: root(item.root))
                if item.isRewrite, CoreSupport.entryExists(destination) {
                    guard rename(source.path, destination.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                } else {
                    try files.moveItem(at: source, to: destination)
                }
            }
        }
        try finish(&batch)
    }

    public func permanentlyRemove(_ id: UUID) throws {
        var batch = try load(id)
        let folder = batchFolder(id)
        for item in batch.items where CoreSupport.entryExists(folder.appending(path: "\(item.root)/\(item.path)")) {
            try validate(item, in: .trash(folder))
            guard try fingerprint(item, in: .trash(folder)) == batch.digests[item.id] else { throw AIManagerError.sourceChanged }
        }
        batch.phase = "removing"
        try save(batch)
        for item in batch.items {
            for path in item.allPaths {
                let target = folder.appending(path: "\(item.root)/\(path)")
                guard CoreSupport.entryExists(target) else { continue }
                try validateAncestors(target.deletingLastPathComponent(), within: folder)
                try files.removeItem(at: target)
            }
        }
        try finish(&batch)
    }

    private func finish(_ batch: inout ConversationCleanupBatch) throws {
        batch.phase = "finished"
        batch.items = []
        batch.digests = [:]
        try save(batch)
    }

    // MARK: Paths

    private enum Place { case live, trash(URL) }

    private func batchFolder(_ id: UUID) -> URL { trash.appending(path: id.uuidString) }
    private func root(_ index: Int) -> URL { index == 0 ? home : userHome }

    private func url(_ rootIndex: Int, _ path: String) throws -> URL {
        guard [0, 1].contains(rootIndex), CleanupGuard.acceptable(path) else {
            throw AIManagerError.unsafePath("Cleanup does not accept this path.")
        }
        return root(rootIndex).appending(path: path)
    }

    private func place(_ item: CleanupItem, _ path: String, _ place: Place) throws -> (URL, URL) {
        switch place {
        case .live: return (try url(item.root, path), root(item.root))
        case .trash(let folder):
            guard CleanupGuard.acceptable(path) else { throw AIManagerError.unsafePath("Cleanup does not accept this path.") }
            return (folder.appending(path: "\(item.root)/\(path)"), folder)
        }
    }

    private func validate(_ item: CleanupItem, in where_: Place) throws {
        guard item.protectedReason == nil else { throw AIManagerError.unsafePath("Cleanup found a protected item: \(item.title)") }
        for path in item.allPaths {
            let (target, within) = try place(item, path, where_)
            if path != item.path, !CoreSupport.entryExists(target) { continue }
            try validateAncestors(target.deletingLastPathComponent(), within: within)
            var info = stat()
            guard lstat(target.path, &info) == 0, info.st_uid == getuid() else {
                throw AIManagerError.unsafePath("Cleanup found a missing or foreign item: \(target.lastPathComponent)")
            }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR else {
                throw AIManagerError.unsafePath("Cleanup found a linked or unsafe item: \(target.lastPathComponent)")
            }
            if kind == S_IFREG, info.st_nlink != 1 {
                throw AIManagerError.unsafePath("Cleanup found a linked or unsafe item: \(target.lastPathComponent)")
            }
            if path == item.path {
                guard UInt64(info.st_ino) == item.inode, UInt64(info.st_dev) == item.device else { throw AIManagerError.sourceChanged }
                if case .live = where_, item.isRewrite {
                    guard kind == S_IFREG else { throw AIManagerError.unsafePath("Cleanup found a linked or unsafe item: \(target.lastPathComponent)") }
                    guard Date().timeIntervalSince1970 - CleanupScanner.modified(info) >= ConversationCleanup.rewriteQuietPeriod else {
                        throw AIManagerError.operationFailed("A chat changed in the last hour, so its images stay. Try again later.")
                    }
                }
            }
        }
    }

    /// Size, modified time and inode of every entry below the item (links are never followed).
    private func fingerprint(_ item: CleanupItem, in where_: Place) throws -> String {
        var lines: [String] = []
        for path in item.allPaths {
            let (target, _) = try place(item, path, where_)
            guard CoreSupport.entryExists(target) else { continue }
            try describe(target, name: path, into: &lines)
        }
        return CoreSupport.digest(Data(lines.joined(separator: "\n").utf8))
    }

    private func describe(_ url: URL, name: String, into lines: inout [String]) throws {
        try Task.checkCancellation()
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw AIManagerError.sourceChanged }
        lines.append("\(name)|\(info.st_mode & S_IFMT)|\(info.st_size)|\(CleanupScanner.modified(info))|\(info.st_ino)")
        if info.st_mode & S_IFMT == S_IFDIR {
            for child in try files.contentsOfDirectory(atPath: url.path).sorted() {
                try describe(url.appending(path: child), name: name + "/" + child, into: &lines)
            }
        }
    }

    private func load(_ id: UUID) throws -> ConversationCleanupBatch {
        let folder = batchFolder(id)
        let manifest = folder.appending(path: "manifest.json")
        try validateAncestors(folder, within: home)
        var info = stat()
        guard lstat(manifest.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
            throw AIManagerError.unsafePath("Cleanup found a linked or unsafe journal.")
        }
        let batch = try JSONDecoder().decode(ConversationCleanupBatch.self, from: Data(contentsOf: manifest))
        guard batch.id == id, batch.home == home, batch.userHome == userHome,
              Set(batch.items.map(\.id)).count == batch.items.count,
              batch.items.allSatisfy({ item in item.allPaths.allSatisfy(CleanupGuard.acceptable) }) else { throw AIManagerError.sourceChanged }
        return batch
    }

    private func save(_ batch: ConversationCleanupBatch) throws {
        let folder = batchFolder(batch.id)
        try validateAncestors(folder, within: home)
        try CoreSupport.atomicWrite(JSONEncoder().encode(batch), to: folder.appending(path: "manifest.json"), fileManager: files)
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

    private func prepareDirectory(_ url: URL, within root: URL? = nil) throws {
        let root = root ?? home
        try validateAncestors(url, within: root)
        try CoreSupport.privateDirectory(url, fileManager: files)
        try validateAncestors(url, within: root)
    }
}
