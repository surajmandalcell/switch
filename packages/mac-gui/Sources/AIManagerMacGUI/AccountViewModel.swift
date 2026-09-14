import AppKit
import Combine
import Foundation
import AIManagerCore

protocol ChatHistoryProviding: Sendable {
    func refresh(query: String) async throws -> ChatHistorySnapshot
    func search(query: String) async -> ChatHistorySnapshot
    func detail(for id: String) async throws -> ChatThreadDetail?
}

private struct IndexedChatHistoryProvider: ChatHistoryProviding {
    let index: ChatHistoryIndex

    func refresh(query: String) async throws -> ChatHistorySnapshot {
        try await index.refresh(query: query)
    }

    func search(query: String) async -> ChatHistorySnapshot {
        await index.search(query: query)
    }

    func detail(for id: String) async throws -> ChatThreadDetail? {
        try await index.detail(for: id)
    }
}

@MainActor
final class AccountViewModel: ObservableObject {
    #if AI_MANAGER_PREVIEW
    enum Scenario { case demo, empty, allStates, historyStress }
    #endif

    @Published var status: ManagerStatus?
    @Published var selectedAccountID: UUID?
    @Published var discoveries: [DiscoveredSource] = []
    @Published var isBusy = false
    @Published var refreshedAt: Date?
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var showImport = false
    @Published var selectedProviderID: ProviderID = .codex
    @Published var importMode: ImportMode = .authOnly
    @Published var selectedSourceID: String?
    @Published var importPlan: ImportPlan?
    @Published var conflictChoices: [String: ConflictChoice] = [:]
    @Published var importResult: ImportResult?
    @Published var accountHistory: [UUID: HistorySummary] = [:]
    @Published private(set) var chatHistory = ChatHistorySnapshot()
    @Published private(set) var selectedChatID: String?
    @Published private(set) var selectedChat: ChatThreadDetail?
    @Published private(set) var renderedChatMessages: [String: AttributedString] = [:]
    @Published private(set) var isChatHistoryLoading = false
    @Published private(set) var isChatLoading = false
    @Published private(set) var chatHistoryError: String?
    @Published private(set) var isUnavailable = false
    @Published private(set) var hasLoaded = false

