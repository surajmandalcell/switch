import Foundation

/// Drives every engine timer (architecture.md 3.1), so cadence tests run in virtual time.
/// Named `AppClock` because the standard library already has a `Clock` protocol.
public protocol AppClock: Sendable {
    var now: Date { get }
    /// Throws `CancellationError` when the task is cancelled.
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemClock: AppClock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// A clock that moves only when a test calls `advance`.
public final class ManualClock: AppClock, @unchecked Sendable {
    private struct Sleeper {
        let id: UUID
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: Date
    private var sleepers: [Sleeper] = []

    public init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Tasks parked in `sleep`; tests wait for this before they advance.
    public var sleeperCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.count
    }

    public func sleep(seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                let deadline = current.addingTimeInterval(seconds)
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if seconds <= 0 {
                    lock.unlock()
                    continuation.resume()
                } else {
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let index = sleepers.firstIndex { $0.id == id }
            let sleeper = index.map { sleepers.remove(at: $0) }
            lock.unlock()
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed, earliest first.
    public func advance(seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        let due = sleepers.filter { $0.deadline <= current }.sorted { $0.deadline < $1.deadline }
        sleepers.removeAll { $0.deadline <= current }
        lock.unlock()
        due.forEach { $0.continuation.resume() }
    }
}
