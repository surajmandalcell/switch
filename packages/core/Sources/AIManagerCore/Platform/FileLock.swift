import Foundation

/// An exclusive lock on a private file, held while this object lives; the OS drops it when the process exits, so a
/// crash leaves no stale lock (plan unit P3, the part the helper needs).
public final class FileLock: @unchecked Sendable {
    private let lock: OperationLock

    /// Nil when another process holds the lock. Throws when the file is unsafe (a link, not owner-only).
    public init?(at url: URL) throws {
        lock = try OperationLock(at: url, fileManager: .default)
        guard lock.hold() else { return nil }
    }
}