    let paths: ManagerPaths
    private let manager: AccountManager?
    private let chatHistoryProvider: (any ChatHistoryProviding)?
    private let chatHistoryMonitor: (any ChatHistoryMonitoring)?
    #if AI_MANAGER_PREVIEW
    private var scenario: Scenario?
    #endif
    private var unavailableReason: String? = nil
    private var actionGeneration = 0
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
            try await reloadStatus(using: manager)
            let newStatus = status!
            if selectedAccountID == nil {
                selectedAccountID = newStatus.defaultAccountID ?? newStatus.accounts.first?.id
            }
        }
    }

    func refresh() async {
        if let manager {
            await perform(failure: "Couldn’t refresh accounts.", recovery: "Try Refresh again.") {
                try await reloadStatus(using: manager)
                refreshedAt = Date()
                notice = "Accounts and backup state refreshed."
            }
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
        status = ManagerStatus(
            accounts: accounts,
            defaultAccountID: accounts.first?.id,
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
        selectedProviderID = .codex
        importMode = .authOnly
        importPlan = nil
        conflictChoices = [:]
        importResult = nil
        accountHistory = Dictionary(uniqueKeysWithValues: accounts.map {
            ($0.id, HistorySummary(activeTranscripts: 475, archivedTranscripts: 92, hasIndexes: true))
        })
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

    func beginImport() async {
        guard !isUnavailable else { reportUnavailable(); return }
        guard !isBusy else { return }
        showImport = true
        resetImport()
        await discover()
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

    func switchDefault() async {
        if let manager {
            guard let id = selectedAccountID else { return }
            await perform(
                failure: "Couldn’t change the default account.",
                recovery: "Close running Codex sessions, resolve Backup items, then retry."
            ) {
                let result = try await manager.switchDefault(to: id)
                try await reloadStatus(using: manager)
                notice = "New Codex sessions will use this account. Backup: \(result.backup.path)"
            }
            return
        }
        #if AI_MANAGER_PREVIEW
        guard isDemo else { reportUnavailable(); return }
        guard let id = selectedAccountID, var current = status else { return }
        await perform {
            current.defaultAccountID = id
            status = current
            notice = "Future demo sessions will use this account. Existing sessions are unchanged."
        }
        #else
        reportUnavailable()
        #endif
    }

    func verify() async {
        if let manager {
            guard let id = selectedAccountID else { return }
            await perform(failure: "Couldn’t check the account files.", recovery: "Try the check again.") {
                let result = await manager.verifyLocal(accountID: id)
                notice = result.detail
                try await reloadStatus(using: manager)
            }
            return
        }
        #if AI_MANAGER_PREVIEW
        guard isDemo else { reportUnavailable(); return }
        guard let id = selectedAccountID, var current = status,
              let index = current.accounts.firstIndex(where: { $0.id == id }) else { return }
        await perform {
            current.accounts[index].verification = VerificationResult(
                state: .verifiedWithCodex,
                checkedAt: DemoData.now,
                detail: "Demo verification passed without a network request."
            )
            status = current
            notice = current.accounts[index].verification.detail
        }
        #else
        reportUnavailable()
        #endif
    }

    func openAccount() async {
        if let manager {
            guard let id = selectedAccountID else { return }
            await perform(
                failure: "Couldn’t open Codex.",
                recovery: "Run ai-manager open \(id.uuidString) in a terminal."
            ) {
                if paths.isolationRoot != nil {
                    _ = try await manager.switchDefault(to: id)
                    let spec = try await manager.launchSpec(accountID: id)
                    try await reloadStatus(using: manager)
                    _ = try makeLaunchArtifact(spec)
                    notice = "Account launch file prepared for isolated validation. Terminal was not opened."
                    return
                }
                let script = try makeCoordinatedLaunchArtifact(accountID: id)
                guard NSWorkspace.shared.open(script) else {
                    throw AIManagerError.operationFailed(
                        "Terminal could not open the account launch file. Run ai-manager open \(id.uuidString) in a terminal.")
                }
                notice = "Terminal accepted the launch request. Account activation and any startup error appear there."
            }
            return
        }
        #if AI_MANAGER_PREVIEW
        guard isDemo else { reportUnavailable(); return }
        await perform {
            guard selectedAccount != nil else { return }
            notice = "Demo account opened. No Terminal process was started."
        }
        #else
        reportUnavailable()
        #endif
    }

    func repairLinkedSetting(_ issue: LinkedSettingsDivergence) async {
        if let manager {
            await perform(
                failure: "Couldn’t repair the shared setting.",
                recovery: "Refresh the account and review the changed entry again."
            ) {
                let result = try await manager.repairLinkedSetting(
                    accountID: issue.accountID,
                    relativePath: issue.relativePath,
                    reviewedFingerprint: issue.localFingerprint
                )
                try await reloadStatus(using: manager)
                notice = "The shared settings link was restored. The displaced local entry is preserved in \(result.backup.path)."
            }
            return
        }
        #if AI_MANAGER_PREVIEW
        guard isDemo else { reportUnavailable(); return }
        await perform {
            guard var current = status else { return }
            current.linkedSettingsDivergences.removeAll { $0.id == issue.id }
            status = current
            notice = "Demo shared settings link repaired in memory."
        }
        #else
        reportUnavailable()
        #endif
    }

    func copySavedAuthPath() {
        guard !isUnavailable else { reportUnavailable(); return }
        guard let credential = selectedAccount?.credentialFile.path else { return }
        #if AI_MANAGER_PREVIEW
        if isDemo {
            notice = "Demo saved auth path ready. The clipboard was not changed."
            return
        }
        #endif
        if paths.isolationRoot != nil {
            notice = "Saved auth path validated in isolation. The clipboard was not changed."
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(credential, forType: .string)
            notice = "Saved auth path copied."
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

    func showSharedRoot() {
        guard !isUnavailable else { reportUnavailable(); return }
        #if AI_MANAGER_PREVIEW
        if isDemo {
            notice = "Demo shared data includes 8 settings and 567 chats. Finder was not opened."
            return
        }
        #endif
        if paths.isolationRoot != nil {
            notice = "Shared data path validated in isolation. Finder was not opened."
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([paths.sharedRoot])
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

    func watchChatHistory() async {
        await refreshChatHistory(query: requestedChatHistoryQuery)
        #if AI_MANAGER_PREVIEW
        if isDemo { return }
        #endif
        guard let chatHistoryMonitor else { return }
        for await _ in chatHistoryMonitor.changes() {
            guard !Task.isCancelled else { return }
            await refreshChatHistory(query: requestedChatHistoryQuery)
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
        await loadSelectedChat(id)
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

    private func loadSelectedChat(_ id: String) async {
        chatDetailTask?.cancel()
        chatSelectionGeneration += 1
        let generation = chatSelectionGeneration
        let showsLoader = selectedChat == nil
        if showsLoader { isChatLoading = true }
        defer {
            if showsLoader, generation == chatSelectionGeneration { isChatLoading = false }
        }
        #if AI_MANAGER_PREVIEW
        if isDemo {
            let detail = DemoData.chatDetail(id)
            renderedChatMessages = (try? await Self.render(messages: detail?.messages ?? [])) ?? [:]
            selectedChat = detail
            return
        }
        #endif
        guard let chatHistoryProvider else { return }
        let task = Task { try await chatHistoryProvider.detail(for: id) }
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
            renderedChatMessages = rendered
            if detail != selectedChat { selectedChat = detail }
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
                rendered[message.id] = (try? AttributedString(markdown: message.text))
                    ?? AttributedString(message.text)
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

    private func reloadStatus(using manager: AccountManager) async throws {
        let newStatus = try await manager.status()
        let sharedHistory = await manager.historySummary(for: paths.sharedRoot)
        let summaries = Dictionary(uniqueKeysWithValues: newStatus.accounts.map {
            ($0.id, sharedHistory)
        })
        status = newStatus
        accountHistory = summaries
    }

    private func makeLaunchArtifact(_ spec: LaunchSpec) throws -> URL {
        let directory = paths.applicationSupport.appending(path: "Launch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: "Open Switch Account.command")
        var exports = spec.environment["CODEX_HOME"].map { ["export CODEX_HOME=\(shellQuote($0))"] } ?? []
        if paths.isolationRoot != nil, let home = spec.environment["HOME"] {
            exports.append("export HOME=\(shellQuote(home))")
        }
        let command = ([spec.executable.path] + spec.arguments).map(shellQuote).joined(separator: " ")
        let workingDirectory = spec.workingDirectory.map { "cd \(shellQuote($0.path))\n" } ?? ""
        let contents = (
            ["#!/bin/zsh", "set -e", "unset OPENAI_API_KEY CODEX_ACCESS_TOKEN"]
                + exports + [workingDirectory + "exec \(command)"]
        ).joined(separator: "\n") + "\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func makeCoordinatedLaunchArtifact(accountID: UUID, helper suppliedHelper: URL? = nil) throws -> URL {
        let helper = suppliedHelper ?? Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/ai-manager")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw AIManagerError.operationFailed(
                "The bundled account launcher is missing. Reinstall Switch or run ai-manager open \(accountID.uuidString) in a terminal.")
        }
        let directory = paths.applicationSupport.appending(path: "Launch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: "Open Switch Account.command")
        let command = [helper.path, "open", accountID.uuidString].map(shellQuote).joined(separator: " ")
        let contents = [
            "#!/bin/zsh",
            "set -e",
            "unset OPENAI_API_KEY CODEX_ACCESS_TOKEN",
            "exec \(command)",
        ].joined(separator: "\n") + "\n"
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
            project: "/Projects/Switch", minutesAgo: 8, messages: 4),
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
                (.user, "Keep every source row visible and give the groups more breathing room."),
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
        account(id: "7A08CA5E-F528-4E45-B730-DAF68B0A3133", email: "suraj@example.com", workspace: "personal", state: .verifiedWithCodex, detail: "Verified with Codex at 10:15 AM."),
        account(id: "5EA89BE0-D9A1-4727-983B-91640279C396", email: "studio@example.com", workspace: "design-team", state: .needsSignIn, detail: "Sign in before this account can launch Codex."),
        account(id: "A9FC9B4F-94AC-4645-AF6C-617546DBA966", email: "studio@example.com", workspace: "research-team", state: .imported, detail: "Imported locally. Verification has not run."),
    ]

    static let discoveries = [
        source(id: "default-home", path: "/Demo/Sources/.codex", email: "new@example.com", workspace: "personal", settings: ["config.toml", "AGENTS.md", "rules", "skills"], active: 248, archived: 19),
        source(id: "orca-team", path: "/Demo/Sources/Orca/team", email: "studio@example.com", workspace: "research-team", settings: ["config.toml", "rules", "skills", "hooks.json"], active: 291, archived: 9),
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

    static let manualSource = source(id: "chosen-home", path: "/Demo/Sources/Chosen Home", email: "chosen@example.com", workspace: "freelance", settings: ["config.toml", "AGENTS.md"], active: 37, archived: 2)

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
            verification: VerificationResult(state: .imported, checkedAt: now, detail: "Demo import verified locally."),
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
            unreadableRecordCount: 0)
    }
}
#endif
