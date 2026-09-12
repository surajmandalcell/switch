import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

#if canImport(Darwin)
import Darwin
#else
import Glibc

@_silgen_name("renameat2")
private func linuxRenameAt2(
    _ oldDirectory: Int32,
    _ oldPath: UnsafePointer<CChar>,
    _ newDirectory: Int32,
    _ newPath: UnsafePointer<CChar>,
    _ flags: UInt32
) -> Int32
#endif

@inline(__always)
func withAutoreleasePool<T>(_ body: () throws -> T) rethrows -> T {
#if canImport(ObjectiveC)
    return try autoreleasepool(invoking: body)
#else
    return try body()
#endif
}

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
            try withAutoreleasePool {
                guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { ended = true; return }
                hasher.update(data: data)
            }
            if ended { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func privateDirectory(_ url: URL, fileManager: FileManager) throws {
        if entryExists(url),
           (try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw AIManagerError.unsafePath("private directory is a symbolic link: \(url.path)")
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw AIManagerError.unsafePath("private path is not a directory: \(url.path)")
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func atomicWrite(_ data: Data, to destination: URL, permissions: Int = 0o600, fileManager: FileManager) throws {
        try privateDirectory(destination.deletingLastPathComponent(), fileManager: fileManager)
        let temporary = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        guard rename(temporary.path, destination.path) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    static func publish(_ staged: URL, replacing destination: URL, fileManager: FileManager) throws {
        guard entryExists(destination) else {
            guard rename(staged.path, destination.path) == 0 else { throw posixError() }
            return
        }

#if os(Linux)
        let result = staged.path.withCString { stagedPath in
            destination.path.withCString { destinationPath in
                linuxRenameAt2(AT_FDCWD, stagedPath, AT_FDCWD, destinationPath, 2)
            }
        }
#else
        let result = renamex_np(staged.path, destination.path, UInt32(RENAME_SWAP))
#endif
        guard result == 0 else { throw posixError() }
        try fileManager.removeItem(at: staged)
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
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
        if CoreSupport.entryExists(url),
           (try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw AIManagerError.unsafePath("operation lock is a symbolic link")
        }
        let opened = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard opened >= 0 else { throw AIManagerError.operationFailed("Could not open the operation lock.") }
        var info = stat()
        guard fstat(opened, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              fchmod(opened, S_IRUSR | S_IWUSR) == 0 else {
            close(opened)
            throw AIManagerError.operationFailed("The operation lock is not a private regular file.")
        }
        descriptor = opened
    }

    deinit { close(descriptor) }

    func withLock<T>(_ operation: () throws -> T) throws -> T {
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw AIManagerError.operationFailed("Another IIA Directeur process is changing accounts.") }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
