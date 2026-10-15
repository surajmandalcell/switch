import AppKit
import Combine
import Foundation
import AIManagerCore

/// What one day needs, read off the main actor (AccountViewModel.loadUsageDay).
struct OverviewDayInput: Sendable {
    var points: [UsageHistoryPoint]
    /// Nil when no engine could list sessions.
    var sessions: [UsageDaySession]?
    /// Transcripts Conversations still holds, by Codex thread id.
    var threads: [String: ChatThreadSummary]
}

protocol ChatHistoryProviding: Sendable {
    func attachActivityCache(_ cache: CodexUsageStatisticsCache) async
    func refresh(query: String) async throws -> ChatHistorySnapshot
    func search(query: String) async -> ChatHistorySnapshot
    func detail(for id: String) async throws -> ChatThreadDetail?
    func page(for id: String, offset: Int, query: String, filter: ChatMessageFilter) async throws -> ChatThreadDetail?
    func clearCache() async throws
    func cleanupSummaries() async -> [ChatThreadSummary]
    func preserveActivity(for sources: [URL]) async throws
}

extension ChatHistoryProviding {
    func attachActivityCache(_ cache: CodexUsageStatisticsCache) async {}
    func cleanupSummaries() async -> [ChatThreadSummary] { [] }
    func preserveActivity(for sources: [URL]) async throws {
        throw AIManagerError.operationFailed("The activity ledger is unavailable. Conversations were kept.")
    }
    func page(for id: String, offset: Int, query: String, filter: ChatMessageFilter) async throws -> ChatThreadDetail? {
        guard let detail = try await detail(for: id) else { return nil }
        let result = try await ChatMessageSearch.search(detail.messages, query: query, filter: filter)
        let messages = Array(result.messages.dropFirst(offset).prefix(100))
        let next = offset + messages.count
        return ChatThreadDetail(thread: detail.thread, messages: messages, omittedMessageCount: 0,
            matchingMessageCount: result.matchingMessageCount,
            nextOffset: next < result.matchingMessageCount ? next : nil)
    }
}

private struct IndexedChatHistoryProvider: ChatHistoryProviding {
    let index: ChatHistoryIndex

    func attachActivityCache(_ cache: CodexUsageStatisticsCache) async {
        await index.attachActivityCache(cache)
    }

    func refresh(query: String) async throws -> ChatHistorySnapshot {
        try await index.refresh(query: query)
    }

    func search(query: String) async -> ChatHistorySnapshot {
        await index.search(query: query)
    }

    func detail(for id: String) async throws -> ChatThreadDetail? {
        try await index.detail(for: id)
    }

    func page(for id: String, offset: Int, query: String, filter: ChatMessageFilter) async throws -> ChatThreadDetail? {
        try await index.detail(for: id, offset: offset, query: query, filter: filter)
    }

    func clearCache() async throws {
        try await index.clearCache()
    }
    func cleanupSummaries() async -> [ChatThreadSummary] { await index.cleanupSummaries() }
    func preserveActivity(for sources: [URL]) async throws { try await index.preserveActivity(for: sources) }
}

struct RebuildableCacheSizes: Equatable, Sendable {
    let usageBytes: Int64
    let conversationBytes: Int64
}

enum AccountModalMode {
    case add
    case advancedImport
}

@MainActor
final class AccountViewModel: ObservableObject {
    static let usageRefreshInterval: TimeInterval = 3 * 60

