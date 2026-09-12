import AppKit
import Combine
import Foundation
import AIManagerCore

@MainActor
final class AccountViewModel: ObservableObject {
    enum Scenario { case demo, empty, allStates }

    @Published var status: ManagerStatus?
    @Published var selectedAccountID: UUID?
    @Published var discoveries: [DiscoveredSource] = []
    @Published var isBusy = false
    @Published var refreshedAt: Date?
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var showImport = false
    @Published var importMode: ImportMode = .authOnly
    @Published var selectedSourceID: String?
    @Published var importPlan: ImportPlan?
    @Published var conflictChoices: [String: ConflictChoice] = [:]
    @Published var importResult: ImportResult?
    @Published var accountHistory: [UUID: HistorySummary] = [:]
    @Published private(set) var isUnavailable = false
    @Published private(set) var hasLoaded = false

    let paths: ManagerPaths
    private let manager: AccountManager?
    private var scenario: Scenario?
    private var unavailableReason: String? = nil
    private var actionGeneration = 0

    init(paths: ManagerPaths, manager injectedManager: AccountManager? = nil) {
        self.paths = paths
        scenario = nil
        do {
            manager = try injectedManager ?? AccountManager(paths: paths)
        } catch {
            manager = nil
            isUnavailable = true
            hasLoaded = true
            unavailableReason = "IIA Directeur could not open its private data folder. \(error.localizedDescription)"
            errorMessage = unavailableReason
        }
    }

    init(scenario: Scenario = .demo, demoPaths: ManagerPaths? = nil) {
        paths = demoPaths ?? DemoData.paths
        manager = nil
        self.scenario = scenario
        reset(to: scenario)
    }

    var isDemo: Bool { scenario != nil }

    var selectedAccount: AccountRecord? {
        status?.accounts.first { $0.id == selectedAccountID }
    }

