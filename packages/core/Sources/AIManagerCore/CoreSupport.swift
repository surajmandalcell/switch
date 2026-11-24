import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import CRT
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

public enum PlatformText {
    /// The machine in user-facing text: "this Mac" on macOS, "this computer" on Linux and Windows.
    public static let thisComputer: String = {
#if os(macOS)
        return "this Mac"
#else
        return "this computer"
#endif
    }()

    /// Where the app icon lives in user-facing text: "menu bar" on macOS, "notification area" on Windows,
    /// "system tray" on Linux.
    public static let trayName: String = {
#if os(macOS)
        return "menu bar"
#elseif os(Windows)
        return "notification area"
#else
        return "system tray"
#endif
    }()

    /// `trayName` as a heading: "Menu bar", "Notification area", "System tray".
    public static let trayTitle = trayName.prefix(1).uppercased() + trayName.dropFirst()

    /// The app icon there: the Mac keeps its hyphenated "menu-bar icon".
    public static let trayIcon: String = {
#if os(macOS)
        return "menu-bar icon"
#else
        return "\(trayName) icon"
#endif
    }()

    /// The sign-in CLI check failed; the text says so, apart from a terminal that could not open.
    public static func missingCommand(_ name: String, _ command: String) -> String {
        "\(name) sign-in needs the `\(command)` command, and Switch did not find it on \(thisComputer). "
            + "Install it, or add its folder to PATH, then try again."
    }
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
        return candidateParts.count >= parentParts.count && zip(candidateParts, parentParts).allSatisfy(equalPathNames)
    }

    static func sameLocation(_ first: URL, _ second: URL) -> Bool {
        canonical(first).pathComponents.elementsEqual(canonical(second).pathComponents, by: equalPathNames)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `cancellable`: check Cancel before every chunk (backup work), so a large file cannot hold up a cancelled run.
    static func digest(file url: URL, cancellable: Bool = false) throws -> String {
        // open(), not FileHandle(forReadingFrom:): Foundation on Windows cannot open a path over 260 characters.
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if cancellable { try Task.checkCancellation() }
            var ended = false
            try withAutoreleasePool {
                guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { ended = true; return }
                hasher.update(data: data)
            }
            if ended { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Copies a regular file to a new owner-only `target` in 1 MB chunks and returns the same digest as
    /// `digest(file:)`, so a backup reads each file once. Cancel is checked before every chunk: a large file
    /// cannot hold up a cancelled run.
    static func copyHashing(_ source: URL, to target: URL) throws -> String {
        let input = open(source.path, O_RDONLY | O_CLOEXEC)
        guard input >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let reader = FileHandle(fileDescriptor: input, closeOnDealloc: true)
        defer { try? reader.close() }
        let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard output >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let writer = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        defer { try? writer.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            var ended = false
            try withAutoreleasePool {
                guard let data = try reader.read(upToCount: 1_048_576), !data.isEmpty else { ended = true; return }
                hasher.update(data: data)
                try writer.write(contentsOf: data)
            }
            if ended { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func privateDirectory(_ url: URL, fileManager: FileManager, preserveExistingACL: Bool = false) throws {
#if os(Windows)
        try WindowsFiles.privateDirectory(url, preserveExistingACL: preserveExistingACL)
#else
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
#endif
    }

    static func atomicWrite(_ data: Data, to destination: URL, permissions: Int = 0o600, fileManager: FileManager,
                            beforeReplace: () throws -> Void = {}) throws {
#if os(Windows)
        // Always owner-only: Windows has no group or other bits to honour `permissions` with.
        try privateDirectory(destination.deletingLastPathComponent(), fileManager: fileManager, preserveExistingACL: true)
        try WindowsFiles.writePrivate(data, to: destination, beforeReplace: beforeReplace)
#else
        try privateDirectory(destination.deletingLastPathComponent(), fileManager: fileManager)
        let temporary = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        defer { if entryExists(temporary) { try? fileManager.removeItem(at: temporary) } }
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        try beforeReplace()
        guard rename(temporary.path, destination.path) == 0 else {
            throw posixError()
        }
#endif
    }

    static func publish(_ staged: URL, replacing destination: URL, fileManager: FileManager) throws {
        guard entryExists(destination) else {
            guard rename(staged.path, destination.path) == 0 else { throw posixError() }
            return
        }

        try exchange(staged, destination)
        try fileManager.removeItem(at: staged)
    }

    static func exchange(_ first: URL, _ second: URL) throws {
#if os(Windows)
        try WindowsFiles.exchange(first, second)
#else
#if os(Linux)
        let result = first.path.withCString { stagedPath in
            second.path.withCString { destinationPath in
                linuxRenameAt2(AT_FDCWD, stagedPath, AT_FDCWD, destinationPath, 2)
            }
        }
#else
        let result = renamex_np(first.path, second.path, UInt32(RENAME_SWAP))
#endif
        guard result == 0 else { throw posixError() }
#endif
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    static func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("\0") && normalizedPathSeparators(path)
            .split(separator: "/", omittingEmptySubsequences: false).allSatisfy(isSafeRelativeComponent)
    }

    static func entryExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}

private enum OperationLockTaskContext {
    @TaskLocal static var heldTokens: Set<UUID> = []
}

final class OperationLock: @unchecked Sendable {
    private let descriptor: Int32
    private let token = UUID()
    private var isHeld = false

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

    /// Takes the lock until this object goes away (or the process exits); false when another holder has it.
    func hold() -> Bool { flock(descriptor, LOCK_EX | LOCK_NB) == 0 }

    func withLock<T>(_ operation: () throws -> T) throws -> T {
        if OperationLockTaskContext.heldTokens.contains(token) { return try operation() }
        guard !isHeld else { throw AIManagerError.operationFailed("Another Switch process is changing accounts.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw AIManagerError.operationFailed("Another Switch process is changing accounts.") }
        isHeld = true
        defer {
            isHeld = false
            flock(descriptor, LOCK_UN)
        }
        return try OperationLockTaskContext.$heldTokens.withValue(
            OperationLockTaskContext.heldTokens.union([token]),
            operation: operation
        )
    }

    func withAsyncLock<T>(_ operation: () async throws -> T) async throws -> T {
        if OperationLockTaskContext.heldTokens.contains(token) { return try await operation() }
        guard !isHeld else { throw AIManagerError.operationFailed("Another Switch process is changing accounts.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw AIManagerError.operationFailed("Another Switch process is changing accounts.") }
        isHeld = true
        defer {
            isHeld = false
            flock(descriptor, LOCK_UN)
        }
        return try await OperationLockTaskContext.$heldTokens.withValue(
            OperationLockTaskContext.heldTokens.union([token]),
            operation: operation
        )
    }
}
