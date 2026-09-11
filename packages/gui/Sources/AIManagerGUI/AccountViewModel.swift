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

    let paths: ManagerPaths
    private var scenario: Scenario
    private var actionGeneration = 0

    init(
        paths: ManagerPaths? = nil,
        scenario: Scenario = .demo
    ) {
        self.paths = paths ?? DemoData.paths
        self.scenario = scenario
        reset(to: scenario)
    }

    var selectedAccount: AccountRecord? {
        status?.accounts.first { $0.id == selectedAccountID }
    }

    func load() async {
        if status == nil { reset(to: scenario) }
    }

    func refresh() async {
        await perform {
            refreshedAt = Date()
            notice = "Demo data refreshed. Accounts and selections are unchanged."
        }
    }

    func reset(to scenario: Scenario = .demo) {
        actionGeneration += 1
        self.scenario = scenario
        let accounts = scenario == .empty ? [] : DemoData.accounts
        status = ManagerStatus(
            accounts: accounts,
            defaultAccountID: accounts.first?.id,
            sharedRoot: paths.sharedRoot,
            pendingRecovery: scenario == .allStates ? [DemoData.recovery(paths: paths)] : [],
            linkedSettingsDivergences: scenario == .allStates ? [DemoData.divergence(paths: paths)] : []
        )
        selectedAccountID = accounts.first?.id
        discoveries = scenario == .empty ? [] : DemoData.discoveries
        selectedSourceID = discoveries.first(where: { $0.support == .supportedChatGPT })?.id
        isBusy = false
        refreshedAt = nil
        errorMessage = scenario == .allStates ? "Demo: Codex could not verify one account." : nil
        notice = scenario == .allStates ? "Demo recovery and settings issues are ready to review." : nil
        showImport = false
        importMode = .authOnly
        importPlan = nil
        conflictChoices = [:]
        importResult = nil
    }

    func beginImport() async {
        showImport = true
        resetImport()
        await discover()
    }

    func discover(explicit _: URL? = nil) async {
        await perform {
            discoveries = DemoData.discoveries
            if !discoveries.contains(where: { $0.id == selectedSourceID }) {
                selectedSourceID = discoveries.first(where: { $0.support == .supportedChatGPT })?.id
            }
            notice = "Demo sources refreshed. No files were inspected."
        }
    }

    func chooseSource() async {
        await perform {
            selectedSourceID = DemoData.manualSource.id
            if !discoveries.contains(where: { $0.id == DemoData.manualSource.id }) {
                discoveries.append(DemoData.manualSource)
            }
            notice = "Demo source selected. No file picker was opened."
        }
    }

    func reviewImport() async {
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
        guard let plan = importPlan else { return }
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
        await perform {
            guard var plan = importPlan,
                  let index = plan.conflicts.firstIndex(where: { $0.relativePath == relativePath }) else { return }
            plan.conflicts[index].externalTargetBytes = 12_480
            importPlan = plan
            notice = "Demo linked data reviewed. No file was opened."
        }
    }

    func switchDefault() async {
        guard let id = selectedAccountID, var current = status else { return }
        await perform {
            current.defaultAccountID = id
            status = current
            notice = "Future demo sessions will use this account. Existing sessions are unchanged."
        }
    }

    func verify() async {
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
        await perform {
            guard selectedAccount != nil else { return }
            notice = "Demo account opened. No Terminal process was started."
        }
    }

    func repairLinkedSetting(_ issue: LinkedSettingsDivergence) async {
        await perform {
            guard var current = status else { return }
            current.linkedSettingsDivergences.removeAll { $0.id == issue.id }
            status = current
            notice = "Demo shared settings link repaired in memory."
        }
    }

    func copyProfilePath() {
        guard selectedAccount != nil else { return }
        notice = "Demo profile path ready. The clipboard was not changed."
    }

    func showSharedRoot() {
        notice = "Demo shared data includes 8 settings and 567 chats. Finder was not opened."
    }

    func recover() async {
        await perform {
            guard var current = status else { return }
            let count = current.pendingRecovery.count
            current.pendingRecovery = []
            status = current
            notice = count == 0 ? "No recovery was needed." : "Demo recovery completed in memory."
        }
    }

    func showDemoError() {
        errorMessage = "Demo: The selected credential needs sign-in."
    }

    func resetImport() {
        actionGeneration += 1
        importPlan = nil
        importResult = nil
        conflictChoices = [:]
    }

    private func perform(_ operation: () -> Void) async {
        guard !isBusy else { return }
        let generation = actionGeneration
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, generation == actionGeneration else { return }
        operation()
    }
}

private enum DemoData {
    static let now = Date(timeIntervalSince1970: 1_788_748_100)
    static let paths = ManagerPaths(
        applicationSupport: URL(fileURLWithPath: "/AI Manager Demo", isDirectory: true),
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

    static func divergence(paths: ManagerPaths) -> LinkedSettingsDivergence {
        LinkedSettingsDivergence(
            accountID: accounts[1].id, relativePath: "config.toml", localPath: accounts[1].home.appending(path: "config.toml"),
            intendedTarget: paths.sharedRoot.appending(path: "config.toml"), localFingerprint: "demo-local-settings",
            backupRoot: paths.applicationSupport.appending(path: "backups/settings", directoryHint: .isDirectory)
        )
    }

    private static func account(id: String, email: String, workspace: String, state: VerificationState, detail: String) -> AccountRecord {
        AccountRecord(
            id: UUID(uuidString: id)!, identity: AccountIdentity(email: email, accountID: "acct-\(workspace)", workspaceID: workspace, authMode: .chatGPT),
            home: URL(fileURLWithPath: "/Demo/Accounts/\(workspace)", isDirectory: true),
            source: URL(fileURLWithPath: "/Demo/Sources/\(workspace)", isDirectory: true), importedAt: now.addingTimeInterval(-86_400),
            verification: VerificationResult(state: state, checkedAt: state == .needsSignIn ? nil : now, detail: detail),
            lastUsedAt: state == .verifiedWithCodex ? now : nil, credentialDigest: "demo-\(workspace)-credential"
        )
    }

    private static func source(id: String, path: String, email: String, workspace: String, settings: [String], active: Int, archived: Int) -> DiscoveredSource {
        DiscoveredSource(
            id: id, path: URL(fileURLWithPath: path, isDirectory: true),
            identity: AccountIdentity(email: email, accountID: "source-\(workspace)", workspaceID: workspace, authMode: .chatGPT),
            support: .supportedChatGPT, settings: settings,
            history: HistorySummary(activeTranscripts: active, archivedTranscripts: archived, hasIndexes: true)
        )
    }
}
