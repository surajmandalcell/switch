import CryptoKit
import Darwin
import Foundation

enum CoreSupport {
    static let settings = ["config.toml", "AGENTS.md", "agents", "rules", "context", "skills", "hooks.json"]
    static let historyDirectories = ["sessions", "archived_sessions"]
    static let historyIndexes = ["history.jsonl", "session_index.jsonl"]
    static let sharedHistoryEntries = historyDirectories + historyIndexes
    static let maxAuthBytes = 2 * 1_024 * 1_024

    static func home(for selected: URL) -> URL {
        selected.lastPathComponent == "auth.json" ? selected.deletingLastPathComponent() : selected
    }

    static func canonical(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        var existing = standardized
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            suffix.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath().standardizedFileURL
        for component in suffix { resolved.append(path: component) }
        return resolved.standardizedFileURL
    }

    static func isContained(_ candidate: URL, by parent: URL) -> Bool {
        let candidateParts = canonical(candidate).pathComponents
        let parentParts = canonical(parent).pathComponents
        return candidateParts.count >= parentParts.count && Array(candidateParts.prefix(parentParts.count)) == parentParts
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(file url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            var ended = false
            try autoreleasepool {
                guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { ended = true; return }
                hasher.update(data: data)
            }
            if ended { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func privateDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func atomicWrite(_ data: Data, to destination: URL, permissions: Int = 0o600, fileManager: FileManager) throws {
        try privateDirectory(destination.deletingLastPathComponent(), fileManager: fileManager)
        let temporary = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    static func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    static func entryExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}

final class OperationLock: @unchecked Sendable {
    private let descriptor: Int32

    init(at url: URL, fileManager: FileManager) throws {
        try CoreSupport.privateDirectory(url.deletingLastPathComponent(), fileManager: fileManager)
        descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AIManagerError.operationFailed("Could not open the operation lock.") }
    }

    deinit { close(descriptor) }

    func withLock<T>(_ operation: () throws -> T) throws -> T {
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw AIManagerError.operationFailed("Another AI Manager process is changing accounts.") }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