    func load() async {
        defer { hasLoaded = true }
        guard let manager else {
            if status == nil, let scenario { reset(to: scenario) }
            if scenario == nil { reportUnavailable() }
            return
        }
        await perform(
            failure: "Couldn’t load accounts.",
            recovery: "Refresh after resolving any item shown in Recovery."
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
                notice = "Accounts and recovery state refreshed."
            }
            return
        }
        guard isDemo else { reportUnavailable(); return }
        await perform {
            refreshedAt = Date()
            notice = "Demo data refreshed. Accounts and selections are unchanged."
        }
    }

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
        notice = scenario == .allStates ? "Demo recovery and settings issues are ready to review." : nil
        showImport = false
        importMode = .authOnly
        importPlan = nil
        conflictChoices = [:]
        importResult = nil
        accountHistory = Dictionary(uniqueKeysWithValues: accounts.map {
            ($0.id, HistorySummary(activeTranscripts: 475, archivedTranscripts: 92, hasIndexes: true))
        })
        hasLoaded = true
    }

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
                failure: "Couldn’t find Codex profiles.",
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
        guard isDemo else { reportUnavailable(); return }
        await perform {
            discoveries = DemoData.discoveries
            if !discoveries.contains(where: { $0.id == selectedSourceID }) {
                selectedSourceID = discoveries.first(where: { $0.support == .supportedChatGPT })?.id
            }
            notice = "Demo sources refreshed. No files were inspected."
        }
    }

    func chooseSource() async {
        if manager != nil {
            let panel = NSOpenPanel()
            panel.title = "Choose a Codex home or auth.json"
            panel.prompt = "Choose"
            panel.canChooseDirectories = true
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            await discover(explicit: url)
            return
        }
        guard isDemo else { reportUnavailable(); return }
        await perform {
            selectedSourceID = DemoData.manualSource.id
            if !discoveries.contains(where: { $0.id == DemoData.manualSource.id }) {
                discoveries.append(DemoData.manualSource)
            }
            notice = "Demo source selected. No file picker was opened."
        }
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
    }

    func commitImport() async {
        guard let plan = importPlan else {
            if isUnavailable { reportUnavailable() }
            return
        }
        if let manager {
            await perform(
                failure: "Couldn’t import the account.",
                recovery: "Open Recovery before retrying if an interrupted operation is listed."
            ) {
                importResult = try await manager.importAccount(plan: plan, decisions: conflictChoices)
                try await reloadStatus(using: manager)
                selectedAccountID = importResult?.account.id
            }
            return
        }
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
        guard isDemo else { reportUnavailable(); return }
        await perform {
            guard var plan = importPlan,
                  let index = plan.conflicts.firstIndex(where: { $0.relativePath == relativePath }) else { return }
            plan.conflicts[index].externalTargetBytes = 12_480
            importPlan = plan
            notice = "Demo linked data reviewed. No file was opened."
        }
    }

    func switchDefault() async {
        if let manager {
            guard let id = selectedAccountID else { return }
            await perform(
                failure: "Couldn’t change the default account.",
                recovery: "Close running Codex sessions, resolve Recovery items, then retry."
            ) {
                let result = try await manager.switchDefault(to: id)
                try await reloadStatus(using: manager)
                notice = "Future default-home Codex sessions will use this account. Backup: \(result.backup.path)"
            }
            return
        }
        guard isDemo else { reportUnavailable(); return }
        guard let id = selectedAccountID, var current = status else { return }
        await perform {
            current.defaultAccountID = id
            status = current
            notice = "Future demo sessions will use this account. Existing sessions are unchanged."
        }
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
    }

    func openAccount() async {
        if let manager {
            guard let id = selectedAccountID else { return }
            await perform(
                failure: "Couldn’t open Codex.",
                recovery: "Copy the profile path and open it from a terminal."
            ) {
                let spec = try await manager.launchSpec(accountID: id)
                let script = try makeLaunchArtifact(spec)
                if paths.isolationRoot != nil {
                    notice = "Account launch file prepared for isolated validation. Terminal was not opened."
                    return
                }
                guard NSWorkspace.shared.open(script) else {
                    throw AIManagerError.operationFailed(
                        "Terminal could not open the account launch file. Copy the profile path and open it from a terminal instead.")
                }
                notice = "Opened a new terminal session for this account. Existing sessions keep their current account."
            }
            return
        }
        guard isDemo else { reportUnavailable(); return }
        await perform {
            guard selectedAccount != nil else { return }
            notice = "Demo account opened. No Terminal process was started."
        }
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
        guard isDemo else { reportUnavailable(); return }
        await perform {
            guard var current = status else { return }
            current.linkedSettingsDivergences.removeAll { $0.id == issue.id }
            status = current
            notice = "Demo shared settings link repaired in memory."
        }
    }

    func copyProfilePath() {
        guard !isUnavailable else { reportUnavailable(); return }
        guard let home = selectedAccount?.home.path else { return }
        if isDemo {
            notice = "Demo profile path ready. The clipboard was not changed."
        } else if paths.isolationRoot != nil {
            notice = "Profile path validated in isolation. The clipboard was not changed."
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(home, forType: .string)
            notice = "Profile path copied."
        }
    }

    func showSharedRoot() {
        guard !isUnavailable else { reportUnavailable(); return }
        if isDemo {
            notice = "Demo shared data includes 8 settings and 567 chats. Finder was not opened."
        } else if paths.isolationRoot != nil {
            notice = "Shared data path validated in isolation. Finder was not opened."
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([paths.sharedRoot])
        }
    }

    func recover() async {
        if let manager {
            await perform(
                failure: "Couldn’t recover the interrupted operation.",
                recovery: "Review the pending item and its protected backup before retrying."
            ) {
                let results = try await manager.recover()
                notice = results.isEmpty
                    ? "No recovery was needed." : results.map(\.message).joined(separator: " ")
                try await reloadStatus(using: manager)
            }
            return
        }
        guard isDemo else { reportUnavailable(); return }
        await perform {
            guard var current = status else { return }
            let count = current.pendingRecovery.count
            current.pendingRecovery = []
            status = current
            notice = count == 0 ? "No recovery was needed." : "Demo recovery completed in memory."
        }
    }

    func resolveRecoveryConflict(_ operation: RecoveryOperation, choice: RecoveryConflictChoice) async {
        if let manager {
            await perform(
                failure: "Couldn’t resolve the recovery conflict.",
                recovery: "Confirm that Codex is closed, then review the protected backup and retry."
            ) {
                let result = try await manager.resolveRecoveryConflict(
                    operationID: operation.id,
                    choice: choice
                )
                notice = result.message
                try await reloadStatus(using: manager)
            }
            return
        }
        guard isDemo else { reportUnavailable(); return }
        await perform {
            guard var current = status else { return }
            current.pendingRecovery.removeAll { $0.id == operation.id }
            status = current
            notice = choice == .preserveCurrent
                ? "Current demo files kept; the protected backup remains available."
                : "Protected demo backup restored; the replaced files remain preserved."
        }
    }

    func showDemoError() {
        guard isDemo else { return }
        errorMessage = "The selected account needs sign-in before it can be opened."
    }

    func history(for account: AccountRecord) -> HistorySummary {
        accountHistory[account.id] ?? HistorySummary()
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
        if isDemo { try? await Task.sleep(for: .milliseconds(250)) }
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
        errorMessage = unavailableReason ?? "IIA Directeur is unavailable until its private data folder can be opened."
    }

    private func reloadStatus(using manager: AccountManager) async throws {
        let newStatus = try await manager.status()
        var summaries: [UUID: HistorySummary] = [:]
        for account in newStatus.accounts {
            summaries[account.id] = await manager.historySummary(for: account.home)
        }
        status = newStatus
        accountHistory = summaries
    }

    private func makeLaunchArtifact(_ spec: LaunchSpec) throws -> URL {
        let directory = paths.applicationSupport.appending(path: "Launch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: "Open IIA Directeur Account.command")
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

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum DemoData {
    static let now = Date(timeIntervalSince1970: 1_788_748_100)
    static let paths = ManagerPaths(
        applicationSupport: URL(fileURLWithPath: "/IIA Directeur Demo", isDirectory: true),
        defaultHome: URL(fileURLWithPath: "/Demo/Codex", isDirectory: true),
        sharedRoot: URL(fileURLWithPath: "/Demo/Shared", isDirectory: true),
        orcaAccountsRoot: URL(fileURLWithPath: "/Demo/Orca", isDirectory: true)
    )

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
        let conflicts = mode == .full ? [
            SettingConflict(relativePath: "config.toml", importedDigest: "demo-imported-config", sharedDigest: "demo-shared-config"),
            SettingConflict(relativePath: "rules", importedDigest: "demo-imported-rules", sharedDigest: "demo-shared-rules", externalTarget: URL(fileURLWithPath: "/Demo/External Rules", isDirectory: true)),
        ] : []
        var manifest = [
            ManifestEntry(relativePath: "auth.json", category: .credential, byteCount: 2_048, selected: true, disposition: "Copy credential"),
            ManifestEntry(relativePath: "config.toml", category: .setting, byteCount: 1_024, selected: mode == .full, disposition: mode == .full ? "Review conflict" : "Link shared"),
        ]
        if mode == .full {
            manifest.append(ManifestEntry(relativePath: "sessions", category: .transcript, byteCount: 48_000_000, selected: true, disposition: "Merge 248 chats"))
        }
        return ImportPlan(
            id: UUID(uuidString: "84EB5AA2-E27F-4A92-9C4D-C1A678565F31")!, source: source.path,
            destination: paths.applicationSupport.appending(path: "accounts/demo-import/home", directoryHint: .isDirectory),
            backup: paths.applicationSupport.appending(path: "backups/demo-import", directoryHint: .isDirectory),
            mode: mode, identity: identity, sourceAuthDigest: "demo-auth-digest", reviewedDataDigest: "demo-reviewed-digest",
            manifest: manifest, conflicts: conflicts,
            warnings: mode == .full ? ["Shared settings choices affect every linked account."] : [],
            requiredBytes: mode == .full ? 48_003_072 : 3_072
        )
    }

    static func importResult(plan: ImportPlan) -> ImportResult {
        let account = AccountRecord(
            id: UUID(), identity: plan.identity,
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
}
