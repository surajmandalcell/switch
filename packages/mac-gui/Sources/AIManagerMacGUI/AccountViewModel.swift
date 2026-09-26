import AppKit
import Combine
import Foundation
import AIManagerCore

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

    @Published var status: ManagerStatus?
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
    @Published var notice: String?
    @Published var showImport = false
    @Published var accountModalMode: AccountModalMode = .add
    @Published var providers: [ProviderDescriptor] = AccountManager.providerCatalog
    @Published var pendingLoginSessions: [AccountLoginSession] = []
    @Published var accountLoginSession: AccountLoginSession?
    @Published var accountLoginState: AccountLoginState?
    @Published var accountLoginMessage: String?
    @Published var selectedProviderID: ProviderID = .codex
    @Published var importMode: ImportMode = .authOnly
    @Published var selectedSourceID: String?
    @Published var importPlan: ImportPlan?
    @Published var conflictChoices: [String: ConflictChoice] = [:]
    @Published var importResult: ImportResult?
    @Published var accountHistory: [UUID: HistorySummary] = [:]
    @Published private(set) var accountUsage: [UUID: CachedCodexAccountUsage] = [:]
    @Published private(set) var usageSnapshots: [UUID: CodexAccountUsageSnapshot] = [:]
    @Published private(set) var retainedDailyUsage: [UUID: [CodexDailyUsageSnapshot]] = [:]
    @Published private(set) var apiPrice: CodexAPIPrice?
    @Published private(set) var usageRefreshAccountID: UUID?
    @Published private(set) var usageError: String?
    @Published private(set) var chatHistory = ChatHistorySnapshot()
    @Published private(set) var selectedChatID: String?
    @Published private(set) var selectedChat: ChatThreadDetail?
    @Published private(set) var renderedChatMessages: [String: AttributedString] = [:]
    @Published private(set) var isChatHistoryLoading = false
    @Published private(set) var isChatPageLoading = false
    private var selectedChatQuery = ""
    private var selectedChatFilter: ChatMessageFilter = .all
    @Published private(set) var isChatLoading = false
    @Published private(set) var chatHistoryError: String?
    @Published private(set) var isUnavailable = false
    @Published private(set) var hasLoaded = false

    let paths: ManagerPaths
    private let manager: AccountManager?
    private var usageCache: CodexUsageStatisticsCache?
    private let usageDatabaseURL: URL?
    private let pricingResolver: CodexAPIPricingResolver?
    private var didPrepareUsageCache = false
    private var usageErrorAccountID: UUID?
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
        usageDatabaseURL = paths.applicationSupport.appending(path: "cache/account-usage.sqlite")
        pricingResolver = CodexAPIPricingResolver(
            cacheURL: paths.applicationSupport.appending(path: "cache/model-pricing.json"))
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
    }

    #if AI_MANAGER_PREVIEW
    init(scenario: Scenario = .demo, demoPaths: ManagerPaths? = nil) {
        paths = demoPaths ?? DemoData.paths
        manager = nil
        usageCache = nil
        usageDatabaseURL = nil
        pricingResolver = nil
        didPrepareUsageCache = true
        chatHistoryProvider = nil
        chatHistoryMonitor = nil
        self.scenario = scenario
        reset(to: scenario)
    }

    var isDemo: Bool { scenario != nil }
    #endif

    var selectedAccount: AccountRecord? {
        status?.accounts.first { $0.id == selectedAccountID }
    }

    func load() async {
        defer { hasLoaded = true }
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
        Task { await self.loadAPIPricing() }
        Task { await self.refreshAutomaticUsage() }
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
        } catch {
            errorMessage = "Couldn’t refresh accounts. \(error.localizedDescription)"
        }
    }

    func refresh() async {
        if let manager {
            await perform(failure: "Couldn’t refresh accounts.", recovery: "Try Refresh again.") {
                apply(try await manager.refreshAccounts(includeDiscoveries: false))
                refreshedAt = Date()
                notice = "Accounts, sign-ins, and backup state refreshed."
            }
            await loadCachedUsage()
            Task { await self.loadAPIPricing() }
            await refreshDefaultUsage()
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
        let accounts = scenario == .empty ? [] : DemoData.accounts
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
        usageSnapshots = Dictionary(uniqueKeysWithValues: accounts.enumerated().map { index, account in
            (account.id, DemoData.usage(account: account, offset: index))
        })
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
        renderedChatMessages = Dictionary(uniqueKeysWithValues: (selectedChat?.messages ?? []).map {
            ($0.id, (try? AttributedString(markdown: $0.text)) ?? AttributedString($0.text))
        })
        isChatHistoryLoading = false
        isChatLoading = false
        chatHistoryError = nil
        hasScannedChatHistory = true
        hasLoaded = true
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
            let providerName = providerID.displayName
            await perform(
                failure: "Couldn’t start sign-in.",
                recovery: "Confirm that \(providerName) is installed, then try again."
            ) {
                let start = try await manager.startAccountLogin(providerID: providerID)
                accountLoginSession = start.session
                accountLoginState = .waitingForLogin
                accountLoginMessage = "Finish signing in to \(providerName), then return here and choose Check Now."
                if !pendingLoginSessions.contains(where: { $0.id == start.session.id }) {
                    pendingLoginSessions.append(start.session)
                }
            }
            return
        }
        #if AI_MANAGER_PREVIEW
        guard isDemo else { reportUnavailable(); return }
        await perform {
            guard selectedProviderID == .codex else {
                throw AIManagerError.unsupportedSource("This provider is not available yet.")
            }
            let session = AccountLoginSession(
                id: UUID(uuidString: "45A9767B-D942-41B6-88D8-2410E367B815")!,
                providerID: .codex,
                createdAt: DemoData.now
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
            let providerName = session.providerID.displayName
            await perform(
                failure: "Couldn’t complete sign-in.",
                recovery: "Finish the \(providerName) sign-in and choose Check Now again."
            ) {
                let check = try await manager.checkAccountLogin(
                    id: session.id,
                    credentialChoice: credentialChoice
                )
                accountLoginState = check.state
                accountLoginMessage = check.message
                if let account = check.account {
                    try await reloadStatus(using: manager)
                    selectedAccountID = account.id
                    pendingLoginSessions.removeAll { $0.id == session.id }
                    let name = account.identity.email ?? account.identity.accountID ?? "The account"
                    let providerName = account.identity.providerID.displayName
                    notice = status?.isDefault(account) == true
                        ? "New \(providerName) sessions will use \(name)."
                        : "\(name) was saved. Choose Use for New Sessions when you want to switch."
                    await loadCachedUsage()
                    Task { await self.refreshUsage(accountID: account.id) }
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
            if let account = status?.accounts.first {
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

    func switchDefault(to requestedID: UUID? = nil) async {
        if let manager {
            guard let id = requestedID ?? selectedAccountID,
                  let providerID = status?.accounts.first(where: { $0.id == id })?
                    .identity.providerID else { return }
            let providerName = providerID.displayName
            await perform(
                failure: "Couldn’t change the default account.",
                recovery: "Resolve any item in Backup, then try again."
            ) {
                let result = try await manager.switchDefault(to: id)
                try await reloadStatus(using: manager)
                selectedAccountID = id
                notice = "New \(providerName) sessions will use this account. Backup: \(result.backup.path)"
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
                notice = result.verification.detail
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
            let providerName = providerID.displayName
            await perform(
                failure: "Couldn’t open \(providerName).",
                recovery: "Check the saved account, then try again."
            ) {
                if status?.defaultAccountID(for: providerID) != id {
                    _ = try await manager.switchDefault(to: id)
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
                notice = "Terminal accepted the \(providerName) launch request."
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
                let result = try await manager.repairLinkedSetting(
                    accountID: issue.accountID,
                    relativePath: issue.relativePath,
                    reviewedFingerprint: issue.localFingerprint
                )
                try await reloadStatus(using: manager)
                notice = "The account data entry was restored. The displaced local entry is preserved in \(result.backup.path)."
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
                if usageErrorAccountID == accountID {
                    usageError = nil
                    usageErrorAccountID = nil
                }
                if selectedAccountID == accountID {
                    selectedAccountID = status?.firstDefaultAccountID ?? status?.accounts.first?.id
                }
                let accountName = account.identity.email ?? account.identity.accountID ?? "Account"
                notice = "\(accountName) was deleted from Switch."
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
            if selectedAccountID == accountID {
                selectedAccountID = current.firstDefaultAccountID ?? current.accounts.first?.id
            }
            let accountName = account.identity.email ?? account.identity.accountID ?? "Account"
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
                let results = try await manager.recover()
                notice = results.isEmpty
                    ? "No backup work was needed."
                    : results.map { backupCopy($0.message) }.joined(separator: " ")
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
                let result = try await manager.resolveRecoveryConflict(
                    operationID: operation.id,
                    choice: choice
                )
                notice = backupCopy(result.message)
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
            notice = "Usage cache cleared. Refresh an account to fetch it again."
        }
    }

    func cleanupData() async throws -> (conversations: [CleanupConversation], samples: [CleanupUsageSample], trash: [ConversationCleanupBatch]) {
        #if AI_MANAGER_PREVIEW
        if isDemo { return ([], [], []) }
        #endif
        await prepareUsageCache()
        guard let manager, let usageCache else { throw AIManagerError.operationFailed("Cleanup storage is unavailable.") }
        _ = try await chatHistoryProvider?.refresh(query: "")
        let summaries = await chatHistoryProvider?.cleanupSummaries() ?? []
        let conversations = try await manager.cleanupInventory(summaries: summaries)
        let samples = try await usageCache.cleanupSamples()
        let trash = try await manager.cleanupTrash()
        return (conversations, samples, trash)
    }

    func reviewConversationCleanup(_ items: [CleanupConversation]) async throws -> ConversationCleanupPlan {
        guard let manager else { throw AIManagerError.operationFailed("Cleanup is unavailable.") }
        return try await manager.reviewCleanup(items)
    }

    func applyCleanup(_ plan: ConversationCleanupPlan?, samples: [CleanupUsageSample], clearIndex: Bool) async throws {
        guard !isBusy, let manager, let usageCache, let chatHistoryProvider else {
            throw AIManagerError.operationFailed("Cleanup is unavailable while another action is running.")
        }
        isBusy = true
        defer { isBusy = false }
        if let plan {
            _ = try await manager.moveConversationsToTrash(plan) { sources in
                try await chatHistoryProvider.preserveActivity(for: sources)
            }
            chatDetailTask?.cancel()
            chatSelectionGeneration += 1
            selectedChat = nil
            selectedChatID = nil
            renderedChatMessages = [:]
            hasScannedChatHistory = false
        }
        try await usageCache.removeCleanupSamples(samples)
        await loadCachedUsage()
        if clearIndex {
            try await chatHistoryProvider.clearCache()
            chatHistory = ChatHistorySnapshot()
            selectedChat = nil
            selectedChatID = nil
            renderedChatMessages = [:]
            hasScannedChatHistory = false
        }
        let moved = plan?.conversations.count ?? 0
        let bytes = ByteCountFormatter.string(fromByteCount: plan?.bytes ?? 0, countStyle: .file)
        notice = "Cleanup complete: \(moved) conversations (\(bytes)) moved to recoverable trash; \(samples.count) usage samples cleared\(clearIndex ? "; conversation index cleared" : ""). Daily activity totals were retained."
    }

    func restoreCleanup(_ id: UUID) async throws {
        guard !isBusy, let manager else { throw AIManagerError.operationFailed("Another action is running.") }
        isBusy = true
        defer { isBusy = false }
        try await manager.restoreCleanupTrash(id)
        hasScannedChatHistory = false
        notice = "Conversations restored."
    }

    func emptyCleanup(_ id: UUID) async throws {
        guard !isBusy, let manager else { throw AIManagerError.operationFailed("Another action is running.") }
        isBusy = true
        defer { isBusy = false }
        try await manager.permanentlyRemoveCleanupTrash(id)
        notice = "Selected conversation trash permanently removed."
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
            renderedChatMessages = [:]
            isChatHistoryLoading = false
            isChatLoading = false
            chatHistoryError = nil
            notice = "Conversation index cleared. It will rebuild when Chat History opens."
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
        renderedChatMessages = [:]
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
            renderedChatMessages = (try? await Self.render(messages: detail?.messages ?? [])) ?? [:]
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
            let rendered = try await Self.render(messages: detail?.messages ?? [])
            guard !Task.isCancelled,
                  generation == chatSelectionGeneration,
                  selectedChatID == id else { return }
            if appending, let detail, let previous {
                renderedChatMessages.merge(rendered) { _, new in new }
                selectedChat = ChatThreadDetail(thread: detail.thread,
                    messages: previous.messages + detail.messages, omittedMessageCount: 0,
                    matchingMessageCount: detail.matchingMessageCount, nextOffset: detail.nextOffset)
            } else {
                renderedChatMessages = rendered
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

    nonisolated private static func render(
        messages: [ChatMessage]
    ) async throws -> [String: AttributedString] {
        let task = Task.detached(priority: .userInitiated) {
            var rendered: [String: AttributedString] = [:]
            rendered.reserveCapacity(messages.count)
            for (index, message) in messages.enumerated() {
                if index.isMultiple(of: 16) { try Task.checkCancellation() }
                let text = String(message.text.prefix(120_000))
                rendered[message.id] = (try? AttributedString(markdown: text)) ?? AttributedString(text)
            }
            return rendered
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
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
    }

    private func resetAccountLogin() {
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

    private func makeLaunchArtifact(_ spec: LaunchSpec) throws -> URL {
        let directory = paths.applicationSupport.appending(path: "Launch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: "Open Switch Account.command")
        var exports = ["CODEX_HOME", "GROK_HOME", "CLAUDE_CONFIG_DIR"].compactMap { key in
            spec.environment[key].map { "export \(key)=\(shellQuote($0))" }
        }
        if paths.isolationRoot != nil, let home = spec.environment["HOME"] {
            exports.append("export HOME=\(shellQuote(home))")
        }
        let command = ([spec.executable.path] + spec.arguments).map(shellQuote).joined(separator: " ")
        let workingDirectory = spec.workingDirectory.map { "cd \(shellQuote($0.path))\n" } ?? ""
        let contents = (
            ["#!/bin/zsh", "set -e", "unset OPENAI_API_KEY CODEX_ACCESS_TOKEN XAI_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_AWS_API_KEY ANTHROPIC_BASE_URL CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS"]
                + exports + [workingDirectory + "exec \(command)"]
        ).joined(separator: "\n") + "\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func backupCopy(_ value: String) -> String {
        value
            .replacingOccurrences(of: "Recovery", with: "Backup")
            .replacingOccurrences(of: "recovery", with: "backup")
    }
}

#if AI_MANAGER_PREVIEW
private enum DemoData {
    static let now = Date(timeIntervalSince1970: 1_789_281_000)
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
                (.assistant, "The import step now groups each source with its location and chat count. The choice stays visible while the review panel updates below it."),
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

    static let accounts = [
        account(id: "7A08CA5E-F528-4E45-B730-DAF68B0A3133", email: "ladygaga@gmail.com", workspace: "personal", state: .verifiedWithCodex, detail: "Codex CLI account check completed at 10:15 AM."),
        account(id: "5EA89BE0-D9A1-4727-983B-91640279C396", email: "bankai39@gmail.com", workspace: "design-team", state: .needsSignIn, detail: "Sign in before this account can launch Codex."),
        account(id: "A9FC9B4F-94AC-4645-AF6C-617546DBA966", email: "joestar89@gmail.com", workspace: "research-team", state: .imported, detail: "Imported locally. The account check has not run."),
    ]

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
            dailyUsage: [
                CodexDailyUsageSnapshot(startDate: "2026-09-14", tokens: Int64(42_000 + offset * 5_000)),
                CodexDailyUsageSnapshot(startDate: "2026-09-13", tokens: Int64(31_000 + offset * 4_000)),
                CodexDailyUsageSnapshot(startDate: "2026-09-12", tokens: Int64(18_000 + offset * 3_000)),
            ],
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
