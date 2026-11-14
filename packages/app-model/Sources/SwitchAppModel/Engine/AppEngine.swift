import Foundation
import AIManagerCore

public enum AppEngineError: Error, Equatable, LocalizedError {
    /// Another action holds the lane. The Mac app drops the second action; the helper answers -32001.
    case busy
    /// The private data folder could not open.
    case unavailable
    /// A plan or flow id that was replaced, discarded, or never existed (-32004).
    case stale
    /// Not available on this platform in this version (-32005).
    case unsupported(String)
    /// No backup set, snapshot, or cleanup batch has that id (-32003).
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let text): text
        case .busy: "Switch is busy with another action."
        case .unavailable: AppEngine.unavailableText
        case .stale: "That plan expired or was replaced. Review it again."
        case .unsupported(let reason): reason
        }
    }
}

/// The shared app logic behind every GUI (architecture.md 3). It owns the topic values, runs the single action
/// lane, and publishes committed changes through `changes`, at most one per topic per 100 ms.
public actor AppEngine {
    public static let coalesceInterval: TimeInterval = 0.1
    static let unavailableText = "Switch is unavailable until its private data folder can be opened."

    /// Committed changes, in order. One consumer (the helper's notification writer).
    public nonisolated let changes: AsyncStream<TopicChange>
    private let continuation: AsyncStream<TopicChange>.Continuation

    let manager: AccountManager?
    let paths: ManagerPaths
    let clock: any AppClock

    private struct Slot {
        var rev = 0
        var value: any TopicValue
        var bytes: Data
        var pending: (value: any TopicValue, bytes: Data)?
        var flushScheduled = false
    }

    private var slots: [Topic: Slot] = [:]
    private(set) var app: AppStateValue
    private(set) var notices = NoticesValue()
    private var started = false
    private var stopped = false
    var timers: [Task<Void, Never>] = []

    // Accounts and usage (Accounts.swift).
    let codexCache: CodexUsageStatisticsCache?
    var status: ManagerStatus?
    var codexUsage: [UUID: CachedCodexAccountUsage] = [:]
    var codexRefreshing: UUID?
    var providerUsage: [UUID: ProviderUsageState] = [:]
    // Overview history (History.swift).
    var history: UsageHistorySnapshot?
    var historyEngine: UsageHistory?
    var historyLoadedAt: Date?

    /// Isolated runs (tests, demos) read no live usage, as on the Mac. Tests with synthetic providers turn it on.
    var refreshesInIsolation = false
    var refreshes: Bool { paths.isolationRoot == nil || refreshesInIsolation }
    func setRefreshesInIsolation(_ value: Bool) { refreshesInIsolation = value }

    // Settings (Settings.swift).
    let settings: any SettingsStore
    // Account lifecycle (Lifecycle.swift): the one import plan under review.
    var importPlan: ImportPlan?

    /// `manager` is nil when the private data folder cannot open; `app.isUnavailable` is then true.
    /// `codexCache` is the Codex usage SQLite cache the helper shares with its read methods. Without `settings`
    /// the engine opens `settings.json` at `JSONFileSettingsStore.location`.
    public init(manager: AccountManager?, paths: ManagerPaths, clock: any AppClock = SystemClock(),
                codexCache: CodexUsageStatisticsCache? = nil, settings: (any SettingsStore)? = nil) {
        self.manager = manager
        self.paths = paths
        self.clock = clock
        self.codexCache = codexCache
        self.settings = settings ?? JSONFileSettingsStore(url: JSONFileSettingsStore.location(
            paths: paths, environment: ProcessInfo.processInfo.environment))
        (changes, continuation) = AsyncStream.makeStream(of: TopicChange.self)
        app = AppStateValue(isUnavailable: manager == nil, dataLocation: paths.applicationSupport.path)
        slots[.app] = Self.slot(app)
        slots[.notices] = Self.slot(notices)
        slots[.accounts] = Self.slot(AccountsValue())
        slots[.settings] = Self.slot(Self.settingsValue(self.settings))
    }

    /// Loads the accounts and starts the usage timers once, after the client's `initialized`.
    public func start() async {
        guard !started, !stopped else { return }
        started = true
        if manager == nil { setError(Self.unavailableText) }
        if let notice = (settings as? JSONFileSettingsStore)?.notice { setNotice(notice) }
        await reloadAccounts()
        app.hasLoaded = true
        app.refreshedAt = clock.now
        publish(.app, app)
        if manager != nil { startUsageTimers() }
    }

    /// Cancels every timer and ends `changes`.
    public func stop() {
        stopped = true
        timers.forEach { $0.cancel() }
        timers = []
        continuation.finish()
    }

    /// The committed value and rev of each topic. A change still inside its 100 ms window arrives later as rev + 1.
    public func snapshot(_ topics: [Topic]) -> [Topic: TopicChange] {
        var result: [Topic: TopicChange] = [:]
        for topic in topics {
            guard let slot = slots[topic] else { continue }
            result[topic] = TopicChange(topic: topic, rev: slot.rev, value: slot.value)
        }
        return result
    }

    // MARK: - Action lane

    /// Runs one user action at a time. A second action while one runs throws `busy`. A failure sets
    /// `notices.error` to "failure detail recovery", as the Mac `perform` does, and is rethrown.
    @discardableResult
    public func perform<Result: Sendable>(failure: String? = nil, recovery: String? = nil,
                                          _ operation: @Sendable () async throws -> Result) async throws -> Result {
        guard manager != nil else {
            setError(Self.unavailableText)
            throw AppEngineError.unavailable
        }
        guard !app.isBusy else { throw AppEngineError.busy }
        app.isBusy = true
        publish(.app, app)
        setError(nil)
        defer {
            app.isBusy = false
            publish(.app, app)
        }
        do {
            return try await operation()
        } catch {
            setError([failure, describe(error), recovery].compactMap { $0 }.joined(separator: " "))
            throw error
        }
    }

    func setError(_ text: String?) {
        notices.error = text
        publish(.notices, notices)
    }

    func setNotice(_ text: String?) {
        notices.notice = text
        publish(.notices, notices)
    }

    // MARK: - Publishing

    /// Records a new value. Equal values (same JSON) change nothing; changes inside one window are coalesced.
    func publish(_ topic: Topic, _ value: any TopicValue) {
        guard !stopped, var slot = slots[topic], let bytes = try? Self.encoder.encode(value) else { return }
        guard bytes != (slot.pending?.bytes ?? slot.bytes) else { return }
        slot.pending = (value, bytes)
        if !slot.flushScheduled {
            slot.flushScheduled = true
            let clock = clock
            timers.removeAll { $0.isCancelled }
            timers.append(Task {
                guard (try? await clock.sleep(seconds: Self.coalesceInterval)) != nil else { return }
                await self.flush(topic)
            })
        }
        slots[topic] = slot
    }

    private func flush(_ topic: Topic) {
        guard !stopped, var slot = slots[topic] else { return }
        slot.flushScheduled = false
        defer { slots[topic] = slot }
        guard let pending = slot.pending else { return }
        slot.pending = nil
        guard pending.bytes != slot.bytes else { return }
        slot.rev += 1
        slot.value = pending.value
        slot.bytes = pending.bytes
        continuation.yield(TopicChange(topic: topic, rev: slot.rev, value: pending.value))
    }

    /// Test seam: the newest value of `topic`, committed or still inside its 100 ms window.
    func latest(_ topic: Topic) -> (any TopicValue)? { slots[topic].map { $0.pending?.value ?? $0.value } }

    /// Test seam: a flush timer for `topic` has not fired yet.
    func isFlushScheduled(_ topic: Topic) -> Bool { slots[topic]?.flushScheduled ?? false }
    var scheduledFlushes: Int { slots.values.filter(\.flushScheduled).count }

    private static func slot(_ value: any TopicValue) -> Slot {
        Slot(value: value, bytes: (try? encoder.encode(value)) ?? Data())
    }

    /// Canonical JSON used only to tell whether a value changed.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