    static func automaticUsageRefreshIsDue(
        fetchedAt: Date?,
        failedAt: Date?,
        onCadence: Bool = false,
        now: Date = Date()
    ) -> Bool {
        if let failedAt, now.timeIntervalSince(failedAt) < 5 * 60 { return false }
        if onCadence { return true }
        guard let fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) >= usageRefreshInterval
    }

    #if AI_MANAGER_PREVIEW
    enum Scenario { case demo, empty, allStates, historyStress }
    #endif

    @Published var status: ManagerStatus? {
        didSet { rebuildAccountPresentations() }
    }
    @Published var selectedAccountID: UUID? {
        didSet {
            if let oldValue, oldValue != selectedAccountID { previousSelectedAccountID = oldValue }
        }
    }
    private var previousSelectedAccountID: UUID?
    @Published var discoveries: [DiscoveredSource] = []
    @Published var isBusy = false
    @Published var refreshedAt: Date?
    @Published var errorMessage: String?
    /// The result of the last action. No page renders it: the app posts it as a macOS notification.
    @Published var notice: String? {
        didSet { if let notice { postMessage(notice) } }
    }
    /// Delivers a message to the user. Only the app installs one; checks and Preview leave it nil.
    var messagePoster: ((String) -> Void)?
    @Published var showImport = false
    @Published var accountModalMode: AccountModalMode = .add
    @Published var providers: [ProviderDescriptor] = AccountManager.providerCatalog
    @Published var pendingLoginSessions: [AccountLoginSession] = []
    @Published var accountLoginSession: AccountLoginSession?
    @Published var accountLoginState: AccountLoginState?
    @Published var accountLoginMessage: String?
    @Published private(set) var signInAccountID: UUID?
    @Published var selectedProviderID: ProviderID = .codex
    /// Providers whose login is already present on this Mac, found when Add Account opens.
    @Published private(set) var signedInProviderIDs: Set<ProviderID> = []
    @Published var importMode: ImportMode = .authOnly
    @Published var selectedSourceID: String?
    @Published var importPlan: ImportPlan?
    @Published var conflictChoices: [String: ConflictChoice] = [:]
    @Published var importResult: ImportResult?
    @Published var accountHistory: [UUID: HistorySummary] = [:]
    @Published private(set) var accountUsage: [UUID: CachedCodexAccountUsage] = [:]
    @Published private(set) var usageSnapshots: [UUID: CodexAccountUsageSnapshot] = [:] {
        didSet { rebuildAccountPresentations() }
    }
    @Published private(set) var retainedDailyUsage: [UUID: [CodexDailyUsageSnapshot]] = [:]
    @Published private(set) var apiPrice: CodexAPIPrice?
    @Published private(set) var usageRefreshAccountID: UUID?
    @Published private(set) var usageError: String?
    /// Usage of every account whose provider is not Codex. Codex keeps its own pipeline above.
    @Published private(set) var providerUsage: [UUID: ProviderUsageState] = [:] {
        didSet { rebuildAccountPresentations() }
    }
    @Published private(set) var accountWindows: [UUID: [UsageWindow]] = [:]
    private var presentationPreferences: AnyCancellable?
    private var presentationHiddenRows: [UUID: String] = [:]
    /// Last good incident of each provider that has a saved account. Empty when status checks are off.
    @Published private(set) var providerStatus: [ProviderID: ProviderStatusEntry] = [:]
    /// Local Claude Code usage across all profiles, from the log scan.
    @Published private(set) var claudeActivity: ClaudeActivitySummary?
    @Published private(set) var isClaudeActivityLoading = false
    /// A year of daily usage for the Overview charts. Nil until the first load ends.
    @Published private(set) var usageHistory: UsageHistorySnapshot?
    /// Counts loads, so a page can tell a new snapshot from the one it drew.
    @Published private(set) var usageHistoryVersion = 0
    @Published private(set) var claudeShellIntegrationOn = false
    @Published private(set) var claudeShellIntegrationError: String?
    @Published private(set) var chatHistory = ChatHistorySnapshot()
    @Published private(set) var selectedChatID: String? {
        didSet { if selectedChatID != oldValue { ChatPlace.saveSelected(selectedChatID) } }
    }
    @Published private(set) var selectedChat: ChatThreadDetail?
    /// The Markdown blocks of every loaded message, parsed off the main actor together with the page,
    /// so a row never shows plain text first and then changes height.
    @Published private(set) var chatPresentations: [String: ChatMessagePresentation] = [:]
    @Published private(set) var isChatHistoryLoading = false
    @Published private(set) var isChatPageLoading = false
    private var selectedChatQuery = ""
    private var selectedChatFilter: ChatMessageFilter = .all
    @Published private(set) var isChatLoading = false
    @Published private(set) var chatHistoryError: String?
    @Published private(set) var isUnavailable = false
    @Published private(set) var hasLoaded = false

    let paths: ManagerPaths
    /// Maintenance: the chosen source, backup sets, schedule, and recent snapshots.
    lazy var maintenance = MaintenanceStore(model: self)
    private let manager: AccountManager?
    private var usageCache: CodexUsageStatisticsCache?
    private let usageDatabaseURL: URL?
    private let pricingResolver: CodexAPIPricingResolver?
    private var didPrepareUsageCache = false
    private let providerUsageCacheURL: URL?
    private var providerUsageCacheLoaded = false
    private let statusPoller = ProviderStatusPoller()
    private let claudeCostCacheURL: URL?
    private let claudePricing: ClaudePricingSource?
    private var usageErrorAccountID: UUID?
    private var usageHistoryLoadedAt: Date?
    private var isUsageHistoryLoading = false
    /// The engine behind `usageHistory`; the day sheet asks it for the sessions of one day.
    private var usageEngine: UsageHistory?
    private let chatHistoryProvider: (any ChatHistoryProviding)?
    private let chatHistoryMonitor: (any ChatHistoryMonitoring)?
    #if AI_MANAGER_PREVIEW
    private var scenario: Scenario?
    #endif
    private var unavailableReason: String? = nil
    private var actionGeneration = 0
    private var isActivationReloading = false
    private var chatSelectionGeneration = 0
    private var hasScannedChatHistory = false
    private var requestedChatHistoryQuery = ""
    private var appliedChatHistoryQuery: String?
    private var chatDetailTask: Task<ChatThreadDetail?, Error>?

    init(
        paths: ManagerPaths,
        manager injectedManager: AccountManager? = nil,
        chatHistoryProvider injectedChatHistoryProvider: (any ChatHistoryProviding)? = nil,
        chatHistoryMonitor injectedChatHistoryMonitor: (any ChatHistoryMonitoring)? = nil
    ) {
        self.paths = paths
        usageCache = nil
        providerUsageCacheURL = ProviderUsageCache.url(in: paths.applicationSupport)
        usageDatabaseURL = paths.applicationSupport.appending(path: "cache/account-usage.sqlite")
        let pricingCacheURL = paths.applicationSupport.appending(path: "cache/model-pricing.json")
        pricingResolver = CodexAPIPricingResolver(cacheURL: pricingCacheURL)
        claudeCostCacheURL = paths.applicationSupport.appending(path: "claude-cost-cache.json")
        claudePricing = ClaudePricingSource(cacheURL: pricingCacheURL)
        do {
            manager = try injectedManager ?? AccountManager(paths: paths)
            chatHistoryProvider = injectedChatHistoryProvider
                ?? IndexedChatHistoryProvider(index: ChatHistoryIndex(
                    home: paths.sharedRoot,
                    cacheFile: paths.applicationSupport.appending(
                        path: "cache/chat-history-v1.json")))
            chatHistoryMonitor = injectedChatHistoryMonitor
                ?? FSEventChatHistoryMonitor(home: paths.sharedRoot)
        } catch {
            manager = nil
            chatHistoryProvider = nil
            chatHistoryMonitor = nil
            isUnavailable = true
            hasLoaded = true
            unavailableReason = "Switch could not open its private data folder. \(error.localizedDescription)"
            errorMessage = unavailableReason
        }
        // Conversations reopens on the conversation that was selected at quit.
        selectedChatID = ChatPlace.selectedID()
        watchPresentationPreferences()
    }

    #if AI_MANAGER_PREVIEW
    init(scenario: Scenario = .demo, demoPaths: ManagerPaths? = nil) {
        paths = demoPaths ?? DemoData.paths
        manager = nil
        providerUsageCacheURL = nil
        claudeCostCacheURL = nil
        claudePricing = nil
        usageCache = nil
        usageDatabaseURL = nil
        pricingResolver = nil
        didPrepareUsageCache = true
        chatHistoryProvider = nil
        chatHistoryMonitor = nil
        self.scenario = scenario
        reset(to: scenario)
        watchPresentationPreferences()
    }

    var isDemo: Bool { scenario != nil }
    #endif

    var selectedAccount: AccountRecord? {
        status?.accounts.first { $0.id == selectedAccountID }
    }

    private func watchPresentationPreferences() {
        presentationPreferences = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let hidden = self.hiddenPresentationRows()
                if hidden != self.presentationHiddenRows { self.rebuildAccountPresentations() }
            }
    }

    private func hiddenPresentationRows() -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: (status?.accounts ?? []).map {
            ($0.id, UserDefaults.standard.string(forKey: "hiddenUsageRows.\($0.id.uuidString)") ?? "")
        })
    }

    private func rebuildAccountPresentations() {
        presentationHiddenRows = hiddenPresentationRows()
        let next = Dictionary(uniqueKeysWithValues: (status?.accounts ?? []).map {
            ($0.id, makeAccountWindows(for: $0))
        })
        if next != accountWindows { accountWindows = next }
    }

    private func makeAccountWindows(for account: AccountRecord) -> [UsageWindow] {
        if account.verification.state == .needsSignIn { return [] }
        let hidden = Set((presentationHiddenRows[account.id] ?? "").split(separator: "\n").map(String.init))
        if account.identity.providerID == .codex {
            guard let limits = usageSnapshots[account.id]?.rateLimits else { return [] }
            var seen = Set<String>()
            var result: [(window: UsageWindow, bucket: String)] = []
            func append(_ bucket: CodexRateLimitBucketSnapshot, key: String) {
                guard seen.insert(bucket.id ?? key).inserted else { return }
                let name = CodexBucketNaming.title(id: bucket.id, name: bucket.name, model: bucket.model, fallback: key)
                for row in bucket.windowRows(idPrefix: "\(key)/") where !hidden.contains(row.usage.id) {
                    result.append((row.usage, name))
                }
            }
            if let bucket = limits.defaultBucket { append(bucket, key: bucket.id ?? "default") }
            for (key, bucket) in limits.buckets.sorted(by: {
                $0.key.localizedStandardCompare($1.key) == .orderedAscending
            }) { append(bucket, key: key) }
            let titles = result.map(\.window.title)
            return result.map { item in
                var window = item.window
                if titles.filter({ $0 == window.title }).count > 1 { window.title = "\(item.bucket) · \(window.title)" }
                return window
            }
        }
        guard let state = providerUsage[account.id], !state.needsSignIn, let usage = state.usage else { return [] }
        return usage.windows.filter { !hidden.contains($0.id) }
    }

    func load() async {
        defer { hasLoaded = true; maintenance.start() }
        guard let manager else {
            #if AI_MANAGER_PREVIEW
            if status == nil, let scenario { reset(to: scenario) }
            if scenario == nil { reportUnavailable() }
            #else
            reportUnavailable()
            #endif
            return
        }
        await perform(
            failure: "Couldn’t load accounts.",
            recovery: "Refresh after resolving any item shown in Backup."
        ) {
            if hasLoaded {
                try await reloadStatus(using: manager)
            } else {
                apply(try await manager.refreshAccounts(includeDiscoveries: false))
            }
            let newStatus = status!
            if selectedAccountID == nil {
                selectedAccountID = newStatus.firstDefaultAccountID ?? newStatus.accounts.first?.id
            }
        }
        await loadCachedUsage()
        await loadProviderUsageCache()
        await loadClaudeShellIntegration()
        Task { await self.loadAPIPricing() }
        Task { await self.refreshAutomaticUsage() }
        Task { await self.refreshProviderUsage() }
    }

    func reloadAfterActivation() async {
        guard hasLoaded, !showImport, !isBusy, !isActivationReloading, let manager else { return }
        isActivationReloading = true
        defer { isActivationReloading = false }
        do {
            try await reloadStatus(using: manager)
            await loadCachedUsage()
            Task { await self.loadAPIPricing() }
            Task { await self.refreshAutomaticUsage() }
            Task { await self.refreshProviderUsage() }
        } catch {
            errorMessage = "Couldn’t refresh accounts. \(error.localizedDescription)"
        }
    }

    func refresh() async {
        if let manager {
            await perform(failure: "Couldn’t refresh accounts.", recovery: "Try Refresh again.") {
                apply(try await manager.refreshAccounts(includeDiscoveries: false))
                refreshedAt = Date()
                notice = "Accounts refreshed."
            }
            await loadCachedUsage()
            Task { await self.loadAPIPricing() }
            await refreshDefaultUsage()
            await refreshProviderUsage(accountIDs: providerUsageAccountIDs)
            Task { await self.refreshSideChecks(forceClaudeActivity: true) }
            return
        }
        #if AI_MANAGER_PREVIEW
        guard isDemo else { reportUnavailable(); return }
        await perform {
            refreshedAt = Date()
            notice = "Demo data refreshed. Accounts and selections are unchanged."
        }
        #else
        reportUnavailable()
        #endif
    }

    #if AI_MANAGER_PREVIEW
    func reset(to scenario: Scenario = .demo) {
        guard isDemo else { return }
        actionGeneration += 1
        self.scenario = scenario
        let accounts = scenario == .empty
            ? [] : DemoData.accounts + DemoData.serviceAccounts + DemoData.genericAccounts
        var defaultAccountIDs: [String: UUID] = [:]
        for account in accounts where defaultAccountIDs[account.identity.providerID.rawValue] == nil {
            defaultAccountIDs[account.identity.providerID.rawValue] = account.id
        }
        status = ManagerStatus(
            accounts: accounts,
            defaultAccountID: nil,
            defaultAccountIDs: defaultAccountIDs,
            sharedRoot: paths.sharedRoot,
            pendingRecovery: scenario == .allStates
                ? [DemoData.recovery(paths: paths), DemoData.recoveryConflict(paths: paths)] : [],
            linkedSettingsDivergences: scenario == .allStates ? [DemoData.divergence(paths: paths)] : []
        )
        selectedAccountID = accounts.first?.id
        discoveries = scenario == .empty ? [] : DemoData.discoveries
        selectedSourceID = discoveries.first(where: { $0.support == .supportedChatGPT })?.id
        isBusy = false
        refreshedAt = nil
        errorMessage = scenario == .allStates ? "One account needs sign-in before it can be opened." : nil
        notice = scenario == .allStates ? "Demo backup and settings issues are ready to review." : nil
        showImport = false
        accountModalMode = .add
        providers = AccountManager.providerCatalog
        pendingLoginSessions = []
        accountLoginSession = nil
        accountLoginState = nil
        accountLoginMessage = nil
        selectedProviderID = .codex
        importMode = .authOnly
        importPlan = nil
        conflictChoices = [:]
        importResult = nil
        accountHistory = Dictionary(uniqueKeysWithValues: accounts.map {
            ($0.id, HistorySummary(activeTranscripts: 475, archivedTranscripts: 92, hasIndexes: true))
        })
        usageSnapshots = Dictionary(uniqueKeysWithValues: accounts.enumerated().compactMap { index, account in
            account.identity.providerID == .codex
                ? (account.id, DemoData.usage(account: account, offset: index)) : nil
        })
        providerUsage = scenario == .empty ? [:] : DemoData.providerUsageStates
        providerStatus = scenario == .empty || !ProviderStatusPoller.isEnabled() ? [:] : DemoData.providerStatus
        claudeActivity = scenario == .empty ? nil : DemoData.claudeActivity
        // `--overview-loading` and `--overview-empty` render the two states a screenshot cannot reach otherwise.
        let arguments = CommandLine.arguments
        usageHistory = arguments.contains("--overview-loading") ? nil
            : scenario == .empty || arguments.contains("--overview-empty")
            ? UsageHistorySnapshot(points: [], today: DemoData.usageHistory(accounts: []).today)
            : DemoData.usageHistory(accounts: accounts)
        claudeShellIntegrationOn = false
        claudeShellIntegrationError = nil
        accountUsage = [:]
        usageRefreshAccountID = nil
        usageError = nil
        usageErrorAccountID = nil
        apiPrice = CodexAPIPrice(
            model: "gpt-5.6-sol", inputPerMillion: 4,
            cachedInputPerMillion: 0.4, outputPerMillion: 20)
        let demoThreads = scenario == .empty
            ? [] : (scenario == .historyStress ? DemoData.stressChatThreads : DemoData.chatThreads)
        chatHistory = ChatHistorySnapshot(
            threads: demoThreads,
            totalThreadCount: demoThreads.count,
            matchingThreadCount: demoThreads.count)
        selectedChatID = demoThreads.first?.id
        selectedChat = selectedChatID.flatMap(DemoData.chatDetail)
        chatPresentations = Dictionary(uniqueKeysWithValues: (selectedChat?.messages ?? []).compactMap { message in
            (try? ChatMessagePresenter.parse(message)).map { (message.id, $0) }
        })
        isChatHistoryLoading = false
        isChatLoading = false
        chatHistoryError = nil
        hasScannedChatHistory = true
        hasLoaded = true
    }

    /// Preview only: many accounts and a long daily activity history, so the page-switch check
    /// runs against a large dataset.
    func installScaleFixture(accountCount: Int, activityDays: Int) {
        guard isDemo, var next = status else { return }
        let codex = next.accounts.filter { $0.identity.providerID == .codex }
        guard !codex.isEmpty else { return }
        for index in 0..<accountCount {
            var copy = codex[index % codex.count]
            copy.id = UUID()
            copy.identity.email = "scale\(index)@example.test"
            next.accounts.append(copy)
        }
        status = next
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        day.timeZone = TimeZone(secondsFromGMT: 0)
        let days = (0..<activityDays).map { offset in
            CodexDailyUsageSnapshot(
                startDate: day.string(from: Date().addingTimeInterval(-Double(offset) * 86_400)),
                tokens: Int64(40_000 + (offset * 7_919) % 3_000_000))
        }
        for (offset, account) in next.accounts.enumerated() where account.identity.providerID == .codex {
            let base = DemoData.usage(account: account, offset: offset)
            usageSnapshots[account.id] = CodexAccountUsageSnapshot(
                account: base.account, requiresOpenAIAuthentication: base.requiresOpenAIAuthentication,
                rateLimits: base.rateLimits, usage: base.usage, dailyUsage: days, fetchedAt: base.fetchedAt)
            retainedDailyUsage[account.id] = days
            accountHistory[account.id] = HistorySummary(activeTranscripts: 475, archivedTranscripts: 92, hasIndexes: true)
        }
    }
    #endif

    func beginAddAccount() async {
        guard !isUnavailable else { reportUnavailable(); return }
        guard !isBusy else { return }
        resetAccountModal()
        accountModalMode = .add
        showImport = true
        if let pending = pendingLoginSessions.first {
            accountLoginSession = pending
            selectedProviderID = pending.providerID
            accountLoginState = .waitingForLogin
            accountLoginMessage = "Finish the existing sign-in, then check it here."
        }
    }

    /// An account whose saved sign-in no longer works: verification says so, or its usage request did.
    func needsSignIn(_ account: AccountRecord) -> Bool {
        account.verification.state == .needsSignIn || providerUsage[account.id]?.needsSignIn == true
    }

    /// Provider-scoped sign-in is reserved for adding an account.
    func beginSignIn(for providerID: ProviderID) async {
        await beginAddAccount()
        guard showImport, accountLoginSession == nil else { return }
        selectedProviderID = providerID
        if ProviderChoices.builtIn.contains(providerID) { await startAccountLogin() }
    }

    func beginSignIn(for accountID: UUID) async {
        guard !isUnavailable else { reportUnavailable(); return }
        guard !isBusy, let account = status?.accounts.first(where: { $0.id == accountID }) else { return }
        resetAccountModal()
        accountModalMode = .add
        showImport = true
        signInAccountID = accountID
        selectedProviderID = account.identity.providerID
        if selectedProviderID == .droid { droidAccountName = account.identity.accountID ?? "Droid 1" }
        if let pending = pendingLoginSessions.first(where: { $0.accountID == accountID }) {
            accountLoginSession = pending
            accountLoginState = .waitingForLogin
            accountLoginMessage = "Finish signing in to this account, then choose Check Now."
        } else {
            await startAccountLogin()
        }
    }

    func beginAdvancedImport() async {
        guard !isUnavailable else { reportUnavailable(); return }
        guard !isBusy else { return }
        resetAccountModal()
        accountModalMode = .advancedImport
        showImport = true
        resetImport()
        await discover()
    }

    func beginImport() async {
        await beginAdvancedImport()
    }

    func startAccountLogin() async {
        if let manager {
            let providerID = selectedProviderID
            let providerName = providerID.guiName
            await perform(
                failure: "Couldn’t start sign-in.",
                recovery: "Confirm that \(providerName) is installed, then try again."
            ) {
                let start: AccountLoginStart
                if let accountID = signInAccountID {
                    var confirmed = false
                    if providerID == .droid {
                        let name = status?.accounts.first { $0.id == accountID }?.identity.accountID ?? "Droid"
                        guard confirmDroidAction(DroidAccountError.confirmSignIn(name).localizedDescription, action: "Sign in") else { return }
                        confirmed = true
                    }
                    start = try await manager.startAccountLogin(accountID: accountID, confirmDroidAccount: confirmed)
                } else {
                    start = try await manager.startAccountLogin(providerID: providerID)
                }
                accountLoginSession = start.session
                accountLoginState = .waitingForLogin
                accountLoginMessage = "Finish signing in to \(providerName), then return here and choose Check Now."
                if !pendingLoginSessions.contains(where: { $0.id == start.session.id }) {
                    pendingLoginSessions.append(start.session)
                }
                if start.opensInTerminal {
                    // Switch never launches a generic sign-in itself: Terminal runs the saved command.
                    let spec = ProviderCatalog.spec(providerID)
                    let keys = ["HOME", "FACTORY_HOME_OVERRIDE", "FACTORY_DISABLE_KEYRING"] + (spec?.files.compactMap(\.homeEnv) ?? [])
                        + (spec?.loginEnv.keys.sorted() ?? [])
                    let script = try makeLaunchArtifact(
                        start.launchSpec, name: "Sign In to Switch Account.command", exportKeys: keys)
                    if paths.isolationRoot != nil {
                        accountLoginMessage = "Sign-in file prepared for isolated validation. Terminal was not opened."
                    } else {
                        guard NSWorkspace.shared.open(script) else {
                            throw AIManagerError.operationFailed(
                                "Terminal could not open the \(providerName) sign-in file.")
                        }
                        accountLoginMessage = "Terminal opened. Finish signing in to \(providerName) there, then return here and choose Check Now."
                        if providerID == .droid { accountLoginMessage = "Terminal opened. Type /login, finish signing in, then exit Droid. Switch checks this temporary login automatically." }
                    }
                }
            }
            return
        }
        #if AI_MANAGER_PREVIEW
        guard isDemo else { reportUnavailable(); return }
        await perform {
            guard selectedProviderID == .codex || ProviderCatalog.spec(selectedProviderID) != nil else {
                throw AIManagerError.unsupportedSource("This provider is not available yet.")
            }
            let session = AccountLoginSession(
                id: UUID(uuidString: "45A9767B-D942-41B6-88D8-2410E367B815")!,
                providerID: selectedProviderID,
                createdAt: DemoData.now,
                accountID: signInAccountID
            )
            accountLoginSession = session
            pendingLoginSessions = [session]
            accountLoginState = .waitingForLogin
            accountLoginMessage = "Demo sign-in is ready to check. No browser or process was opened."
        }
        #else
        reportUnavailable()
        #endif
    }

    func checkAccountLogin(credentialChoice: ConflictChoice? = nil) async {
        guard let session = accountLoginSession else { return }
        if let manager {
            let providerName = session.providerID.guiName
            await perform(
                failure: "Couldn’t complete sign-in.",
                recovery: "Finish the \(providerName) sign-in and choose Check Now again."
            ) {
                let check: AccountLoginCheck
                do {
                    var allowRunning = false, allowDuplicate = false
                    while true {
                        do {
                            check = try await manager.checkAccountLogin(id: session.id, credentialChoice: credentialChoice,
                                droidName: droidAccountName, allowRunningDroid: allowRunning, allowDuplicateDroid: allowDuplicate)
                            break
                        } catch let error as DroidAccountError {
                            switch error {
                            case .running where !allowRunning:
                                guard confirmDroidAction(error.localizedDescription, action: "Switch") else { return }
                                allowRunning = true
                            case .duplicateIdentity where !allowDuplicate:
                                guard confirmDroidAction(error.localizedDescription, action: "Add anyway") else { return }
                                allowDuplicate = true
                            default: throw error
                            }
                        }
                    }
                } catch let error as AIManagerError {
                    if case .signInIdentityMismatch = error {
                        pendingLoginSessions.removeAll { $0.id == session.id }
                        accountLoginSession = nil
                        accountLoginState = .needsAttention
                        accountLoginMessage = error.localizedDescription
                    }
                    throw error
                }
                accountLoginState = check.state
                accountLoginMessage = check.message
                if session.providerID == .droid, let account = check.account, !droidAPIKey.isEmpty {
                    try await manager.setDroidUsageAPIKey(accountID: account.id, apiKey: droidAPIKey)
                    droidAPIKey = ""
                }
                if let account = check.account {
                    try await reloadStatus(using: manager)
                    selectedAccountID = account.id
                    pendingLoginSessions.removeAll { $0.id == session.id }
                    let name = EmailPrivacy.display(account.identity.email ?? account.identity.accountID ?? "The account")
                    let providerName = account.identity.providerID.guiName
                    notice = status?.isDefault(account) == true
                        ? "New \(providerName) sessions will use \(name)."
                        : "\(name) saved."
                    await loadCachedUsage()
                    Task { await self.refreshAnyUsage(accountID: account.id) }
                }
            }
            return
        }
        #if AI_MANAGER_PREVIEW
        guard isDemo else { reportUnavailable(); return }
        await perform {
            accountLoginState = .completed
            accountLoginMessage = "Demo account access was saved in memory."
            pendingLoginSessions.removeAll { $0.id == session.id }
            if let accountID = session.accountID {
                selectedAccountID = accountID
            } else if session.providerID != .codex {
                selectedAccountID = addDemoProviderAccount(session.providerID).id
            } else if let account = status?.accounts.first {
                selectedAccountID = account.id
            }
        }
        #else
        reportUnavailable()
        #endif
    }

    func submitGrokAuthorizationCode(_ input: String) async -> Bool {
        guard let session = accountLoginSession, session.providerID == .grokBuild else { return false }
        var submitted = false
        if let manager {
            await perform(
                failure: "Couldn’t submit the Grok authorization code.",
                recovery: "Start Grok sign-in again if the code expired."
            ) {
                try await manager.submitAccountLoginCode(id: session.id, input: input)
                accountLoginMessage = "Authorization code submitted. Waiting for Grok to finish signing in."
                submitted = true
            }
        }
        return submitted
    }

    func cancelAccountLogin() async {
        guard let session = accountLoginSession else {
            resetAccountLogin()
            return
        }
        if let manager {
            await perform(
                failure: "Couldn’t cancel sign-in.",
                recovery: "Refresh and retry from the pending sign-in."
            ) {
                try await manager.cancelAccountLogin(id: session.id)
                pendingLoginSessions.removeAll { $0.id == session.id }
                resetAccountLogin()
            }
            return
        }
        #if AI_MANAGER_PREVIEW
        guard isDemo else { reportUnavailable(); return }
        await perform {
            pendingLoginSessions.removeAll { $0.id == session.id }
            resetAccountLogin()
        }
        #else
        reportUnavailable()
        #endif
    }

    // MARK: Generic provider accounts

    @Published var droidAccountName = "Droid 1"
    @Published var droidAPIKey = ""
    var droidConfirmation: ((String, String) -> Bool)?

    func importDroidAccount() async {
        guard let manager else { reportUnavailable(); return }
        await perform(failure: "Could not import Droid.", recovery: "Enter a name and check that Factory is signed in.") {
            let account: AccountRecord
            do {
                account = try await manager.importDroidAccount(name: droidAccountName,
                    apiKey: droidAPIKey.isEmpty ? nil : droidAPIKey)
            } catch let error as DroidAccountError {
                guard case .duplicateIdentity = error else { throw error }
                guard confirmDroidAction(error.localizedDescription, action: "Add anyway") else { return }
                account = try await manager.importDroidAccount(name: droidAccountName,
                    apiKey: droidAPIKey.isEmpty ? nil : droidAPIKey, allowDuplicate: true)
            }
            droidAPIKey = ""
            try await reloadStatus(using: manager)
            finishProviderAccount(account)
            notice = "Droid account saved."
        }
    }

    func saveDroidUsageKey(accountID: UUID, key: String) async {
        guard let manager else { reportUnavailable(); return }
        await perform {
            try await manager.setDroidUsageAPIKey(accountID: accountID, apiKey: key)
        }
        await refreshProviderUsage(accountID: accountID)
    }

    private func confirmDroidAction(_ message: String, action: String) -> Bool {
        if let droidConfirmation { return droidConfirmation(message, action) }
        guard paths.isolationRoot == nil else { return false }
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: action)
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.last?.keyEquivalent = ""
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func switchWithDroidConfirmation(_ manager: AccountManager, to id: UUID) async throws -> SwitchResult? {
        do { return try await manager.switchDefault(to: id) }
        catch let error as DroidAccountError {
            guard case .running = error else { throw error }
            guard confirmDroidAction(error.localizedDescription, action: "Switch") else { return nil }
            return try await manager.switchDefault(to: id, allowRunningDroid: true)
        }
    }

    /// Environment variable that may prefill a credential field. Never read in Preview or in an
    /// isolated validation run.
    func environmentPrefill(for field: CredentialField) -> String? {
        #if AI_MANAGER_PREVIEW
        if isDemo { return nil }
        #endif
        guard paths.isolationRoot == nil else { return nil }
        let environment = ProcessInfo.processInfo.environment
        return field.env.lazy.compactMap { environment[$0] }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Saves typed credentials for a `.secret` provider. Returns true when the account was saved.
    func addProviderAccount(providerID: ProviderID, fields: [String: String]) async -> Bool {
        var saved = false
        if let manager {
            await perform(
                failure: "Couldn’t save the account.",
                recovery: "Check the credentials and try again."
            ) {
                let record = try await manager.addProviderAccount(providerID: providerID, fields: fields)
                try await reloadStatus(using: manager)
                finishProviderAccount(record)
                saved = true
            }
        } else {
            #if AI_MANAGER_PREVIEW
            guard isDemo else { reportUnavailable(); return false }
            await perform {
                finishProviderAccount(addDemoProviderAccount(providerID))
                saved = true
            }
            #else
            reportUnavailable()
            #endif
        }
        if saved, let id = selectedAccountID { Task { await self.refreshAnyUsage(accountID: id) } }
        return saved
    }

    /// Saves the sign-in that the provider's own app or CLI currently holds.
    func importLiveProviderAccount(providerID: ProviderID) async -> Bool {
        var saved = false
        if let manager {
            await perform(
                failure: "Couldn’t import the current sign-in.",
                recovery: "Sign in with the official app or CLI, then try again."
            ) {
                let record = try await manager.importLiveProviderAccount(providerID: providerID)
                try await reloadStatus(using: manager)
                finishProviderAccount(record)
                saved = true
            }
        } else {
            #if AI_MANAGER_PREVIEW
            guard isDemo else { reportUnavailable(); return false }
            await perform {
                finishProviderAccount(addDemoProviderAccount(providerID))
                saved = true
            }
            #else
            reportUnavailable()
            #endif
        }
        if saved, let id = selectedAccountID { Task { await self.refreshAnyUsage(accountID: id) } }
        return saved
    }

    /// Identity of the sign-in that the provider currently holds, read without changing anything.
    func liveProviderIdentity(_ providerID: ProviderID) async -> CredentialIdentity? {
        if let manager { return await manager.liveProviderIdentity(providerID: providerID) }
        #if AI_MANAGER_PREVIEW
        if isDemo { return DemoData.liveIdentity(providerID) }
        #endif
        return nil
    }

    /// Marks every file-based provider whose real login exists on this Mac. Each read runs on the
    /// account manager's actor, not on the main actor, and changes nothing.
    func detectSignedInProviders() async {
        // A spec whose files are all optional (Muse) reads as signed in on an empty home, so it
        // cannot be detected from files alone.
        let specs = ProviderCatalog.addable.filter { $0.style == .files && $0.files.contains { !$0.optional } }
        var found: Set<ProviderID> = []
        #if AI_MANAGER_PREVIEW
        if isDemo {
            found = Set(specs.map(\.id).filter { DemoData.signedInOnThisMac.contains($0.rawValue) })
        } else {
            for spec in specs where await liveProviderIdentity(spec.id) != nil { found.insert(spec.id) }
        }
        #else
        for spec in specs where await liveProviderIdentity(spec.id) != nil { found.insert(spec.id) }
        #endif
        if found != signedInProviderIDs { signedInProviderIDs = found }
    }

    func openDashboard(_ url: URL) {
        #if AI_MANAGER_PREVIEW
        if isDemo {
            notice = "The dashboard opens in production. The browser was not opened from Preview."
            return
        }
        #endif
        if paths.isolationRoot != nil {
            notice = "Dashboard link validated in isolation. The browser was not opened."
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func finishProviderAccount(_ record: AccountRecord) {
        selectedAccountID = record.id
        accountLoginState = .completed
        accountLoginMessage = "\(record.identity.providerID.guiName) account was saved."
        notice = nil
    }

    func discover(explicit: URL? = nil) async {
        if let manager {
            await perform(
                failure: "Couldn’t find Codex accounts.",
                recovery: "Choose another folder or check its permissions."
            ) {
                discoveries = await manager.discover(explicit: explicit)
                let selectedPath = explicit.map {
                    $0.lastPathComponent == "auth.json" ? $0.deletingLastPathComponent() : $0
                }
                if let selectedPath,
                   let source = discoveries.first(where: {
                       $0.path.standardizedFileURL.path == selectedPath.standardizedFileURL.path
                   }) {
                    selectedSourceID = source.id
                } else if !discoveries.contains(where: { $0.id == selectedSourceID }) {
                    selectedSourceID = discoveries.first(where: { $0.support == .supportedChatGPT })?.id
                }
            }
            return
        }
        #if AI_MANAGER_PREVIEW
        guard isDemo else { reportUnavailable(); return }
        await perform {
            discoveries = DemoData.discoveries
            if !discoveries.contains(where: { $0.id == selectedSourceID }) {
                selectedSourceID = discoveries.first(where: { $0.support == .supportedChatGPT })?.id
            }
            notice = "Demo sources refreshed. No files were inspected."
        }
        #else
        reportUnavailable()
        #endif
    }

    func chooseSource() async {
        if manager != nil {
            let panel = NSOpenPanel()
            panel.title = "Choose Codex Data"
            panel.message = "Select a Codex home folder or its auth.json file."
            panel.prompt = "Choose"
            panel.canChooseDirectories = true
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.showsHiddenFiles = true
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            guard panel.runModal() == .OK, let url = panel.url else { return }
            await discover(explicit: url)
            return
        }
        #if AI_MANAGER_PREVIEW
        guard isDemo else { reportUnavailable(); return }
        await perform {
            selectedSourceID = DemoData.manualSource.id
            if !discoveries.contains(where: { $0.id == DemoData.manualSource.id }) {
                discoveries.append(DemoData.manualSource)
            }
            notice = "Demo source selected. No file picker was opened."
        }
        #else
        reportUnavailable()
        #endif
    }

    func reviewImport() async {
        if let manager {
            guard let source = discoveries.first(where: { $0.id == selectedSourceID }) else {
                errorMessage = "Choose a supported source."
                return
            }
            await perform(
                failure: "Couldn’t prepare the import.",
                recovery: "Choose the source again and review its files."
            ) {
                importPlan = try await manager.planImport(source: source.path, mode: importMode)
                conflictChoices = [:]
                importResult = nil
            }
            return
        }
        #if AI_MANAGER_PREVIEW
        guard isDemo else { reportUnavailable(); return }
        guard let source = discoveries.first(where: { $0.id == selectedSourceID }),
              source.support == .supportedChatGPT,
              let identity = source.identity else {
            errorMessage = "Choose a supported source."
            return
        }
        await perform {
            importPlan = DemoData.importPlan(source: source, identity: identity, mode: importMode, paths: paths)
            conflictChoices = [:]
            importResult = nil
        }
        #else
        reportUnavailable()
        #endif
    }

    func commitImport() async {
        guard let plan = importPlan else {
            if isUnavailable { reportUnavailable() }
            return
        }
        if let manager {
            await perform(
                failure: "Couldn’t import the account.",
                recovery: "Open Backup before retrying if an interrupted operation is listed."
            ) {
                importResult = try await manager.importAccount(plan: plan, decisions: conflictChoices)
                try await reloadStatus(using: manager)
                selectedAccountID = importResult?.account.id
            }
            if let accountID = importResult?.account.id {
                Task { await self.refreshUsage(accountID: accountID) }
            }
            return
        }
        #if AI_MANAGER_PREVIEW
        guard isDemo else { reportUnavailable(); return }
        let missing = plan.conflicts.filter { conflictChoices[$0.relativePath] == nil }.map(\.relativePath)
        guard missing.isEmpty else {
            errorMessage = "Choose how to resolve: \(missing.joined(separator: ", "))"
            return
        }
        await perform {
            var result = DemoData.importResult(plan: plan)
            if var current = status {
                if let index = current.accounts.firstIndex(where: { $0.identity == result.account.identity }) {
                    result.account.id = current.accounts[index].id
                    current.accounts[index] = result.account
                } else {
                    current.accounts.append(result.account)
                }
                status = current
            }
            importResult = result
            selectedAccountID = result.account.id
            notice = "Demo import completed in memory."
        }
        #else
        reportUnavailable()
        #endif
    }

    func reviewExternalSetting(_ relativePath: String) async {
        if let manager {
            guard let plan = importPlan else {
                errorMessage = "Review an import plan before reviewing linked data."
                return
            }
            await perform(
                failure: "Couldn’t review the linked data.",
                recovery: "Check that the linked folder is connected, then review it again."
            ) {
                importPlan = try await manager.reviewExternalSetting(
                    plan: plan, relativePath: relativePath)
            }
            return
        }
        #if AI_MANAGER_PREVIEW
        guard isDemo else { reportUnavailable(); return }
        await perform {
            guard var plan = importPlan,
                  let index = plan.conflicts.firstIndex(where: { $0.relativePath == relativePath }) else { return }
            plan.conflicts[index].externalTargetBytes = 12_480
            importPlan = plan
            notice = "Demo linked data reviewed. No file was opened."
        }
        #else
        reportUnavailable()
        #endif
    }

    /// `announce: false` skips the "New sessions will use this account" notification; Auto switch
    /// sends its own.
    func switchDefault(to requestedID: UUID? = nil, announce: Bool = true) async {
        if let manager {
            guard let id = requestedID ?? selectedAccountID,
                  let providerID = status?.accounts.first(where: { $0.id == id })?
                    .identity.providerID else { return }
            let providerName = providerID.guiName
            await perform(
                failure: "Couldn’t change the default account.",
                recovery: "Resolve any item in Backup, then try again."
            ) {
                guard try await switchWithDroidConfirmation(manager, to: id) != nil else { return }
                try await reloadStatus(using: manager)
                selectedAccountID = id
                if announce { notice = "New \(providerName) sessions will use this account." }
            }
            if status?.defaultAccountID(for: providerID) == id {
                await loadCachedUsage()
                if shouldRefreshDefaultUsage {
                    Task { await self.refreshDefaultUsage() }
                }
            }
            return
        }
        #if AI_MANAGER_PREVIEW
        guard isDemo else { reportUnavailable(); return }
        guard let id = requestedID ?? selectedAccountID, var current = status,
              let account = current.accounts.first(where: { $0.id == id }) else { return }
        await perform {
            current.setDefaultAccountID(id, for: account.identity.providerID)
            status = current
            selectedAccountID = id
            notice = "Future demo sessions will use this account. Existing sessions are unchanged."
        }
        #else
        reportUnavailable()
        #endif
    }

    func checkAccount(_ requestedID: UUID? = nil) async {
        if let manager {
            guard let id = requestedID ?? selectedAccountID else { return }
            await perform(failure: "Couldn’t check the account files.", recovery: "Try the check again.") {
                let result = await manager.checkAccount(accountID: id)
                try await reloadStatus(using: manager)
                selectedAccountID = id
                // A failed check needs action, so it goes to the red bar, not a passing message.
                switch result.verification.state {
                case .verifiedLocally, .verifiedWithCodex: notice = "Account checked."
                default: errorMessage = result.verification.detail
                }
                if let usage = result.usage {
                    usageSnapshots[id] = usage
                    await prepareUsageCache()
                    try await usageCache?.upsertSuccess(accountID: id, snapshot: usage)
                    await loadCachedUsage()
                }
            }
            return
        }
        #if AI_MANAGER_PREVIEW
        guard isDemo else { reportUnavailable(); return }
        guard let id = requestedID ?? selectedAccountID, var current = status,
              let index = current.accounts.firstIndex(where: { $0.id == id }) else { return }
        await perform {
            current.accounts[index].verification = VerificationResult(
                state: .verifiedWithCodex,
                checkedAt: DemoData.now,
                detail: "Demo account check passed without a network request."
            )
            status = current
            selectedAccountID = id
            notice = current.accounts[index].verification.detail
        }
        #else
        reportUnavailable()
        #endif
    }

    func verify() async {
        await checkAccount()
    }

    func openAccount(_ requestedID: UUID? = nil) async {
        if let manager {
            guard let id = requestedID ?? selectedAccountID,
                  let providerID = status?.accounts.first(where: { $0.id == id })?
                    .identity.providerID else { return }
            let providerName = providerID.guiName
            await perform(
                failure: "Couldn’t open \(providerName).",
                recovery: "Check the saved account, then try again."
            ) {
                if status?.defaultAccountID(for: providerID) != id {
                    guard try await switchWithDroidConfirmation(manager, to: id) != nil else { return }
                    try await reloadStatus(using: manager)
                    selectedAccountID = id
                }
                let spec = try await manager.launchSpec(accountID: id)
                if paths.isolationRoot != nil {
                    _ = try makeLaunchArtifact(spec)
                    notice = "Account launch file prepared for isolated validation. Terminal was not opened."
                    return
                }
                let script = try makeLaunchArtifact(spec)
                guard NSWorkspace.shared.open(script) else {
                    throw AIManagerError.operationFailed(
                        "Terminal could not open the \(providerName) launch file.")
                }
                notice = "\(providerName) opened in Terminal."
            }
            return
        }
        #if AI_MANAGER_PREVIEW
        guard isDemo else { reportUnavailable(); return }
        await perform {
            guard let id = requestedID ?? selectedAccountID,
                  var current = status,
                  let account = current.accounts.first(where: { $0.id == id }) else { return }
            current.setDefaultAccountID(id, for: account.identity.providerID)
            status = current
            selectedAccountID = id
            notice = "Demo account opened. No Terminal process was started."
        }
        #else
        reportUnavailable()
        #endif
    }

    /// Auto switch: opens a stopped Codex or Claude Code session again in a new Terminal window on
    /// the current default account. Terminal opens behind the front app. False when it could not.
    func openResume(_ resume: CLIResume) async -> Bool {
        guard let manager, paths.isolationRoot == nil else { return false }
        let providerID: ProviderID = resume.tool == .codex ? .codex : .claudeCode
        guard let id = status?.defaultAccountID(for: providerID) else { return false }
        do {
            let spec = try await manager.launchSpec(
                accountID: id, arguments: resume.arguments,
                workingDirectory: URL(fileURLWithPath: resume.cwd, isDirectory: true))
            let script = try makeLaunchArtifact(
                spec, name: "Resume \(resume.tool.rawValue) \(resume.sessionID.prefix(8)).command")
            guard let terminal = NSWorkspace.shared.urlForApplication(toOpen: script) else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: configuration)
            return true
        } catch {
            return false
        }
    }

    func moveAccount(_ accountID: UUID, to targetID: UUID) async {
        guard let accounts = status?.accounts,
              let source = accounts.firstIndex(where: { $0.id == accountID }),
              let target = accounts.firstIndex(where: { $0.id == targetID }),
              source != target else { return }
        var ids = accounts.map(\.id)
        ids.insert(ids.remove(at: source), at: target)
        await perform(
            failure: "Couldn’t save the account order.",
            recovery: "Refresh accounts, then try again."
        ) {
            if let manager {
                status = try await manager.reorderAccounts(ids)
                return
            }
            #if AI_MANAGER_PREVIEW
            guard isDemo, var current = status else { return }
            let records = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
            current.accounts = ids.compactMap { records[$0] }
            status = current
            #endif
        }
    }

    func adjacentAccountID(to accountID: UUID, offset: Int) -> UUID? {
        guard let accounts = status?.accounts,
              let index = accounts.firstIndex(where: { $0.id == accountID }),
              accounts.indices.contains(index + offset) else { return nil }
        return accounts[index + offset].id
    }

    func repairLinkedSetting(_ issue: LinkedSettingsDivergence) async {
        if let manager {
            await perform(
                failure: "Couldn’t repair the account data.",
                recovery: "Refresh the account and review the changed entry again."
            ) {
                _ = try await manager.repairLinkedSetting(
                    accountID: issue.accountID,
                    relativePath: issue.relativePath,
                    reviewedFingerprint: issue.localFingerprint
                )
                try await reloadStatus(using: manager)
                notice = "Account data restored."
            }
            return
        }
        #if AI_MANAGER_PREVIEW
        guard isDemo else { reportUnavailable(); return }
        await perform {
            guard var current = status else { return }
            current.linkedSettingsDivergences.removeAll { $0.id == issue.id }
            status = current
            notice = "Demo account data repaired in memory."
        }
        #else
        reportUnavailable()
        #endif
    }

    func canDeleteAccount(_ accountID: UUID) -> Bool {
        guard let current = status,
              let account = current.accounts.first(where: { $0.id == accountID }) else { return false }
        return current.defaultAccountID(for: account.identity.providerID) != accountID
            || deletionReplacement(for: accountID) != nil
    }

    func deletionReplacement(for accountID: UUID) -> AccountRecord? {
        guard let providerID = status?.accounts.first(where: { $0.id == accountID })?
            .identity.providerID else { return nil }
        let candidates = status?.accounts.filter {
            $0.id != accountID && $0.identity.providerID == providerID
                && $0.verification.state != .needsSignIn
                && $0.verification.state != .unsupported
        } ?? []
        for preferred in [selectedAccountID, previousSelectedAccountID] {
            if let account = candidates.first(where: { $0.id == preferred }) { return account }
        }
        return candidates.filter { $0.lastUsedAt != nil }.max {
            ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast)
        } ?? candidates.first
    }

    func deleteAccount(_ accountID: UUID) async {
        guard let account = status?.accounts.first(where: { $0.id == accountID }) else { return }
        guard canDeleteAccount(accountID) else {
            errorMessage = "No saved account is available as a replacement."
            return
        }
        let replacement = status?.defaultAccountID(for: account.identity.providerID) == accountID
            ? deletionReplacement(for: accountID)?.id : nil
        if let manager {
            await perform(
                failure: "Couldn’t delete the account.",
                recovery: "Refresh accounts, then try again."
            ) {
                do {
                    _ = try await manager.deleteAccount(
                        accountID: accountID,
                        replacementDefaultAccountID: replacement)
                } catch {
                    try? await reloadStatus(using: manager)
                    throw error
                }
                try await reloadStatus(using: manager)
                accountUsage[accountID] = nil
                usageSnapshots[accountID] = nil
                retainedDailyUsage[accountID] = nil
                if providerUsage[accountID] != nil {
                    providerUsage[accountID] = nil
                    persistProviderUsage()
                }
                if usageErrorAccountID == accountID {
                    usageError = nil
                    usageErrorAccountID = nil
                }
                if selectedAccountID == accountID {
                    selectedAccountID = status?.firstDefaultAccountID ?? status?.accounts.first?.id
                }
                let accountName = EmailPrivacy.display(account.identity.email ?? account.identity.accountID ?? "Account")
                notice = "\(accountName) deleted."
            }
            return
        }
        #if AI_MANAGER_PREVIEW
        guard isDemo else { reportUnavailable(); return }
        await perform {
            guard var current = status else { return }
            current.accounts.removeAll { $0.id == accountID }
            if current.defaultAccountID(for: account.identity.providerID) == accountID {
                current.setDefaultAccountID(replacement, for: account.identity.providerID)
            }
            current.linkedSettingsDivergences.removeAll { $0.accountID == accountID }
            status = current
            accountHistory[accountID] = nil
            accountUsage[accountID] = nil
            usageSnapshots[accountID] = nil
            providerUsage[accountID] = nil
            if selectedAccountID == accountID {
                selectedAccountID = current.firstDefaultAccountID ?? current.accounts.first?.id
            }
            let accountName = EmailPrivacy.display(account.identity.email ?? account.identity.accountID ?? "Account")
            notice = "\(accountName) was deleted from the demo."
        }
        #else
        reportUnavailable()
        #endif
    }

    func copyPath(_ path: String) -> Bool {
        guard !isUnavailable, !path.isEmpty else { return false }
        #if AI_MANAGER_PREVIEW
        if isDemo { return true }
        #endif
        if paths.isolationRoot != nil { return true }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(path, forType: .string)
    }

    func copySavedAuthPath(for requestedID: UUID? = nil) {
        guard !isUnavailable else { reportUnavailable(); return }
        let account = status?.accounts.first { $0.id == (requestedID ?? selectedAccountID) }
        guard let credential = account?.credentialFile.path else { return }
        let pathName = account?.identity.providerID == .claudeCode ? "Profile config path" : "Saved auth path"
        #if AI_MANAGER_PREVIEW
        if isDemo {
            notice = "Demo \(pathName.lowercased()) ready. The clipboard was not changed."
            return
        }
        #endif
        if paths.isolationRoot != nil {
            notice = "\(pathName) validated in isolation. The clipboard was not changed."
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(credential, forType: .string)
            notice = "\(pathName) copied."
        }
    }

    func copyWarnings(_ warnings: [String]) {
        let warnings = warnings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !warnings.isEmpty else { return }
        let text = warnings.count == 1
            ? warnings[0]
            : warnings.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n\n")
        let noun = warnings.count == 1 ? "Warning" : "\(warnings.count) warnings"
        #if AI_MANAGER_PREVIEW
        if isDemo {
            notice = "\(noun) ready to copy in the production app."
            return
        }
        #endif
        if paths.isolationRoot != nil {
            notice = "\(noun) validated in isolation. The clipboard was not changed."
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            notice = "\(noun) copied."
        }
    }

    func showDataLocation(_ location: URL, name: String) {
        guard !isUnavailable else { reportUnavailable(); return }
        #if AI_MANAGER_PREVIEW
        if isDemo {
            notice = "\(name) is available in production. Finder was not opened from Preview."
            return
        }
        #endif
        if paths.isolationRoot != nil {
            notice = "\(name) was validated in isolation. Finder was not opened."
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([location])
        }
    }

    func recover() async {
        if let manager {
            await perform(
                failure: "Couldn’t finish the interrupted operation.",
                recovery: "Review the pending item and its protected backup before retrying."
            ) {
                let results: [RecoveryResult]
                do { results = try await manager.recover() }
                catch let error as DroidAccountError {
                    guard case .running = error else { throw error }
                    guard confirmDroidAction(error.localizedDescription, action: "Recover") else { return }
                    results = try await manager.recover(allowRunningDroid: true)
                }
                notice = results.isEmpty ? "No backup work was needed."
                    : results.contains { $0.outcome == .conflict } ? "Backup work needs your choice."
                    : "Backup work finished."
                try await reloadStatus(using: manager)
            }
            return
        }
        #if AI_MANAGER_PREVIEW
        guard isDemo else { reportUnavailable(); return }
        await perform {
            guard var current = status else { return }
            let count = current.pendingRecovery.count
            current.pendingRecovery = []
            status = current
            notice = count == 0 ? "No backup work was needed." : "Demo backup work completed in memory."
        }
        #else
        reportUnavailable()
        #endif
    }

    func resolveRecoveryConflict(_ operation: RecoveryOperation, choice: RecoveryConflictChoice) async {
        if let manager {
            await perform(
                failure: "Couldn’t resolve the backup conflict.",
                recovery: "Confirm that Codex is closed, then review the protected backup and retry."
            ) {
                do {
                    _ = try await manager.resolveRecoveryConflict(operationID: operation.id, choice: choice)
                } catch let error as DroidAccountError {
                    guard case .running = error else { throw error }
                    guard confirmDroidAction(error.localizedDescription, action: "Recover") else { return }
                    _ = try await manager.resolveRecoveryConflict(operationID: operation.id, choice: choice, allowRunningDroid: true)
                }
                notice = choice == .preserveCurrent ? "Current files kept." : "Protected backup restored."
                try await reloadStatus(using: manager)
            }
            return
        }
        #if AI_MANAGER_PREVIEW
        guard isDemo else { reportUnavailable(); return }
        await perform {
            guard var current = status else { return }
            current.pendingRecovery.removeAll { $0.id == operation.id }
            status = current
            notice = choice == .preserveCurrent
                ? "Current demo files kept; the protected backup remains available."
                : "Protected demo backup restored; the replaced files remain preserved."
        }
        #else
        reportUnavailable()
        #endif
    }

    #if AI_MANAGER_PREVIEW
    /// Adds (or reuses) a synthetic saved account for a generic provider.
    func addDemoProviderAccount(_ providerID: ProviderID) -> AccountRecord {
        guard var current = status else { preconditionFailure("Demo status is missing") }
        if let existing = current.accounts.first(where: { $0.identity.providerID == providerID }) {
            return existing
        }
        let record = DemoData.genericAccount(providerID)
        current.accounts.append(record)
        if current.defaultAccountID(for: providerID) == nil {
            current.setDefaultAccountID(record.id, for: providerID)
        }
        status = current
        providerUsage[record.id] = ProviderUsageState(
            usage: DemoData.providerUsage(for: providerID, offset: 0), checkedAt: DemoData.now)
        if providerID == .claudeCode { claudeActivity = DemoData.claudeActivity }
        return record
    }

    func showDemoError() {
        guard isDemo else { return }
        errorMessage = "The selected account needs sign-in before it can be opened."
    }
    #endif

    func history(for account: AccountRecord) -> HistorySummary {
        accountHistory[account.id] ?? HistorySummary()
    }

    func usage(for accountID: UUID) -> CodexAccountUsageSnapshot? {
        if status?.accounts.first(where: { $0.id == accountID })?.verification.state == .needsSignIn {
            return nil
        }
        return usageSnapshots[accountID]
    }

    func cachedUsage(for accountID: UUID) -> CachedCodexAccountUsage? {
        accountUsage[accountID]
    }

    func dailyUsage(for accountID: UUID) -> [CodexDailyUsageSnapshot] {
        retainedDailyUsage[accountID] ?? usage(for: accountID)?.dailyUsage ?? []
    }

    func projectActivity(on date: Date) async -> [CodexProjectDailyActivity] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return (try? await usageCache?.projectActivity(on: formatter.string(from: date))) ?? []
    }

    func usageError(for accountID: UUID) -> String? {
        if usageErrorAccountID == nil || usageErrorAccountID == accountID {
            if let usageError { return usageError }
        }
        guard let cached = accountUsage[accountID], let failure = cached.failure else { return nil }
        return cached.failureMessage ?? failure.message
    }

    var shouldRefreshDefaultUsage: Bool {
        guard let id = status?.defaultAccountID else { return false }
        return shouldRefreshUsage(accountID: id, onCadence: false)
    }

    private func shouldRefreshUsage(accountID: UUID, onCadence: Bool) -> Bool {
        guard paths.isolationRoot == nil,
              status?.accounts.contains(where: {
                  $0.id == accountID && $0.identity.providerID == .codex
              }) == true else { return false }
        guard let cached = accountUsage[accountID] else { return true }
        return Self.automaticUsageRefreshIsDue(
            fetchedAt: cached.snapshot == nil ? nil : cached.fetchedAt,
            failedAt: cached.failure == nil ? nil : cached.lastAttemptAt,
            onCadence: onCadence)
    }

    func refreshAutomaticUsage(onCadence: Bool = false) async {
        guard usageRefreshAccountID == nil else { return }
        let accountIDs = status?.accounts.compactMap { account in
            shouldRefreshUsage(accountID: account.id, onCadence: onCadence) ? account.id : nil
        } ?? []
        for accountID in accountIDs {
            await refreshUsage(accountID: accountID)
        }
    }

    func refreshDefaultUsage() async {
        guard let accountID = status?.defaultAccountID else { return }
        await refreshUsage(accountID: accountID)
    }

    func refreshUsage(accountID: UUID) async {
        guard paths.isolationRoot == nil,
              usageRefreshAccountID == nil,
              let manager,
              status?.accounts.contains(where: {
                  $0.id == accountID && $0.identity.providerID == .codex
              }) == true else { return }
        usageRefreshAccountID = accountID
        usageError = nil
        usageErrorAccountID = nil
        defer { usageRefreshAccountID = nil }
        let result = await manager.checkAccount(accountID: accountID)
        try? await reloadStatus(using: manager, refreshHistory: false)
        if result.verification.state == .needsSignIn {
            usageSnapshots.removeValue(forKey: accountID)
            try? await recordUsageFailure(.authenticationRequired, accountID: accountID)
            usageError = CodexUsageStatisticsFailure.authenticationRequired.message
            usageErrorAccountID = accountID
            return
        }
        guard let snapshot = result.usage else {
            try? await recordUsageFailure(.unavailable, accountID: accountID)
            usageError = CodexUsageStatisticsFailure.unavailable.message
            usageErrorAccountID = accountID
            return
        }
        usageSnapshots[accountID] = snapshot
        guard let usageCache else { return }
        do {
            try await usageCache.upsertSuccess(accountID: accountID, snapshot: snapshot)
            await loadCachedUsage()
        } catch {
            usageError = CodexUsageStatisticsFailure.storageUnavailable.message
            usageErrorAccountID = nil
        }
    }

    // MARK: Generic provider usage

    var providerUsageAccountIDs: [UUID] {
        status?.accounts.filter { $0.identity.providerID != .codex }.map(\.id) ?? []
    }

    private func setProviderUsage(_ id: UUID, _ state: ProviderUsageState?) {
        if providerUsage[id] != state { providerUsage[id] = state }
    }

    /// Shows the last good values before the first network check finishes.
    func loadProviderUsageCache() async {
        guard let url = providerUsageCacheURL, !providerUsageCacheLoaded else { return }
        providerUsageCacheLoaded = true
        let cached = await Task.detached(priority: .utility) { ProviderUsageCache.load(from: url) }.value
        let known = Set(providerUsageAccountIDs)
        var merged = providerUsage
        for (id, usage) in cached where known.contains(id) && merged[id] == nil {
            merged[id] = ProviderUsageState(usage: usage, checkedAt: usage.fetchedAt)
        }
        if merged != providerUsage { providerUsage = merged }
    }

    /// Automatic pass: only accounts that are due. `onCadence` is the fixed timer tick.
    func refreshProviderUsage(onCadence: Bool = false) async {
        let due = providerUsageAccountIDs.filter {
            ProviderUsagePolicy.isDue(providerUsage[$0], onCadence: onCadence)
        }
        Task { await self.refreshSideChecks() }
        await runProviderUsage(due)
    }

    /// Provider incident status and the Claude log scan ride along with every refresh pass. Both
    /// throttle themselves, so extra calls are cheap.
    private func refreshSideChecks(forceClaudeActivity: Bool = false) async {
        async let status: Void = refreshProviderStatus()
        async let activity: Void = refreshClaudeActivity(force: forceClaudeActivity)
        _ = await (status, activity)
    }

    // MARK: Provider status

    /// Providers with at least one saved account.
    var providerStatusIDs: [ProviderID] {
        Array(Set(status?.accounts.map(\.identity.providerID) ?? []))
    }

    /// Fetches due incident feeds; keeps the last good value on failure. With "Check provider
    /// status" off it makes no request and clears the indicators.
    func refreshProviderStatus() async {
        #if AI_MANAGER_PREVIEW
        if isDemo { return }
        #endif
        guard paths.isolationRoot == nil, manager != nil else { return }
        let entries = await statusPoller.poll(providerStatusIDs, enabled: ProviderStatusPoller.isEnabled())
        if entries != providerStatus { providerStatus = entries }
    }

    /// Called when the Settings toggle changes.
    func providerStatusSettingChanged() {
        #if AI_MANAGER_PREVIEW
        if isDemo {
            providerStatus = ProviderStatusPoller.isEnabled() ? DemoData.providerStatus : [:]
            return
        }
        #endif
        Task { await refreshProviderStatus() }
    }

    // MARK: Claude Code activity and shell integration

    /// Scans local Claude Code logs off the main actor, at most every 15 minutes unless `force`.
    func refreshClaudeActivity(force: Bool = false) async {
        #if AI_MANAGER_PREVIEW
        if isDemo { return }
        #endif
        guard paths.isolationRoot == nil, manager != nil, !isClaudeActivityLoading,
              let cacheURL = claudeCostCacheURL, let pricing = claudePricing,
              status?.accounts.contains(where: { $0.identity.providerID == .claudeCode }) == true,
              ClaudeActivity.isDue(computedAt: claudeActivity?.computedAt, force: force)
        else { return }
        isClaudeActivityLoading = true
        defer { isClaudeActivityLoading = false }
        let summary = try? await Task.detached(priority: .utility) {
            try await ClaudeActivity.compute(cacheURL: cacheURL, pricing: pricing)
        }.value
        if let summary { claudeActivity = summary }  // a failed scan keeps the last good numbers
    }

    /// Reads the Overview history off the main actor. A snapshot younger than `maxAge` stays, so a
    /// page switch shows the last charts at once. The scanners keep their own disk caches.
    func loadUsageHistory(maxAge: TimeInterval = 60) async {
        #if AI_MANAGER_PREVIEW
        if isDemo { return }
        #endif
        guard !isUsageHistoryLoading, manager != nil, hasLoaded else { return }
        if let loadedAt = usageHistoryLoadedAt, Date().timeIntervalSince(loadedAt) < maxAge { return }
        isUsageHistoryLoading = true
        defer { isUsageHistoryLoading = false }
        await prepareUsageCache()
        let accounts = status?.accounts ?? []
        let support = paths.applicationSupport
        var sources = UsageHistorySources(ledger: usageCache, pricing: claudePricing?.loader())
        // A test home never reads the real Claude or Grok folders.
        if paths.isolationRoot == nil, let pricing = claudePricing {
            let grok = accounts.filter { $0.identity.providerID == .grokBuild }
            sources.claude = ClaudeCostScanner(
                cacheURL: support.appending(path: "cache/claude-history.json"), pricing: pricing.loader())
            sources.claudeHomes = UsageHistory.claudeProfileHomes(
                applicationSupport: support,
                accountIDs: accounts.filter { $0.identity.providerID == .claudeCode }.map(\.id))
            sources.grokSessions = UsageHistory.grokSessionsFolder()
            sources.grokAccountID = grok.count == 1 ? grok.first?.id.uuidString.lowercased() : nil
        }
        // Providers with a transcript scanner above must not be counted twice from their charts.
        let scanned: Set<ProviderID> = [.codex, .claudeCode, .grokBuild]
        sources.charts = accounts.filter { !scanned.contains($0.identity.providerID) }.flatMap { account in
            (providerUsage[account.id]?.usage?.charts ?? []).map {
                ProviderChartSource(
                    service: account.identity.providerID.rawValue,
                    accountID: account.id.uuidString.lowercased(), chart: $0)
            }
        }
        let loaded = sources
        // ponytail: a new engine per load re-parses Grok sessions; keep one engine if that shows in Overview.
        let engine = UsageHistory(sources: loaded)
        usageHistory = await Task.detached(priority: .utility) { await engine.snapshot() }.value
        usageEngine = engine
        usageHistoryVersion += 1
        usageHistoryLoadedAt = Date()
    }

    /// What the Overview day sheet needs for one UTC day, read off the main actor: the day's history
    /// points, its sessions (nil when no engine ran), and the transcripts Conversations still holds
    /// for the Codex sessions, by thread id.
    func loadUsageDay(_ day: String) async -> OverviewDayInput {
        #if AI_MANAGER_PREVIEW
        if isDemo { return DemoData.usageDay(day, points: usageHistory?.points ?? []) }
        #endif
        let points = usageHistory?.points
        let engine = usageEngine
        let provider = chatHistoryProvider
        return await Task.detached(priority: .userInitiated) {
            let dayPoints = (points ?? []).filter { $0.day == day }
            guard let engine else { return OverviewDayInput(points: dayPoints, sessions: nil, threads: [:]) }
            let sessions = await engine.daySessions(day: day)
            var threads: [String: ChatThreadSummary] = [:]
            let wanted = sessions.compactMap(\.threadID)
            if !wanted.isEmpty, let provider {
                for thread in (try? await provider.refresh(query: ""))?.threads ?? [] { threads[thread.threadID] = thread }
                // Older than the newest threads the list holds: ask for the id itself.
                for id in wanted where threads[id] == nil {
                    if let thread = await provider.search(query: id).threads.first(where: { $0.threadID == id }) {
                        threads[id] = thread
                    }
                }
            }
            return OverviewDayInput(points: dayPoints, sessions: sessions, threads: threads)
        }.value
    }

    func loadClaudeShellIntegration() async {
        guard let manager else { return }
        claudeShellIntegrationOn = await manager.claudeShellIntegrationInstalled()
    }

    /// Adds or removes the one `~/.zshrc` line that makes a plain `claude` use the default account.
    func setClaudeShellIntegration(_ enabled: Bool) async {
        claudeShellIntegrationError = nil
        #if AI_MANAGER_PREVIEW
        if isDemo {
            claudeShellIntegrationOn = enabled
            return
        }
        #endif
        guard let manager else { return }
        do {
            try await manager.setClaudeShellIntegration(enabled)
        } catch {
            claudeShellIntegrationError = "Couldn’t update the shell setup. \(error.localizedDescription)"
        }
        claudeShellIntegrationOn = await manager.claudeShellIntegrationInstalled()
    }

    /// Manual refresh: immediate, ignoring age and the failure cooldown.
    func refreshProviderUsage(accountIDs: [UUID]) async {
        await runProviderUsage(accountIDs.filter { providerUsage[$0]?.isRefreshing != true })
    }

    func refreshProviderUsage(accountID: UUID) async {
        #if AI_MANAGER_PREVIEW
        if isDemo {
            notice = "Demo usage is illustrative. No provider was contacted."
            return
        }
        #endif
        await refreshProviderUsage(accountIDs: [accountID])
    }

    /// The toolbar's Refresh All Usage: every saved account, each with its provider's pipeline.
    func refreshAllUsage() async {
        let accounts = status?.accounts ?? []
        for account in accounts where account.identity.providerID == .codex {
            await refreshUsage(accountID: account.id)
        }
        await refreshProviderUsage(accountIDs: accounts
            .filter { $0.identity.providerID != .codex }.map(\.id))
    }

    /// Refreshes one saved account with the pipeline of its provider.
    func refreshAnyUsage(accountID: UUID) async {
        if status?.accounts.first(where: { $0.id == accountID })?.identity.providerID == .codex {
            await refreshUsage(accountID: accountID)
        } else {
            await refreshProviderUsage(accountID: accountID)
        }
    }

    /// This entry point is used only by the focused Droid card's Allow access button.
    func allowDroidUsageAccess(accountID: UUID) async {
        guard status?.accounts.contains(where: { $0.id == accountID && $0.identity.providerID == .droid }) == true,
              providerUsage[accountID]?.needsKeychainAccess == true,
              providerUsage[accountID]?.isRefreshing != true else { return }
        await runProviderUsage([accountID], interactive: true)
    }

    private func runProviderUsage(_ requested: [UUID], interactive: Bool = false) async {
        let known = Set(providerUsageAccountIDs)
        let ids = requested.filter(known.contains)
        guard !ids.isEmpty, paths.isolationRoot == nil, let manager else { return }
        for id in ids {
            var state = providerUsage[id] ?? ProviderUsageState()
            state.isRefreshing = true
            setProviderUsage(id, state)
        }
        await withTaskGroup(of: (UUID, Result<ProviderUsage, Error>).self) { group in
            var pending = ids[...]
            func launch(_ id: UUID) {
                group.addTask { await Self.fetchProviderUsage(manager, id, interactive: interactive) }
            }
            for _ in 0..<min(ProviderUsagePolicy.maxConcurrent, ids.count) {
                if let id = pending.popFirst() { launch(id) }
            }
            while let (id, result) = await group.next() {
                applyProviderUsage(id, result)
                if let next = pending.popFirst() { launch(next) }
            }
        }
        persistProviderUsage()
    }

    nonisolated private static func fetchProviderUsage(
        _ manager: AccountManager, _ id: UUID, interactive: Bool = false
    ) async -> (UUID, Result<ProviderUsage, Error>) {
        do {
            let usage = try await ProviderUsageCache.withTimeout(ProviderUsagePolicy.fetchTimeout) {
                try await manager.readProviderUsage(accountID: id, interactive: interactive)
            }
            return (id, .success(usage))
        } catch {
            return (id, .failure(error))
        }
    }

    private func applyProviderUsage(_ id: UUID, _ result: Result<ProviderUsage, Error>) {
        guard providerUsageAccountIDs.contains(id) else {
            providerUsage[id] = nil
            return
        }
        var state = providerUsage[id] ?? ProviderUsageState()
        state.isRefreshing = false
        state.checkedAt = Date()
        switch result {
        case .success(let usage):
            state.usage = usage
            state.error = nil
            state.needsSignIn = false
            state.needsKeychainAccess = false
        case .failure(let error):
            let failure = ProviderUsagePolicy.failure(error)
            state.error = failure.message
            state.needsSignIn = failure.needsSignIn
            state.needsKeychainAccess = error as? DroidLoginError == .needsKeychainAccess
            // Stale numbers never sit beside a sign-in request.
            if failure.needsSignIn { state.usage = nil }
        }
        setProviderUsage(id, state)
    }

    private func persistProviderUsage() {
        guard let url = providerUsageCacheURL else { return }
        let snapshot = providerUsage.compactMapValues(\.usage)
        Task.detached(priority: .utility) { try? ProviderUsageCache.save(snapshot, to: url) }
    }

    private func loadCachedUsage() async {
        await prepareUsageCache()
        guard let usageCache else { return }
        do {
            let accountIDs = status?.accounts.map(\.id) ?? []
            let cached = try await usageCache.latest(for: accountIDs)
            let newUsage = Dictionary(uniqueKeysWithValues: cached.map { ($0.accountID, $0) })
            let newSnapshots = Dictionary(uniqueKeysWithValues: cached.compactMap { entry in
                entry.snapshot.map { (entry.accountID, $0) }
            })
            var daily: [UUID: [CodexDailyUsageSnapshot]] = [:]
            for id in accountIDs { daily[id] = try await usageCache.dailyUsage(for: id) }
            if accountUsage != newUsage { accountUsage = newUsage }
            if usageSnapshots != newSnapshots { usageSnapshots = newSnapshots }
            if retainedDailyUsage != daily { retainedDailyUsage = daily }
        } catch {
            usageError = CodexUsageStatisticsFailure.storageUnavailable.message
            usageErrorAccountID = nil
        }
    }

    private func loadAPIPricing() async {
        guard let pricingResolver else { return }
        let configURL = paths.defaultHome.appending(path: "config.toml")
        let model = await Task.detached(priority: .utility) {
            (try? Data(contentsOf: configURL, options: [.mappedIfSafe]))
                .flatMap(CodexAPIPricingResolver.configuredModel)
        }.value
        guard let model, let price = try? await pricingResolver.price(for: model) else { return }
        if apiPrice != price { apiPrice = price }
    }

    private func prepareUsageCache() async {
        guard !didPrepareUsageCache, let usageDatabaseURL else { return }
        didPrepareUsageCache = true
        let activityURL = paths.applicationSupport.appending(path: "activity/daily.sqlite")
        let refreshInterval = Self.usageRefreshInterval
        do {
            usageCache = try await Task.detached(priority: .utility) {
                try CodexUsageStatisticsCache(
                    databaseURL: usageDatabaseURL,
                    policy: CodexUsageStatisticsCachePolicy(
                        staleAfter: refreshInterval),
                    activityDatabaseURL: activityURL)
            }.value
            if let usageCache { await chatHistoryProvider?.attachActivityCache(usageCache) }
        } catch {
            usageError = "Usage history is unavailable. \(error.localizedDescription)"
            usageErrorAccountID = nil
        }
    }

    private func recordUsageFailure(
        _ failure: CodexUsageStatisticsFailure,
        accountID: UUID
    ) async throws {
        await prepareUsageCache()
        guard let usageCache else { return }
        try await usageCache.recordFailure(accountID: accountID, failure: failure)
        await loadCachedUsage()
    }

    func rebuildableCacheSizes() async -> RebuildableCacheSizes {
        let usageURL = usageDatabaseURL
        let conversationURL = paths.applicationSupport.appending(path: "cache/chat-history-v1.json")
        return await Task.detached(priority: .utility) {
            let usageBytes = usageURL.map { databaseURL in
                ["", "-wal", "-shm"].reduce(Int64(0)) { total, suffix in
                    total + Self.regularFileSize(
                        at: URL(fileURLWithPath: databaseURL.path + suffix))
                }
            } ?? 0
            return RebuildableCacheSizes(
                usageBytes: usageBytes,
                conversationBytes: Self.regularFileSize(at: conversationURL))
        }.value
    }

    func clearUsageCache() async {
        await perform(failure: "Couldn’t clear the usage cache.") {
            await prepareUsageCache()
            try await usageCache?.purgeAll()
            accountUsage.removeAll()
            usageSnapshots.removeAll()
            usageError = nil
            usageErrorAccountID = nil
            notice = "Usage cache cleared."
        }
    }

    // MARK: Maintenance (Cleanup)

    /// One scan of a source: file metadata only. Codex also reads its conversation index for titles and dates.
    func cleanupScan(_ source: CleanupSource) async throws -> CleanupScan {
        var summaries: [ChatThreadSummary] = []
        var readsIndex = source.tool == .codex
        #if AI_MANAGER_PREVIEW
        if isDemo { readsIndex = false }
        #endif
        if readsIndex {
            _ = try await chatHistoryProvider?.refresh(query: "")
            summaries = await chatHistoryProvider?.cleanupSummaries() ?? []
        }
        return try await Task.detached(priority: .utility) {
            try AccountManager.scanCleanup(source, summaries: summaries)
        }.value
    }

    /// Switch's own usage samples (Codex source only).
    func cleanupSamples() async throws -> [CleanupUsageSample] {
        #if AI_MANAGER_PREVIEW
        if isDemo { return [] }
        #endif
        await prepareUsageCache()
        return try await usageCache?.cleanupSamples() ?? []
    }

    func cleanupTrash(_ source: CleanupSource) async throws -> [ConversationCleanupBatch] {
        if let manager { return try await manager.cleanupTrash(source) }
        return try ConversationCleanup(home: source.home, userHome: source.userHome).batches()
    }

    func reviewCleanup(_ source: CleanupSource, _ items: [CleanupItem]) async throws -> ConversationCleanupPlan {
        if let manager { return try await manager.reviewCleanup(source, items) }
        // Without a manager only the Preview runs cleanup, on its synthetic Mac.
        #if AI_MANAGER_PREVIEW
        if isDemo { return try ConversationCleanup(home: source.home, userHome: source.userHome).review(items) }
        #endif
        throw AIManagerError.operationFailed("Cleanup is unavailable.")
    }

    func applyCleanup(_ source: CleanupSource, plan: ConversationCleanupPlan?, samples: [CleanupUsageSample], clearIndex: Bool) async throws {
        guard !isBusy else { throw AIManagerError.operationFailed("Cleanup is unavailable while another action is running.") }
        isBusy = true
        defer { isBusy = false }
        if let plan {
            if let manager {
                let provider = chatHistoryProvider
                _ = try await manager.moveToCleanupTrash(source, plan) { sources in
                    guard let provider else { throw AIManagerError.operationFailed("The activity ledger is unavailable. Conversations were kept.") }
                    try await provider.preserveActivity(for: sources)
                }
            } else {
                _ = try ConversationCleanup(home: source.home, userHome: source.userHome).moveToTrash(plan)
            }
        }
        guard let usageCache, let chatHistoryProvider else {
            notice = Self.cleanupNotice(plan, samples: samples.count, clearIndex: false)
            return
        }
        if plan != nil, source.tool == .codex {
            chatDetailTask?.cancel()
            chatSelectionGeneration += 1
            selectedChat = nil
            selectedChatID = nil
            chatPresentations = [:]
            hasScannedChatHistory = false
        }
        try await usageCache.removeCleanupSamples(samples)
        await loadCachedUsage()
        if clearIndex {
            try await chatHistoryProvider.clearCache()
            chatHistory = ChatHistorySnapshot()
            selectedChat = nil
            selectedChatID = nil
            chatPresentations = [:]
            hasScannedChatHistory = false
        }
        notice = Self.cleanupNotice(plan, samples: samples.count, clearIndex: clearIndex)
    }

    private static func cleanupNotice(_ plan: ConversationCleanupPlan?, samples: Int, clearIndex: Bool) -> String {
        var parts: [String] = []
        if let plan {
            let bytes = ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file)
            parts.append("\(plan.items.count.formatted()) \(plan.items.count == 1 ? "item" : "items") (\(bytes)) moved to the trash")
        }
        if samples > 0 { parts.append("\(samples.formatted()) usage samples cleared") }
        if clearIndex { parts.append("conversation index cleared") }
        return parts.isEmpty ? "Cleanup finished." : parts.joined(separator: "; ") + "."
    }

    func restoreCleanup(_ source: CleanupSource, _ id: UUID) async throws {
        guard !isBusy else { throw AIManagerError.operationFailed("Another action is running.") }
        isBusy = true
        defer { isBusy = false }
        if let manager { try await manager.restoreCleanupTrash(source, id) }
        else { try ConversationCleanup(home: source.home, userHome: source.userHome).restore(id) }
        if source.tool == .codex { hasScannedChatHistory = false }
        notice = "Items restored."
    }

    func emptyCleanup(_ source: CleanupSource, _ id: UUID) async throws {
        guard !isBusy else { throw AIManagerError.operationFailed("Another action is running.") }
        isBusy = true
        defer { isBusy = false }
        if let manager { try await manager.permanentlyRemoveCleanupTrash(source, id) }
        else { try ConversationCleanup(home: source.home, userHome: source.userHome).permanentlyRemove(id) }
        notice = "Items deleted for good."
    }

    func clearConversationIndex() async {
        await perform(failure: "Couldn’t clear the conversation index.") {
            chatDetailTask?.cancel()
            chatSelectionGeneration += 1
            try await chatHistoryProvider?.clearCache()
            hasScannedChatHistory = false
            appliedChatHistoryQuery = nil
            chatHistory = ChatHistorySnapshot()
            selectedChatID = nil
            selectedChat = nil
            chatPresentations = [:]
            isChatHistoryLoading = false
            isChatLoading = false
            chatHistoryError = nil
            notice = "Conversation index cleared."
        }
    }

    nonisolated private static func regularFileSize(at url: URL) -> Int64 {
        guard let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else { return 0 }
        return Int64(values.fileSize ?? 0)
    }

    func watchActivity() async {
        #if AI_MANAGER_PREVIEW
        if isDemo { return }
        #endif
        await prepareUsageCache()
        guard let chatHistoryMonitor, let chatHistoryProvider else { return }
        await indexActivity()
        for await _ in chatHistoryMonitor.changes() {
            guard !Task.isCancelled else { return }
            await indexActivity()
        }

        func indexActivity() async {
            do {
                let snapshot = try await chatHistoryProvider.refresh(query: requestedChatHistoryQuery)
                guard !Task.isCancelled else { return }
                if hasScannedChatHistory {
                    applyChatHistory(snapshot, query: requestedChatHistoryQuery)
                    await selectVisibleChat()
                }
            } catch is CancellationError {
                return
            } catch {
                chatHistoryError = "Activity could not be saved. \(error.localizedDescription)"
            }
        }
    }

    func searchChatHistory(query: String) async {
        if !query.isEmpty {
            do { try await Task.sleep(for: .milliseconds(120)) }
            catch { return }
        }
        guard !Task.isCancelled else { return }
        requestedChatHistoryQuery = query
        #if AI_MANAGER_PREVIEW
        if isDemo {
            await refreshChatHistory(query: query)
            return
        }
        #endif
        guard hasScannedChatHistory, let chatHistoryProvider else { return }
        let snapshot = await chatHistoryProvider.search(query: query)
        guard !Task.isCancelled, requestedChatHistoryQuery == query else { return }
        applyChatHistory(snapshot, query: query)
        await selectVisibleChat()
    }

    func refreshChatHistory(query: String) async {
        requestedChatHistoryQuery = query
        #if AI_MANAGER_PREVIEW
        if isDemo {
            let terms = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
            let all = scenario == .empty
                ? [] : (scenario == .historyStress ? DemoData.stressChatThreads : DemoData.chatThreads)
            let matches = terms.isEmpty ? all : all.filter { thread in
                let text = [thread.title, thread.preview, thread.workingDirectory, thread.threadID]
                    .compactMap { $0 }.joined(separator: "\n").lowercased()
                return terms.allSatisfy(text.contains)
            }
            applyChatHistory(ChatHistorySnapshot(
                threads: matches,
                totalThreadCount: all.count,
                matchingThreadCount: matches.count), query: query)
            await selectVisibleChat()
            return
        }
        #endif
        guard let chatHistoryProvider else {
            let message = unavailableReason ?? "The chat library is unavailable."
            if chatHistoryError != message { chatHistoryError = message }
            return
        }
        let showsInitialLoader = !hasScannedChatHistory
        if showsInitialLoader { isChatHistoryLoading = true }
        defer { if showsInitialLoader { isChatHistoryLoading = false } }
        do {
            let snapshot = try await chatHistoryProvider.refresh(query: query)
            guard !Task.isCancelled else { return }
            hasScannedChatHistory = true
            applyChatHistory(snapshot, query: query)
            if chatHistoryError != nil { chatHistoryError = nil }
            await selectVisibleChat()
        } catch is CancellationError {
            return
        } catch {
            hasScannedChatHistory = true
            let message = "The chat library could not refresh. \(error.localizedDescription)"
            if chatHistoryError != message { chatHistoryError = message }
        }
    }

    private func applyChatHistory(_ snapshot: ChatHistorySnapshot, query: String) {
        guard appliedChatHistoryQuery != query
                || snapshot.libraryRevision != chatHistory.libraryRevision
                || snapshot.totalThreadCount != chatHistory.totalThreadCount
                || snapshot.matchingThreadCount != chatHistory.matchingThreadCount
                || snapshot.skippedFileCount != chatHistory.skippedFileCount
                || snapshot.unreadableRecordCount != chatHistory.unreadableRecordCount
        else { return }
        chatHistory = snapshot
        appliedChatHistoryQuery = query
    }

    func selectChat(_ id: String) async {
        guard selectedChatID != id || selectedChat?.thread.id != id else { return }
        selectedChatID = id
        selectedChat = nil
        chatPresentations = [:]
        selectedChatQuery = ""
        selectedChatFilter = .all
        isChatPageLoading = false
        await loadSelectedChat(id)
    }

    func searchChatMessages(query: String, filter: ChatMessageFilter) async {
        guard let id = selectedChatID,
              selectedChatQuery != query || selectedChatFilter != filter else { return }
        selectedChatQuery = query
        selectedChatFilter = filter
        await loadSelectedChat(id)
    }

    func loadMoreChatMessages() async {
        guard !isChatPageLoading, chatDetailTask == nil,
              let id = selectedChatID, selectedChat?.nextOffset != nil else { return }
        await loadSelectedChat(id, appending: true)
    }

    private func selectVisibleChat() async {
        let visible = chatHistory.threads
        if let selectedChatID {
            if let summary = visible.first(where: { $0.id == selectedChatID }),
               selectedChat?.thread != summary {
                await loadSelectedChat(selectedChatID)
            } else if requestedChatHistoryQuery.isEmpty, selectedChat == nil, !visible.isEmpty,
                      !visible.contains(where: { $0.id == selectedChatID }) {
                // The remembered conversation is gone: open the newest one instead.
                self.selectedChatID = visible[0].id
                await loadSelectedChat(visible[0].id)
            }
            return
        }
        guard !visible.isEmpty else {
            return
        }
        let nextID = visible[0].id
        selectedChatID = nextID
        await loadSelectedChat(nextID)
    }

    private func loadSelectedChat(_ id: String, appending: Bool = false) async {
        chatDetailTask?.cancel()
        chatSelectionGeneration += 1
        let generation = chatSelectionGeneration
        let previous = selectedChat
        let offset = appending ? previous?.nextOffset ?? 0 : 0
        let query = selectedChatQuery
        let filter = selectedChatFilter
        if appending { isChatPageLoading = true }
        let showsLoader = selectedChat == nil
        if showsLoader { isChatLoading = true }
        defer {
            if generation == chatSelectionGeneration { isChatPageLoading = false }
            if showsLoader, generation == chatSelectionGeneration { isChatLoading = false }
        }
        #if AI_MANAGER_PREVIEW
        if isDemo {
            let detail = DemoData.chatDetail(id).map { detail in
                let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
                let matches = detail.messages.filter {
                    filter.includes($0.role) && terms.allSatisfy($0.text.lowercased().contains)
                }
                return ChatThreadDetail(thread: detail.thread,
                    messages: matches, omittedMessageCount: 0, matchingMessageCount: matches.count)
            }
            chatPresentations = (try? await ChatMessagePresenter.render(messages: detail?.messages ?? [])) ?? [:]
            selectedChat = detail
            return
        }
        #endif
        guard let chatHistoryProvider else { return }
        let task = Task { try await chatHistoryProvider.page(for: id, offset: offset, query: query, filter: filter) }
        chatDetailTask = task
        do {
            let detail = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            let rendered = try await ChatMessagePresenter.render(messages: detail?.messages ?? [])
            guard !Task.isCancelled,
                  generation == chatSelectionGeneration,
                  selectedChatID == id else { return }
            if appending, let detail, let previous {
                chatPresentations.merge(rendered) { _, new in new }
                selectedChat = ChatThreadDetail(thread: detail.thread,
                    messages: previous.messages + detail.messages, omittedMessageCount: 0,
                    matchingMessageCount: detail.matchingMessageCount, nextOffset: detail.nextOffset)
            } else {
                chatPresentations = rendered
                if detail != selectedChat { selectedChat = detail }
            }
            chatDetailTask = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == chatSelectionGeneration else { return }
            chatDetailTask = nil
            let message = "The selected chat could not open. \(error.localizedDescription)"
            if chatHistoryError != message { chatHistoryError = message }
        }
    }

    func resetImport() {
        actionGeneration += 1
        importPlan = nil
        importResult = nil
        conflictChoices = [:]
    }

    func closeAccountModal() {
        actionGeneration += 1
        showImport = false
        resetImport()
        accountModalMode = .add
        resetAccountLogin()
    }

    private func resetAccountModal() {
        actionGeneration += 1
        errorMessage = nil
        notice = nil
        resetImport()
        resetAccountLogin()
        droidAPIKey = ""
        droidAccountName = "Droid \((status?.accounts.filter { $0.identity.providerID == .droid }.count ?? 0) + 1)"
    }

    private func resetAccountLogin() {
        signInAccountID = nil
        accountLoginSession = nil
        accountLoginState = nil
        accountLoginMessage = nil
        selectedProviderID = .codex
    }

    private func perform(
        failure: String? = nil,
        recovery: String? = nil,
        _ operation: () async throws -> Void
    ) async {
        guard !isUnavailable else { reportUnavailable(); return }
        guard !isBusy else { return }
        let generation = actionGeneration
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        #if AI_MANAGER_PREVIEW
        if isDemo { try? await Task.sleep(for: .milliseconds(250)) }
        #endif
        guard !Task.isCancelled, generation == actionGeneration else { return }
        do { try await operation() }
        catch {
            errorMessage = [failure, error.localizedDescription, recovery]
                .compactMap { $0 }
                .joined(separator: " ")
        }
    }

    private func postMessage(_ text: String) {
        guard paths.isolationRoot == nil, let messagePoster else { return }
        #if AI_MANAGER_PREVIEW
        guard !isDemo else { return }
        #endif
        messagePoster(text)
    }

    private func reportUnavailable() {
        guard isUnavailable else { return }
        errorMessage = unavailableReason ?? "Switch is unavailable until its private data folder can be opened."
    }

    private func reloadStatus(
        using manager: AccountManager,
        refreshHistory: Bool = true
    ) async throws {
        let newStatus = try await manager.status()
        if status != newStatus { status = newStatus }
        if refreshHistory {
            let sharedHistory = await manager.historySummary(for: paths.sharedRoot)
            let summaries = Dictionary(uniqueKeysWithValues: newStatus.accounts.map {
                ($0.id, sharedHistory)
            })
            if accountHistory != summaries { accountHistory = summaries }
        }
    }

    private func apply(_ snapshot: AccountSnapshot) {
        status = snapshot.status
        providers = snapshot.providers
        discoveries = snapshot.discoveries
        pendingLoginSessions = snapshot.pendingLoginSessions
        if let current = accountLoginSession,
           !snapshot.pendingLoginSessions.contains(where: { $0.id == current.id }),
           accountLoginState != .completed {
            resetAccountLogin()
        }
    }

    private func makeLaunchArtifact(
        _ spec: LaunchSpec, name: String = "Open Switch Account.command", exportKeys: [String]? = nil
    ) throws -> URL {
        let directory = paths.applicationSupport.appending(path: "Launch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: name)
        var exports = (exportKeys ?? ["CODEX_HOME", "GROK_HOME", "CLAUDE_CONFIG_DIR", "FACTORY_HOME_OVERRIDE", "FACTORY_DISABLE_KEYRING"]).compactMap { key in
            spec.environment[key].map { "export \(key)=\(shellQuote($0))" }
        }
        if exportKeys == nil, paths.isolationRoot != nil, let home = spec.environment["HOME"] {
            exports.append("export HOME=\(shellQuote(home))")
        }
        let command = ([spec.executable.path] + spec.arguments).map(shellQuote).joined(separator: " ")
        let workingDirectory = spec.workingDirectory.map { "cd \(shellQuote($0.path))\n" } ?? ""
        let contents = (
            ["#!/bin/zsh", "set -e", "unset FACTORY_API_KEY OPENAI_API_KEY CODEX_ACCESS_TOKEN XAI_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_AWS_API_KEY ANTHROPIC_BASE_URL CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS"]
                + exports + [workingDirectory + "exec \(command)"]
        ).joined(separator: "\n") + "\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

#if AI_MANAGER_PREVIEW
enum DemoData {
    static let now = Date(timeIntervalSince1970: 1_789_281_000)

    // Synthetic generic-provider accounts: no credential, no network.
    static let genericAccounts: [AccountRecord] = [
        genericAccount(ProviderID(rawValue: "openrouter")),
        genericAccount(.geminiCLI),
        genericAccount(ProviderID(rawValue: "cursor")),
        genericAccount(ProviderID(rawValue: "zai")),
    ]

    /// The owner's other services, so Preview shows every kind of account: Grok Build, Claude Code,
    /// and Droid (a named login with a masked email hint).
    static let serviceAccounts: [AccountRecord] = {
        var droid = genericAccount(.droid)
        droid.identity.accountID = "Droid personal"
        droid.identity.email = "s***@gmail.com"
        return [genericAccount(.grokBuild), genericAccount(.claudeCode), droid]
    }()

    static func genericAccount(_ providerID: ProviderID) -> AccountRecord {
        let email: String?
        let key: String
        switch providerID.rawValue {
        case "grok-build": (email, key) = ("grok.demo@example.test", "grok-demo")
        case "claude-code": (email, key) = ("claude.demo@example.test", "claude-demo")
        case "droid": (email, key) = (nil, "droid-demo")
        case "openrouter": (email, key) = (nil, "or-9f3a1c27d84e")
        case "gemini-cli": (email, key) = ("ada.lovelace@example.test", "gemini-ada")
        case "cursor": (email, key) = ("grace.hopper@example.test", "cursor-grace")
        case "zai": (email, key) = (nil, "zai-71b0e55c09aa")
        default: (email, key) = (nil, "demo-\(providerID.rawValue)-5d2f")
        }
        let spec = ProviderCatalog.spec(providerID)
        // Stable identifiers so the checks and screenshots can name these accounts.
        let literal: String? = [
            "grok-build": "0E0A1005-7F3A-4C27-9D84-5B1E2A6C0005",
            "claude-code": "0E0A1006-7F3A-4C27-9D84-5B1E2A6C0006",
            "droid": "0E0A1007-7F3A-4C27-9D84-5B1E2A6C0007",
            "openrouter": "0E0A1001-7F3A-4C27-9D84-5B1E2A6C0001",
            "gemini-cli": "0E0A1002-7F3A-4C27-9D84-5B1E2A6C0002",
            "cursor": "0E0A1003-7F3A-4C27-9D84-5B1E2A6C0003",
            "zai": "0E0A1004-7F3A-4C27-9D84-5B1E2A6C0004",
        ][providerID.rawValue]
        let digest = literal.flatMap(UUID.init(uuidString:)) ?? UUID()
        return AccountRecord(
            id: digest,
            identity: AccountIdentity(
                providerID: providerID, email: email, userID: key,
                authMode: spec?.style == .files || [.grokBuild, .droid, .claudeCode].contains(providerID) ? .oauth : .apiKey),
            credentialFile: URL(fileURLWithPath: "/Demo/.switch/\(providerID.rawValue)/\(digest.uuidString).json"),
            home: URL(fileURLWithPath: "/Demo/Accounts/\(providerID.rawValue)", isDirectory: true),
            source: URL(fileURLWithPath: "/Demo/Sources/\(providerID.rawValue)", isDirectory: true),
            importedAt: now.addingTimeInterval(-3 * 86_400),
            verification: VerificationResult(
                state: .verifiedLocally, checkedAt: now,
                detail: "Saved locally. Usage has not been checked yet."),
            lastUsedAt: nil, credentialDigest: "demo-\(providerID.rawValue)-credential",
            autoImported: ["droid", "gemini-cli"].contains(providerID.rawValue))
    }

    /// Providers the Preview treats as already signed in on this Mac.
    static let signedInOnThisMac: Set<String> = ["gemini-cli", "cursor", "kilo"]

    static func liveIdentity(_ providerID: ProviderID) -> CredentialIdentity? {
        switch providerID.rawValue {
        case "gemini-cli": CredentialIdentity(key: "gemini-ada", email: "ada.lovelace@example.test")
        case "cursor": CredentialIdentity(key: "cursor-grace", email: "grace.hopper@example.test", plan: "Pro")
        case "windsurf", "kiro": nil
        default: CredentialIdentity(key: "demo-live-5d2f", email: "demo.user@example.test")
        }
    }

    /// Usage whose resets are relative to the real clock, so countdowns and pace stay lifelike.
    static var providerUsageStates: [UUID: ProviderUsageState] {
        var result: [UUID: ProviderUsageState] = [:]
        for (offset, account) in (serviceAccounts + genericAccounts).enumerated() {
            let providerID = account.identity.providerID
            var state = ProviderUsageState(
                usage: providerUsage(for: providerID, offset: offset), checkedAt: Date())
            if providerID.rawValue == "zai" {
                state.error = "The provider is rate limiting usage checks. Switch will retry later."
            }
            result[account.id] = state
        }
        return result
    }

    /// Synthetic incidents: a minor one for Codex (yellow dot), a major one for Gemini CLI (red),
    /// and scheduled maintenance for Claude Code (yellow).
    static var providerStatus: [ProviderID: ProviderStatusEntry] {
        let now = Date()
        return [
            .codex: ProviderStatusEntry(
                incident: ProviderIncident(
                    indicator: .minor, description: "Elevated error rates for Codex tasks",
                    updatedAt: now.addingTimeInterval(-14 * 60)),
                checkedAt: now),
            .geminiCLI: ProviderStatusEntry(
                incident: ProviderIncident(
                    indicator: .major, description: "Gemini CLI requests are failing for some users",
                    updatedAt: now.addingTimeInterval(-42 * 60)),
                checkedAt: now),
            .claudeCode: ProviderStatusEntry(
                incident: ProviderIncident(
                    indicator: .maintenance, description: "Scheduled maintenance for Claude Code",
                    updatedAt: now.addingTimeInterval(-3_600)),
                checkedAt: now),
        ]
    }

    /// 30 synthetic days ending today with a weekday rhythm, so charts look lifelike.
    static func demoChart(id: String, title: String, unit: String, scale: Double) -> UsageChart? {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"
        var values: [String: Double] = [:]
        for offset in 0..<30 {
            let date = Date().addingTimeInterval(-Double(offset) * 86_400)
            let wave = 0.55 + 0.45 * abs(sin(Double(offset) * 0.9))
            let weekend = Calendar(identifier: .gregorian).isDateInWeekend(date) ? 0.3 : 1
            values[day.string(from: date)] = (scale * wave * weekend * 100).rounded() / 100
        }
        return UsageChart.daily(id: id, title: title, unit: unit, values: values)
    }

    /// Synthetic Claude Code activity across all profiles.
    static var claudeActivity: ClaudeActivitySummary {
        ClaudeActivitySummary(
            rows: [
                ClaudeActivityRow(
                    label: "Today", tokens: 18_400_000, costUSD: 12.37,
                    detail: "Input 410,000, output 190,000, cache read 16,900,000, cache write 900,000 tokens."),
                ClaudeActivityRow(
                    label: "Yesterday", tokens: 31_900_000, costUSD: 21.08,
                    detail: "Input 720,000, output 330,000, cache read 29,000,000, cache write 1,850,000 tokens."),
                ClaudeActivityRow(
                    label: "Last 30 days", tokens: 612_000_000, costUSD: 403.9,
                    detail: "Input 14,000,000, output 6,100,000, cache read 560,000,000, cache write 31,900,000 tokens."),
            ],
            unpricedModels: ["claude-preview-synthetic"], computedAt: Date(),
            chart: demoChart(id: "claude-daily", title: "Daily cost (API-equivalent estimate)", unit: "USD", scale: 24))
    }

    static func providerUsage(for providerID: ProviderID, offset: Int) -> ProviderUsage {
        let now = Date()
        func window(_ id: String, _ title: String, used: Double, minutes: Int, resetsIn: TimeInterval,
                    detail: String? = nil) -> UsageWindow {
            UsageWindow(id: id, title: title, usedPercent: used, resetsAt: now.addingTimeInterval(resetsIn),
                        windowMinutes: minutes, detail: detail)
        }
        switch providerID.rawValue {
        case "claude-code":
            return ProviderUsage(
                windows: [
                    window("session", "Session", used: 31, minutes: 300, resetsIn: 3 * 3_600 + 12 * 60),
                    window("weekly", "Weekly", used: 46, minutes: 10_080, resetsIn: 4 * 86_400 + 3_600),
                    // A model-specific weekly window is named by its model.
                    window("weekly-fable", "Weekly Fable", used: 72, minutes: 10_080,
                           resetsIn: 4 * 86_400 + 3_600),
                ],
                plan: "Max", email: "claude.demo@example.test", fetchedAt: now.addingTimeInterval(-120))
        case "droid":
            return ProviderUsage(
                windows: [window("standard", "Standard tokens", used: 41, minutes: 43_200,
                                 resetsIn: 12 * 86_400, detail: "20.5M / 50M tokens")],
                plan: "Pro", fetchedAt: now.addingTimeInterval(-300))
        case "openrouter":
            return ProviderUsage(
                cost: UsageCost(used: 37.6, balance: 12.4, currency: "USD", period: "This month"),
                sections: [UsageSection("Key", [UsageRow("Label", "dev-laptop"), UsageRow("Free tier", "No")])],
                fetchedAt: now.addingTimeInterval(-90),
                charts: [demoChart(id: "activity-spend", title: "Daily spend", unit: "USD", scale: 2.4)].compactMap { $0 })
        case "gemini-cli":
            return ProviderUsage(
                windows: [
                    window("pro", "Pro models", used: 62, minutes: 1_440, resetsIn: 10 * 3_600,
                           detail: "620 / 1,000 requests"),
                    window("flash", "Flash models", used: 18, minutes: 1_440, resetsIn: 10 * 3_600,
                           detail: "180 / 1,000 requests"),
                ],
                plan: "Code Assist", email: "ada.lovelace@example.test", fetchedAt: now.addingTimeInterval(-150))
        case "cursor":
            return ProviderUsage(
                windows: [window("requests", "Included requests", used: 66, minutes: 43_200,
                                 resetsIn: 9 * 86_400 + 2 * 3_600, detail: "330 / 500 requests")],
                cost: UsageCost(used: 4.1, limit: 50, balance: 18.25, currency: "USD", period: "This cycle"),
                sections: [UsageSection("Plan", [UsageRow("Seats", "1"), UsageRow("On-demand", "Enabled")])],
                plan: "Pro", email: "grace.hopper@example.test", fetchedAt: now.addingTimeInterval(-240),
                charts: [demoChart(id: "spend-daily", title: "Daily tokens", unit: "tokens", scale: 1_800_000)].compactMap { $0 })
        default:
            return ProviderUsage(
                windows: [
                    window("session", "Session", used: 24, minutes: 300, resetsIn: 2 * 3_600 + 20 * 60),
                    window("weekly", "Weekly", used: 38, minutes: 10_080, resetsIn: 3 * 86_400 + 4 * 3_600),
                ],
                plan: "Coding Plan", fetchedAt: now.addingTimeInterval(-780))
        }
    }

    static let paths = ManagerPaths(
        applicationSupport: URL(fileURLWithPath: "/Switch Demo", isDirectory: true),
        defaultHome: URL(fileURLWithPath: "/Demo/Codex", isDirectory: true),
        sharedRoot: URL(fileURLWithPath: "/Demo/Shared", isDirectory: true),
        orcaAccountsRoot: URL(fileURLWithPath: "/Demo/Orca", isDirectory: true)
    )

    static let chatThreads = [
        chatThread(
            id: "demo-chat-accounts", threadID: "019f4b6d-accounts",
            title: "Polish the account import flow",
            preview: "The source rows now stay aligned and the review step is ready.",
            project: "/Projects/Switch", minutesAgo: 8, messages: 10, tokens: 15_200),
        chatThread(
            id: "demo-chat-linux", threadID: "019f4b6d-linux",
            title: "Verify the Linux release matrix",
            preview: "Both ARM64 and AMD64 passed in clean read-only containers.",
            project: "/Projects/Switch", minutesAgo: 74, messages: 3),
        chatThread(
            id: "demo-chat-icon", threadID: "019f4b6d-icon",
            title: "Trace the final Switch icon",
            preview: "The approved pixel trace is packaged for light and dark appearances.",
            project: "/Projects/Switch", minutesAgo: 1_460, messages: 4, archived: true),
    ]

    static let stressChatThreads: [ChatThreadSummary] = chatThreads + (chatThreads.count..<1_717).map {
        chatThread(
            id: "stress-chat-\($0)",
            threadID: "synthetic-\($0)",
            title: "Synthetic chat \(String(format: "%04d", $0))",
            preview: "A bounded synthetic row used to verify virtual chat rendering.",
            project: "/Tests/Chat History",
            minutesAgo: $0 + 1,
            messages: 8)
    }

    static func chatDetail(_ id: String) -> ChatThreadDetail? {
        guard let thread = chatThreads.first(where: { $0.id == id }) else { return nil }
        let copy: [(ChatMessageRole, String)]
        switch id {
        case "demo-chat-accounts":
            copy = [
                (.user, "Make the Codex account import flow compact and easy to scan."),
                (.assistant, "I aligned the provider, source, and scope sections to one grid."),
                (.tool, "read_file\nAccountWindow.swift"),
                (.other, "Checked the modal grid and row spacing."),
                (.user, "Keep every source row visible and give the groups more breathing room."),
                (.assistant, "The import step now groups each source with its location and chat count. The choice stays visible while the review panel updates below it.\n\n" + (1...24).map { "Step \($0): the source list, the review count, and the selected location stay in sync after each change." }.joined(separator: "\n")),
                (.tool, "```swift\nlet sources = discoveredSources.filter(\\.isSupported)\nfor source in sources {\n  review(source)\n}\n```"),
                (.other, "The selected source and review count matched after switching tabs."),
                (.user, "Check scrolling over the message and code blocks too."),
                (.assistant, "The source rows now stay aligned and the review step is ready."),
            ]
        case "demo-chat-linux":
            copy = [
                (.user, "Run the core and CLI checks on both Linux architectures."),
                (.assistant, "The read-only ARM64 container passed."),
                (.assistant, "Both ARM64 and AMD64 passed in clean read-only containers."),
            ]
        default:
            copy = [
                (.user, "Use the approved pixel trace everywhere."),
                (.assistant, "I preserved the exact silhouette and rebuilt each icon size."),
                (.user, "Check the light and dark variants at small sizes."),
                (.assistant, "The approved pixel trace is packaged for light and dark appearances."),
            ]
        }
        return ChatThreadDetail(
            thread: thread,
            messages: copy.enumerated().map { index, item in
                ChatMessage(
                    id: "\(id)#\(index)", role: item.0, text: item.1,
                    timestamp: thread.updatedAt.addingTimeInterval(Double(index - copy.count) * 45))
            },
            omittedMessageCount: 0)
    }

    /// Two Codex CLI accounts: one signed in and the default, one that needs sign-in.
    static let accounts = [
        account(id: "7A08CA5E-F528-4E45-B730-DAF68B0A3133", email: "ladygaga@gmail.com", workspace: "personal", state: .verifiedWithCodex, detail: "Codex CLI account check completed at 10:15 AM."),
        account(id: "5EA89BE0-D9A1-4727-983B-91640279C396", email: "bankai39@gmail.com", workspace: "design-team", state: .needsSignIn, detail: "Sign in before this account can launch Codex."),
    ]

    private static func utcDay(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// A year of synthetic daily usage for the Overview: an account total for each Codex, Gemini,
    /// and Cursor demo account, plus shared transcripts by model and project.
    static func usageHistory(accounts: [AccountRecord]) -> UsageHistorySnapshot {
        let today = Int(now.timeIntervalSince1970 / 86_400)
        func noise(_ day: Int, _ salt: Int) -> Double {
            abs(sin(Double(day * 31 + salt * 17) * 12.9898) * 43_758.5453).truncatingRemainder(dividingBy: 1)
        }
        func tokens(_ day: Int, _ salt: Int, _ base: Double) -> Int64 {
            let age = Double(day - (today - 364)) / 364
            let weekday = (day + 4) % 7  // 0 is Sunday
            let rhythm = weekday == 0 || weekday == 6 ? 0.35 : 1
            let spike = noise(day, salt + 50) > 0.93 ? 2.2 : 1
            if noise(day, salt + 90) < 0.07 { return 0 }
            return Int64(base * (0.55 + 0.45 * age) * rhythm * spike * (0.4 + 1.2 * noise(day, salt)))
        }
        let owned = accounts.filter { ["codex", "gemini-cli", "cursor"].contains($0.identity.providerID.rawValue) }
        let transcripts: [(service: String, model: String, project: String, base: Double)] = [
            ("codex", "gpt-5.6-sol", "/Users/demo/dev/switch", 2_500_000),
            ("codex", "gpt-5.6-sol", "/Users/demo/dev/site", 1_200_000),
            ("codex", "gpt-5.5-luna", "/Users/demo/dev/dotfiles", 600_000),
            ("claude-code", "claude-sonnet-5-5", "/Users/demo/dev/switch", 2_200_000),
            ("claude-code", "claude-opus-5", "/Users/demo/dev/recap", 1_100_000),
            ("claude-code", "claude-haiku-5", "/Users/demo/dev/dotfiles", 400_000),
            ("grok-build", "grok-build-2", "/Users/demo/dev/switch", 500_000),
        ]
        var points: [UsageHistoryPoint] = []
        for day in (today - 364)...today {
            let name = utcDay(Date(timeIntervalSince1970: Double(day) * 86_400))
            for (index, account) in owned.enumerated() {
                let count = tokens(day, index + 1, 3_000_000 / Double(index + 1))
                points.append(UsageHistoryPoint(
                    day: name, service: account.identity.providerID.rawValue,
                    accountID: account.id.uuidString.lowercased(), tokens: count, costUSD: Double(count) * 3.1e-6))
            }
            for (index, row) in transcripts.enumerated() {
                let count = tokens(day, index + 20, row.base)
                points.append(UsageHistoryPoint(
                    day: name, service: row.service, model: row.model, project: row.project,
                    tokens: count, costUSD: Double(count) * 4.2e-6))
            }
        }
        return UsageHistorySnapshot(points: points, today: utcDay(Date(timeIntervalSince1970: Double(today) * 86_400)))
    }

    /// Synthetic sessions for one demo day: each transcript point becomes a session; the first two
    /// Codex ones have transcripts in the demo library, the rest were "removed".
    static func usageDay(_ day: String, points: [UsageHistoryPoint]) -> OverviewDayInput {
        let dayPoints = points.filter { $0.day == day }
        let library = ["019f4b6d-accounts", "019f4b6d-linux"]
        let base = Double((OverviewDay.epoch(day) ?? 0) * 86_400)
        var codex = 0
        let sessions: [UsageDaySession] = dayPoints.filter { $0.project != nil && $0.tokens > 0 }.enumerated().map { index, point in
            var threadID: String?
            if point.service == "codex" {
                threadID = codex < library.count ? library[codex] : "removed-\(codex)"
                codex += 1
            }
            return UsageDaySession(
                id: "\(point.service):\(index)", service: point.service, threadID: threadID,
                project: point.project ?? "", model: point.model, start: Date(timeIntervalSince1970: base + 8 * 3_600 + Double(index) * 5_400),
                tokens: point.tokens, costUSD: point.costUSD)
        }.sorted { $0.tokens > $1.tokens }
        return OverviewDayInput(
            points: dayPoints, sessions: sessions,
            threads: Dictionary(chatThreads.map { ($0.threadID, $0) }, uniquingKeysWith: { first, _ in first }))
    }

    static func usage(account: AccountRecord, offset: Int) -> CodexAccountUsageSnapshot {
        let used = [42, 68, 17][offset % 3]
        let resetNow = Date()
        return CodexAccountUsageSnapshot(
            account: CodexAccountDetailsSnapshot(
                kind: "chatgpt",
                email: account.identity.email,
                plan: offset == 1 ? "Team" : "Plus"
            ),
            requiresOpenAIAuthentication: true,
            rateLimits: CodexRateLimitsSnapshot(
                accountID: account.identity.accountID,
                ordinaryUsageAllowed: offset != 2,
                defaultBucket: CodexRateLimitBucketSnapshot(
                    id: "codex",
                    name: "Codex",
                    plan: offset == 1 ? "Team" : "Plus",
                    model: "gpt-5.6-sol",
                    primary: CodexRateLimitWindowSnapshot(
                        usedPercent: used,
                        windowDurationMinutes: 300,
                        resetsAt: resetNow.addingTimeInterval(Double(75 + offset * 20) * 60)
                    ),
                    secondary: CodexRateLimitWindowSnapshot(
                        usedPercent: min(used + 11, 100),
                        windowDurationMinutes: 10_080,
                        resetsAt: resetNow.addingTimeInterval(Double(2 + offset) * 86_400)
                    ),
                    credits: CodexCreditsSnapshot(
                        hasCredits: true,
                        unlimited: offset == 1,
                        balance: offset == 1 ? nil : "12.50"
                    ),
                    spendControlReached: offset == 2
                ),
                buckets: [
                    "codex-mini": CodexRateLimitBucketSnapshot(
                        id: "codex-mini",
                        name: "Fast models",
                        plan: offset == 1 ? "Team" : "Plus",
                        model: "gpt-5.6-luna",
                        primary: CodexRateLimitWindowSnapshot(
                            usedPercent: min(used + 8, 100),
                            windowDurationMinutes: 1_440,
                            resetsAt: resetNow.addingTimeInterval(Double(12 + offset) * 3_600)
                        ),
                        secondary: nil,
                        credits: nil,
                        spendControlReached: false
                    )
                ]
            ),
            usage: CodexUsageSummarySnapshot(
                lifetimeTokens: Int64(2_840_000 + offset * 490_000),
                peakDailyTokens: Int64(184_000 + offset * 23_000),
                currentStreakDays: Int64(4 + offset),
                longestStreakDays: 12,
                longestRunningTurnSeconds: 214
            ),
            // Synthetic days counted back from today, so Today and Yesterday are never empty.
            dailyUsage: (0..<21).map { day in
                CodexDailyUsageSnapshot(
                    startDate: utcDay(resetNow.addingTimeInterval(-Double(day) * 86_400)),
                    tokens: Int64(max(4_000, 5_200_000 - day * 230_000 + offset * 500_000)))
            },
            fetchedAt: resetNow.addingTimeInterval(Double(-offset * 480))
        )
    }

    static let discoveries = [
        source(id: "default-home", path: "/Demo/Sources/.codex", email: "ladygaga@gmail.com", workspace: "personal", settings: ["config.toml", "AGENTS.md", "rules", "skills"], active: 248, archived: 19),
        source(id: "orca-team", path: "/Demo/Sources/Orca/team", email: "bankai39@gmail.com", workspace: "research-team", settings: ["config.toml", "rules", "skills", "hooks.json"], active: 291, archived: 9),
        DiscoveredSource(
            id: "needs-sign-in",
            path: URL(fileURLWithPath: "/Demo/Sources/Needs Sign-in", isDirectory: true),
            identity: nil,
            support: .missingAuth,
            settings: ["config.toml"],
            history: HistorySummary(activeTranscripts: 28, archivedTranscripts: 4, hasIndexes: true),
            inspectionError: "No auth.json was found."
        ),
        DiscoveredSource(
            id: "keychain-only",
            path: URL(fileURLWithPath: "/Demo/Sources/Keychain Only", isDirectory: true),
            identity: nil,
            support: .keychainOnly,
            settings: [],
            history: HistorySummary(),
            inspectionError: "Sign in with Codex to create file-based credentials."
        ),
    ]

    static let manualSource = source(id: "chosen-home", path: "/Demo/Sources/Chosen Home", email: "joestar89@gmail.com", workspace: "freelance", settings: ["config.toml", "AGENTS.md"], active: 37, archived: 2)

    static func importPlan(source: DiscoveredSource, identity: AccountIdentity, mode: ImportMode, paths: ManagerPaths) -> ImportPlan {
        let id: UUID
        switch source.id {
        case "orca-team":
            id = UUID(uuidString: "5E0D7961-54CB-4D75-9CDA-715A3FF20F17")!
        case "chosen-home":
            id = UUID(uuidString: "B0BCF8B7-A01C-42F8-A494-3FB9D16504BB")!
        default:
            id = UUID(uuidString: "84EB5AA2-E27F-4A92-9C4D-C1A678565F31")!
        }
        let conflicts = mode == .full ? [
            SettingConflict(relativePath: "config.toml", importedDigest: "demo-imported-config", sharedDigest: "demo-shared-config"),
            SettingConflict(relativePath: "rules", importedDigest: "demo-imported-rules", sharedDigest: "demo-shared-rules", externalTarget: URL(fileURLWithPath: "/Demo/External Rules", isDirectory: true)),
        ] : []
        var manifest = [
            ManifestEntry(relativePath: "auth.json", category: .credential, byteCount: 2_048, selected: true, disposition: "Copy credential"),
            ManifestEntry(relativePath: "config.toml", category: .setting, byteCount: 1_024, selected: mode == .full, disposition: mode == .full ? "Review conflict" : "Keep shared"),
        ]
        if mode == .full {
            manifest.append(ManifestEntry(relativePath: "sessions", category: .transcript, byteCount: 48_000_000, selected: true, disposition: "Merge 248 chats"))
        }
        return ImportPlan(
            id: id, source: source.path,
            destination: paths.applicationSupport.appending(path: "accounts/\(id.uuidString)/home", directoryHint: .isDirectory),
            backup: paths.applicationSupport.appending(path: "backups/\(id.uuidString)", directoryHint: .isDirectory),
            mode: mode, identity: identity, sourceAuthDigest: "demo-auth-digest", reviewedDataDigest: "demo-reviewed-digest",
            manifest: manifest, conflicts: conflicts,
            warnings: mode == .full ? ["Shared settings choices affect every account opened from this Mac."] : [],
            requiredBytes: mode == .full ? 48_003_072 : 3_072,
            credentialDestination: paths.credentialStore.appending(path: "\(id.uuidString).json"),
            sharedDestination: paths.sharedRoot
        )
    }

    static func importResult(plan: ImportPlan) -> ImportResult {
        let account = AccountRecord(
            id: plan.id, identity: plan.identity,
            credentialFile: plan.credentialDestination,
            home: plan.destination, source: plan.source, importedAt: now,
            verification: VerificationResult(state: .imported, checkedAt: now, detail: "Demo import passed the local account check."),
            credentialDigest: "demo-imported-credential"
        )
        return ImportResult(account: account, backup: plan.backup, importedFiles: plan.manifest.filter(\.selected).count,
                            importedChats: plan.mode == .full ? 248 : 0, unresolved: [], verification: account.verification)
    }

    static func recovery(paths: ManagerPaths) -> RecoveryOperation {
        RecoveryOperation(
            id: UUID(uuidString: "91A8C7EB-CF4B-4991-A17B-E9CC68C66E15")!, kind: "import", phase: .staged,
            source: URL(fileURLWithPath: "/Demo/Sources/Interrupted Import", isDirectory: true),
            destination: paths.applicationSupport.appending(path: "accounts/recovery/home", directoryHint: .isDirectory),
            backup: paths.applicationSupport.appending(path: "backups/recovery", directoryHint: .isDirectory)
        )
    }

    static func recoveryConflict(paths: ManagerPaths) -> RecoveryOperation {
        RecoveryOperation(
            id: UUID(uuidString: "146E18F1-41BB-45EC-BA80-F309458F1414")!, kind: "switch", phase: .conflicted,
            source: paths.defaultHome.appending(path: "auth.json"),
            destination: paths.defaultHome.appending(path: "auth.json"),
            backup: paths.applicationSupport.appending(path: "backups/conflicted-switch", directoryHint: .isDirectory)
        )
    }

    static func divergence(paths: ManagerPaths) -> LinkedSettingsDivergence {
        LinkedSettingsDivergence(
            accountID: accounts[1].id, relativePath: "config.toml", localPath: accounts[1].home.appending(path: "config.toml"),
            intendedTarget: paths.sharedRoot.appending(path: "config.toml"), localFingerprint: "demo-local-settings",
            backupRoot: paths.applicationSupport.appending(path: "backups/settings", directoryHint: .isDirectory)
        )
    }

    private static func account(id: String, email: String, workspace: String, state: VerificationState, detail: String) -> AccountRecord {
        AccountRecord(
            id: UUID(uuidString: id)!, identity: AccountIdentity(email: email, userID: "user-\(id)", accountID: "acct-\(workspace)", workspaceID: workspace, authMode: .chatGPT),
            home: URL(fileURLWithPath: "/Demo/Accounts/\(workspace)", isDirectory: true),
            source: URL(fileURLWithPath: "/Demo/Sources/\(workspace)", isDirectory: true), importedAt: now.addingTimeInterval(-86_400),
            verification: VerificationResult(state: state, checkedAt: state == .needsSignIn ? nil : now, detail: detail),
            lastUsedAt: state == .verifiedWithCodex ? now : nil, credentialDigest: "demo-\(workspace)-credential"
        )
    }

    private static func source(id: String, path: String, email: String, workspace: String, settings: [String], active: Int, archived: Int) -> DiscoveredSource {
        DiscoveredSource(
            id: id, path: URL(fileURLWithPath: path, isDirectory: true),
            identity: AccountIdentity(email: email, userID: "source-user-\(workspace)", accountID: "source-\(workspace)", workspaceID: workspace, authMode: .chatGPT),
            support: .supportedChatGPT, settings: settings,
            history: HistorySummary(activeTranscripts: active, archivedTranscripts: archived, hasIndexes: true)
        )
    }

    private static func chatThread(
        id: String,
        threadID: String,
        title: String,
        preview: String,
        project: String,
        minutesAgo: Int,
        messages: Int,
        tokens: Int64? = nil,
        archived: Bool = false
    ) -> ChatThreadSummary {
        ChatThreadSummary(
            id: id,
            threadID: threadID,
            title: title,
            preview: preview,
            workingDirectory: project,
            updatedAt: now.addingTimeInterval(Double(-minutesAgo * 60)),
            archived: archived,
            messageCount: messages,
            fileByteCount: Int64(messages * 2_048),
            source: paths.sharedRoot.appending(path: "sessions/\(id).jsonl"),
            unreadableRecordCount: 0,
            totalTokens: tokens)
    }
}
#endif
