import Foundation
import AIManagerCore

// shortcut: written from view-model.md 4.4 beside the Mac copies in ProviderUsageStore.swift (ProviderUsageState,
// ProviderUsagePolicy, ProviderUsageCache.withTimeout) and AccountViewModel.automaticUsageRefreshIsDue, delete those
// when the Mac app adopts SwitchAppModel.

/// Last known usage of one non-Codex account, plus the state of its latest check.
public struct ProviderUsageState: Equatable, Sendable {
    public var usage: ProviderUsage?
    public var error: String?
    /// The provider error behind `error`, so the cadence can honor a rate limit's retry time.
    public var providerError: ProviderError?
    public var needsSignIn = false
    public var needsKeychainAccess = false
    /// End of the latest attempt, successful or not.
    public var checkedAt: Date?
    public var isRefreshing = false

    public init() {}

    /// Last good values kept after a failed check.
    public var isOutdated: Bool { usage != nil && error != nil }
}

/// Other providers: 300 s timer, 300 s failure cooldown (longer when Retry-After says so), 60 s timeout, 4 at once.
public enum ProviderUsagePolicy {
    public static let interval: TimeInterval = 5 * 60
    public static let failureCooldown: TimeInterval = 5 * 60
    public static let fetchTimeout: TimeInterval = 60
    public static let maxConcurrent = 4
    public static let timeoutMessage = "The usage check timed out. Switch will retry later."

    /// `onCadence` is the fixed timer tick: it ignores the age of the cache but not a failure.
    public static func isDue(_ state: ProviderUsageState?, onCadence: Bool, now: Date) -> Bool {
        guard let state else { return true }
        if state.isRefreshing { return false }
        if state.error != nil, let checkedAt = state.checkedAt,
           !ProviderRefreshPolicy.isDue(lastError: state.providerError, failedAt: checkedAt, now: now,
                                        cooldown: failureCooldown) { return false }
        if onCadence { return true }
        guard let fetchedAt = state.usage?.fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) >= interval
    }

    /// Runs `operation` and fails with a retryable network error when it takes longer than `seconds` on `clock`.
    public static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval, clock: any AppClock, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await clock.sleep(seconds: seconds)
                throw ProviderError.network(timeoutMessage)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }
}

/// Codex: 180 s timer, due after 180 s age, no retry within 300 s of a failure, one account at a time.
public enum CodexUsagePolicy {
    public static let interval: TimeInterval = 3 * 60
    public static let failureCooldown: TimeInterval = 5 * 60

    public static func isDue(fetchedAt: Date?, failedAt: Date?, onCadence: Bool, now: Date) -> Bool {
        if let failedAt, now.timeIntervalSince(failedAt) < failureCooldown { return false }
        if onCadence { return true }
        guard let fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) >= interval
    }
}
