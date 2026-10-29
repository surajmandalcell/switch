import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum WriterState: Sendable { case inactive, active, unknown }
public enum FaultPoint: Sendable, Equatable { case duringHistoryCopy, afterTemporaryCopy, afterHomePublication, afterCredentialPublication, afterDefaultCredentialPublication, afterRegistryCommit, afterRecoveryConflictRestore, afterProcessStart }

public actor AccountManager {
    public typealias WriterCheck = @Sendable (URL) async -> WriterState
    public typealias CapacityCheck = @Sendable (URL) -> Int64?

    private struct Registry: Codable {
        var accounts: [AccountRecord] = []
        var defaultAccountIDs: [String: UUID] = [:]
        var needsDefaultMigration = false

        var defaultAccountID: UUID? {
            get { defaultAccountID(for: .codex) }
            set { setDefaultAccountID(newValue, for: .codex) }
        }

        init() {}

        func defaultAccountID(for providerID: ProviderID) -> UUID? {
            defaultAccountIDs[providerID.rawValue]
        }

        mutating func setDefaultAccountID(_ accountID: UUID?, for providerID: ProviderID) {
            if let accountID {
                defaultAccountIDs[providerID.rawValue] = accountID
            } else {
                defaultAccountIDs.removeValue(forKey: providerID.rawValue)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case accounts, defaultAccountID, defaultAccountIDs
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            accounts = try values.decodeIfPresent([AccountRecord].self, forKey: .accounts) ?? []
            let decodedDefaults = try values.decodeIfPresent(
                [String: UUID].self, forKey: .defaultAccountIDs)
            defaultAccountIDs = decodedDefaults ?? [:]
            needsDefaultMigration = decodedDefaults == nil
            if let legacy = try values.decodeIfPresent(UUID.self, forKey: .defaultAccountID),
               let providerID = accounts.first(where: { $0.id == legacy })?.identity.providerID,
               defaultAccountIDs[providerID.rawValue] == nil {
                defaultAccountIDs[providerID.rawValue] = legacy
            }
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(accounts, forKey: .accounts)
            try values.encodeIfPresent(defaultAccountID, forKey: .defaultAccountID)
            try values.encode(defaultAccountIDs, forKey: .defaultAccountIDs)
        }
    }

    private struct RecoveryTarget {
        var destination: URL
        var backup: URL?
        var previousDigest: String?
    }

    private struct UsageReadLease {
        var accountID: UUID
        var defaultAccountID: UUID?
        var identity: AccountIdentity
        var credentialDigest: String
        var sourceCredentialDigest: String
        var usesLiveCredential: Bool
        var root: URL
        var source: CodexAppServerSource
        var executable: URL
    }

    private let paths: ManagerPaths
    private let fileManager: FileManager
    private let provider: CodexProviderAdapter
    private let grokProvider: GrokProviderAdapter
    private let droidProvider: DroidProviderAdapter
    private let droidLoginReader: DroidLoginReader
    private let droidProcessLister: @Sendable () throws -> [DroidProcess]
    private let claudeProfiles: ClaudeCodeProfiles
    private let providerStore: ProviderAccountStore
    private let providerSpecs: [ProviderSpec]
    private let writerCheck: WriterCheck
    private let faultInjector: @Sendable (FaultPoint) throws -> Void
    private let verificationTimeout: TimeInterval
    private let capacityCheck: CapacityCheck
    private let loginRunner: AccountLoginRunner
    private let lock: OperationLock
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var grokRefreshAttempts: [String: Date] = [:]
    private var grokRefreshTimeout: TimeInterval = 20
    /// Digest of the live Droid login that discovery last examined, so doctor runs once per login.
    private var droidProbe: String?

    public init(paths: ManagerPaths = .standard(), fileManager: FileManager = .default, writerCheck: WriterCheck? = nil, capacityCheck: CapacityCheck? = nil, verificationTimeout: TimeInterval = 10, loginRunner: AccountLoginRunner = .foundation, faultInjector: @escaping @Sendable (FaultPoint) throws -> Void = { _ in }, providerSpecs: [ProviderSpec] = ProviderCatalog.all, droidProcessLister: (@Sendable () throws -> [DroidProcess])? = nil, droidLoginReader: DroidLoginReader = .init()) throws {
        self.paths = paths
        self.fileManager = fileManager
        self.provider = CodexProviderAdapter(fileManager: fileManager)
        self.grokProvider = GrokProviderAdapter(fileManager: fileManager)
        self.droidProvider = DroidProviderAdapter(fileManager: fileManager)
        self.droidLoginReader = droidLoginReader
        self.droidProcessLister = droidProcessLister ?? { try DroidProviderAdapter.processes() }
        self.claudeProfiles = try ClaudeCodeProfiles(paths: paths, fileManager: fileManager,
                                                      loginRunner: loginRunner)
        self.providerSpecs = providerSpecs
        self.providerStore = try ProviderAccountStore(paths: paths, fileManager: fileManager,
                                                      specs: providerSpecs)
        self.writerCheck = writerCheck ?? { home in await AccountManager.systemWriterCheck(home: home) }
        self.faultInjector = faultInjector
        self.verificationTimeout = verificationTimeout
        self.capacityCheck = capacityCheck ?? { AccountManager.systemCapacity(at: $0) }
        self.loginRunner = loginRunner
        self.lock = try OperationLock(at: paths.applicationSupport.appending(path: "manager.lock"), fileManager: fileManager)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func status() throws -> ManagerStatus {
        let registry = try loadRegistry()
        let codexAccounts = registry.accounts.filter { $0.identity.providerID == provider.id }
        let claudeAccounts = try claudeProfiles.accounts()
        let allAccounts = registry.accounts + claudeAccounts + (try providerStore.accounts())
        let savedOrder = try claudeProfiles.accountOrder()
        let positions = Dictionary(uniqueKeysWithValues: savedOrder.enumerated().map { ($0.element, $0.offset) })
        var defaults = registry.defaultAccountIDs
        defaults[ProviderID.claudeCode.rawValue] = try claudeProfiles.defaultID()
        defaults.merge(try providerStore.defaults()) { _, new in new }
        return .init(
            accounts: allAccounts.enumerated().sorted { left, right in
                (positions[left.element.id] ?? savedOrder.count + left.offset)
                    < (positions[right.element.id] ?? savedOrder.count + right.offset)
            }.map(\.element),
            defaultAccountID: registry.defaultAccountID,
            defaultAccountIDs: defaults,
            sharedRoot: paths.sharedRoot,
            pendingRecovery: try pendingOperations(),
            linkedSettingsDivergences: try inspectLinkedSettings(accounts: codexAccounts)
        )
    }

    public func reorderAccounts(_ accountIDs: [UUID]) throws -> ManagerStatus {
        let claudeIDs = Set(try claudeProfiles.accounts().map(\.id))
        let externalIDs = claudeIDs.union(try providerStore.accounts().map(\.id))
        try lock.withLock {
            try ensureNoRecovery()
            var registry = try loadRegistryLocked()
            let registryIDs = accountIDs.filter { !externalIDs.contains($0) }
            guard accountIDs.count == registry.accounts.count + externalIDs.count,
                  Set(registryIDs) == Set(registry.accounts.map(\.id)),
                  accountIDs.count == Set(accountIDs).count else {
                throw AIManagerError.sourceChanged
            }
            if registryIDs != registry.accounts.map(\.id) {
                let accounts = Dictionary(uniqueKeysWithValues: registry.accounts.map { ($0.id, $0) })
                registry.accounts = registryIDs.compactMap { accounts[$0] }
                try saveRegistry(registry)
            }
            if !externalIDs.isEmpty { try claudeProfiles.reorder(accountIDs) }
        }
        return try status()
    }

    /// Droid logins are opaque, so the owner's name is the account's only label. The login, the
    /// default, the usage key, and missions stay keyed by the account id.
    public func renameDroidAccount(_ accountID: UUID, to name: String) throws -> ManagerStatus {
        let label = try Self.droidAccountName(name)
        try lock.withLock {
            try ensureNoRecovery()
            var registry = try loadRegistryLocked()
            guard let index = registry.accounts.firstIndex(where: { $0.id == accountID && $0.identity.providerID == .droid }) else {
                throw AIManagerError.accountNotFound
            }
            guard registry.accounts[index].identity.accountID != label else { return }
            registry.accounts[index].identity.accountID = label
            try saveRegistry(registry)
        }
        return try status()
    }

    public static func droidAccountName(_ name: String) throws -> String {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 100, !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AIManagerError.invalidSource("Enter a Droid account name with 1 to 100 characters.")
        }
        return label
    }

    /// Scans one source. It reads only metadata and runs without the manager lock.
    public static func scanCleanup(_ source: CleanupSource, summaries: [ChatThreadSummary] = []) throws -> CleanupScan {
        try CleanupScanner(source: source, summaries: summaries).scan()
    }

    public func reviewCleanup(_ source: CleanupSource, _ items: [CleanupItem]) throws -> ConversationCleanupPlan {
        try ConversationCleanup(home: source.home, userHome: source.userHome).review(items)
    }

    public func cleanupTrash(_ source: CleanupSource) throws -> [ConversationCleanupBatch] {
        try ConversationCleanup(home: source.home, userHome: source.userHome).batches()
    }

    public func moveToCleanupTrash(
        _ source: CleanupSource,
        _ plan: ConversationCleanupPlan,
        preserveActivity: @Sendable ([URL]) async throws -> Void
    ) async throws -> ConversationCleanupBatch {
        try await lock.withAsyncLock {
            try ensureNoRecovery()
            try await ensureCleanupWritersInactive(source)
            let cleanup = ConversationCleanup(home: source.home, userHome: source.userHome)
            try cleanup.validate(plan)
            // Only Codex keeps a daily activity ledger; its transcripts are recorded before they move.
            if source.tool == .codex {
                let transcripts = plan.items.filter { $0.root == 0 && $0.path.hasSuffix(".jsonl") && !$0.isRewrite }
                try await preserveActivity(transcripts.map { plan.home.appending(path: $0.path) })
            }
            try await ensureCleanupWritersInactive(source)
            return try cleanup.moveToTrash(plan)
        }
    }

    public func restoreCleanupTrash(_ source: CleanupSource, _ id: UUID) async throws {
        try await lock.withAsyncLock {
            try ensureNoRecovery()
            try await ensureCleanupWritersInactive(source)
            try ConversationCleanup(home: source.home, userHome: source.userHome).restore(id)
        }
    }

    public func permanentlyRemoveCleanupTrash(_ source: CleanupSource, _ id: UUID) throws {
        try lock.withLock {
            try ensureNoRecovery()
            try ConversationCleanup(home: source.home, userHome: source.userHome).permanentlyRemove(id)
        }
    }

    private func ensureCleanupWritersInactive(_ source: CleanupSource) async throws {
        if source.tool == .codex { return try await ensureWritersInactive([source.home]) }
        switch ToolWriterProbe.check(tool: source.tool, home: source.home) {
        case .active: throw AIManagerError.operationFailed("\(source.title) is writing to its folder. Close it and try again.")
        case .unknown: throw AIManagerError.writerStateUnknown
        case .inactive: break
        }
    }

    public static let providerCatalog: [ProviderDescriptor] = descriptors(for: ProviderCatalog.all)

    /// Codex, Grok Build, and Claude Code first, then every generic spec. A spec supersedes the
    /// disabled placeholder with the same id.
    static func descriptors(for specs: [ProviderSpec]) -> [ProviderDescriptor] {
        let builtIn: [ProviderID] = [.codex, .grokBuild, .droid, .claudeCode]
        let generic = specs.filter { !builtIn.contains($0.id) }
        let placeholders: [ProviderDescriptor] = [
            .init(
                id: .geminiCLI, displayName: "Gemini CLI", availability: .disabled,
                unavailableReason: "Gemini CLI account setup is not available yet."),
            .init(
                id: .antigravityCLI, displayName: "Antigravity CLI", availability: .disabled,
                unavailableReason: "Antigravity CLI account setup is not available yet."),
        ].filter { placeholder in !generic.contains { $0.id == placeholder.id } }
        return [
            .init(id: .codex, displayName: "Codex CLI", availability: .enabled),
            .init(id: .grokBuild, displayName: "Grok Build", availability: .enabled),
            .init(id: .droid, displayName: "Droid", availability: .enabled),
            .init(id: .claudeCode, displayName: "Claude Code", availability: .enabled),
        ] + placeholders + generic.map {
            ProviderDescriptor(id: $0.id, displayName: $0.name, availability: .enabled)
        }
    }

    public func refreshAccounts(includeDiscoveries: Bool = true) async throws -> AccountSnapshot {
        if try !pendingOperations().isEmpty {
            _ = try await recover()
        }
        try await pruneRetiredLoginSessions()
        if try pendingOperations().isEmpty { importLiveLogins() }
        var current = try status()
        if current.pendingRecovery.isEmpty, current.accounts.isEmpty {
            let live = provider.inspect(home: paths.defaultHome)
            if live.support == .supportedChatGPT, live.identity?.isResolved == true {
                try provider.validatePrivateCredentialFile(
                    paths.defaultHome.appending(path: "auth.json"))
                _ = try await adoptLiveAccount()
                current = try status()
            }
        }
        return .init(
            status: current,
            providers: Self.descriptors(for: providerSpecs),
            discoveries: includeDiscoveries ? await discover() : [],
            pendingLoginSessions: try loadLoginSessions() + claudeProfiles.pending()
                + providerStore.pending()
        )
    }

    public func startAccountLogin(accountID: UUID, confirmDroidAccount: Bool = false) async throws -> AccountLoginStart {
        let accounts = try loadRegistry().accounts + claudeProfiles.accounts() + providerStore.accounts()
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            throw AIManagerError.accountNotFound
        }
        if account.identity.providerID == .droid, !confirmDroidAccount {
            throw DroidAccountError.confirmSignIn(account.identity.accountID ?? "Droid")
        }
        return try await startAccountLogin(providerID: account.identity.providerID, accountID: accountID)
    }

    public func startAccountLogin(providerID: ProviderID) async throws -> AccountLoginStart {
        try await startAccountLogin(providerID: providerID, accountID: nil)
    }

    private func startAccountLogin(providerID: ProviderID, accountID: UUID?) async throws -> AccountLoginStart {
        try ensureNoRecovery()
        if providerID == .droid { return try lock.withLock { try startDroidLogin(accountID: accountID) } }
        if providerID == .claudeCode { return try claudeProfiles.startLogin(accountID: accountID) }
        if ![.codex, .grokBuild].contains(providerID),
           let spec = providerSpecs.first(where: { $0.id == providerID }),
           spec.style == .files, spec.login != nil {
            var start = try providerStore.startLogin(providerID, accountID: accountID)
            start.opensInTerminal = true
            return start
        }
        guard Self.providerCatalog.first(where: { $0.id == providerID })?.availability == .enabled else {
            throw AIManagerError.unsupportedSource(
                Self.providerCatalog.first(where: { $0.id == providerID })?.unavailableReason
                    ?? "Provider \(providerID.rawValue) is not available.")
        }
        guard [ProviderID.codex, .grokBuild].contains(providerID) else {
            throw AIManagerError.unsupportedSource(
                "Provider \(providerID.rawValue) is not supported by this release.")
        }
        let executable = providerID == .codex ? resolveExecutable() : resolveGrokExecutable()
        guard let executable else { throw AIManagerError.cliNotFound }
        let session = AccountLoginSession(id: UUID(), providerID: providerID, createdAt: Date(), accountID: accountID)
        let home = loginHome(session.id)
        try CoreSupport.privateDirectory(loginSessionsURL, fileManager: fileManager)
        try CoreSupport.privateDirectory(loginRoot(session.id), fileManager: fileManager)
        try CoreSupport.privateDirectory(home, fileManager: fileManager)
        try saveLoginSession(session)
        var environment = ProcessInfo.processInfo.environment
        let arguments: [String]
        if providerID == .codex {
            environment.removeValue(forKey: "OPENAI_API_KEY")
            environment.removeValue(forKey: "CODEX_ACCESS_TOKEN")
            environment["CODEX_HOME"] = home.path
            arguments = ["-c", "cli_auth_credentials_store=\"file\"", "login"]
        } else {
            environment.removeValue(forKey: "XAI_API_KEY")
            environment["GROK_HOME"] = home.path
            arguments = ["login", "--oauth"]
        }
        if let isolationRoot = paths.isolationRoot { environment["HOME"] = isolationRoot.path }
        let spec = LaunchSpec(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
        do {
            try loginRunner.launch(session.id, spec)
        } catch {
            if session.accountID == nil { _ = loginRunner.cancel(session.id) }
            try? fileManager.removeItem(at: loginRoot(session.id))
            throw error
        }
        return .init(session: session, launchSpec: spec)
    }

    public func checkAccountLogin(
        id: UUID,
        credentialChoice: ConflictChoice? = nil,
        droidName: String = "Droid 1",
        allowRunningDroid: Bool = false,
        allowDuplicateDroid: Bool = false
    ) async throws -> AccountLoginCheck {
        try ensureNoRecovery()
        if try claudeProfiles.pending().contains(where: { $0.id == id }) {
            return try await claudeProfiles.checkLogin(id)
        }
        if try providerStore.pending().contains(where: { $0.id == id }) {
            return try providerStore.checkLogin(id)
        }
        let session = try loadLoginSession(id)
        if session.providerID == .droid { return try checkDroidLogin(session, name: droidName, allowRunning: allowRunningDroid, allowDuplicate: allowDuplicateDroid) }
        if session.accountID != nil { return try await refreshLoginAccount(session) }
        if session.providerID == .grokBuild {
            return try await checkGrokAccountLogin(
                session: session, credentialChoice: credentialChoice)
        }
        try provider.requireSupported(session.providerID)
        let inspection = provider.inspect(home: loginHome(id))
        guard inspection.support == .supportedChatGPT, inspection.identity?.isResolved == true else {
            let waiting = inspection.support == .missingAuth
            return .init(
                session: session,
                state: waiting ? .waitingForLogin : .needsAttention,
                message: waiting
                    ? "Codex sign-in has not produced account access yet."
                    : (inspection.error ?? "Codex sign-in did not produce supported account access.")
            )
        }
        try provider.validatePrivateCredentialFile(loginHome(id).appending(path: "auth.json"))
        let plan = try await makeImportPlan(
            source: loginHome(id), mode: .authOnly, allowApplicationSupportSource: true)
        if plan.conflicts.contains(where: { $0.relativePath == "auth.json" }), credentialChoice == nil {
            return .init(
                session: session,
                state: .credentialChoiceRequired,
                message: "This login matches a saved account with different access. Choose which credential to keep."
            )
        }
        let decisions = credentialChoice.map { ["auth.json": $0] } ?? [:]
        let ownedLogin = loginRunner.cancel(id)
        let result = try await importAccount(plan: plan, decisions: decisions)
        try await activateLoginAccountIfNeeded(result.account.id)
        if ownedLogin {
            try fileManager.removeItem(at: loginRoot(id))
        } else {
            try retireLoginSession(id)
        }
        return .init(
            session: session,
            state: .completed,
            account: result.account,
            message: "Codex account access was saved."
        )
    }

    public func submitAccountLoginCode(id: UUID, input: String) throws {
        try ensureNoRecovery()
        let session = try loadLoginSession(id)
        guard session.providerID == .grokBuild else {
            throw AIManagerError.unsupportedSource(
                "Manual authorization codes are supported only for Grok Build.")
        }
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 8_192,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw AIManagerError.operationFailed(
                "Paste a valid Grok authorization code or callback URL.")
        }
        guard try loginRunner.submit(id, value) else {
            throw AIManagerError.operationFailed(
                "Grok sign-in is no longer waiting for an authorization code. Start sign-in again.")
        }
    }

    private func refreshLoginAccount(_ session: AccountLoginSession) async throws -> AccountLoginCheck {
        let isGrok = session.providerID == .grokBuild
        let home = loginHome(session.id)
        let inspection = isGrok ? grokProvider.inspect(home: home) : provider.inspect(home: home)
        guard inspection.support == (isGrok ? .supportedOAuth : .supportedChatGPT),
              let identity = inspection.identity, identity.isResolved else {
            return .init(session: session,
                         state: inspection.support == .missingAuth ? .waitingForLogin : .needsAttention,
                         message: inspection.error ?? "Sign-in has not produced account access yet.")
        }
        try provider.validatePrivateCredentialFile(home.appending(path: "auth.json"))
        let account = try await lock.withAsyncLock {
            try ensureNoRecovery()
            var registry = try loadRegistry()
            guard let index = registry.accounts.firstIndex(where: {
                $0.id == session.accountID && $0.identity.providerID == session.providerID
            }) else { throw AIManagerError.accountNotFound }
            let target = registry.accounts[index]
            guard isGrok ? grokProvider.sameIdentity(target.identity, identity)
                         : provider.sameIdentity(target.identity, identity) else {
                try fileManager.removeItem(at: loginRoot(session.id))
                throw target.identity.signInMismatch(identity.email ?? identity.accountID ?? identity.userID ?? "another account")
            }
            let isDefault = registry.defaultAccountID(for: session.providerID) == target.id
            if isDefault {
                let live = isGrok ? grokProvider.inspect(home: paths.grokHome) : provider.inspect(home: paths.defaultHome)
                if let liveIdentity = live.identity {
                    guard isGrok ? grokProvider.sameIdentity(target.identity, liveIdentity)
                                 : provider.sameIdentity(target.identity, liveIdentity) else {
                        throw AIManagerError.credentialConflict
                    }
                } else if live.support != .missingAuth {
                    throw AIManagerError.credentialConflict
                }
            }
            try validateDeleteTargets(target)
            let validatedAuth = loginRoot(session.id).appending(path: "validated-auth.json")
            try CoreSupport.atomicWrite(inspection.data, to: validatedAuth, fileManager: fileManager)
            let operationID = UUID()
            var operation = RecoveryOperation(
                id: operationID, kind: "account-login-refresh", phase: .prepared,
                source: validatedAuth, destination: target.credentialFile,
                backup: paths.applicationSupport.appending(path: "backups/\(operationID.uuidString)"),
                expectedDigest: inspection.digest, previousDigest: try treeDigest(target.credentialFile),
                registryAccountID: target.id, registryCredentialDigest: inspection.digest, previousAccount: target)
            try saveOperation(operation)
            try replaceRecoverably(source: operation.source, destination: target.credentialFile,
                                   operation: &operation, backupName: "auth.json")
            guard try treeDigest(target.credentialFile) == inspection.digest else { throw AIManagerError.sourceChanged }
            try faultInjector(.afterCredentialPublication)
            registry.accounts[index].credentialDigest = inspection.digest
            registry.accounts[index].verification = .init(state: .imported, checkedAt: Date(),
                                                          detail: "Account access was refreshed for the saved identity.")
            try saveRegistry(registry)
            try faultInjector(.afterRegistryCommit)
            try finishOperation(&operation)
            if isDefault {
                if isGrok { _ = try performGrokSwitch(to: target.id, captureOutgoingCredential: false, refreshOnly: true) }
                else { _ = try performSwitch(to: target.id, captureOutgoingCredential: false, refreshOnly: true) }
            }
            return registry.accounts[index]
        }
        try fileManager.removeItem(at: loginRoot(session.id))
        return .init(session: session, state: .completed, account: account,
                     message: "Account access was refreshed.")
    }

    private func checkGrokAccountLogin(
        session: AccountLoginSession,
        credentialChoice: ConflictChoice?
    ) async throws -> AccountLoginCheck {
        let inspection = grokProvider.inspect(home: loginHome(session.id))
        guard inspection.support == .supportedOAuth, inspection.identity?.isResolved == true else {
            let waiting = inspection.support == .missingAuth
            return .init(
                session: session,
                state: waiting ? .waitingForLogin : .needsAttention,
                message: waiting
                    ? "Grok sign-in has not produced account access yet."
                    : (inspection.error ?? "Grok sign-in did not produce supported account access.")
            )
        }
        try grokProvider.validatePrivateCredentialFile(
            loginHome(session.id).appending(path: "auth.json"))
        let registry = try loadRegistry()
        let matching = registry.accounts.first { account in
            account.identity.providerID == .grokBuild
                && inspection.identity.map {
                    grokProvider.sameIdentity(account.identity, $0)
                } == true
        }
        if let matching, matching.credentialDigest != inspection.digest, credentialChoice == nil {
            return .init(
                session: session,
                state: .credentialChoiceRequired,
                message: "This Grok account is already saved with different access. Choose which credential to keep."
            )
        }
        let ownedLogin = loginRunner.cancel(session.id)
        let account = try await lock.withAsyncLock {
            try ensureNoRecovery()
            return try performGrokImport(
                inspection: inspection,
                source: loginHome(session.id),
                keepExistingCredential: credentialChoice == .keepShared)
        }
        try await activateLoginAccountIfNeeded(account.id)
        if ownedLogin {
            try fileManager.removeItem(at: loginRoot(session.id))
        } else {
            try retireLoginSession(session.id)
        }
        return .init(
            session: session,
            state: .completed,
            account: account,
            message: "Grok account access was saved."
        )
    }

    public func cancelAccountLogin(id: UUID) async throws {
        if try claudeProfiles.pending().contains(where: { $0.id == id }) {
            return try await claudeProfiles.cancelLogin(id)
        }
        if try providerStore.pending().contains(where: { $0.id == id }) {
            return try providerStore.cancelLogin(id)
        }
        let session = try loadLoginSession(id)
        guard try !pendingOperations().contains(where: {
            CoreSupport.isContained($0.source, by: loginRoot(id))
        }) else { throw AIManagerError.recoveryRequired }
        if session.accountID != nil || loginRunner.cancel(id) {
            try fileManager.removeItem(at: loginRoot(id))
        } else {
            try retireLoginSession(id)
        }
    }

    public func discover(explicit: URL? = nil) async -> [DiscoveredSource] {
        let candidates = provider.discoveryCandidates(paths: paths, explicit: explicit)

        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let canonical = CoreSupport.canonical(candidate)
            guard seen.insert(canonical.path).inserted,
                  fileManager.fileExists(atPath: candidate.path) || candidate == CoreSupport.home(for: explicit ?? candidate) && explicit != nil else { return nil }
            return inspectSource(candidate)
        }
    }

    public func historySummary(for home: URL) -> HistorySummary {
        historySummary(in: CoreSupport.home(for: home))
    }

    public func planImport(source selected: URL, mode: ImportMode) async throws -> ImportPlan {
        try await makeImportPlan(
            source: selected, mode: mode, allowApplicationSupportSource: false)
    }

    private func makeImportPlan(
        source selected: URL,
        mode: ImportMode,
        allowApplicationSupportSource: Bool
    ) async throws -> ImportPlan {
        try ensureNoRecovery()
        let source = CoreSupport.home(for: selected)
        let inspection = provider.inspect(home: selected)
        guard inspection.support == .supportedChatGPT else {
            throw AIManagerError.unsupportedSource(inspection.error ?? inspection.support.rawValue)
        }
        guard let identity = inspection.identity, identity.isResolved else { throw AIManagerError.unresolvedIdentity }
        let registry = try loadRegistry()
        let existing = registry.accounts.first { provider.sameIdentity($0.identity, identity) }
        let id = existing?.id ?? UUID()
        let operationID = UUID()
        let destination = existing?.home
            ?? paths.applicationSupport.appending(path: "accounts/\(id.uuidString)/home", directoryHint: .isDirectory)
        guard (allowApplicationSupportSource || !CoreSupport.isContained(source, by: paths.applicationSupport)),
              !CoreSupport.isContained(destination, by: source) else {
            throw AIManagerError.unsafePath("source and managed destination overlap")
        }
        let manifest = try buildManifest(source: source, mode: mode)
        var conflicts = try mode == .full ? settingConflicts(source: source) : []
        if let existing = registry.accounts.first(where: { provider.sameIdentity($0.identity, identity) }), existing.credentialDigest != inspection.digest {
            conflicts.append(.init(relativePath: "auth.json", importedDigest: inspection.digest, sharedDigest: existing.credentialDigest, affectsAllAccounts: false))
        }
        var warnings = manifest.compactMap { entry -> String? in
            guard !entry.selected,
                  entry.disposition.contains("requires explicit review")
                    || entry.disposition.contains("symbolic links are not imported")
            else { return nil }
            return "Excluded \(entry.relativePath): \(entry.disposition)"
        }
        if try sourceMayBeChanging(source) { warnings.append("The source appears active. Close Codex before a full import.") }
        var requiredBytes = manifest.filter(\.selected).reduce(Int64(0)) { partial, entry in
            let (sum, overflow) = partial.addingReportingOverflow(entry.byteCount)
            return overflow ? Int64.max : sum
        }
        let databaseBackupBytes = manifest.filter { $0.selected && $0.category == .database && !$0.relativePath.hasSuffix("-wal") && !$0.relativePath.hasSuffix("-shm") }
            .reduce(Int64(0)) { partial, entry in
                let (sum, overflow) = partial.addingReportingOverflow(entry.byteCount)
                return overflow ? Int64.max : sum
            }
        requiredBytes = requiredBytes.addingReportingOverflow(databaseBackupBytes).overflow ? Int64.max : requiredBytes + databaseBackupBytes
        for destination in [paths.applicationSupport, paths.sharedRoot] {
            if let available = capacityCheck(destination), available < requiredBytes {
                throw AIManagerError.operationFailed(
                    "The destination needs \(requiredBytes) bytes but only \(available) bytes are available.")
            }
        }
        return .init(
            id: id,
            operationID: operationID,
            source: source,
            destination: destination,
            backup: paths.applicationSupport.appending(
                path: "backups/\(operationID.uuidString)", directoryHint: .isDirectory),
            mode: mode,
            identity: identity,
            sourceAuthDigest: inspection.digest,
            reviewedDataDigest: try reviewedDataDigest(
                source: source, mode: mode, authDigest: inspection.digest, manifest: manifest),
            manifest: manifest,
            conflicts: conflicts,
            warnings: warnings,
            requiredBytes: requiredBytes,
            credentialDestination: credentialFile(for: id),
            sharedDestination: paths.sharedRoot
        )
    }

    public func importAccount(plan: ImportPlan, decisions: [String: ConflictChoice] = [:]) async throws -> ImportResult {
        try ensureNoRecovery()
        let missing = plan.conflicts.map(\.relativePath).filter { decisions[$0] == nil }
        guard missing.isEmpty else { throw AIManagerError.missingConflictDecisions(missing) }
        var requiredBytes = plan.requiredBytes
        for conflict in plan.conflicts where conflict.externalTarget != nil && decisions[conflict.relativePath] == .useImported {
            guard conflict.externalTargetBytes != nil, conflict.importedDigest != "external-link-requires-review" else {
                throw AIManagerError.invalidSource("Review the linked target for \(conflict.relativePath) before importing it.")
            }
            let source = plan.source.appending(path: conflict.relativePath)
            guard try firstExternalLink(source, sourceRoot: plan.source) == conflict.externalTarget,
                  try portableLogicalSize(source) == conflict.externalTargetBytes,
                  try treeDigest(source) == conflict.importedDigest else {
                throw AIManagerError.sourceChanged
            }
            let (sum, overflow) = requiredBytes.addingReportingOverflow(conflict.externalTargetBytes ?? 0)
            requiredBytes = overflow ? Int64.max : sum
        }
        for destination in [paths.applicationSupport, paths.sharedRoot] {
            if let available = capacityCheck(destination), available < requiredBytes {
                throw AIManagerError.operationFailed(
                    "The destination needs \(requiredBytes) bytes but only \(available) bytes are available.")
            }
        }
        let current = provider.inspect(home: plan.source)
        guard current.digest == plan.sourceAuthDigest else { throw AIManagerError.sourceChanged }
        guard try reviewedDataDigest(
            source: plan.source, mode: plan.mode, authDigest: current.digest,
            manifest: plan.manifest) == plan.reviewedDataDigest else { throw AIManagerError.sourceChanged }
        return try await lock.withAsyncLock {
            try ensureNoRecovery()
            if plan.mode == .full {
                try await ensureWritersInactive([plan.source, paths.sharedRoot])
            }
            return try performImport(
                plan: plan, auth: current.data, decisions: decisions, setsDefaultAccount: false)
        }
    }

    public func reviewExternalSetting(plan: ImportPlan, relativePath: String) throws -> ImportPlan {
        guard CoreSupport.settings.contains(relativePath),
              let index = plan.conflicts.firstIndex(where: { $0.relativePath == relativePath && $0.externalTarget != nil }) else {
            throw AIManagerError.invalidSource("No reviewed external setting exists at \(relativePath).")
        }
        let source = plan.source.appending(path: relativePath)
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink == true else {
            throw AIManagerError.invalidSource(
                "Nested external links are not imported. Keep the shared \(relativePath) entry instead.")
        }
        let currentTarget = lexicalLinkTarget(source)
        guard currentTarget == plan.conflicts[index].externalTarget else { throw AIManagerError.sourceChanged }
        var reviewed = plan
        reviewed.conflicts[index].externalTargetBytes = try portableLogicalSize(source)
        reviewed.conflicts[index].importedDigest = try treeDigest(source)
        return reviewed
    }

    public func switchDefault(to accountID: UUID, allowRunningDroid: Bool = false) async throws -> SwitchResult {
        if try providerStore.contains(accountID) { return try providerStore.makeDefault(accountID) }
        if try claudeProfiles.accounts().contains(where: { $0.id == accountID }) {
            return try claudeProfiles.makeDefault(accountID)
        }
        return try await lock.withAsyncLock {
            try ensureNoRecovery()
            let registry = try loadRegistry()
            guard let selected = registry.accounts.first(where: { $0.id == accountID }) else {
                throw AIManagerError.accountNotFound
            }
            if selected.identity.providerID == .droid {
                try guardDroidProcesses(allowRunning: allowRunningDroid)
                return try droidProvider.withWriteLock(home: paths.droidHome) {
                    try performDroidSwitch(to: accountID)
                }
            }
            if selected.identity.providerID == .grokBuild {
                try grokProvider.validateManagedCredential(selected)
                return try performGrokSwitch(to: accountID)
            }
            try provider.validateManagedCredential(selected)
            return try performSwitch(to: accountID)
        }
    }

    /// Deletes the account and remembers its identity so discovery never imports it again.
    public func deleteAccount(
        accountID: UUID,
        replacementDefaultAccountID: UUID? = nil
    ) async throws -> AccountDeletionResult {
        let keys = try removalKeys(of: accountID)
        let result = try await removeAccount(accountID: accountID, replacementDefaultAccountID: replacementDefaultAccountID)
        forgetLogins(keys)
        droidProbe = nil
        return result
    }

    private func removeAccount(
        accountID: UUID,
        replacementDefaultAccountID: UUID? = nil
    ) async throws -> AccountDeletionResult {
        if try providerStore.contains(accountID) {
            return try providerStore.delete(accountID, replacement: replacementDefaultAccountID)
        }
        if try claudeProfiles.accounts().contains(where: { $0.id == accountID }) {
            return try await claudeProfiles.delete(accountID, replacement: replacementDefaultAccountID)
        }
        let initial = try loadRegistry()
        guard let initialAccount = initial.accounts.first(where: { $0.id == accountID }) else {
            throw AIManagerError.accountNotFound
        }
        let providerID = initialAccount.identity.providerID
        let initialDefaultAccountID = initial.defaultAccountID(for: providerID)
        if let replacementDefaultAccountID {
            guard replacementDefaultAccountID != accountID,
                  initial.accounts.contains(where: {
                      $0.id == replacementDefaultAccountID
                          && $0.identity.providerID == providerID
                  }) else {
                throw AIManagerError.invalidReplacementAccount
            }
        }
        if initialDefaultAccountID == accountID {
            guard let replacementDefaultAccountID else {
                throw AIManagerError.defaultAccountReplacementRequired
            }
            _ = try await switchDefault(to: replacementDefaultAccountID)
        }

        return try await lock.withAsyncLock {
            try ensureNoRecovery()
            var registry = try loadRegistry()
            guard let index = registry.accounts.firstIndex(where: { $0.id == accountID }) else {
                throw AIManagerError.accountNotFound
            }
            let account = registry.accounts[index]
            guard registry.defaultAccountID(for: account.identity.providerID) != accountID else {
                throw AIManagerError.defaultAccountReplacementRequired
            }
            try validateDeleteTargets(account)

            let operationID = UUID()
            let backup = paths.applicationSupport.appending(
                path: "backups/\(operationID.uuidString)", directoryHint: .isDirectory)
            var operation = RecoveryOperation(
                id: operationID,
                kind: "delete-account",
                phase: .prepared,
                source: account.source,
                destination: account.home,
                backup: backup,
                touchedItems: [],
                registryAccountID: accountID,
                previousDefaultAccountID: registry.defaultAccountID(
                    for: account.identity.providerID),
                previousAccount: account
            )
            try saveOperation(operation)
            try CoreSupport.privateDirectory(backup, fileManager: fileManager)

            var ownedTargets = [
                (account.home, backup.appending(path: "account-home", directoryHint: .isDirectory)),
                (account.credentialFile, backup.appending(path: "auth.json")),
            ]
            if account.identity.providerID == .droid {
                ownedTargets.append((droidUsageKey(accountID), backup.appending(path: "usage-key.json")))
            }
            for (destination, protected) in ownedTargets where CoreSupport.entryExists(destination) {
                let digest = try treeDigest(destination)
                try copyPortable(destination, to: protected)
                guard try treeDigest(protected) == digest else {
                    throw AIManagerError.operationFailed("The account deletion backup did not verify.")
                }
                operation.touchedItems = (operation.touchedItems ?? []) + [
                    .init(
                        destination: destination,
                        backup: protected,
                        expectedDigest: digest,
                        previousDigest: digest
                    )
                ]
                try saveOperation(operation)
            }
            operation.phase = .backedUp
            try saveOperation(operation)
            for item in operation.touchedItems ?? [] {
                guard CoreSupport.entryExists(item.destination),
                      try treeDigest(item.destination) == item.expectedDigest else {
                    throw AIManagerError.sourceChanged
                }
            }

            registry.accounts.remove(at: index)
            try saveRegistry(registry)
            operation.phase = .registryCommitted
            try saveOperation(operation)
            try faultInjector(.afterRegistryCommit)

            for item in operation.touchedItems ?? [] {
                let destinationUnchanged: Bool
                if CoreSupport.entryExists(item.destination) {
                    destinationUnchanged = try treeDigest(item.destination) == item.expectedDigest
                } else {
                    destinationUnchanged = true
                }
                guard destinationUnchanged else {
                    operation.phase = .conflicted
                    try saveOperation(operation)
                    throw AIManagerError.sourceChanged
                }
                if CoreSupport.entryExists(item.destination) {
                    try fileManager.removeItem(at: item.destination)
                }
            }
            try? fileManager.removeItem(at: backup)
            try finishOperation(&operation)
            return .init(
                accountID: accountID,
                replacementDefaultAccountID: initialDefaultAccountID == accountID
                    ? replacementDefaultAccountID : nil,
                removedManagedHome: !CoreSupport.entryExists(account.home),
                removedCredential: !CoreSupport.entryExists(account.credentialFile)
            )
        }
    }

    private func activateLoginAccountIfNeeded(_ accountID: UUID) async throws {
        try await lock.withAsyncLock {
            try ensureNoRecovery()
            let registry = try loadRegistry()
            guard let selected = registry.accounts.first(where: { $0.id == accountID }) else {
                throw AIManagerError.accountNotFound
            }
            let current = registry.defaultAccountID(for: selected.identity.providerID)
            guard current == nil || current == accountID else { return }
            if selected.identity.providerID == .grokBuild {
                try grokProvider.validateManagedCredential(selected)
                _ = try performGrokSwitch(to: accountID, captureOutgoingCredential: false)
            } else {
                try provider.validateManagedCredential(selected)
                _ = try performSwitch(to: accountID, captureOutgoingCredential: false)
            }
        }
    }

    public func readCodexAccountUsage(
        accountID: UUID,
        reader: CodexAppServerAccountReader = .init(),
        limits: CodexAppServerLimits = .init()
    ) async throws -> CodexAccountUsageSnapshot {
        let lease = try lock.withLock {
            try prepareUsageRead(accountID: accountID)
        }
        defer { removeUsageRead(lease) }

        let snapshot = try await reader.read(
            executable: lease.executable,
            source: lease.source,
            limits: limits
        )
        try lock.withLock {
            try validateUsageRead(lease)
        }
        return snapshot
    }

    // MARK: Generic providers

    public func addProviderAccount(providerID: ProviderID, fields: [String: String]) async throws -> AccountRecord {
        try providerStore.addSecret(providerID, fields: fields)
    }

    @discardableResult
    public func importLiveProviderAccount(providerID: ProviderID) throws -> AccountRecord {
        if providerID == .droid { return try importDroidAccount(name: "Droid 1") }
        return try providerStore.importLive(providerID)
    }

    /// Copies each live CLI login that no saved or deleted account covers into Switch's own store.
    /// Uses the "Import current sign-in" paths. The imported account becomes its provider's default
    /// (the live files belong to it); no live file is written. Never throws: a failed import is retried on the next refresh.
    @discardableResult
    public func importLiveLogins() -> [AccountRecord] {
        let removed = Set(removedLogins())
        var added: [AccountRecord] = []
        let skipped: Set<ProviderID> = [.codex, .grokBuild, .claudeCode, .droid]
        for spec in providerSpecs where spec.style == .files && !skipped.contains(spec.id) {
            if let record = try? providerStore.autoImportLive(spec.id, removed: removed) { added.append(record) }
        }
        if let record = try? importLiveDroidLogin(removed: removed) { added.append(record) }
        for key in ZCodeCredentials.apiKeys(home: paths.userHome) {
            if let record = try? providerStore.autoImportSecret(
                ProviderID(rawValue: "zai"), fields: ["apiKey": key.apiKey], name: key.accountName, removed: removed) {
                added.append(record)
            }
        }
        // OpenCode 2 keeps its z.ai coding-plan key in its database; the same key as a Z Code one is skipped.
        let openCode = paths.userHome.appending(path: ".local/share/opencode")
        if let login = OpenCodeGoUsage.databaseLogin("zai-coding-plan", directory: openCode),
           let record = try? providerStore.autoImportSecret(
               ProviderID(rawValue: "zai"), fields: ["apiKey": login.key], name: "OpenCode z.ai coding plan", removed: removed) {
            added.append(record)
        }
        return added
    }

    /// Droid hides its identity: import when no Droid account is saved, or when the doctor mask
    /// differs from every saved one. Equal or unknown masks skip, because they prove nothing.
    private func importLiveDroidLogin(removed: Set<String>) throws -> AccountRecord? {
        let files = try droidProvider.files(in: paths.droidHome)
        guard (try? droidProvider.requireLogin(files)) != nil else { return nil }
        let live = Self.loginDigest(files)
        guard live != droidProbe else { return nil }
        let saved = try loadRegistry().accounts.filter { $0.identity.providerID == .droid }
        guard !removed.contains(Self.droidKey(live)),
              !saved.contains(where: { (try? droidProvider.files(in: $0.credentialFile)).map(Self.loginDigest) == live })
        else { droidProbe = live; return nil }
        let hint = droidIdentityHint(home: paths.droidHome)
        if let hint, removed.contains(Self.droidKey(hint)) { droidProbe = live; return nil }
        if !saved.isEmpty, hint == nil || droidMaskTwin(of: files, hint: hint, in: saved) != nil {
            droidProbe = live
            return nil
        }
        let record = try importDroidAccount(name: "Droid \(saved.count + 1)", automatic: true)
        droidProbe = live
        return record
    }

    /// The saved Droid account that may be this login: the same doctor mask, and no token subject
    /// that proves a different person. The mask keeps only the first letter and the domain.
    private func droidMaskTwin(of files: [String: Data], hint: String?, in accounts: [AccountRecord]) -> AccountRecord? {
        guard let hint else { return nil }
        let twins = accounts.filter { $0.identity.providerID == .droid && $0.identity.email?.lowercased() == hint }
        guard !twins.isEmpty else { return nil }
        guard let subject = droidLoginReader.subject(files: files) else { return twins.first }
        return twins.first { account in
            let saved = (try? droidProvider.files(in: account.credentialFile)).flatMap(droidLoginReader.subject)
            return saved == nil || saved == subject
        }
    }

    private static func loginDigest(_ files: [String: Data]) -> String {
        CoreSupport.digest(Data(files.sorted { $0.key < $1.key }.flatMap { Array($0.key.utf8) + [0] + Array($0.value) + [0] }))
    }

    private static func droidKey(_ identity: String) -> String {
        ProviderAccountStore.removedKey(.droid, identity.lowercased())
    }

    // MARK: Removed logins

    private var removedLoginsURL: URL {
        paths.applicationSupport.appending(path: "provider-accounts/removed-logins.json")
    }

    /// Identities of deleted accounts (provider plus identity key or Droid mask or login digest; no secrets).
    private func removedLogins() -> [String] {
        (try? decoder.decode([String].self, from: Data(contentsOf: removedLoginsURL))) ?? []
    }

    private func removalKeys(of accountID: UUID) throws -> [String] {
        if let stored = try providerStore.accounts().first(where: { $0.id == accountID }) {
            return stored.identity.userID.map { [ProviderAccountStore.removedKey(stored.identity.providerID, $0)] } ?? []
        }
        guard let droid = try loadRegistry().accounts.first(where: { $0.id == accountID && $0.identity.providerID == .droid })
        else { return [] }
        let digest = (try? droidProvider.files(in: droid.credentialFile)).map(Self.loginDigest)
        return ([droid.identity.email] + [digest]).compactMap { $0 }.map(Self.droidKey)
    }

    private func forgetLogins(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        let all = Array(Set(removedLogins() + keys)).sorted()
        try? CoreSupport.privateDirectory(removedLoginsURL.deletingLastPathComponent(), fileManager: fileManager)
        try? CoreSupport.atomicWrite(try encoder.encode(all), to: removedLoginsURL, fileManager: fileManager)
    }

    /// Read-only identity of the login currently in the provider's real home.
    public func liveProviderIdentity(providerID: ProviderID) -> CredentialIdentity? {
        providerStore.liveIdentity(providerID)
    }

    /// Whether the opt-in shell function that makes a plain `claude` use the default Claude account is installed.
    public func claudeShellIntegrationInstalled() -> Bool {
        claudeProfiles.shellIntegrationInstalled()
    }

    /// Adds (or removes) the Claude shell integration. Install keeps a one-time `.switch-backup` of each rc file.
    public func setClaudeShellIntegration(_ enabled: Bool) throws {
        if enabled {
            try claudeProfiles.installShellIntegration()
        } else {
            try claudeProfiles.removeShellIntegration()
        }
    }

    /// Reads usage through the provider's `ProviderSpec`. Refreshed credentials are saved for store
    /// accounts only; Codex and Grok registry accounts are never rewritten from here.
    public func readProviderUsage(accountID: UUID, interactive: Bool = false) async throws -> ProviderUsage {
        try await fetchProviderUsage(accountID: accountID, interactive: interactive).sanitized()
    }

    private func fetchProviderUsage(accountID: UUID, interactive: Bool) async throws -> ProviderUsage {
        if try providerStore.contains(accountID) {
            let spec = try providerStore.spec(forAccount: accountID)
            let stored = try providerStore.credential(for: accountID)
            let result = try await spec.fetch(stored.credential)
            if let updated = result.updated {
                try providerStore.persist(accountID, updated, live: stored.live, liveDigest: stored.liveDigest)
            }
            return result.usage
        }
        guard let account = try loadRegistry().accounts.first(where: { $0.id == accountID }) else {
            if try claudeProfiles.accounts().contains(where: { $0.id == accountID }) {
                return try await claudeProfiles.usage(accountID: accountID)
            }
            throw AIManagerError.accountNotFound
        }
        if account.identity.providerID == .droid {
            let file = droidUsageKey(accountID)
            let credential: ProviderCredential
            if CoreSupport.entryExists(file) {
                try provider.validatePrivateCredentialFile(file)
                credential = try decoder.decode(ProviderCredential.self, from: Data(contentsOf: file))
            } else {
                let active = try loadRegistry().defaultAccountID(for: .droid) == accountID
                let home = active ? paths.droidHome : account.credentialFile
                let login = try droidLoginReader.read(files: droidProvider.files(in: home), interactive: interactive)
                credential = ProviderCredential(fields: ["apiKey": login.accessToken])
            }
            let factory = providerSpecs.first { $0.id.rawValue == "factory" } ?? ProviderCatalog.agentFactory
            return try await factory.fetch(credential).usage
        }
        guard let spec = providerSpecs.first(where: { $0.id == account.identity.providerID }),
              let file = spec.files.first else {
            throw ProviderError.unsupported(
                "Usage for \(account.identity.providerID.displayName) accounts is not available yet.")
        }
        var credential = try registryCredential(account, fileID: file.id)
        if credential.isLive, account.identity.providerID == .grokBuild,
           GrokBuildUsage.expiresSoon(credential.files[file.id]), await refreshLiveGrokLogin() {
            credential = try registryCredential(account, fileID: file.id)
        }
        let result = try await spec.fetch(credential)
        if let refreshed = result.updated?.files[file.id], !credential.isLive,
           account.identity.providerID == .grokBuild {
            try? persistRefreshedGrokCredential(account, refreshed)
        }
        return result.usage
    }

    /// Grok access tokens last about 6 hours and only the official CLI may refresh the live login. When the
    /// token is (nearly) expired, run `grok models` once per 5 minutes per home so the CLI refreshes its own
    /// `auth.json` under its own lock. No arguments carry secrets; output is discarded. True when it exited 0.
    private func refreshLiveGrokLogin() async -> Bool {
        let key = paths.grokHome.path
        if let last = grokRefreshAttempts[key], Date().timeIntervalSince(last) < 300 { return false }
        guard let executable = resolveGrokExecutable() else { return false }
        grokRefreshAttempts[key] = Date()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["models"]
        process.environment = ProcessInfo.processInfo.environment.merging(["GROK_HOME": key]) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let timeout = grokRefreshTimeout
        var watchdog: Task<Void, Error>?
        // The termination handler, set before run(), fires even when the child exits at once.
        // waitUntilExit on a worker thread can miss that exit and block forever.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in done.resume() }
            do { try process.run() } catch {
                process.terminationHandler = nil
                done.resume()
                return
            }
            watchdog = Task.detached {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                process.terminate()
                try await Task.sleep(nanoseconds: 2_000_000_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        watchdog?.cancel()
        guard watchdog != nil else { return false }
        return process.terminationReason == .exit && process.terminationStatus == 0
    }

    func setGrokRefreshTimeout(_ seconds: TimeInterval) { grokRefreshTimeout = seconds }

    /// Saves tokens that Switch refreshed for a non-default Grok account. The vault copy is the only
    /// holder of that refresh token. The write is dropped when anything changed since the fetch began.
    private func persistRefreshedGrokCredential(_ account: AccountRecord, _ data: Data) throws {
        try lock.withLock {
            try ensureNoRecovery()
            var registry = try loadRegistryLocked()
            guard let index = registry.accounts.firstIndex(where: { $0.id == account.id }),
                  registry.defaultAccountID(for: .grokBuild) != account.id,
                  grokProvider.inspect(credentialFile: registry.accounts[index].credentialFile).digest
                    == registry.accounts[index].credentialDigest,
                  registry.accounts[index].credentialDigest == account.credentialDigest else { return }
            let scratch = registry.accounts[index].credentialFile.deletingLastPathComponent()
                .appending(path: ".refresh-\(UUID().uuidString).tmp")
            defer { try? fileManager.removeItem(at: scratch) }
            try CoreSupport.atomicWrite(data, to: scratch, fileManager: fileManager)
            let inspection = grokProvider.inspect(credentialFile: scratch)
            guard inspection.support == .supportedOAuth, let identity = inspection.identity,
                  grokProvider.sameIdentity(registry.accounts[index].identity, identity) else { return }
            try CoreSupport.atomicWrite(data, to: registry.accounts[index].credentialFile, fileManager: fileManager)
            registry.accounts[index].credentialDigest = inspection.digest
            try saveRegistry(registry)
        }
    }

    private func registryCredential(_ account: AccountRecord, fileID: String) throws -> ProviderCredential {
        let providerID = account.identity.providerID
        if try loadRegistry().defaultAccountID(for: providerID) == account.id {
            let live: Data?
            switch providerID {
            case .grokBuild:
                let found = grokProvider.inspect(home: paths.grokHome)
                live = found.support == .supportedOAuth
                    && found.identity.map({ grokProvider.sameIdentity(account.identity, $0) }) == true
                    ? found.data : nil
            case .codex:
                let found = provider.inspect(home: paths.defaultHome)
                live = found.support == .supportedChatGPT
                    && found.identity.map({ provider.sameIdentity(account.identity, $0) }) == true
                    ? found.data : nil
            default:
                live = nil
            }
            if let live { return ProviderCredential(files: [fileID: live], isLive: true) }
        }
        let values = try account.credentialFile.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= CoreSupport.maxAuthBytes else {
            throw AIManagerError.credentialConflict
        }
        return ProviderCredential(files: [fileID: try Data(contentsOf: account.credentialFile)])
    }

    private func checkProviderAccount(_ accountID: UUID) async -> AccountCheckResult {
        let result: VerificationResult
        do {
            _ = try await readProviderUsage(accountID: accountID)
            result = .init(state: .verifiedLocally, checkedAt: Date(),
                           detail: "The provider accepted this account and returned usage.")
        } catch let error as ProviderError {
            let state: VerificationState = error.needsSignIn ? .needsSignIn
                : { if case .unsupported = error { return .unsupported } else { return .imported } }()
            result = .init(state: state, checkedAt: Date(),
                           detail: error.errorDescription ?? "The provider check failed.")
        } catch {
            result = .init(state: .imported, checkedAt: Date(),
                           detail: error.localizedDescription)
        }
        try? providerStore.recordCheck(accountID, result)
        return .init(verification: result)
    }

    public func checkAccount(
        accountID: UUID,
        reader: CodexAppServerAccountReader = .init(),
        limits: CodexAppServerLimits = .init()
    ) async -> AccountCheckResult {
        if (try? providerStore.contains(accountID)) == true {
            return await checkProviderAccount(accountID)
        }
        if (try? claudeProfiles.accounts().contains(where: { $0.id == accountID })) == true {
            return await claudeProfiles.check(accountID)
        }
        let account: AccountRecord
        do {
            let registry = try loadRegistry()
            guard let found = registry.accounts.first(where: { $0.id == accountID }) else {
                throw AIManagerError.accountNotFound
            }
            account = found
            if account.identity.providerID == .droid {
                try validateDroidCredential(account)
                let result = VerificationResult(state: .verifiedLocally, checkedAt: Date(),
                    detail: "The encrypted Droid files passed digest and permission checks. Switch cannot check their account identity.")
                try? recordAccountCheck(result, accountID: accountID, expected: account)
                return .init(verification: result)
            }
            if account.identity.providerID == .grokBuild {
                try grokProvider.validateManagedCredential(account)
                let result = VerificationResult(
                    state: .verifiedLocally,
                    checkedAt: Date(),
                    detail: "The saved Grok subscription OAuth session passed its local identity, digest, and permission checks."
                )
                try? recordAccountCheck(result, accountID: accountID, expected: account)
                return .init(verification: result)
            }
            guard account.identity.providerID == provider.id else {
                let result = VerificationResult(
                    state: .unsupported,
                    checkedAt: Date(),
                    detail: "Provider \(account.identity.providerID.rawValue) is not supported by this release."
                )
                try? recordAccountCheck(result, accountID: accountID, expected: account)
                return .init(verification: result)
            }
            try provider.validateManagedCredential(account)
        } catch {
            let result = VerificationResult(
                state: .needsSignIn,
                checkedAt: Date(),
                detail: "The saved auth.json failed its local format, identity, digest, or permission check."
            )
            try? recordAccountCheck(result, accountID: accountID, expected: nil)
            return .init(verification: result)
        }

        do {
            let snapshot = try await readCodexAccountUsage(
                accountID: accountID,
                reader: reader,
                limits: limits
            )
            let accountIDMatches = snapshot.rateLimits?.accountID.map {
                $0 == account.identity.accountID
            } ?? true
            let authenticated = accountIDMatches && snapshot.account != nil
            let result: VerificationResult
            if !accountIDMatches
                || (snapshot.account == nil && snapshot.requiresOpenAIAuthentication == true) {
                result = .init(
                    state: .needsSignIn,
                    checkedAt: snapshot.fetchedAt,
                    detail: !accountIDMatches
                        ? "Codex returned a different account for this saved auth.json."
                        : "Codex requires sign-in for this saved auth.json."
                )
            } else if authenticated {
                result = .init(
                    state: .verifiedWithCodex,
                    checkedAt: snapshot.fetchedAt,
                    detail: "Codex CLI returned account and usage data without a model request."
                )
            } else {
                result = .init(
                    state: .verifiedLocally,
                    checkedAt: snapshot.fetchedAt,
                    detail: "The saved auth.json passed local checks. Codex returned no account identity."
                )
            }
            let email = authenticated ? snapshot.account?.email : nil
            try recordAccountCheck(
                result,
                accountID: accountID,
                expected: account,
                authoritativeEmail: email
            )
            return .init(
                verification: result,
                usage: result.state == .needsSignIn ? nil : snapshot
            )
        } catch {
            // Codex reports an expired or revoked sign-in as an RPC failure carrying the HTTP 401.
            if case CodexAppServerError.rpcFailure(_, let message) = error,
               message.contains("token_expired") || message.contains("401 Unauthorized") {
                let result = VerificationResult(
                    state: .needsSignIn,
                    checkedAt: Date(),
                    detail: "Codex says this sign-in expired. Sign in again to read its usage."
                )
                try? recordAccountCheck(result, accountID: accountID, expected: account)
                return .init(verification: result)
            }
            let detail = error as? AIManagerError == .cliNotFound
                ? "The saved auth.json passed local checks. Codex CLI was not found, so account and usage checks were unavailable."
                : "The saved auth.json passed local checks. Codex account and usage checks were unavailable."
            let result = VerificationResult(
                state: .verifiedLocally,
                checkedAt: Date(),
                detail: detail
            )
            try? recordAccountCheck(result, accountID: accountID, expected: account)
            return .init(verification: result)
        }
    }

    public func launchSpec(accountID: UUID, arguments: [String] = [], workingDirectory: URL? = nil) throws -> LaunchSpec {
        try ensureNoRecovery()
        if try claudeProfiles.accounts().contains(where: { $0.id == accountID }) {
            return try claudeProfiles.launchSpec(accountID, arguments: arguments,
                                                  workingDirectory: workingDirectory)
        }
        let registry = try loadRegistry()
        guard let account = registry.accounts.first(where: { $0.id == accountID }) else { throw AIManagerError.accountNotFound }
        if account.identity.providerID == .droid {
            try validateDroidCredential(account)
            guard registry.defaultAccountID(for: .droid) == accountID else {
                throw AIManagerError.operationFailed("Switch to this account before opening Droid.")
            }
            guard let executable = resolveDroidExecutable() else { throw AIManagerError.cliNotFound }
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "FACTORY_API_KEY")
            environment["FACTORY_HOME_OVERRIDE"] = paths.droidHome.deletingLastPathComponent().path
            environment["FACTORY_DISABLE_KEYRING"] = try droidProvider.files(in: account.credentialFile)["auth.v2.loginkeychain"] == nil ? "1" : "0"
            if let root = paths.isolationRoot { environment["HOME"] = root.path }
            return .init(executable: executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory)
        }
        if account.identity.providerID == .grokBuild {
            return try grokLaunchSpec(
                account: account,
                registry: registry,
                arguments: arguments,
                workingDirectory: workingDirectory)
        }
        try provider.validateManagedCredential(account)
        guard registry.defaultAccountID == accountID else {
            throw AIManagerError.operationFailed("Use this account before opening Codex.")
        }
        try provider.validatePrivateCredentialFile(
            paths.defaultHome.appending(path: "auth.json"))
        let live = provider.inspect(home: paths.defaultHome)
        guard live.support == .supportedChatGPT,
              let liveIdentity = live.identity,
              provider.sameIdentity(account.identity, liveIdentity) else {
            throw AIManagerError.credentialConflict
        }
        guard let executable = resolveExecutable() else { throw AIManagerError.cliNotFound }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_ACCESS_TOKEN")
        environment["CODEX_HOME"] = paths.defaultHome.path
        if let isolationRoot = paths.isolationRoot { environment["HOME"] = isolationRoot.path }
        return .init(
            executable: executable,
            arguments: ["-c", "cli_auth_credentials_store=\"file\""] + arguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
    }

    private func grokLaunchSpec(
        account: AccountRecord,
        registry: Registry,
        arguments: [String],
        workingDirectory: URL?
    ) throws -> LaunchSpec {
        try grokProvider.validateManagedCredential(account)
        guard registry.defaultAccountID(for: .grokBuild) == account.id else {
            throw AIManagerError.operationFailed("Use this account before opening Grok Build.")
        }
        let liveAuth = paths.grokHome.appending(path: "auth.json")
        try grokProvider.validatePrivateCredentialFile(liveAuth)
        let live = grokProvider.inspect(home: paths.grokHome)
        guard live.support == .supportedOAuth,
              let liveIdentity = live.identity,
              grokProvider.sameIdentity(account.identity, liveIdentity) else {
            throw AIManagerError.credentialConflict
        }
        guard let executable = resolveGrokExecutable() else { throw AIManagerError.cliNotFound }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "XAI_API_KEY")
        environment["GROK_HOME"] = paths.grokHome.path
        if let isolationRoot = paths.isolationRoot { environment["HOME"] = isolationRoot.path }
        return .init(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory)
    }

    @discardableResult
    public func activateAndRun(
        accountID: UUID,
        arguments: [String] = [],
        workingDirectory: URL? = nil
    ) async throws -> Int32 {
        if try claudeProfiles.accounts().contains(where: { $0.id == accountID }) {
            _ = try claudeProfiles.makeDefault(accountID)
            let process = configuredProcess(try claudeProfiles.launchSpec(
                accountID, arguments: arguments, workingDirectory: workingDirectory))
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        var launched: Process?
        var launchedProviderName = "Provider"
        try await lock.withAsyncLock {
            try ensureNoRecovery()
            let registry = try loadRegistry()
            guard let account = registry.accounts.first(where: { $0.id == accountID }) else {
                throw AIManagerError.accountNotFound
            }
            launchedProviderName = account.identity.providerID.displayName
            let alreadyActive: Bool
            if account.identity.providerID == .droid {
                try guardDroidProcesses(allowRunning: false)
                _ = try droidProvider.withWriteLock(home: paths.droidHome) { try performDroidSwitch(to: accountID) }
                alreadyActive = true
            } else if account.identity.providerID == .grokBuild {
                try grokProvider.validateManagedCredential(account)
                let live = grokProvider.inspect(home: paths.grokHome)
                alreadyActive = registry.defaultAccountID(for: .grokBuild) == accountID
                    && live.identity.map { grokProvider.sameIdentity(account.identity, $0) } == true
                if !alreadyActive { _ = try performGrokSwitch(to: accountID) }
            } else {
                try provider.validateManagedCredential(account)
                let live = provider.inspect(home: paths.defaultHome)
                alreadyActive = registry.defaultAccountID == accountID
                    && live.identity.map { provider.sameIdentity(account.identity, $0) } == true
                if !alreadyActive { _ = try performSwitch(to: accountID) }
            }
            let process = configuredProcess(
                try launchSpec(
                    accountID: accountID,
                    arguments: arguments,
                    workingDirectory: workingDirectory
                )
            )
            try process.run()
            do {
                try faultInjector(.afterProcessStart)
            } catch {
                if process.isRunning {
                    process.terminate()
                }
                process.waitUntilExit()
                throw error
            }
            launched = process
        }
        guard let launched else {
            throw AIManagerError.operationFailed("\(launchedProviderName) did not start.")
        }
        launched.waitUntilExit()
        return launched.terminationStatus
    }

    public func repairLinkedSetting(accountID: UUID, relativePath: String, reviewedFingerprint: String) async throws -> LinkedSettingRepairResult {
        try await lock.withAsyncLock {
            try ensureNoRecovery()
            guard CoreSupport.settings.contains(relativePath) else { throw AIManagerError.unsafePath(relativePath) }
            let registry = try loadRegistry()
            guard let account = registry.accounts.first(where: { $0.id == accountID }) else { throw AIManagerError.accountNotFound }
            try provider.requireSupported(account.identity.providerID)
            try await ensureWritersInactive([account.home, paths.sharedRoot])
            guard let issue = try inspectLinkedSettings(accounts: [account]).first(where: { $0.relativePath == relativePath }) else {
                throw AIManagerError.operationFailed("The reviewed settings link is no longer divergent.")
            }
            guard issue.localFingerprint == reviewedFingerprint else { throw AIManagerError.sourceChanged }
            guard CoreSupport.entryExists(issue.intendedTarget) else {
                throw AIManagerError.operationFailed("The shared settings target is missing and cannot be linked.")
            }

            let operationID = UUID()
            let backupRoot = issue.backupRoot.appending(path: operationID.uuidString, directoryHint: .isDirectory)
            let backup = backupRoot.appending(path: accountID.uuidString).appending(path: relativePath)
            try CoreSupport.privateDirectory(backup.deletingLastPathComponent(), fileManager: fileManager)
            if CoreSupport.entryExists(issue.localPath) { try fileManager.copyItem(at: issue.localPath, to: backup) }

            let temporary = issue.localPath.deletingLastPathComponent().appending(path: ".\(issue.localPath.lastPathComponent).\(operationID.uuidString).link")
            if CoreSupport.entryExists(temporary) { try fileManager.removeItem(at: temporary) }
            try fileManager.createSymbolicLink(at: temporary, withDestinationURL: issue.intendedTarget)
            guard try linkedSettingFingerprint(issue.localPath) == reviewedFingerprint else {
                try? fileManager.removeItem(at: temporary)
                throw AIManagerError.sourceChanged
            }
            let expectedDigest = try treeDigest(temporary)
            let previousDigest = CoreSupport.entryExists(issue.localPath) ? try? treeDigest(issue.localPath) : nil
            var operation = RecoveryOperation(
                id: operationID,
                kind: "settings-link-repair",
                phase: .prepared,
                source: issue.localPath,
                destination: issue.localPath,
                backup: backupRoot,
                expectedDigest: expectedDigest,
                touchedItems: [.init(destination: issue.localPath, backup: CoreSupport.entryExists(backup) ? backup : nil, expectedDigest: expectedDigest, previousDigest: previousDigest, temporary: temporary)],
                registryAccountID: accountID
            )
            try saveOperation(operation)
            guard try linkedSettingFingerprint(issue.localPath) == reviewedFingerprint else {
                try? fileManager.removeItem(at: temporary)
                try finishOperation(&operation)
                throw AIManagerError.sourceChanged
            }
            if CoreSupport.entryExists(issue.localPath) {
                let values = try issue.localPath.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true, values.isSymbolicLink != true {
                    try fileManager.removeItem(at: issue.localPath)
                }
            }
            let renamed = temporary.path.withCString { temporaryPath in
                issue.localPath.path.withCString { destinationPath in rename(temporaryPath, destinationPath) }
            }
            guard renamed == 0 else {
                throw AIManagerError.operationFailed("The repaired settings link could not be published (errno \(errno)).")
            }
            try faultInjector(.afterHomePublication)
            guard link(issue.localPath, pointsTo: issue.intendedTarget) else {
                throw AIManagerError.operationFailed("The repaired settings link could not be verified.")
            }
            operation.phase = .published
            try saveOperation(operation)
            try finishOperation(&operation)
            return .init(accountID: accountID, relativePath: relativePath, backup: backupRoot)
        }
    }

    @discardableResult
    public func run(_ spec: LaunchSpec) async throws -> Int32 {
        let process = configuredProcess(spec)
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func configuredProcess(_ spec: LaunchSpec) -> Process {
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.environment = spec.environment
        process.currentDirectoryURL = spec.workingDirectory
        return process
    }

    public func verifyLocal(accountID: UUID) async -> VerificationResult {
        await checkAccount(
            accountID: accountID,
            limits: .init(timeout: verificationTimeout)
        ).verification
    }

    public func recover(allowRunningDroid: Bool = false) async throws -> [RecoveryResult] {
        try await lock.withAsyncLock {
            let reviewed = try pendingOperations()
            if reviewed.contains(where: touchesDroidLive) {
                try guardDroidProcesses(allowRunning: allowRunningDroid)
            }
            let reviewedHomes = try Dictionary(uniqueKeysWithValues: reviewed.map { operation in
                (operation.id, Set(try affectedRecoveryHomes(operation).map { CoreSupport.canonical($0).path }))
            })
            try await ensureWritersInactive(reviewed.flatMap { try affectedRecoveryHomes($0) })
            let current = try pendingOperations()
            guard Set(current.map(\.id)) == Set(reviewed.map(\.id)) else {
                throw AIManagerError.sourceChanged
            }
            for operation in current {
                let homes = Set(try affectedRecoveryHomes(operation).map { CoreSupport.canonical($0).path })
                guard homes == reviewedHomes[operation.id] else { throw AIManagerError.sourceChanged }
            }
            return try current.map { operation in
                if touchesDroidLive(operation) {
                    return try droidProvider.withWriteLock(home: paths.droidHome) { try recoverOperation(operation) }
                }
                return try recoverOperation(operation)
            }
        }
    }

    public func resolveRecoveryConflict(
        operationID: UUID,
        choice: RecoveryConflictChoice,
        allowRunningDroid: Bool = false
    ) async throws -> RecoveryResult {
        try await lock.withAsyncLock {
            guard let operation = try pendingOperations().first(where: { $0.id == operationID }) else {
                throw AIManagerError.operationFailed("Recovery operation not found.")
            }
            guard operation.phase == .conflicted else {
                throw AIManagerError.operationFailed("Recovery operation is not conflicted.")
            }
            let affectedHomes = try affectedRecoveryHomes(operation)
            try await ensureWritersInactive(affectedHomes)
            guard let current = try pendingOperations().first(where: { $0.id == operationID }) else {
                throw AIManagerError.operationFailed("Recovery operation not found.")
            }
            guard current.phase == .conflicted else {
                throw AIManagerError.operationFailed("Recovery operation is not conflicted.")
            }
            let reviewedHomes = Set(affectedHomes.map { CoreSupport.canonical($0).path })
            let currentHomes = Set(try affectedRecoveryHomes(current).map { CoreSupport.canonical($0).path })
            guard currentHomes == reviewedHomes else { throw AIManagerError.sourceChanged }
            if touchesDroidLive(current) {
                try guardDroidProcesses(allowRunning: allowRunningDroid)
                return try droidProvider.withWriteLock(home: paths.droidHome) {
                    try resolveRecoveryConflict(current, choice: choice)
                }
            }
            return try resolveRecoveryConflict(current, choice: choice)
        }
    }
}

final class JSONLReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var offset = 0
    private var bufferOffset: UInt64 = 0
    private(set) var lastRecordOffset: UInt64 = 0
    private(set) var lastRecordEndedWithNewline = true
    private var reachedEnd = false
    private let maximumRecordBytes: Int

    init(
        url: URL,
        maximumRecordBytes: Int = 64 * 1_024 * 1_024,
        startingAt startOffset: UInt64 = 0
    ) throws {
        self.maximumRecordBytes = maximumRecordBytes
        handle = try FileHandle(forReadingFrom: url)
        if startOffset > 0 {
            try handle.seek(toOffset: startOffset)
            bufferOffset = startOffset
        }
    }

    deinit { try? handle.close() }

    func next() throws -> Data? {
        while true {
            if offset < buffer.count, let newline = buffer[offset...].firstIndex(of: 0x0A) {
                guard newline - offset <= maximumRecordBytes else {
                    throw AIManagerError.invalidSource("A JSONL record exceeds the validation limit.")
                }
                lastRecordOffset = bufferOffset + UInt64(offset)
                lastRecordEndedWithNewline = true
                let record = Data(buffer[offset..<newline])
                offset = newline + 1
                compactIfNeeded()
                if record.isEmpty { continue }
                return record
            }
            if reachedEnd {
                guard offset < buffer.count else { return nil }
                guard buffer.count - offset <= maximumRecordBytes else {
                    throw AIManagerError.invalidSource("A JSONL record exceeds the validation limit.")
                }
                lastRecordOffset = bufferOffset + UInt64(offset)
                lastRecordEndedWithNewline = false
                let record = Data(buffer[offset...])
                offset = buffer.count
                return record.isEmpty ? nil : record
            }
            guard buffer.count - offset <= maximumRecordBytes else {
                throw AIManagerError.invalidSource("A JSONL record exceeds the validation limit.")
            }
            if let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { buffer.append(chunk) }
            else { reachedEnd = true }
        }
    }

    private func compactIfNeeded() {
        if offset >= 1_048_576 {
            bufferOffset += UInt64(offset)
            buffer.removeSubrange(0..<offset)
            offset = 0
        }
    }
}

extension AccountManager {
    public static func systemCapacity(at destination: URL) -> Int64? {
        var candidate = destination
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 { candidate.deleteLastPathComponent() }
        let values = try? candidate.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let capacity = values?.volumeAvailableCapacity, capacity > 0 else { return nil }
        return Int64(capacity)
    }

    public static func systemWriterCheck(home: URL) async -> WriterState {
        CodexWriterProbe.check(home: home)
    }

    // MARK: Droid opaque file logins

    public func importDroidAccount(name: String, apiKey: String? = nil, allowDuplicate: Bool = false, automatic: Bool = false) throws -> AccountRecord {
        try lock.withLock {
            try ensureNoRecovery()
            // Import takes the same writer lock but never changes live authentication.
            try droidProvider.requireLogin(droidProvider.files(in: paths.droidHome))
            let hint = droidIdentityHint(home: paths.droidHome)
            return try droidProvider.withWriteLock(home: paths.droidHome) {
                let account = try saveDroidAccount(from: paths.droidHome, hint: hint, name: name, targetID: nil, adoptLive: true, allowDuplicate: allowDuplicate, automatic: automatic)
                if let apiKey, !apiKey.isEmpty { try saveDroidUsageKey(apiKey, accountID: account.id) }
                return account
            }
        }
    }

    public func setDroidUsageAPIKey(accountID: UUID, apiKey: String) throws {
        try lock.withLock {
            try ensureNoRecovery()
            guard try loadRegistry().accounts.contains(where: { $0.id == accountID && $0.identity.providerID == .droid }) else {
                throw AIManagerError.accountNotFound
            }
            try saveDroidUsageKey(apiKey, accountID: accountID)
        }
    }

    /// Whether a usage key is saved for the account. Never returns the key.
    public func hasDroidUsageAPIKey(accountID: UUID) -> Bool {
        CoreSupport.entryExists(droidUsageKey(accountID))
    }

    private func droidUsageKey(_ id: UUID) -> URL {
        paths.applicationSupport.appending(path: "droid-usage/\(id.uuidString).json")
    }

    private func saveDroidUsageKey(_ key: String, accountID: UUID) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            if CoreSupport.entryExists(droidUsageKey(accountID)) { try fileManager.removeItem(at: droidUsageKey(accountID)) }
        } else {
            try CoreSupport.atomicWrite(try encoder.encode(ProviderCredential(fields: ["apiKey": value])),
                                        to: droidUsageKey(accountID), fileManager: fileManager)
        }
    }

    private func validateDroidCredential(_ account: AccountRecord) throws {
        try validateDeleteTargets(account)
        try droidProvider.requireLogin(droidProvider.files(in: account.credentialFile))
        let names = try fileManager.contentsOfDirectory(atPath: account.credentialFile.path)
        guard Set(names).isSubset(of: Set(DroidProviderAdapter.authNames)),
              try treeDigest(account.credentialFile) == account.credentialDigest else {
            throw AIManagerError.credentialConflict
        }
    }

    private func guardDroidProcesses(allowRunning: Bool) throws {
        let running = try droidProcessLister().filter {
            $0.home == nil || CoreSupport.sameLocation($0.home!, paths.droidHome)
        }
        if !running.isEmpty, !allowRunning { throw DroidAccountError.running(running) }
    }

    private func touchesDroidLive(_ operation: RecoveryOperation) -> Bool {
        operation.kind == "switch-droid" || (operation.kind == "import-droid" && (operation.touchedItems ?? []).contains {
            DroidProviderAdapter.authNames.contains($0.destination.lastPathComponent)
                && CoreSupport.sameLocation($0.destination.deletingLastPathComponent(), paths.droidHome)
        })
    }

    private func resolveDroidExecutable() -> URL? {
        if let explicit = paths.droidExecutable { return validatedExecutable(explicit) }
        guard paths.isolationRoot == nil else { return nil }
        let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "droid") }
            + [paths.userHome.appending(path: ".local/bin/droid"), URL(fileURLWithPath: "/Applications/Factory.app/Contents/Resources/bin/droid")]
        return candidates.compactMap(validatedExecutable).first
    }

    private func startDroidLogin(accountID: UUID?) throws -> AccountLoginStart {
        guard try !loadLoginSessions().contains(where: { $0.providerID == .droid }) else {
            throw DroidAccountError.loginInProgress
        }
        let live = try droidProvider.files(in: paths.droidHome)
        try droidProvider.requireLogin(live)
        guard let executable = resolveDroidExecutable() else { throw AIManagerError.cliNotFound }
        let session = AccountLoginSession(id: UUID(), providerID: .droid, createdAt: Date(), accountID: accountID)
        try CoreSupport.privateDirectory(loginHome(session.id), fileManager: fileManager)
        try saveLoginSession(session)
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "FACTORY_API_KEY")
        environment["FACTORY_HOME_OVERRIDE"] = loginHome(session.id).path
        environment["FACTORY_DISABLE_KEYRING"] = live["auth.v2.loginkeychain"] == nil ? "1" : "0"
        if let root = paths.isolationRoot { environment["HOME"] = root.path }
        // The help exposes only an initial prompt, not a login command. Do not submit /login as an AI request.
        let spec = LaunchSpec(executable: executable, arguments: [], environment: environment,
                              workingDirectory: loginHome(session.id))
        var start = AccountLoginStart(session: session, launchSpec: spec)
        start.opensInTerminal = true
        return start
    }

    private func checkDroidLogin(_ session: AccountLoginSession, name: String, allowRunning: Bool, allowDuplicate: Bool) throws -> AccountLoginCheck {
        let home = loginHome(session.id).appending(path: ".factory")
        guard ["auth.v2.loginkeychain", "auth.v2.file"].contains(where: { CoreSupport.entryExists(home.appending(path: $0)) }) else {
            return .init(session: session, state: .waitingForLogin,
                         message: "In Terminal, type /login and finish signing in. Then exit Droid to save the account.")
        }
        let account: AccountRecord
        do { account = try lock.withLock {
            try ensureNoRecovery()
            let registry = try loadRegistry()
            let target = registry.accounts.first { $0.id == session.accountID && $0.identity.providerID == .droid }
            if session.accountID != nil, target == nil { throw AIManagerError.accountNotFound }
            let refreshLive = target != nil && registry.defaultAccountID(for: .droid) == target?.id
            if refreshLive { try guardDroidProcesses(allowRunning: allowRunning) }
            let hint = droidIdentityHint(home: home)
            return try droidProvider.withWriteLock(home: home) {
                if refreshLive {
                    return try droidProvider.withWriteLock(home: paths.droidHome) {
                        try saveDroidAccount(from: home, hint: hint, name: target?.identity.accountID ?? name,
                                             targetID: target?.id, adoptLive: false, refreshLive: true, allowDuplicate: allowDuplicate)
                    }
                }
                return try saveDroidAccount(from: home, hint: hint, name: target?.identity.accountID ?? name,
                                            targetID: target?.id, adoptLive: false, allowDuplicate: allowDuplicate)
            }
        } } catch let error as AIManagerError {
            if case .signInIdentityMismatch = error {
                try fileManager.removeItem(at: loginRoot(session.id))
            }
            throw error
        } catch DroidAccountError.writeLockBusy {
            return .init(session: session, state: .waitingForLogin,
                         message: "Droid is still saving the login. Switch will check it again.")
        }
        // Terminal owns the process. Retire metadata without killing it or deleting an open home.
        try retireLoginSession(session.id)
        return .init(session: session, state: .completed, account: account,
                     message: "Droid account saved. Choose Switch to use this login for new requests. \(account.verification.detail)")
    }

    /// Runs `droid doctor --auth --json` on the login's own home, never a copy. Doctor may refresh an expired token, and a
    /// copy would spend a rotating refresh token that the live login still holds, which could sign Factory.app out.
    /// Order: doctor first, then the write lock, then read the files. Droid takes `auth.v2.write.lock` itself to save a
    /// refresh, so Switch must not hold it while doctor runs. The files read after the lock hold whatever doctor left.
    private func droidIdentityHint(home: URL) -> String? {
        let live = CoreSupport.sameLocation(home, paths.droidHome)
        let bundled = live ? paths.droidBundledExecutable.flatMap(validatedExecutable) : nil
        guard let executable = bundled ?? resolveDroidExecutable() else { return nil }
        return droidProvider.doctor(executable: executable, factoryHome: home,
                                    scratch: paths.applicationSupport.appending(path: "staging"),
                                    keyring: CoreSupport.entryExists(home.appending(path: "auth.v2.loginkeychain")),
                                    home: paths.isolationRoot)
    }

    private func saveDroidAccount(from source: URL, hint: String?, name: String, targetID: UUID?, adoptLive: Bool, refreshLive: Bool = false, allowDuplicate: Bool = false, automatic: Bool = false) throws -> AccountRecord {
        let label = try Self.droidAccountName(name)
        let files = try droidProvider.files(in: source)
        try droidProvider.requireLogin(files)
        var registry = try loadRegistry()
        let detail = hint.map { "Droid doctor reported \($0). Equal masks can belong to different people." }
            ?? "Droid doctor could not confirm a masked email. Saved using the account name only."
        let previous = registry.accounts.first { $0.id == targetID }
        if let hint, let savedHint = previous?.identity.email, hint != savedHint.lowercased() {
            throw AIManagerError.signInIdentityMismatch(signedIn: hint, target: savedHint)
        }
        if targetID == nil, !allowDuplicate, let hint,
           let existing = droidMaskTwin(of: files, hint: hint, in: registry.accounts) {
            throw DroidAccountError.duplicateIdentity(name: existing.identity.accountID ?? "Droid", hint: hint)
        }
        let id = targetID ?? UUID(), operationID = UUID()
        let staged = paths.applicationSupport.appending(path: "staging/\(operationID.uuidString)/droid-auth")
        try CoreSupport.privateDirectory(staged, fileManager: fileManager)
        for (name, bytes) in files { try CoreSupport.atomicWrite(bytes, to: staged.appending(path: name), fileManager: fileManager) }
        let digest = try treeDigest(staged)
        if targetID == nil, let index = registry.accounts.firstIndex(where: { $0.identity.providerID == .droid && $0.credentialDigest == digest }) {
            var existing = registry.accounts[index]
            existing.identity.email = hint ?? existing.identity.email
            existing.verification.detail = detail
            registry.accounts[index] = existing
            try fileManager.removeItem(at: staged.deletingLastPathComponent())
            if adoptLive {
                registry.setDefaultAccountID(existing.id, for: .droid)
            }
            try saveRegistry(registry)
            return existing
        }
        let saved = credentialFile(for: id, providerID: .droid)
        let home = accountsRoot.appending(path: "\(id.uuidString)/home")
        var operation = RecoveryOperation(id: operationID, kind: "import-droid", phase: .prepared,
            source: staged, destination: saved, backup: paths.applicationSupport.appending(path: "backups/\(operationID.uuidString)"),
            expectedDigest: digest, previousDigest: CoreSupport.entryExists(saved) ? try treeDigest(saved) : nil,
            registryAccountID: id, previousDefaultAccountID: registry.defaultAccountID(for: .droid),
            registryCredentialDigest: digest, previousAccount: previous, setsDefaultAccount: adoptLive)
        try saveOperation(operation)
        try replaceRecoverably(source: staged, destination: saved, operation: &operation, backupName: "account-home")
        try faultInjector(.afterCredentialPublication)
        if refreshLive { try publishDroidFiles(from: staged, files: files, operation: &operation) }
        try CoreSupport.privateDirectory(home, fileManager: fileManager)
        let account = AccountRecord(id: id, identity: .init(providerID: .droid, email: hint ?? previous?.identity.email, accountID: label, authMode: .oauth),
            credentialFile: saved, home: home, source: source, importedAt: previous?.importedAt ?? Date(),
            verification: .init(state: .imported, detail: detail), credentialDigest: digest,
            autoImported: previous?.autoImported ?? automatic)
        if let index = registry.accounts.firstIndex(where: { $0.id == id }) { registry.accounts[index] = account }
        else { registry.accounts.append(account) }
        if adoptLive { registry.setDefaultAccountID(id, for: .droid) }
        try saveRegistry(registry)
        try faultInjector(.afterRegistryCommit)
        operation.phase = .registryCommitted
        try saveOperation(operation)
        try finishOperation(&operation)
        try fileManager.removeItem(at: staged.deletingLastPathComponent())
        return account
    }

    private func performDroidSwitch(to accountID: UUID) throws -> SwitchResult {
        var registry = try loadRegistry()
        guard let index = registry.accounts.firstIndex(where: { $0.id == accountID && $0.identity.providerID == .droid }) else {
            throw AIManagerError.accountNotFound
        }
        let requested = registry.accounts[index]
        try validateDroidCredential(requested)
        var incoming = try droidProvider.files(in: requested.credentialFile)
        let outgoing = try droidProvider.files(in: paths.droidHome)
        let previousDefault = registry.defaultAccountID(for: .droid)
        if previousDefault == accountID, !outgoing.isEmpty { incoming = outgoing }
        if !outgoing.isEmpty, previousDefault == nil {
            throw AIManagerError.operationFailed("Import the current Droid login before switching, so Switch can capture it safely.")
        }
        let operationID = UUID()
        let backup = paths.applicationSupport.appending(path: "backups/\(operationID.uuidString)")
        let primaryName = incoming["auth.v2.loginkeychain"] != nil ? "auth.v2.loginkeychain" : "auth.v2.file"
        let primary = paths.droidHome.appending(path: primaryName)
        var operation = RecoveryOperation(id: operationID, kind: "switch-droid", phase: .prepared,
            source: requested.credentialFile, destination: primary, backup: backup,
            expectedDigest: CoreSupport.digest(incoming[primaryName]!), touchedItems: [],
            previousDigest: outgoing[primaryName].map(CoreSupport.digest),
            registryAccountID: accountID, previousDefaultAccountID: previousDefault)
        try saveOperation(operation)
        // Capture rotated outgoing bytes before publishing any incoming file.
        if CoreSupport.entryExists(primary) { try copyPortable(primary, to: backup.appending(path: "auth.json")) }
        if let outgoingIndex = registry.accounts.firstIndex(where: { $0.id == previousDefault }),
           !outgoing.isEmpty {
            let staged = paths.applicationSupport.appending(path: "staging/\(operationID.uuidString)/outgoing")
            try CoreSupport.privateDirectory(staged, fileManager: fileManager)
            for (name, bytes) in outgoing { try CoreSupport.atomicWrite(bytes, to: staged.appending(path: name), fileManager: fileManager) }
            operation.previousAccount = registry.accounts[outgoingIndex]
            try replaceRecoverably(source: staged, destination: registry.accounts[outgoingIndex].credentialFile,
                                   operation: &operation, backupName: "outgoing-auth")
            registry.accounts[outgoingIndex].credentialDigest = try treeDigest(staged)
        }
        try publishDroidFiles(from: requested.credentialFile, files: incoming, operation: &operation)
        registry.setDefaultAccountID(accountID, for: .droid)
        registry.accounts[index].lastUsedAt = Date()
        try saveRegistry(registry)
        try faultInjector(.afterRegistryCommit)
        operation.phase = .registryCommitted
        try saveOperation(operation)
        try finishOperation(&operation)
        let staged = paths.applicationSupport.appending(path: "staging/\(operationID.uuidString)")
        if CoreSupport.entryExists(staged) { try fileManager.removeItem(at: staged) }
        recordDroidMissionSwitch(from: previousDefault, to: accountID)
        return .init(accountID: accountID, backup: backup, previousAccountID: previousDefault)
    }

    private func publishDroidFiles(from source: URL, files incoming: [String: Data], operation: inout RecoveryOperation) throws {
        for name in DroidProviderAdapter.authNames {
            let live = paths.droidHome.appending(path: name)
            if incoming[name] != nil {
                try replaceRecoverably(source: source.appending(path: name), destination: live,
                                       operation: &operation, backupName: "live/\(name)")
            } else if CoreSupport.entryExists(live) {
                let protected = operation.backup.appending(path: "live/\(name)")
                try copyPortable(live, to: protected)
                operation.touchedItems!.append(.init(destination: live, backup: protected,
                    expectedDigest: "absent", previousDigest: try treeDigest(live)))
                try saveOperation(operation)
                try fileManager.removeItem(at: live)
            } else { continue }
            try faultInjector(.afterDefaultCredentialPublication)
        }
        guard try droidProvider.files(in: paths.droidHome) == incoming else { throw AIManagerError.sourceChanged }
    }

    private var registryURL: URL { paths.applicationSupport.appending(path: "accounts.json") }

    // MARK: Droid missions

    private var missionOwnersURL: URL { paths.applicationSupport.appending(path: "droid-missions.json") }

    /// The mission folders, newest first, each with its owner. Owners of deleted accounts read as
    /// unknown. A refresh also gives new missions to the default account (see `DroidMissionOwners`).
    public func droidMissions() throws -> [DroidMission] {
        let registry = try loadRegistry()
        let saved = Set(registry.accounts.filter { $0.identity.providerID == .droid }.map(\.id))
        var missions = DroidMissionReader.list(droidHome: paths.droidHome, fileManager: fileManager)
        var owners = DroidMissionOwners.load(missionOwnersURL)
        let before = owners
        owners.refresh(missions, defaultAccount: registry.defaultAccountID(for: .droid), now: Date())
        if owners != before { try? owners.save(missionOwnersURL, fileManager: fileManager) }
        for index in missions.indices {
            missions[index].owner = owners.owners[missions[index].id].flatMap { saved.contains($0) ? $0 : nil }
        }
        return missions
    }

    public func setDroidMissionOwner(folder: String, accountID: UUID) throws {
        let registry = try loadRegistry()
        guard registry.accounts.contains(where: { $0.id == accountID && $0.identity.providerID == .droid }) else {
            throw AIManagerError.accountNotFound
        }
        var owners = DroidMissionOwners.load(missionOwnersURL)
        owners.owners[folder] = accountID
        try owners.save(missionOwnersURL, fileManager: fileManager)
    }

    /// Writes the "Start here" plan of a mission to application support `Launch/` and returns it.
    public func writeDroidMissionPlan(folder: String) throws -> URL {
        guard DroidMissionReader.list(droidHome: paths.droidHome, fileManager: fileManager).contains(where: { $0.id == folder }),
              let plan = DroidMissionReader.plan(folder: folder, droidHome: paths.droidHome, fileManager: fileManager) else {
            throw AIManagerError.operationFailed("That Droid mission could not be read.")
        }
        let url = paths.applicationSupport.appending(path: "Launch/Droid mission \(folder.prefix(8)) plan.md")
        try CoreSupport.atomicWrite(Data(plan.utf8), to: url, fileManager: fileManager)
        return url
    }

    /// After a switch away from an account: how many missions it started that still have features
    /// left. Zero when the default did not change.
    public func unfinishedDroidMissions(after result: SwitchResult) throws -> Int {
        guard let previous = result.previousAccountID, previous != result.accountID else { return 0 }
        return try droidMissions().filter { $0.owner == previous && $0.left > 0 }.count
    }

    private func recordDroidMissionSwitch(from previous: UUID?, to accountID: UUID) {
        guard previous != accountID else { return }
        var owners = DroidMissionOwners.load(missionOwnersURL)
        let missions = DroidMissionReader.list(droidHome: paths.droidHome, fileManager: fileManager)
        owners.switched(from: previous, to: accountID, missions, now: Date())
        try? owners.save(missionOwnersURL, fileManager: fileManager)
    }
    private var accountsRoot: URL {
        paths.applicationSupport.appending(path: "accounts", directoryHint: .isDirectory)
    }
    private func credentialFile(
        for accountID: UUID,
        providerID: ProviderID = .codex
    ) -> URL {
        if providerID == .droid { return paths.droidCredentialStore.appending(path: accountID.uuidString) }
        let root = providerID == .grokBuild
            ? paths.grokCredentialStore : paths.credentialStore
        return root.appending(path: "\(accountID.uuidString).json")
    }
    private var transactionsURL: URL { paths.applicationSupport.appending(path: "transactions", directoryHint: .isDirectory) }
    private var loginSessionsURL: URL {
        paths.applicationSupport.appending(path: "account-login", directoryHint: .isDirectory)
    }

    private func validateDeleteTargets(_ account: AccountRecord) throws {
        let expectedHome = accountsRoot.appending(path: account.id.uuidString)
            .appending(path: "home", directoryHint: .isDirectory)
        guard CoreSupport.sameLocation(account.home, expectedHome),
              CoreSupport.isContained(account.home, by: accountsRoot) else {
            throw AIManagerError.unsafePath("managed account home is outside the private account root")
        }
        let credentialRoot = account.identity.providerID == .droid ? paths.droidCredentialStore
            : account.identity.providerID == .grokBuild ? paths.grokCredentialStore : paths.credentialStore
        let expectedCredential = credentialFile(
            for: account.id, providerID: account.identity.providerID)
        guard CoreSupport.sameLocation(account.credentialFile, expectedCredential),
              CoreSupport.isContained(account.credentialFile, by: credentialRoot) else {
            throw AIManagerError.unsafePath("saved credential is outside the private credential store")
        }
    }

    private func loginRoot(_ id: UUID) -> URL {
        loginSessionsURL.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func loginHome(_ id: UUID) -> URL {
        loginRoot(id).appending(path: "home", directoryHint: .isDirectory)
    }

    private func loginSessionURL(_ id: UUID) -> URL {
        loginRoot(id).appending(path: "session.json")
    }

    private func saveLoginSession(_ session: AccountLoginSession) throws {
        let record = VersionedLoginSession(version: 1, session: session)
        try CoreSupport.atomicWrite(
            try encoder.encode(record), to: loginSessionURL(session.id), fileManager: fileManager)
    }

    private func loadLoginSession(_ id: UUID) throws -> AccountLoginSession {
        let record = try loadLoginSessionRecord(id)
        guard record.retiredAt == nil else {
            throw AIManagerError.invalidSource("Account login session is no longer active.")
        }
        return record.session
    }

    private func loadLoginSessionRecord(_ id: UUID) throws -> VersionedLoginSession {
        let root = loginRoot(id)
        guard CoreSupport.isContained(root, by: loginSessionsURL) else {
            throw AIManagerError.unsafePath(root.path)
        }
        try validatePrivateLoginDirectory(root)
        try validatePrivateLoginDirectory(loginHome(id))
        let url = loginSessionURL(id)
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 64 * 1_024 else {
            throw AIManagerError.invalidSource("Account login session is not a bounded regular file.")
        }
        try provider.validatePrivateCredentialFile(url)
        let record = try decoder.decode(VersionedLoginSession.self, from: Data(contentsOf: url))
        guard record.version == 1, record.session.id == id else {
            throw AIManagerError.invalidSource("Account login session version or identity is invalid.")
        }
        return record
    }

    private func retireLoginSession(_ id: UUID) throws {
        var record = try loadLoginSessionRecord(id)
        guard record.retiredAt == nil else {
            throw AIManagerError.invalidSource("Account login session is no longer active.")
        }
        record.retiredAt = Date()
        try CoreSupport.atomicWrite(
            try encoder.encode(record), to: loginSessionURL(id), fileManager: fileManager)
    }

    private func pruneRetiredLoginSessions() async throws {
        guard CoreSupport.entryExists(loginSessionsURL) else { return }
        try await lock.withAsyncLock {
            guard try pendingOperations().isEmpty else { return }
            try validatePrivateLoginDirectory(loginSessionsURL)
            let entries = try fileManager.contentsOfDirectory(
                at: loginSessionsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            for entry in entries {
                guard let id = UUID(uuidString: entry.lastPathComponent) else { continue }
                let reviewed = try loadLoginSessionRecord(id)
                if reviewed.session.providerID == .droid,
                   try !droidProcessLister().filter({
                       $0.home == nil || CoreSupport.sameLocation($0.home!, loginHome(id).appending(path: ".factory"))
                   }).isEmpty { continue }
                guard let retiredAt = reviewed.retiredAt,
                      await writerCheck(loginHome(id)) == .inactive else { continue }
                let current = try loadLoginSessionRecord(id)
                guard current.retiredAt == retiredAt, current.session.createdAt == reviewed.session.createdAt else {
                    throw AIManagerError.sourceChanged
                }
                guard try pendingOperations().isEmpty else { return }
                try fileManager.removeItem(at: loginRoot(id))
            }
        }
    }

    private func loadLoginSessions() throws -> [AccountLoginSession] {
        guard CoreSupport.entryExists(loginSessionsURL) else { return [] }
        let values = try loginSessionsURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw AIManagerError.unsafePath("Account login root is not a private directory.")
        }
        try validatePrivateLoginDirectory(loginSessionsURL)
        return try fileManager.contentsOfDirectory(
            at: loginSessionsURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            let record = try loadLoginSessionRecord(id)
            return record.retiredAt == nil ? record.session : nil
        }.sorted { $0.createdAt < $1.createdAt }
    }

    private func validatePrivateLoginDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o700 else {
            throw AIManagerError.unsafePath("Account login directory is not private: \(url.path)")
        }
    }

    private func adoptLiveAccount() async throws -> ImportResult {
        let plan = try await makeImportPlan(
            source: paths.defaultHome, mode: .authOnly, allowApplicationSupportSource: false)
        guard plan.conflicts.isEmpty else { throw AIManagerError.credentialConflict }
        let current = provider.inspect(home: paths.defaultHome)
        guard current.support == .supportedChatGPT,
              current.digest == plan.sourceAuthDigest else { throw AIManagerError.sourceChanged }
        return try await lock.withAsyncLock {
            try ensureNoRecovery()
            guard try loadRegistry().accounts.isEmpty else {
                throw AIManagerError.operationFailed("The account registry changed during live account adoption.")
            }
            return try performImport(
                plan: plan, auth: current.data, decisions: [:], setsDefaultAccount: true)
        }
    }

    private func operationItemsURL(_ id: UUID) -> URL {
        transactionsURL.appending(path: "\(id.uuidString).items", directoryHint: .isDirectory)
    }

    private func loadRegistry() throws -> Registry {
        try lock.withLock { try loadRegistryLocked() }
    }

    private func loadRegistryLocked() throws -> Registry {
        guard CoreSupport.entryExists(registryURL) else { return Registry() }
        let values = try registryURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= 16 * 1_024 * 1_024 else {
            throw AIManagerError.unsafePath("account registry is not a bounded regular file")
        }
        var registry = try decoder.decode(Registry.self, from: Data(contentsOf: registryURL))
        guard Set(registry.accounts.map(\.id)).count == registry.accounts.count else {
            throw AIManagerError.invalidSource("The account registry contains duplicate identifiers.")
        }
        var migratedCredential = false
        for index in registry.accounts.indices {
            let account = registry.accounts[index]
            let expected = accountsRoot.appending(path: account.id.uuidString)
                .appending(path: "home", directoryHint: .isDirectory)
            guard CoreSupport.sameLocation(account.home, expected) else {
                throw AIManagerError.unsafePath("managed account home is outside the private account root")
            }
            let expectedCredential = credentialFile(
                for: account.id, providerID: account.identity.providerID)
            let legacyCredential = account.home.appending(path: "auth.json")
            if account.identity.providerID == .codex,
               account.credentialFile.standardizedFileURL.path == legacyCredential.standardizedFileURL.path {
                let legacy = provider.inspect(credentialFile: legacyCredential)
                guard legacy.support == .supportedChatGPT,
                      let identity = legacy.identity,
                      provider.sameIdentity(account.identity, identity) else {
                    throw AIManagerError.credentialConflict
                }
                if CoreSupport.entryExists(expectedCredential) {
                    let saved = provider.inspect(credentialFile: expectedCredential)
                    guard saved.support == .supportedChatGPT,
                          let savedIdentity = saved.identity,
                          provider.sameIdentity(identity, savedIdentity),
                          saved.digest == legacy.digest else {
                        throw AIManagerError.credentialConflict
                    }
                } else {
                    try CoreSupport.atomicWrite(legacy.data, to: expectedCredential, fileManager: fileManager)
                }
                registry.accounts[index].credentialFile = expectedCredential
                registry.accounts[index].credentialDigest = legacy.digest
                migratedCredential = true
            } else {
                guard account.credentialFile.standardizedFileURL.path
                    == expectedCredential.standardizedFileURL.path else {
                    throw AIManagerError.unsafePath("saved credential is outside the private credential store")
                }
                if account.identity.providerID == .droid {
                    // Recovery may temporarily differ from the committed digest.
                    try droidProvider.requireLogin(droidProvider.files(in: account.credentialFile))
                } else if account.identity.providerID == .grokBuild {
                    try grokProvider.validateManagedCredential(account)
                } else {
                    try provider.validatePrivateCredentialFile(account.credentialFile)
                    let saved = provider.inspect(credentialFile: account.credentialFile)
                    guard saved.support == .supportedChatGPT,
                          let savedIdentity = saved.identity,
                          provider.sameIdentity(account.identity, savedIdentity) else {
                        throw AIManagerError.credentialConflict
                    }
                }
            }
        }
        let migratedDefaults = registry.needsDefaultMigration
        if registry.needsDefaultMigration {
            for providerID in [ProviderID.codex, .grokBuild]
                where registry.defaultAccountID(for: providerID) == nil {
                if let accountID = liveDefaultAccountID(
                    for: providerID, accounts: registry.accounts) {
                    registry.setDefaultAccountID(accountID, for: providerID)
                }
            }
        }
        for (provider, defaultID) in registry.defaultAccountIDs {
            guard registry.accounts.contains(where: {
                $0.id == defaultID && $0.identity.providerID.rawValue == provider
            }) else {
                throw AIManagerError.invalidSource(
                    "A provider default account is missing from the registry.")
            }
        }
        registry.needsDefaultMigration = false
        if migratedCredential || migratedDefaults { try saveRegistry(registry) }
        return registry
    }

    private func liveDefaultAccountID(
        for providerID: ProviderID,
        accounts: [AccountRecord]
    ) -> UUID? {
        switch providerID {
        case .codex:
            let live = provider.inspect(home: paths.defaultHome)
            guard live.support == .supportedChatGPT, let identity = live.identity else { return nil }
            return accounts.first {
                $0.identity.providerID == providerID
                    && provider.sameIdentity($0.identity, identity)
            }?.id
        case .grokBuild:
            let live = grokProvider.inspect(home: paths.grokHome)
            guard live.support == .supportedOAuth, let identity = live.identity else { return nil }
            return accounts.first {
                $0.identity.providerID == providerID
                    && grokProvider.sameIdentity($0.identity, identity)
            }?.id
        default:
            return nil
        }
    }

    private func saveRegistry(_ registry: Registry) throws {
        try CoreSupport.atomicWrite(try encoder.encode(registry), to: registryURL, fileManager: fileManager)
    }

    private func recordAccountCheck(
        _ result: VerificationResult,
        accountID: UUID,
        expected: AccountRecord?,
        authoritativeEmail: String? = nil
    ) throws {
        try lock.withLock {
            var registry = try loadRegistry()
            guard let index = registry.accounts.firstIndex(where: { $0.id == accountID }) else {
                throw AIManagerError.accountNotFound
            }
            if let expected {
                guard registry.accounts[index].identity == expected.identity,
                      registry.accounts[index].credentialDigest == expected.credentialDigest else {
                    throw AIManagerError.sourceChanged
                }
            }
            if let email = authoritativeEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
               !email.isEmpty {
                registry.accounts[index].identity.email = String(email.prefix(320))
            }
            registry.accounts[index].verification = result
            try saveRegistry(registry)
        }
    }

    private func pendingOperations() throws -> [RecoveryOperation] {
        guard fileManager.fileExists(atPath: transactionsURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: transactionsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .map {
                var operation = try decoder.decode(RecoveryOperation.self, from: Data(contentsOf: $0))
                let itemRoot = operationItemsURL(operation.id)
                if fileManager.fileExists(atPath: itemRoot.path) {
                    let items = try fileManager.contentsOfDirectory(at: itemRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                        .filter { $0.pathExtension == "json" }
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
                        .map { try decoder.decode(RecoveryItem.self, from: Data(contentsOf: $0)) }
                    operation.touchedItems = (operation.touchedItems ?? []) + items
                }
                return operation
            }
            .filter { ![.completed, .rolledBack].contains($0.phase) }
    }

    private func ensureNoRecovery() throws {
        if try !pendingOperations().isEmpty { throw AIManagerError.recoveryRequired }
    }

    private func ensureWritersInactive(_ homes: [URL]) async throws {
        var checked = Set<String>()
        for home in homes {
            let canonical = CoreSupport.canonical(home).path
            guard checked.insert(canonical).inserted else { continue }
            switch await writerCheck(home) {
            case .active: throw AIManagerError.activeCodexProcesses
            case .unknown: throw AIManagerError.writerStateUnknown
            case .inactive: break
            }
        }
    }

    private func saveOperation(_ operation: RecoveryOperation) throws {
        if let items = operation.touchedItems, let last = items.last {
            let itemRoot = operationItemsURL(operation.id)
            try CoreSupport.privateDirectory(itemRoot, fileManager: fileManager)
            let name = String(format: "%09d.json", items.count - 1)
            try CoreSupport.atomicWrite(try encoder.encode(last), to: itemRoot.appending(path: name), fileManager: fileManager)
        }
        var header = operation
        header.touchedItems = nil
        try CoreSupport.atomicWrite(try encoder.encode(header), to: transactionsURL.appending(path: "\(operation.id.uuidString).json"), fileManager: fileManager)
    }

    private func finishOperation(_ operation: inout RecoveryOperation) throws {
        operation.phase = .completed
        try saveOperation(operation)
        try? fileManager.removeItem(at: operationItemsURL(operation.id))
    }

    private func inspectSource(_ selected: URL) -> DiscoveredSource {
        let home = CoreSupport.home(for: selected)
        let inspection = provider.inspect(home: selected)
        let settings = CoreSupport.settings.filter { CoreSupport.entryExists(home.appending(path: $0)) }
        let history = historySummary(in: home)
        return .init(
            id: CoreSupport.canonical(home).path,
            providerID: provider.id,
            path: home,
            identity: inspection.identity,
            support: inspection.support,
            settings: settings,
            history: history,
            inspectionError: inspection.error
        )
    }

    private func historySummary(in home: URL) -> HistorySummary {
        HistorySummary(
            activeTranscripts: transcriptCount(in: home.appending(path: "sessions")),
            archivedTranscripts: transcriptCount(in: home.appending(path: "archived_sessions")),
            hasIndexes: ["history.jsonl", "session_index.jsonl"].contains {
                let values = try? home.appending(path: $0).resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values?.isRegularFile == true && values?.isSymbolicLink != true
            }
        )
    }

    private func transcriptCount(in root: URL) -> Int {
        guard fileManager.fileExists(atPath: root.path),
              let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { return 0 }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited > 500_000 { break }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values?.isRegularFile == true, url.pathExtension == "jsonl" { count += 1 }
        }
        return count
    }

    private func buildManifest(source: URL, mode: ImportMode) throws -> [ManifestEntry] {
        var result: [ManifestEntry] = []
        var count = 0
        let topLevel = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [])
        for url in topLevel.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let relative = url.lastPathComponent
            let category = classify(relative)
            let categorySelected = category == .credential || (mode == .full && [.setting, .transcript, .database].contains(category))
            if categorySelected {
                try appendManifest(url: url, relative: relative, source: source, category: category, count: &count, result: &result)
            } else {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                let disposition = values.isSymbolicLink == true && [.transcript, .historyIndex].contains(category)
                    ? "history symbolic links are not imported"
                    : category == .historyIndex
                        ? "Codex rebuilds this local projection from shared transcripts"
                        : "excluded top-level \(category.rawValue) data; descendants were not inspected"
                result.append(.init(relativePath: relative, category: category, byteCount: Int64(values.fileSize ?? 0), selected: false, disposition: disposition))
            }
        }
        if !result.contains(where: { $0.relativePath == "auth.json" }) { throw AIManagerError.invalidSource("auth.json is missing") }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private func appendManifest(url: URL, relative: String, source: URL, category: DataCategory, count: inout Int, result: inout [ManifestEntry]) throws {
        count += 1
        guard count <= 500_000 else { throw AIManagerError.invalidSource("Selected data exceeds the 500,000-entry inspection limit.") }
        guard CoreSupport.safeRelativePath(relative) else { throw AIManagerError.unsafePath(relative) }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        if values.isSymbolicLink == true {
            if category == .transcript {
                result.append(.init(
                    relativePath: relative, category: category,
                    byteCount: Int64(values.fileSize ?? 0), selected: false,
                    disposition: "history symbolic links are not imported"))
                return
            }
            guard let target = lexicalLinkTarget(url) else { throw AIManagerError.unsafePath("unreadable symbolic link \(relative)") }
            let external = !CoreSupport.isContained(target, by: source)
            result.append(.init(relativePath: relative, category: category, byteCount: Int64(values.fileSize ?? 0), selected: !external, disposition: external ? "external symbolic-link target requires explicit review" : "copy target content"))
            return
        }
        if values.isDirectory == true {
            let children = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [])
            if children.isEmpty { result.append(.init(relativePath: relative, category: category, byteCount: 0, selected: true, disposition: "import empty directory")) }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try appendManifest(url: child, relative: "\(relative)/\(child.lastPathComponent)", source: source, category: category, count: &count, result: &result)
            }
            return
        }
        guard values.isRegularFile == true else { throw AIManagerError.unsafePath("special file \(relative)") }
        let isSQLiteSidecar = category == .database && (relative.hasSuffix("-wal") || relative.hasSuffix("-shm"))
        result.append(.init(relativePath: relative, category: category, byteCount: Int64(values.fileSize ?? 0), selected: !isSQLiteSidecar, disposition: isSQLiteSidecar ? "included by the SQLite snapshot" : "import"))
    }

    private func classify(_ relativePath: String) -> DataCategory {
        let first = relativePath.split(separator: "/").first.map(String.init) ?? relativePath
        if first == "auth.json" { return .credential }
        if CoreSupport.settings.contains(first) { return .setting }
        if CoreSupport.historyDirectories.contains(first) { return .transcript }
        if CoreSupport.historyIndexes.contains(first) { return .historyIndex }
        if first.hasPrefix("goals") || first.hasPrefix("memories") { return .durableAuxiliary }
        if first.hasPrefix("logs_") || first.hasPrefix("queue_") || ["locks", "tmp", "queue", "runtime", "shell_snapshots"].contains(first) || first.hasSuffix(".sock") || first.hasSuffix(".pid") { return .runtime }
        if first.hasPrefix("state_") && (first.hasSuffix(".sqlite") || first.contains(".sqlite-")) || first.hasPrefix("thread_history_") && first.hasSuffix(".sqlite") { return .database }
        if ["packages", "logs", "cache", "models"].contains(first) { return .installation }
        if first.hasPrefix(".orca") { return .hostOwned }
        return .unknown
    }

    private func settingConflicts(source: URL) throws -> [SettingConflict] {
        var result: [SettingConflict] = []
        for relative in CoreSupport.settings {
            let imported = source.appending(path: relative)
            let shared = paths.sharedRoot.appending(path: relative)
            if let externalTarget = try firstExternalLink(imported, sourceRoot: source) {
                result.append(.init(relativePath: relative, importedDigest: "external-link-requires-review", sharedDigest: CoreSupport.entryExists(shared) ? "existing-shared-content" : "missing", externalTarget: externalTarget))
                continue
            }
            guard CoreSupport.entryExists(imported), CoreSupport.entryExists(shared) else { continue }
            try collectSettingConflicts(imported: imported, shared: shared, relative: relative, result: &result)
        }
        return result
    }

    private func collectSettingConflicts(imported: URL, shared: URL, relative: String, result: inout [SettingConflict]) throws {
        let importedValues = try imported.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let sharedValues = try shared.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if importedValues.isDirectory == true, importedValues.isSymbolicLink != true,
           sharedValues.isDirectory == true, sharedValues.isSymbolicLink != true {
            for child in try fileManager.contentsOfDirectory(at: imported, includingPropertiesForKeys: nil, options: []).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let sharedChild = shared.appending(path: child.lastPathComponent)
                guard CoreSupport.entryExists(sharedChild) else { continue }
                try collectSettingConflicts(imported: child, shared: sharedChild, relative: "\(relative)/\(child.lastPathComponent)", result: &result)
            }
            return
        }
        let importedDigest = try treeDigest(imported)
        let sharedDigest = try treeDigest(shared)
        if importedDigest != sharedDigest {
            result.append(.init(relativePath: relative, importedDigest: importedDigest, sharedDigest: sharedDigest))
        }
    }

    private func sourceMayBeChanging(_ source: URL) throws -> Bool {
        let lockNames = [".codex.lock", "codex.lock", "app-server.lock"]
        return lockNames.contains { fileManager.fileExists(atPath: source.appending(path: $0).path) }
    }

    private func reviewedDataDigest(
        source: URL, mode: ImportMode, authDigest: String, manifest: [ManifestEntry]
    ) throws -> String {
        var hasher = SHA256()
        hasher.update(data: Data(authDigest.utf8))
        guard mode == .full else { return hasher.finalize().map { String(format: "%02x", $0) }.joined() }
        for name in CoreSupport.settings {
            let entry = source.appending(path: name)
            if CoreSupport.entryExists(entry) { try updateSourceDigest(entry, relative: name, hasher: &hasher, depth: 0) }
        }
        hasher.update(data: Data(try transcriptFingerprint(source).utf8))
        for entry in manifest where entry.category == .database {
            let sourceEntry = source.appending(path: entry.relativePath)
            guard CoreSupport.entryExists(sourceEntry) else { throw AIManagerError.sourceChanged }
            hasher.update(data: Data(entry.relativePath.utf8))
            hasher.update(data: Data(try treeDigest(sourceEntry).utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func updateSourceDigest(_ url: URL, relative: String, hasher: inout SHA256, depth: Int) throws {
        guard depth < 64 else { throw AIManagerError.unsafePath("source tree depth exceeds 64") }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        hasher.update(data: Data(relative.utf8))
        if values.isSymbolicLink == true {
            guard let target = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else { throw AIManagerError.unsafePath("broken symbolic link \(relative)") }
            hasher.update(data: Data(target.utf8))
        } else if values.isDirectory == true {
            for child in try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try updateSourceDigest(child, relative: "\(relative)/\(child.lastPathComponent)", hasher: &hasher, depth: depth + 1)
            }
        } else if values.isRegularFile == true {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while true {
                var ended = false
                try withAutoreleasePool {
                    guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { ended = true; return }
                    hasher.update(data: data)
                }
                if ended { break }
            }
        } else {
            throw AIManagerError.unsafePath("special file in reviewed settings")
        }
    }

    private func performGrokImport(
        inspection: AuthInspection,
        source: URL,
        keepExistingCredential: Bool
    ) throws -> AccountRecord {
        guard inspection.support == .supportedOAuth,
              let identity = inspection.identity, identity.isResolved else {
            throw AIManagerError.invalidSource("Grok auth.json does not contain a supported OAuth session.")
        }
        var registry = try loadRegistry()
        let matching = registry.accounts.firstIndex {
            $0.identity.providerID == .grokBuild
                && grokProvider.sameIdentity($0.identity, identity)
        }
        let accountID = matching.map { registry.accounts[$0].id } ?? UUID()
        let destination = accountsRoot.appending(path: accountID.uuidString)
            .appending(path: "home", directoryHint: .isDirectory)
        let savedCredential = credentialFile(for: accountID, providerID: .grokBuild)
        let selectedInspection: AuthInspection
        if keepExistingCredential, let matching {
            selectedInspection = grokProvider.inspect(
                credentialFile: registry.accounts[matching].credentialFile)
            try grokProvider.validateManagedCredential(registry.accounts[matching])
        } else {
            selectedInspection = inspection
        }

        let operationID = UUID()
        let backup = paths.applicationSupport.appending(
            path: "backups/\(operationID.uuidString)", directoryHint: .isDirectory)
        let staging = paths.applicationSupport.appending(
            path: "staging/\(operationID.uuidString)/home", directoryHint: .isDirectory)
        var operation = RecoveryOperation(
            id: operationID,
            kind: "import-grok",
            phase: .prepared,
            source: source,
            destination: destination,
            backup: backup,
            touchedItems: [],
            registryAccountID: accountID,
            previousDefaultAccountID: registry.defaultAccountID(for: .grokBuild),
            registryCredentialDigest: selectedInspection.digest,
            previousAccount: matching.map { registry.accounts[$0] },
            setsDefaultAccount: false
        )
        try saveOperation(operation)
        try CoreSupport.privateDirectory(backup, fileManager: fileManager)
        if CoreSupport.entryExists(destination) {
            try copyPortable(
                destination,
                to: backup.appending(path: "account-home", directoryHint: .isDirectory))
        }
        operation.phase = .backedUp
        try saveOperation(operation)

        try CoreSupport.privateDirectory(staging, fileManager: fileManager)
        try CoreSupport.atomicWrite(
            selectedInspection.data,
            to: staging.appending(path: "auth.json"),
            fileManager: fileManager)
        operation.expectedDigest = try treeDigest(staging)
        operation.previousDigest = CoreSupport.entryExists(destination)
            ? try treeDigest(destination) : nil
        operation.phase = .staged
        try saveOperation(operation)
        try CoreSupport.privateDirectory(destination.deletingLastPathComponent(), fileManager: fileManager)
        try CoreSupport.publish(staging, replacing: destination, fileManager: fileManager)
        try faultInjector(.afterHomePublication)
        operation.phase = .published
        try saveOperation(operation)

        try replaceRecoverably(
            source: destination.appending(path: "auth.json"),
            destination: savedCredential,
            operation: &operation,
            backupName: "saved-credential.json")
        let saved = grokProvider.inspect(credentialFile: savedCredential)
        guard saved.support == .supportedOAuth,
              let savedIdentity = saved.identity,
              grokProvider.sameIdentity(identity, savedIdentity),
              saved.digest == selectedInspection.digest else {
            throw AIManagerError.credentialConflict
        }
        let verification = VerificationResult(
            state: .imported,
            checkedAt: Date(),
            detail: "Grok subscription OAuth and private destination passed the offline check.")
        let account = AccountRecord(
            id: accountID,
            identity: identity,
            credentialFile: savedCredential,
            home: destination,
            source: source,
            importedAt: matching.map { registry.accounts[$0].importedAt } ?? Date(),
            verification: verification,
            credentialDigest: saved.digest)
        if let matching { registry.accounts[matching] = account }
        else { registry.accounts.append(account) }
        try saveRegistry(registry)
        try faultInjector(.afterRegistryCommit)
        operation.phase = .registryCommitted
        try saveOperation(operation)
        try finishOperation(&operation)
        return account
    }

    private func performImport(
        plan: ImportPlan,
        auth: Data,
        decisions: [String: ConflictChoice],
        setsDefaultAccount: Bool
    ) throws -> ImportResult {
        var registry = try loadRegistry()
        let matching = registry.accounts.firstIndex { provider.sameIdentity($0.identity, plan.identity) }
        let keepExistingCredential = matching != nil && registry.accounts[matching!].credentialDigest != plan.sourceAuthDigest && decisions["auth.json"] == .keepShared
        if let matching, registry.accounts[matching].credentialDigest != plan.sourceAuthDigest,
           decisions["auth.json"] != .useImported, !keepExistingCredential { throw AIManagerError.credentialConflict }
        let accountID = matching.map { registry.accounts[$0].id } ?? plan.id
        let expectedDestination = matching.map { registry.accounts[$0].home }
            ?? accountsRoot.appending(path: accountID.uuidString)
                .appending(path: "home", directoryHint: .isDirectory)
        let expectedBackup = paths.applicationSupport
            .appending(path: "backups/\(plan.operationID.uuidString)", directoryHint: .isDirectory)
        guard accountID == plan.id,
              CoreSupport.sameLocation(plan.destination, expectedDestination),
              CoreSupport.sameLocation(plan.backup, expectedBackup),
              CoreSupport.sameLocation(plan.sharedDestination, paths.sharedRoot),
              plan.credentialDestination.standardizedFileURL.path
                == credentialFile(for: accountID).standardizedFileURL.path else {
            throw AIManagerError.unsafePath("an import destination changed after review")
        }
        let destination = expectedDestination
        let staging = paths.applicationSupport.appending(
            path: "staging/\(plan.operationID.uuidString)/home", directoryHint: .isDirectory)
        var operation = RecoveryOperation(id: plan.operationID, kind: "import", phase: .prepared, source: plan.source, destination: destination, backup: plan.backup, touchedItems: [], registryAccountID: matching.map { registry.accounts[$0].id } ?? plan.id, previousDefaultAccountID: registry.defaultAccountID, registryCredentialDigest: keepExistingCredential ? registry.accounts[matching!].credentialDigest : plan.sourceAuthDigest, previousAccount: matching.map { registry.accounts[$0] }, setsDefaultAccount: setsDefaultAccount)
        try saveOperation(operation)
        try CoreSupport.privateDirectory(plan.backup, fileManager: fileManager)
        _ = try fileManager.contentsOfDirectory(atPath: plan.backup.path)

        if fileManager.fileExists(atPath: destination.path) {
            let saved = plan.backup.appending(path: "account-home", directoryHint: .isDirectory)
            try fileManager.copyItem(at: destination, to: saved)
        }
        operation.phase = .backedUp
        try saveOperation(operation)

        if fileManager.fileExists(atPath: staging.deletingLastPathComponent().path) {
            try fileManager.removeItem(at: staging.deletingLastPathComponent())
        }
        if matching != nil, fileManager.fileExists(atPath: destination.path) {
            try CoreSupport.privateDirectory(staging.deletingLastPathComponent(), fileManager: fileManager)
            try fileManager.copyItem(at: destination, to: staging)
        } else {
            try CoreSupport.privateDirectory(staging, fileManager: fileManager)
        }
        let selectedAuth = keepExistingCredential
            ? try Data(contentsOf: registry.accounts[matching!].credentialFile)
            : auth
        try CoreSupport.atomicWrite(selectedAuth, to: staging.appending(path: "auth.json"), fileManager: fileManager)

        for entry in CoreSupport.settings + CoreSupport.sharedHistoryEntries {
            let target = paths.sharedRoot.appending(path: entry)
            if !fileManager.fileExists(atPath: target.path), CoreSupport.historyDirectories.contains(entry) {
                try CoreSupport.privateDirectory(target, fileManager: fileManager)
            }
            if fileManager.fileExists(atPath: target.path) {
                let link = staging.appending(path: entry)
                if !CoreSupport.entryExists(link) { try fileManager.createSymbolicLink(at: link, withDestinationURL: target) }
            }
        }
        operation.phase = .staged
        try saveOperation(operation)

        var importedFiles = 1
        var importedChats = 0
        let reviewedExternal = plan.conflicts.filter { $0.externalTargetBytes != nil && decisions[$0.relativePath] == .useImported }.map(\.relativePath)
        var unresolved = plan.mode == .full ? plan.manifest.filter { entry in
            !entry.selected && !reviewedExternal.contains { entry.relativePath == $0 || entry.relativePath.hasPrefix($0 + "/") }
        }.map { "\($0.relativePath): \($0.disposition)" } : []
        if plan.mode == .full {
            for setting in CoreSupport.settings where CoreSupport.entryExists(plan.source.appending(path: setting)) {
                let source = plan.source.appending(path: setting)
                let destination = paths.sharedRoot.appending(path: setting)
                let externalConflict = plan.conflicts.first { $0.relativePath == setting && $0.externalTarget != nil }
                if externalConflict != nil, decisions[setting] == .keepShared {
                    if !CoreSupport.entryExists(destination) { unresolved.append("\(setting): kept shared choice, but the shared entry is missing") }
                    continue
                }
                let linkedDigest: String?
                if externalConflict != nil {
                    linkedDigest = try treeDigest(source)
                    try copyPortable(source, to: operation.backup.appending(path: "linked-source/\(setting)"))
                } else { linkedDigest = nil }
                importedFiles += try mergeSetting(
                    source: source,
                    destination: destination,
                    relative: setting,
                    rootChoice: externalConflict.flatMap { _ in decisions[setting] },
                    decisions: decisions,
                    operation: &operation
                )
                if let linkedDigest, try treeDigest(source) != linkedDigest { throw AIManagerError.sourceChanged }
                if !CoreSupport.entryExists(staging.appending(path: setting)) {
                    try fileManager.createSymbolicLink(at: staging.appending(path: setting), withDestinationURL: destination)
                }
            }
            try faultInjector(.duringHistoryCopy)
            let merge = try mergeHistory(from: plan.source, operation: &operation)
            importedChats = merge.imported
            importedFiles += merge.imported
            unresolved += merge.unresolved
            let databases = plan.manifest.filter { $0.category == .database && $0.selected && !$0.relativePath.contains("-wal") && !$0.relativePath.contains("-shm") }
            var databaseOutputs: [String: URL] = [:]
            for database in databases {
                let source = plan.source.appending(path: database.relativePath)
                let output = staging.appending(path: URL(fileURLWithPath: database.relativePath).lastPathComponent)
                do {
                    try SQLiteSupport.snapshot(source: source, destination: output)
                    try copyPortable(output, to: operation.backup.appending(path: "databases/\(database.relativePath)"))
                    databaseOutputs[database.relativePath] = output
                } catch {
                    if CoreSupport.entryExists(output) { try? fileManager.removeItem(at: output) }
                    unresolved.append("\(database.relativePath): database snapshot failed (\(error.localizedDescription))")
                }
            }
            let projectionDatabase = databaseOutputs
                .filter { $0.key.hasPrefix("thread_history_") && $0.key.hasSuffix(".sqlite") }
                .sorted { $0.key < $1.key }
                .first?.value
            for database in databases {
                guard let output = databaseOutputs[database.relativePath] else { continue }
                do {
                    let summary = try SQLiteSupport.rebaseRecognizedRolloutPaths(
                        database: output,
                        sourceHome: plan.source,
                        destinationHome: destination,
                        transcriptDestinations: merge.destinations,
                        projectionDatabase: projectionDatabase
                    )
                    if summary.excludedThreadCount > 0 {
                        unresolved.append("\(database.relativePath): excluded \(summary.excludedThreadCount) index rows without a retained transcript or complete projection")
                    }
                    if summary.unresolvedDatabaseOnlyThreadCount > 0 {
                        let backup = operation.backup.appending(path: "databases/\(database.relativePath)")
                        unresolved.append(
                            "\(database.relativePath): \(summary.unresolvedDatabaseOnlyThreadCount) database-only paginated histories "
                            + "were preserved at \(backup.path) but omitted from the active index because Codex requires rollout files"
                        )
                    }
                    importedFiles += 1
                } catch {
                    if CoreSupport.entryExists(output) { try? fileManager.removeItem(at: output) }
                    unresolved.append("\(database.relativePath): unsupported or busy database (\(error.localizedDescription))")
                }
            }
            guard try reviewedDataDigest(
                source: plan.source, mode: plan.mode, authDigest: plan.sourceAuthDigest,
                manifest: plan.manifest) == plan.reviewedDataDigest else {
                throw AIManagerError.sourceChanged
            }
        }

        operation.expectedDigest = try treeDigest(staging)
        operation.previousDigest = fileManager.fileExists(atPath: destination.path) ? try treeDigest(destination) : nil
        try saveOperation(operation)
        try CoreSupport.privateDirectory(destination.deletingLastPathComponent(), fileManager: fileManager)
        try CoreSupport.publish(staging, replacing: destination, fileManager: fileManager)
        try faultInjector(.afterHomePublication)
        operation.phase = .published
        try saveOperation(operation)

        let savedCredential = plan.credentialDestination
        try replaceRecoverably(
            source: destination.appending(path: "auth.json"),
            destination: savedCredential,
            operation: &operation,
            backupName: "saved-credential.json"
        )
        let savedInspection = provider.inspect(credentialFile: savedCredential)
        guard savedInspection.support == .supportedChatGPT,
              let savedIdentity = savedInspection.identity,
              provider.sameIdentity(plan.identity, savedIdentity),
              savedInspection.digest == (keepExistingCredential
                ? registry.accounts[matching!].credentialDigest : plan.sourceAuthDigest) else {
            throw AIManagerError.credentialConflict
        }

        let verification = VerificationResult(state: .imported, checkedAt: Date(), detail: "Credential format and private destination passed the offline check.")
        let account = AccountRecord(
            id: accountID,
            identity: plan.identity,
            credentialFile: savedCredential,
            home: destination,
            source: plan.source,
            importedAt: matching.map { registry.accounts[$0].importedAt } ?? Date(),
            verification: verification,
            credentialDigest: keepExistingCredential ? registry.accounts[matching!].credentialDigest : plan.sourceAuthDigest
        )
        if let matching { registry.accounts[matching] = account } else { registry.accounts.append(account) }
        if setsDefaultAccount {
            guard CoreSupport.sameLocation(plan.source, paths.defaultHome) else {
                throw AIManagerError.unsafePath("Only the live Codex home can be adopted as default.")
            }
            let live = provider.inspect(home: paths.defaultHome)
            guard live.support == .supportedChatGPT,
                  let liveIdentity = live.identity,
                  provider.sameIdentity(account.identity, liveIdentity),
                  live.digest == account.credentialDigest else {
                throw AIManagerError.sourceChanged
            }
            registry.defaultAccountID = accountID
        }
        try saveRegistry(registry)
        try faultInjector(.afterRegistryCommit)
        operation.phase = .registryCommitted
        try saveOperation(operation)
        try finishOperation(&operation)
        return .init(account: account, backup: plan.backup, importedFiles: importedFiles, importedChats: importedChats, unresolved: unresolved, verification: verification)
    }

    private func performSwitch(
        to accountID: UUID,
        captureOutgoingCredential: Bool = true,
        refreshOnly: Bool = false
    ) throws -> SwitchResult {
        var registry = try loadRegistry()
        guard let requested = registry.accounts.first(where: { $0.id == accountID }) else {
            throw AIManagerError.accountNotFound
        }
        try provider.validateManagedCredential(requested)

        let defaultAuth = paths.defaultHome.appending(path: "auth.json")
        let outgoingFileDigest = try credentialFingerprintIfPresent(defaultAuth)
        let outgoingInspection = provider.inspect(home: paths.defaultHome)
        if refreshOnly {
            guard registry.defaultAccountID == accountID,
                  outgoingInspection.support == .missingAuth || outgoingInspection.identity.map({
                      provider.sameIdentity(requested.identity, $0)
                  }) == true else { throw AIManagerError.credentialConflict }
        }
        var registeredOutgoingIndex: Int?
        var registeredOutgoingInspection: AuthInspection?
        if captureOutgoingCredential,
           outgoingInspection.support == .supportedChatGPT,
           let identity = outgoingInspection.identity, identity.isResolved {
            if let currentID = registry.defaultAccountID(for: .codex),
               let index = registry.accounts.firstIndex(where: {
                   $0.id == currentID && $0.identity.providerID == .codex
               }) {
                guard provider.sameIdentity(registry.accounts[index].identity, identity) else {
                    throw AIManagerError.credentialConflict
                }
                registeredOutgoingIndex = index
            } else {
                registeredOutgoingIndex = registry.accounts.firstIndex(where: { provider.sameIdentity($0.identity, identity) })
            }
            if let index = registeredOutgoingIndex {
                let saved = provider.inspect(credentialFile: registry.accounts[index].credentialFile)
                guard saved.support == .supportedChatGPT, let savedIdentity = saved.identity,
                      provider.sameIdentity(registry.accounts[index].identity, savedIdentity) else { throw AIManagerError.credentialConflict }
                let baseline = registry.accounts[index].credentialDigest
                let savedChanged = saved.digest != baseline
                if savedChanged, outgoingInspection.digest != saved.digest {
                    throw AIManagerError.credentialConflict
                }
                registeredOutgoingInspection = saved
            }
        }
        let id = UUID()
        let backup = paths.applicationSupport.appending(path: "backups/\(id.uuidString)", directoryHint: .isDirectory)
        let originallySelected = requested
        var operation = RecoveryOperation(id: id, kind: "switch", phase: .prepared, source: originallySelected.credentialFile, destination: defaultAuth, backup: backup, touchedItems: [], previousDigest: outgoingFileDigest, registryAccountID: accountID, previousDefaultAccountID: registry.defaultAccountID ?? registeredOutgoingIndex.map { registry.accounts[$0].id })
        try saveOperation(operation)
        try CoreSupport.privateDirectory(backup, fileManager: fileManager)
        if fileManager.fileExists(atPath: defaultAuth.path) {
            let saved = backup.appending(path: "auth.json")
            try copyPortable(defaultAuth, to: saved)
        }
        operation.phase = .backedUp
        try saveOperation(operation)
        if let outgoingIndex = registeredOutgoingIndex, let saved = registeredOutgoingInspection {
            let baseline = registry.accounts[outgoingIndex].credentialDigest
            let defaultChanged = outgoingInspection.digest != baseline
            let savedChanged = saved.digest != baseline
            if defaultChanged, !savedChanged {
                operation.previousAccount = registry.accounts[outgoingIndex]
                try replaceRecoverably(source: defaultAuth, destination: registry.accounts[outgoingIndex].credentialFile, operation: &operation, backupName: "outgoing-saved-auth.json")
                registry.accounts[outgoingIndex].credentialDigest = outgoingInspection.digest
            } else if savedChanged {
                registry.accounts[outgoingIndex].credentialDigest = saved.digest
            }
            registry.defaultAccountID = registry.accounts[outgoingIndex].id
            try saveOperation(operation)
        } else if captureOutgoingCredential,
                  outgoingInspection.support == .supportedChatGPT,
                  let identity = outgoingInspection.identity, identity.isResolved {
                let outgoingID = UUID()
                let outgoingHome = paths.applicationSupport.appending(path: "accounts/\(outgoingID.uuidString)/home")
                try createManagedHome(auth: outgoingInspection.data, at: outgoingHome)
                let outgoingCredential = credentialFile(for: outgoingID)
                try replaceRecoverably(source: defaultAuth, destination: outgoingCredential, operation: &operation, backupName: "captured-outgoing-auth.json")
                registry.accounts.append(.init(id: outgoingID, identity: identity, credentialFile: outgoingCredential, home: outgoingHome, source: paths.defaultHome, importedAt: Date(), verification: .init(state: .imported, checkedAt: Date(), detail: "Captured before changing the default account."), credentialDigest: outgoingInspection.digest))
                registry.defaultAccountID = outgoingID
                operation.previousDefaultAccountID = outgoingID
            try saveOperation(operation)
        }

        guard let incomingIndex = registry.accounts.firstIndex(where: { $0.id == accountID }) else { throw AIManagerError.accountNotFound }
        let incoming = registry.accounts[incomingIndex]
        let incomingInspection = provider.inspect(credentialFile: incoming.credentialFile)
        guard incomingInspection.support == .supportedChatGPT, let incomingIdentity = incomingInspection.identity,
              provider.sameIdentity(incoming.identity, incomingIdentity) else { throw AIManagerError.credentialConflict }
        if registry.defaultAccountID == accountID, outgoingInspection.digest == incomingInspection.digest {
            try saveRegistry(registry)
            try finishOperation(&operation)
            return .init(accountID: accountID, backup: backup, previousAccountID: accountID)
        }
        guard try credentialFingerprintIfPresent(defaultAuth) == outgoingFileDigest else {
            throw AIManagerError.sourceChanged
        }
        operation.expectedDigest = incomingInspection.digest
        try saveOperation(operation)
        try CoreSupport.atomicWrite(incomingInspection.data, to: defaultAuth, fileManager: fileManager)
        try faultInjector(.afterDefaultCredentialPublication)
        operation.phase = .published
        try saveOperation(operation)
        guard provider.inspect(home: paths.defaultHome).digest == incomingInspection.digest else {
            throw AIManagerError.operationFailed("The committed default credential did not verify.")
        }
        let previous = registry.defaultAccountID
        registry.defaultAccountID = accountID
        registry.accounts[incomingIndex].lastUsedAt = Date()
        try saveRegistry(registry)
        try faultInjector(.afterRegistryCommit)
        operation.phase = .registryCommitted
        try saveOperation(operation)
        try finishOperation(&operation)
        return .init(accountID: accountID, backup: backup, previousAccountID: previous)
    }

    private func performGrokSwitch(
        to accountID: UUID,
        captureOutgoingCredential: Bool = true,
        refreshOnly: Bool = false
    ) throws -> SwitchResult {
        var registry = try loadRegistry()
        guard let requested = registry.accounts.first(where: { $0.id == accountID }) else {
            throw AIManagerError.accountNotFound
        }
        try grokProvider.validateManagedCredential(requested)

        let liveAuth = paths.grokHome.appending(path: "auth.json")
        let outgoingFileDigest = try credentialFingerprintIfPresent(liveAuth)
        let outgoingInspection = grokProvider.inspect(home: paths.grokHome)
        if refreshOnly {
            guard registry.defaultAccountID(for: .grokBuild) == accountID,
                  outgoingInspection.support == .missingAuth || outgoingInspection.identity.map({
                      grokProvider.sameIdentity(requested.identity, $0)
                  }) == true else { throw AIManagerError.credentialConflict }
        }
        var registeredOutgoingIndex: Int?
        var registeredOutgoingInspection: AuthInspection?
        if captureOutgoingCredential,
           outgoingInspection.support == .supportedOAuth,
           let identity = outgoingInspection.identity, identity.isResolved {
            if let currentID = registry.defaultAccountID(for: .grokBuild),
               let index = registry.accounts.firstIndex(where: {
                   $0.id == currentID && $0.identity.providerID == .grokBuild
               }) {
                guard grokProvider.sameIdentity(registry.accounts[index].identity, identity) else {
                    throw AIManagerError.credentialConflict
                }
                registeredOutgoingIndex = index
            } else {
                registeredOutgoingIndex = registry.accounts.firstIndex {
                    $0.identity.providerID == .grokBuild
                        && grokProvider.sameIdentity($0.identity, identity)
                }
            }
            if let index = registeredOutgoingIndex {
                let saved = grokProvider.inspect(
                    credentialFile: registry.accounts[index].credentialFile)
                guard saved.support == .supportedOAuth,
                      let savedIdentity = saved.identity,
                      grokProvider.sameIdentity(registry.accounts[index].identity, savedIdentity) else {
                    throw AIManagerError.credentialConflict
                }
                let baseline = registry.accounts[index].credentialDigest
                if saved.digest != baseline, outgoingInspection.digest != saved.digest {
                    throw AIManagerError.credentialConflict
                }
                registeredOutgoingInspection = saved
            }
        }

        let operationID = UUID()
        let backup = paths.applicationSupport.appending(
            path: "backups/\(operationID.uuidString)", directoryHint: .isDirectory)
        let previousDefault = registry.defaultAccountID(for: .grokBuild)
        var operation = RecoveryOperation(
            id: operationID,
            kind: "switch-grok",
            phase: .prepared,
            source: requested.credentialFile,
            destination: liveAuth,
            backup: backup,
            touchedItems: [],
            previousDigest: outgoingFileDigest,
            registryAccountID: accountID,
            previousDefaultAccountID: previousDefault)
        try saveOperation(operation)
        try CoreSupport.privateDirectory(backup, fileManager: fileManager)
        if CoreSupport.entryExists(liveAuth) {
            try copyPortable(liveAuth, to: backup.appending(path: "auth.json"))
        }
        operation.phase = .backedUp
        try saveOperation(operation)

        if let outgoingIndex = registeredOutgoingIndex,
           let saved = registeredOutgoingInspection {
            let baseline = registry.accounts[outgoingIndex].credentialDigest
            let liveChanged = outgoingInspection.digest != baseline
            let savedChanged = saved.digest != baseline
            if liveChanged, !savedChanged {
                operation.previousAccount = registry.accounts[outgoingIndex]
                try replaceRecoverably(
                    source: liveAuth,
                    destination: registry.accounts[outgoingIndex].credentialFile,
                    operation: &operation,
                    backupName: "outgoing-saved-auth.json")
                registry.accounts[outgoingIndex].credentialDigest = outgoingInspection.digest
            } else if savedChanged {
                registry.accounts[outgoingIndex].credentialDigest = saved.digest
            }
            try saveOperation(operation)
            try saveRegistry(registry)
        } else if captureOutgoingCredential,
                  outgoingInspection.support == .supportedOAuth,
                  let identity = outgoingInspection.identity, identity.isResolved {
            let outgoingID = UUID()
            let outgoingHome = accountsRoot.appending(path: outgoingID.uuidString)
                .appending(path: "home", directoryHint: .isDirectory)
            try createManagedGrokHome(auth: outgoingInspection.data, at: outgoingHome)
            let outgoingCredential = credentialFile(for: outgoingID, providerID: .grokBuild)
            try replaceRecoverably(
                source: liveAuth,
                destination: outgoingCredential,
                operation: &operation,
                backupName: "captured-outgoing-auth.json")
            registry.accounts.append(.init(
                id: outgoingID,
                identity: identity,
                credentialFile: outgoingCredential,
                home: outgoingHome,
                source: paths.grokHome,
                importedAt: Date(),
                verification: .init(
                    state: .imported,
                    checkedAt: Date(),
                    detail: "Captured before changing the selected Grok account."),
                credentialDigest: outgoingInspection.digest))
            try saveRegistry(registry)
        }

        guard let incomingIndex = registry.accounts.firstIndex(where: { $0.id == accountID }) else {
            throw AIManagerError.accountNotFound
        }
        let incoming = registry.accounts[incomingIndex]
        let incomingInspection = grokProvider.inspect(credentialFile: incoming.credentialFile)
        guard incomingInspection.support == .supportedOAuth,
              let incomingIdentity = incomingInspection.identity,
              grokProvider.sameIdentity(incoming.identity, incomingIdentity) else {
            throw AIManagerError.credentialConflict
        }
        if registry.defaultAccountID(for: .grokBuild) == accountID,
           outgoingInspection.digest == incomingInspection.digest {
            try finishOperation(&operation)
            return .init(
                accountID: accountID,
                backup: backup,
                previousAccountID: accountID)
        }
        guard try credentialFingerprintIfPresent(liveAuth) == outgoingFileDigest else {
            throw AIManagerError.sourceChanged
        }
        operation.expectedDigest = incomingInspection.digest
        try saveOperation(operation)
        try CoreSupport.atomicWrite(incomingInspection.data, to: liveAuth, fileManager: fileManager)
        try faultInjector(.afterDefaultCredentialPublication)
        operation.phase = .published
        try saveOperation(operation)
        guard grokProvider.inspect(home: paths.grokHome).digest == incomingInspection.digest else {
            throw AIManagerError.operationFailed("The committed Grok credential did not verify.")
        }
        registry.setDefaultAccountID(accountID, for: .grokBuild)
        registry.accounts[incomingIndex].lastUsedAt = Date()
        try saveRegistry(registry)
        try faultInjector(.afterRegistryCommit)
        operation.phase = .registryCommitted
        try saveOperation(operation)
        try finishOperation(&operation)
        return .init(
            accountID: accountID,
            backup: backup,
            previousAccountID: previousDefault)
    }

    private var usageReadsURL: URL {
        paths.applicationSupport.appending(path: "usage-reads", directoryHint: .isDirectory)
    }

    private func prepareUsageRead(accountID: UUID) throws -> UsageReadLease {
        try ensureNoRecovery()
        let registry = try loadRegistry()
        guard let account = registry.accounts.first(where: { $0.id == accountID }) else {
            throw AIManagerError.accountNotFound
        }
        try provider.requireSupported(account.identity.providerID)
        guard account.identity.isResolved else { throw AIManagerError.unresolvedIdentity }
        try provider.validateManagedCredential(account)

        let authData: Data
        let sourceCredentialDigest: String
        let usesLiveCredential: Bool
        if registry.defaultAccountID == accountID {
            let liveAuth = paths.defaultHome.appending(path: "auth.json")
            try provider.validatePrivateCredentialFile(liveAuth)
            let live = provider.inspect(home: paths.defaultHome)
            guard live.support == .supportedChatGPT,
                  let liveIdentity = live.identity,
                  provider.sameIdentity(account.identity, liveIdentity) else {
                throw AIManagerError.credentialConflict
            }
            authData = live.data
            sourceCredentialDigest = live.digest
            usesLiveCredential = true
        } else {
            let saved = provider.inspect(credentialFile: account.credentialFile)
            authData = saved.data
            sourceCredentialDigest = saved.digest
            usesLiveCredential = false
        }
        guard let executable = resolveExecutable() else { throw AIManagerError.cliNotFound }

        let root = usageReadsURL.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        guard CoreSupport.isContained(root, by: usageReadsURL) else {
            throw AIManagerError.unsafePath("usage read escaped its private root")
        }
        do {
            try CoreSupport.privateDirectory(usageReadsURL, fileManager: fileManager)
            try CoreSupport.privateDirectory(root, fileManager: fileManager)
            try CoreSupport.privateDirectory(home, fileManager: fileManager)
            let auth = home.appending(path: "auth.json")
            try CoreSupport.atomicWrite(authData, to: auth, fileManager: fileManager)
            try provider.validatePrivateCredentialFile(auth)
            return .init(
                accountID: accountID,
                defaultAccountID: registry.defaultAccountID,
                identity: account.identity,
                credentialDigest: account.credentialDigest,
                sourceCredentialDigest: sourceCredentialDigest,
                usesLiveCredential: usesLiveCredential,
                root: root,
                source: .init(codexHome: home, authFile: auth),
                executable: executable
            )
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    private func validateUsageRead(_ lease: UsageReadLease) throws {
        try ensureNoRecovery()
        let registry = try loadRegistry()
        guard registry.defaultAccountID == lease.defaultAccountID,
              let account = registry.accounts.first(where: { $0.id == lease.accountID }),
              account.identity == lease.identity,
              account.credentialDigest == lease.credentialDigest else {
            throw AIManagerError.sourceChanged
        }

        guard CoreSupport.isContained(lease.root, by: usageReadsURL) else {
            throw AIManagerError.sourceChanged
        }
        do {
            try provider.validatePrivateCredentialFile(lease.source.authFile)
        } catch {
            throw AIManagerError.sourceChanged
        }
        let isolated = provider.inspect(home: lease.source.codexHome)
        guard isolated.support == .supportedChatGPT,
              let isolatedIdentity = isolated.identity,
              provider.sameIdentity(lease.identity, isolatedIdentity) else {
            throw AIManagerError.sourceChanged
        }

        do {
            try provider.validatePrivateCredentialFile(account.credentialFile)
        } catch {
            throw AIManagerError.sourceChanged
        }
        let saved = provider.inspect(credentialFile: account.credentialFile)
        guard saved.support == .supportedChatGPT,
              let savedIdentity = saved.identity,
              provider.sameIdentity(lease.identity, savedIdentity),
              saved.digest == lease.credentialDigest else {
            throw AIManagerError.sourceChanged
        }
        if lease.usesLiveCredential {
            let liveAuth = paths.defaultHome.appending(path: "auth.json")
            do {
                try provider.validatePrivateCredentialFile(liveAuth)
            } catch {
                throw AIManagerError.sourceChanged
            }
            let live = provider.inspect(home: paths.defaultHome)
            guard live.support == .supportedChatGPT,
                  let liveIdentity = live.identity,
                  provider.sameIdentity(lease.identity, liveIdentity),
                  live.digest == lease.sourceCredentialDigest else {
                throw AIManagerError.sourceChanged
            }
        }
    }

    private func removeUsageRead(_ lease: UsageReadLease) {
        guard CoreSupport.isContained(lease.root, by: usageReadsURL) else { return }
        try? fileManager.removeItem(at: lease.root)
    }

    private func credentialFingerprintIfPresent(_ credential: URL) throws -> String? {
        guard CoreSupport.entryExists(credential) else { return nil }
        try provider.validatePrivateCredentialFile(
            credential,
            requireOwnerOnlyPermissions: false
        )
        return try CoreSupport.digest(file: credential)
    }

    private func createManagedHome(auth: Data, at home: URL) throws {
        try CoreSupport.privateDirectory(home, fileManager: fileManager)
        try CoreSupport.atomicWrite(auth, to: home.appending(path: "auth.json"), fileManager: fileManager)
        for entry in CoreSupport.settings + CoreSupport.sharedHistoryEntries {
            let target = paths.sharedRoot.appending(path: entry)
            guard fileManager.fileExists(atPath: target.path) else { continue }
            try fileManager.createSymbolicLink(at: home.appending(path: entry), withDestinationURL: target)
        }
    }

    private func createManagedGrokHome(auth: Data, at home: URL) throws {
        try CoreSupport.privateDirectory(home, fileManager: fileManager)
        try CoreSupport.atomicWrite(
            auth, to: home.appending(path: "auth.json"), fileManager: fileManager)
    }

    private func resolveExecutable() -> URL? {
        if let explicit = paths.codexExecutable,
           let executable = validatedExecutable(explicit) {
            return executable
        }
        if paths.isolationRoot != nil { return nil }
        var candidates: [URL] = []
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(
                URL(fileURLWithPath: String(directory)).appending(path: "codex"))
        }
        let userHome = fileManager.homeDirectoryForCurrentUser
        candidates += [
            userHome.appending(path: ".local/bin/codex"),
            userHome.appending(path: ".codex/packages/standalone/current/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            userHome.appending(path: "Applications/ChatGPT.app/Contents/Resources/codex"),
        ]
        var seen = Set<String>()
        for candidate in candidates {
            let canonical = CoreSupport.canonical(candidate)
            guard seen.insert(canonical.path).inserted else { continue }
            if let executable = validatedExecutable(candidate) { return executable }
        }
        return nil
    }

    private func resolveGrokExecutable() -> URL? {
        if let explicit = paths.grokExecutable,
           let executable = validatedExecutable(explicit) {
            return executable
        }
        if paths.isolationRoot != nil { return nil }
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appending(path: "grok") }
        let userHome = fileManager.homeDirectoryForCurrentUser
        candidates += [
            userHome.appending(path: ".local/bin/grok"),
            userHome.appending(path: ".grok/bin/grok"),
            URL(fileURLWithPath: "/opt/homebrew/bin/grok"),
            URL(fileURLWithPath: "/usr/local/bin/grok"),
        ]
        var seen = Set<String>()
        for candidate in candidates {
            let canonical = CoreSupport.canonical(candidate)
            guard seen.insert(canonical.path).inserted else { continue }
            if let executable = validatedExecutable(candidate) { return executable }
        }
        return nil
    }

    private func validatedExecutable(_ candidate: URL) -> URL? {
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard let values = try? resolved.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              fileManager.isExecutableFile(atPath: resolved.path) else {
            return nil
        }
        return resolved
    }

    private func lexicalLinkTarget(_ link: URL) -> URL? {
        guard let raw = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else { return nil }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw).standardizedFileURL }
        return link.deletingLastPathComponent().appending(path: raw).standardizedFileURL
    }

    private func link(_ link: URL, pointsTo intendedTarget: URL) -> Bool {
        guard let target = lexicalLinkTarget(link) else { return false }
        return CoreSupport.canonical(target).pathComponents == CoreSupport.canonical(intendedTarget).pathComponents
    }

    private func inspectLinkedSettings(accounts: [AccountRecord]) throws -> [LinkedSettingsDivergence] {
        var result: [LinkedSettingsDivergence] = []
        let backupRoot = paths.applicationSupport.appending(path: "backups/settings-link-repair", directoryHint: .isDirectory)
        for account in accounts {
            for relativePath in CoreSupport.settings {
                let intendedTarget = paths.sharedRoot.appending(path: relativePath).standardizedFileURL
                guard CoreSupport.entryExists(intendedTarget) else { continue }
                let localPath = account.home.appending(path: relativePath)
                if link(localPath, pointsTo: intendedTarget) { continue }
                result.append(.init(
                    accountID: account.id,
                    relativePath: relativePath,
                    localPath: localPath,
                    intendedTarget: intendedTarget,
                    localFingerprint: try linkedSettingFingerprint(localPath),
                    backupRoot: backupRoot
                ))
            }
        }
        return result
    }

    private func linkedSettingFingerprint(_ url: URL) throws -> String {
        var hasher = SHA256()
        guard CoreSupport.entryExists(url) else {
            hasher.update(data: Data("missing".utf8))
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            guard let raw = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
                throw AIManagerError.unsafePath("unreadable settings link \(url.lastPathComponent)")
            }
            hasher.update(data: Data("link:\(raw)".utf8))
        } else {
            try updateSourceDigest(url, relative: url.lastPathComponent, hasher: &hasher, depth: 0)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func containsExternalLink(_ root: URL, sourceRoot: URL) throws -> Bool {
        try firstExternalLink(root, sourceRoot: sourceRoot) != nil
    }

    private func firstExternalLink(_ root: URL, sourceRoot: URL) throws -> URL? {
        guard CoreSupport.entryExists(root) else { return nil }
        let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        if rootValues.isSymbolicLink == true {
            guard let target = lexicalLinkTarget(root) else { throw AIManagerError.unsafePath("broken symbolic link") }
            return CoreSupport.isContained(target, by: sourceRoot) ? nil : target
        }
        guard rootValues.isDirectory == true,
              let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return nil }
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            count += 1
            guard count <= 500_000 else { throw AIManagerError.invalidSource("A settings tree exceeds the inspection limit.") }
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                enumerator.skipDescendants()
                guard let target = lexicalLinkTarget(url) else { throw AIManagerError.unsafePath("broken symbolic link") }
                if !CoreSupport.isContained(target, by: sourceRoot) { return target }
            }
        }
        return nil
    }

    private func treeDigest(_ root: URL) throws -> String {
        var hasher = SHA256()
        var visited = Set<String>()
        try updateDigest(root, relative: "", hasher: &hasher, visited: &visited, depth: 0)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func updateDigest(_ url: URL, relative: String, hasher: inout SHA256, visited: inout Set<String>, depth: Int) throws {
        guard depth < 64 else { throw AIManagerError.unsafePath("symbolic-link depth exceeds 64") }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        if values.isSymbolicLink == true {
            guard let target = lexicalLinkTarget(url) else { throw AIManagerError.unsafePath("broken symbolic link") }
            let key = CoreSupport.canonical(target).path
            guard visited.insert(key).inserted else { throw AIManagerError.unsafePath("symbolic-link cycle") }
            try updateDigest(target, relative: relative, hasher: &hasher, visited: &visited, depth: depth + 1)
            visited.remove(key)
            return
        }
        hasher.update(data: Data(relative.utf8))
        if values.isDirectory == true {
            let children = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                let childRelative = relative.isEmpty ? child.lastPathComponent : "\(relative)/\(child.lastPathComponent)"
                try updateDigest(child, relative: childRelative, hasher: &hasher, visited: &visited, depth: depth + 1)
            }
        } else if values.isRegularFile == true {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while true {
                var ended = false
                try withAutoreleasePool {
                    guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { ended = true; return }
                    hasher.update(data: data)
                }
                if ended { break }
            }
        } else {
            throw AIManagerError.unsafePath("special file in selected data")
        }
    }

    private func copyPortable(_ source: URL, to destination: URL, visited: Set<String> = [], depth: Int = 0) throws {
        guard depth < 64 else { throw AIManagerError.unsafePath("symbolic-link depth exceeds 64") }
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        if values.isSymbolicLink == true {
            guard let target = lexicalLinkTarget(source) else { throw AIManagerError.unsafePath("broken symbolic link") }
            let key = CoreSupport.canonical(target).path
            guard !visited.contains(key) else { throw AIManagerError.unsafePath("symbolic-link cycle") }
            var next = visited
            next.insert(key)
            try copyPortable(target, to: destination, visited: next, depth: depth + 1)
        } else if values.isDirectory == true {
            try CoreSupport.privateDirectory(destination, fileManager: fileManager)
            for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: []) {
                try copyPortable(child, to: destination.appending(path: child.lastPathComponent), visited: visited, depth: depth + 1)
            }
        } else if values.isRegularFile == true {
            try CoreSupport.privateDirectory(destination.deletingLastPathComponent(), fileManager: fileManager)
            try fileManager.copyItem(at: source, to: destination)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } else {
            throw AIManagerError.unsafePath("special file cannot be copied")
        }
    }

    private func portableLogicalSize(_ root: URL) throws -> Int64 {
        var count = 0
        var visited = Set<String>()
        return try portableLogicalSize(root, count: &count, visited: &visited, depth: 0)
    }

    private func portableLogicalSize(_ url: URL, count: inout Int, visited: inout Set<String>, depth: Int) throws -> Int64 {
        guard depth < 64 else { throw AIManagerError.unsafePath("symbolic-link depth exceeds 64") }
        count += 1
        guard count <= 500_000 else { throw AIManagerError.invalidSource("Linked data exceeds the 500,000-entry review limit.") }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
        if values.isSymbolicLink == true {
            guard let target = lexicalLinkTarget(url) else { throw AIManagerError.unsafePath("broken symbolic link") }
            let key = CoreSupport.canonical(target).path
            guard visited.insert(key).inserted else { throw AIManagerError.unsafePath("symbolic-link cycle") }
            defer { visited.remove(key) }
            return try portableLogicalSize(target, count: &count, visited: &visited, depth: depth + 1)
        }
        if values.isDirectory == true {
            return try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []).reduce(Int64(0)) { total, child in
                let size = try portableLogicalSize(child, count: &count, visited: &visited, depth: depth + 1)
                let (sum, overflow) = total.addingReportingOverflow(size)
                guard !overflow else { throw AIManagerError.invalidSource("Linked data size overflowed.") }
                return sum
            }
        }
        guard values.isRegularFile == true else { throw AIManagerError.unsafePath("special file in linked data") }
        return Int64(values.fileSize ?? 0)
    }

    private func replaceRecoverably(source: URL, destination: URL, operation: inout RecoveryOperation, backupName: String) throws {
        let backup = operation.backup.appending(path: backupName)
        let hadDestination = CoreSupport.entryExists(destination)
        if hadDestination {
            try CoreSupport.privateDirectory(backup.deletingLastPathComponent(), fileManager: fileManager)
            try copyPortable(destination, to: backup)
        }
        let temporary = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).\(operation.id.uuidString).stage")
        if fileManager.fileExists(atPath: temporary.path) { try fileManager.removeItem(at: temporary) }
        let previous = hadDestination ? try treeDigest(destination) : nil
        if operation.touchedItems == nil { operation.touchedItems = [] }
        operation.touchedItems!.append(.init(destination: destination, backup: hadDestination ? backup : nil, expectedDigest: "", previousDigest: previous, temporary: temporary))
        try saveOperation(operation)
        try copyPortable(source, to: temporary)
        try faultInjector(.afterTemporaryCopy)
        let expected = try treeDigest(temporary)
        operation.touchedItems![operation.touchedItems!.count - 1].expectedDigest = expected
        try saveOperation(operation)
        try CoreSupport.privateDirectory(destination.deletingLastPathComponent(), fileManager: fileManager)
        try CoreSupport.publish(temporary, replacing: destination, fileManager: fileManager)
    }

    private func mergeSetting(
        source: URL,
        destination: URL,
        relative: String,
        rootChoice: ConflictChoice?,
        decisions: [String: ConflictChoice],
        operation: inout RecoveryOperation
    ) throws -> Int {
        guard CoreSupport.entryExists(destination) else {
            try replaceRecoverably(source: source, destination: destination, operation: &operation, backupName: "shared-created/\(relative)")
            return 1
        }
        let sourceValues = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let destinationValues = try destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if sourceValues.isDirectory == true, sourceValues.isSymbolicLink != true,
           destinationValues.isDirectory == true, destinationValues.isSymbolicLink != true {
            var imported = 0
            for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: []).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                imported += try mergeSetting(
                    source: child,
                    destination: destination.appending(path: child.lastPathComponent),
                    relative: "\(relative)/\(child.lastPathComponent)",
                    rootChoice: rootChoice,
                    decisions: decisions,
                    operation: &operation
                )
            }
            return imported
        }
        guard try treeDigest(source) != treeDigest(destination) else { return 0 }
        switch decisions[relative] ?? rootChoice {
        case .keepShared: return 0
        case .useImported:
            try replaceRecoverably(source: source, destination: destination, operation: &operation, backupName: "shared/\(relative)")
            return 1
        case nil:
            throw AIManagerError.missingConflictDecisions([relative])
        }
    }

    private func transcriptFingerprint(_ source: URL) throws -> String {
        var hasher = SHA256()
        var visited = 0
        for name in CoreSupport.historyDirectories {
            let root = source.appending(path: name)
            guard fileManager.fileExists(atPath: root.path) else { continue }
            if try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { continue }
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { continue }
            while let url = enumerator.nextObject() as? URL {
                visited += 1
                guard visited <= 500_000 else {
                    throw AIManagerError.invalidSource("History exceeds the 500,000-entry inspection limit.")
                }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard values.isRegularFile == true else { continue }
                hasher.update(data: Data(url.path.dropFirst(source.path.count).utf8))
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while true {
                    var ended = false
                    try withAutoreleasePool {
                        guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { ended = true; return }
                        hasher.update(data: data)
                    }
                    if ended { break }
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct TranscriptInfo {
        var url: URL
        var identity: String
        var recordCount: Int
        var contentDigest: String
        var archived: Bool
    }

    private func transcriptInfo(_ url: URL, archived: Bool) throws -> TranscriptInfo {
        let reader = try JSONLReader(url: url)
        var hasher = SHA256()
        var count = 0
        var identity: String?
        while true {
            var ended = false
            try withAutoreleasePool {
                guard let record = try reader.next() else { ended = true; return }
                guard let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any] else {
                    throw AIManagerError.invalidSource("malformed JSONL record")
                }
                if object["type"] as? String == "session_meta" {
                    guard let payload = object["payload"] as? [String: Any],
                          let id = payload["id"] as? String, !id.isEmpty else {
                        throw AIManagerError.invalidSource("session_meta.payload.id is missing")
                    }
                    guard identity == nil || identity == id else {
                        throw AIManagerError.invalidSource("conflicting session_meta.payload.id values")
                    }
                    identity = id
                }
                hasher.update(data: record)
                hasher.update(data: Data([0x0A]))
                count += 1
            }
            if ended { break }
        }
        guard count > 0, let identity else {
            throw AIManagerError.invalidSource("session_meta.payload.id is missing")
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return .init(url: url, identity: identity, recordCount: count, contentDigest: digest, archived: archived)
    }

    private func transcriptFiles(_ root: URL, archived: Bool) throws -> (files: [TranscriptInfo], unresolved: [String]) {
        guard fileManager.fileExists(atPath: root.path) else { return ([], []) }
        if try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            return ([], ["symbolic link was not scanned"])
        }
        guard
              let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return ([], []) }
        var result: [TranscriptInfo] = []
        var unresolved: [String] = []
        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            guard visited <= 500_000 else {
                throw AIManagerError.invalidSource("History exceeds the 500,000-entry inspection limit.")
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, url.pathExtension == "jsonl" else { continue }
            do {
                result.append(try transcriptInfo(url, archived: archived))
            } catch {
                let base = root.standardizedFileURL.pathComponents
                let relative = url.standardizedFileURL.pathComponents.dropFirst(base.count).joined(separator: "/")
                unresolved.append("\(relative): \(error.localizedDescription)")
            }
        }
        return (result, unresolved)
    }

    private func mergeHistory(from sourceHome: URL, operation: inout RecoveryOperation) throws -> (imported: Int, unresolved: [String], destinations: [String: String]) {
        var existing: [String: TranscriptInfo] = [:]
        var duplicateShared = Set<String>()
        var unresolved: [String] = []
        for (name, archived) in [("sessions", false), ("archived_sessions", true)] {
            let scan = try transcriptFiles(paths.sharedRoot.appending(path: name), archived: archived)
            unresolved += scan.unresolved.map { "shared \(name)/\($0)" }
            for info in scan.files {
                if duplicateShared.contains(info.identity) {
                    unresolved.append("duplicate shared transcript ID \(info.identity): \(info.url.lastPathComponent)")
                } else if let first = existing.removeValue(forKey: info.identity) {
                    duplicateShared.insert(info.identity)
                    unresolved.append(
                        "duplicate shared transcript ID \(info.identity): \(first.url.lastPathComponent), \(info.url.lastPathComponent)")
                } else {
                    existing[info.identity] = info
                }
            }
        }
        var imported = 0
        for (name, archived) in [("sessions", false), ("archived_sessions", true)] {
            let sourceRoot = sourceHome.appending(path: name)
            let scan = try transcriptFiles(sourceRoot, archived: archived)
            unresolved += scan.unresolved.map { "\(name)/\($0)" }
            for incoming in scan.files {
                if duplicateShared.contains(incoming.identity) {
                    unresolved.append("\(incoming.identity): skipped because the shared transcript ID is duplicated")
                    continue
                }
                if try file(incoming.url, contains: Data(sourceHome.path.utf8)) {
                    unresolved.append("\(incoming.identity): transcript retains a source path needed for resume context")
                }
                if let current = existing[incoming.identity] {
                    if current.archived != incoming.archived {
                        try preserveConflict(incoming.url, identity: incoming.identity, operation: operation)
                        unresolved.append("\(incoming.identity): active/archive classification conflict")
                    } else if current.recordCount == incoming.recordCount, current.contentDigest == incoming.contentDigest {
                        continue
                    } else if incoming.recordCount > current.recordCount, try transcript(current.url, isPrefixOf: incoming.url, recordCount: current.recordCount) {
                        try replaceRecoverably(source: incoming.url, destination: current.url, operation: &operation, backupName: "history/\(incoming.identity).jsonl")
                        existing[incoming.identity] = .init(url: current.url, identity: incoming.identity, recordCount: incoming.recordCount, contentDigest: incoming.contentDigest, archived: incoming.archived)
                        imported += 1
                    } else if current.recordCount > incoming.recordCount, try transcript(incoming.url, isPrefixOf: current.url, recordCount: incoming.recordCount) {
                        continue
                    } else {
                        try preserveConflict(incoming.url, identity: incoming.identity, operation: operation)
                        unresolved.append("\(incoming.identity): divergent transcript preserved in backup")
                    }
                } else {
                    let sourceComponents = sourceRoot.standardizedFileURL.pathComponents
                    let incomingComponents = incoming.url.standardizedFileURL.pathComponents
                    let relative = incomingComponents.dropFirst(sourceComponents.count).joined(separator: "/")
                    guard CoreSupport.safeRelativePath(relative) else { throw AIManagerError.unsafePath(relative) }
                    let destination = paths.sharedRoot.appending(path: name).appending(path: relative)
                    if fileManager.fileExists(atPath: destination.path) {
                        try preserveConflict(incoming.url, identity: incoming.identity, operation: operation)
                        unresolved.append("\(incoming.identity): filename collision with a different transcript identity")
                    } else {
                        try replaceRecoverably(source: incoming.url, destination: destination, operation: &operation, backupName: "history-created/\(incoming.identity).jsonl")
                        existing[incoming.identity] = .init(url: destination, identity: incoming.identity, recordCount: incoming.recordCount, contentDigest: incoming.contentDigest, archived: archived)
                        imported += 1
                    }
                }
            }
            let auxiliary = try mergeAuxiliaryHistoryFiles(sourceRoot: sourceRoot, destinationRoot: paths.sharedRoot.appending(path: name), operation: &operation)
            imported += auxiliary.imported
            unresolved += auxiliary.unresolved
        }
        let sharedComponents = paths.sharedRoot.standardizedFileURL.pathComponents
        var destinations: [String: String] = [:]
        for (identity, info) in existing {
            let components = info.url.standardizedFileURL.pathComponents
            guard components.count > sharedComponents.count,
                  Array(components.prefix(sharedComponents.count)) == sharedComponents else { continue }
            let relative = components.dropFirst(sharedComponents.count).joined(separator: "/")
            if CoreSupport.safeRelativePath(relative), relative.hasPrefix("sessions/") || relative.hasPrefix("archived_sessions/") {
                destinations[identity] = relative
            }
        }
        return (imported, unresolved, destinations)
    }

    private func transcript(_ prefix: URL, isPrefixOf complete: URL, recordCount: Int) throws -> Bool {
        let prefixReader = try JSONLReader(url: prefix)
        let completeReader = try JSONLReader(url: complete)
        for _ in 0..<recordCount {
            let equal = try withAutoreleasePool {
                guard let left = try prefixReader.next(), let right = try completeReader.next() else { return false }
                return left == right
            }
            guard equal else { return false }
        }
        return try prefixReader.next() == nil
    }

    private func file(_ url: URL, contains needle: Data) throws -> Bool {
        guard !needle.isEmpty else { return true }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var overlap = Data()
        while true {
            var ended = false
            var found = false
            try withAutoreleasePool {
                guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { ended = true; return }
                var window = overlap
                window.append(chunk)
                found = window.range(of: needle) != nil
                overlap = Data(window.suffix(max(0, needle.count - 1)))
            }
            if found { return true }
            if ended { break }
        }
        return false
    }

    private func mergeAuxiliaryHistoryFiles(sourceRoot: URL, destinationRoot: URL, operation: inout RecoveryOperation) throws -> (imported: Int, unresolved: [String]) {
        guard fileManager.fileExists(atPath: sourceRoot.path),
              (try sourceRoot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              let enumerator = fileManager.enumerator(at: sourceRoot, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return (0, []) }
        var imported = 0
        var unresolved: [String] = []
        var visited = 0
        while let source = enumerator.nextObject() as? URL {
            visited += 1
            guard visited <= 500_000 else {
                throw AIManagerError.invalidSource("History exceeds the 500,000-entry inspection limit.")
            }
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, source.pathExtension != "jsonl" else { continue }
            let base = sourceRoot.standardizedFileURL.pathComponents
            let components = source.standardizedFileURL.pathComponents
            let relative = components.dropFirst(base.count).joined(separator: "/")
            guard CoreSupport.safeRelativePath(relative) else { throw AIManagerError.unsafePath(relative) }
            let destination = destinationRoot.appending(path: relative)
            if !fileManager.fileExists(atPath: destination.path) {
                try replaceRecoverably(source: source, destination: destination, operation: &operation, backupName: "history-created-files/\(relative)")
                imported += 1
            } else if try treeDigest(source) != treeDigest(destination) {
                let preserved = operation.backup.appending(path: "conflicts/files/\(relative)")
                try copyPortable(source, to: preserved)
                unresolved.append("\(relative): divergent referenced file preserved in backup")
            }
        }
        return (imported, unresolved)
    }

    private func preserveConflict(_ source: URL, identity: String, operation: RecoveryOperation) throws {
        let safe = identity.replacingOccurrences(of: "/", with: "_")
        let destination = operation.backup.appending(path: "conflicts/\(safe)/\(source.lastPathComponent)")
        try CoreSupport.privateDirectory(destination.deletingLastPathComponent(), fileManager: fileManager)
        try copyPortable(source, to: destination)
    }

    private func affectedRecoveryHomes(_ operation: RecoveryOperation) throws -> [URL] {
        guard ["import", "import-grok", "import-droid", "switch", "switch-grok", "switch-droid", "settings-link-repair", "usage-credential-refresh", "delete-account", "account-login-refresh"].contains(operation.kind),
              CoreSupport.isContained(operation.backup, by: paths.applicationSupport) else {
            throw AIManagerError.invalidSource("Unknown or unsafe recovery operation.")
        }
        let registry = try loadRegistry()
        var candidates = [
            paths.defaultHome, paths.sharedRoot, paths.credentialStore,
            paths.grokHome, paths.grokCredentialStore,
            paths.droidHome, paths.droidCredentialStore, paths.applicationSupport.appending(path: "droid-usage"),
        ]
            + registry.accounts.map(\.home)
        if let previous = operation.previousAccount { candidates.append(previous.home) }
        var homes: [URL] = []
        switch operation.kind {
        case "import-droid":
            guard let id = operation.registryAccountID,
                  CoreSupport.sameLocation(operation.destination, credentialFile(for: id, providerID: .droid)) else {
                throw AIManagerError.unsafePath(operation.destination.path)
            }
        case "switch-droid":
            guard DroidProviderAdapter.authNames.contains(operation.destination.lastPathComponent),
                  CoreSupport.sameLocation(operation.destination.deletingLastPathComponent(), paths.droidHome) else {
                throw AIManagerError.unsafePath(operation.destination.path)
            }
            // The Droid writer lock, rather than Codex writer detection, protects these files.
        case "account-login-refresh":
            guard let account = operation.previousAccount, operation.registryAccountID == account.id,
                  CoreSupport.sameLocation(operation.destination, account.credentialFile) else {
                throw AIManagerError.unsafePath(operation.destination.path)
            }
            try validateDeleteTargets(account)
        case "import", "import-grok":
            let accountsRoot = paths.applicationSupport.appending(path: "accounts", directoryHint: .isDirectory)
            guard CoreSupport.isContained(operation.destination, by: accountsRoot) else {
                throw AIManagerError.unsafePath(operation.destination.path)
            }
            candidates.append(operation.destination)
            homes.append(operation.destination)
        case "switch":
            guard CoreSupport.isContained(operation.destination, by: paths.defaultHome) else {
                throw AIManagerError.unsafePath(operation.destination.path)
            }
            homes.append(paths.defaultHome)
            if let accountID = operation.registryAccountID,
               let selected = registry.accounts.first(where: { $0.id == accountID }) {
                homes.append(selected.home)
            }
        case "switch-grok":
            guard CoreSupport.isContained(operation.destination, by: paths.grokHome) else {
                throw AIManagerError.unsafePath(operation.destination.path)
            }
            homes.append(paths.grokHome)
            if let accountID = operation.registryAccountID,
               let selected = registry.accounts.first(where: { $0.id == accountID }) {
                homes.append(selected.home)
            }
        case "settings-link-repair":
            guard let accountID = operation.registryAccountID,
                  let account = registry.accounts.first(where: { $0.id == accountID }) else {
                throw AIManagerError.unsafePath(operation.destination.path)
            }
            let accountParts = account.home.standardizedFileURL.pathComponents
            let destinationParts = operation.destination.standardizedFileURL.pathComponents
            let isLocalSetting = destinationParts.count > accountParts.count
                && Array(destinationParts.prefix(accountParts.count)) == accountParts
                && CoreSupport.settings.contains(destinationParts.dropFirst(accountParts.count).joined(separator: "/"))
            guard isLocalSetting else { throw AIManagerError.unsafePath(operation.destination.path) }
            homes += [account.home, paths.sharedRoot]
        case "usage-credential-refresh":
            guard let accountID = operation.registryAccountID,
                  let account = registry.accounts.first(where: { $0.id == accountID }),
                  registry.defaultAccountID == accountID,
                  CoreSupport.sameLocation(operation.destination, account.credentialFile),
                  CoreSupport.isContained(operation.destination, by: paths.credentialStore),
                  CoreSupport.sameLocation(
                    operation.source, paths.defaultHome.appending(path: "auth.json")) else {
                throw AIManagerError.unsafePath(operation.destination.path)
            }
            homes.append(paths.defaultHome)
        case "delete-account":
            guard let account = operation.previousAccount,
                  operation.registryAccountID == account.id else {
                throw AIManagerError.invalidSource("Account deletion recovery is missing its account record.")
            }
            try validateDeleteTargets(account)
            guard CoreSupport.sameLocation(operation.destination, account.home) else {
                throw AIManagerError.unsafePath(operation.destination.path)
            }
        default:
            throw AIManagerError.invalidSource("Unknown recovery operation kind.")
        }

        for target in try recoveryTargets(operation) {
            if operation.kind == "settings-link-repair",
               !CoreSupport.sameLocation(target.destination, operation.destination) {
                throw AIManagerError.unsafePath(target.destination.path)
            }
            if let backup = target.backup {
                let backupRootParts = operation.backup.standardizedFileURL.pathComponents
                let backupParts = backup.standardizedFileURL.pathComponents
                let isBackupEntry = backupParts.count > backupRootParts.count
                    && Array(backupParts.prefix(backupRootParts.count)) == backupRootParts
                    && CoreSupport.isContained(backup.deletingLastPathComponent(), by: operation.backup)
                guard isBackupEntry else { throw AIManagerError.unsafePath(backup.path) }
            }
            let matches = candidates.filter { CoreSupport.isContained(target.destination, by: $0) }
            guard !matches.isEmpty else { throw AIManagerError.unsafePath(target.destination.path) }
            if operation.kind != "delete-account" {
                homes += matches
            }
        }
        var seen = Set<String>()
        return homes.filter {
            if operation.kind.contains("droid") { return false }
            return seen.insert(CoreSupport.canonical($0).path).inserted
        }
    }

    private func recoveryTargets(_ operation: RecoveryOperation) throws -> [RecoveryTarget] {
        var result: [RecoveryTarget] = []
        var seen = Set<String>()
        for item in (operation.touchedItems ?? []).reversed() {
            let path = item.destination.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            result.append(.init(
                destination: item.destination,
                backup: item.backup,
                previousDigest: item.previousDigest
            ))
        }
        if operation.expectedDigest != nil && operation.kind != "usage-credential-refresh" {
            let path = operation.destination.standardizedFileURL.path
            if seen.insert(path).inserted {
                let prior: URL
                switch operation.kind {
                case "import", "import-grok", "import-droid":
                    prior = operation.backup.appending(path: "account-home", directoryHint: .isDirectory)
                case "switch", "switch-grok", "switch-droid", "account-login-refresh":
                    prior = operation.backup.appending(path: "auth.json")
                case "settings-link-repair":
                    throw AIManagerError.invalidSource("Settings-link recovery is missing its recorded item.")
                default: throw AIManagerError.invalidSource("Unknown recovery operation kind.")
                }
                let backup = operation.previousDigest != nil || CoreSupport.entryExists(prior) ? prior : nil
                result.append(.init(
                    destination: operation.destination,
                    backup: backup,
                    previousDigest: operation.previousDigest
                ))
            }
        }
        return result
    }

    private func resolveRecoveryConflict(
        _ operation: RecoveryOperation,
        choice: RecoveryConflictChoice
    ) throws -> RecoveryResult {
        if operation.kind == "delete-account" {
            return try resolveDeleteAccountConflict(operation, choice: choice)
        }
        var operation = operation
        switch choice {
        case .preserveCurrent:
            try reconcileRegistryKeepingCurrent(operation)
            try finishOperation(&operation)
            return .init(
                operationID: operation.id,
                outcome: .completed,
                message: "Current files were kept. The protected backup remains at \(operation.backup.path)."
            )
        case .restoreBackup:
            let targets = try recoveryTargets(operation)
            try validateRecoveryBackups(targets)
            try preserveRecoveryTargets(targets, under: operation.backup)
            for target in targets {
                if let backup = target.backup {
                    try CoreSupport.privateDirectory(
                        target.destination.deletingLastPathComponent(), fileManager: fileManager)
                    let staged = target.destination.deletingLastPathComponent()
                        .appending(path: ".\(target.destination.lastPathComponent).\(operation.id.uuidString).recovery")
                    if CoreSupport.entryExists(staged) { try fileManager.removeItem(at: staged) }
                    try fileManager.copyItem(at: backup, to: staged)
                    try CoreSupport.publish(staged, replacing: target.destination, fileManager: fileManager)
                } else if CoreSupport.entryExists(target.destination) {
                    try fileManager.removeItem(at: target.destination)
                }
            }
            try faultInjector(.afterRecoveryConflictRestore)
            var registry = try loadRegistry()
            if registryCommitted(operation, registry: registry) {
                restoreRegistry(operation, registry: &registry)
                try saveRegistry(registry)
            }
            let staging = paths.applicationSupport.appending(path: "staging/\(operation.id.uuidString)")
            if CoreSupport.entryExists(staging) { try fileManager.removeItem(at: staging) }
            operation.phase = .rolledBack
            try saveOperation(operation)
            try? fileManager.removeItem(at: operationItemsURL(operation.id))
            return .init(
                operationID: operation.id,
                outcome: .rolledBack,
                message: "The protected backup was restored. Replaced files remain under \(operation.backup.path)/recovery-conflict."
            )
        }
    }

    private func validateRecoveryBackups(_ targets: [RecoveryTarget]) throws {
        for target in targets {
            switch (target.previousDigest, target.backup) {
            case (nil, nil):
                continue
            case let (expected?, backup?):
                guard CoreSupport.entryExists(backup) else {
                    throw AIManagerError.operationFailed("A protected recovery backup is missing.")
                }
                guard try treeDigest(backup) == expected else {
                    throw AIManagerError.operationFailed("A protected recovery backup changed after it was recorded.")
                }
            default:
                throw AIManagerError.operationFailed(
                    "A protected recovery backup is missing its recorded fingerprint.")
            }
        }
    }

    private func reconcileRegistryKeepingCurrent(_ operation: RecoveryOperation) throws {
        switch operation.kind {
        case "import-droid", "switch-droid":
            var registry = try loadRegistry()
            for index in registry.accounts.indices where registry.accounts[index].identity.providerID == .droid {
                try droidProvider.requireLogin(droidProvider.files(in: registry.accounts[index].credentialFile))
                registry.accounts[index].credentialDigest = try treeDigest(registry.accounts[index].credentialFile)
            }
            if touchesDroidLive(operation) {
                let live = try droidProvider.files(in: paths.droidHome)
                guard let matching = try registry.accounts.first(where: {
                    guard $0.identity.providerID == .droid else { return false }
                    return try droidProvider.files(in: $0.credentialFile) == live
                }) else { throw AIManagerError.credentialConflict }
                registry.setDefaultAccountID(matching.id, for: .droid)
            }
            try saveRegistry(registry)
        case "account-login-refresh":
            var registry = try loadRegistry()
            if operation.previousAccount?.identity.providerID == .grokBuild {
                try refreshManagedGrokCredentialsTouched(by: operation, registry: &registry)
            } else {
                try refreshManagedCredentialsTouched(by: operation, registry: &registry)
            }
            try saveRegistry(registry)
        case "import":
            try reconcileImportRegistryKeepingCurrent(operation)
        case "import-grok":
            try reconcileGrokImportRegistryKeepingCurrent(operation)
        case "switch":
            try reconcileSwitchRegistryKeepingCurrent(operation)
        case "switch-grok":
            try reconcileGrokSwitchRegistryKeepingCurrent(operation)
        case "settings-link-repair":
            break
        default:
            throw AIManagerError.invalidSource("Unknown recovery operation kind.")
        }
    }

    private func reconcileImportRegistryKeepingCurrent(_ operation: RecoveryOperation) throws {
        guard let accountID = operation.registryAccountID else {
            throw AIManagerError.invalidSource("Import recovery is missing its account identifier.")
        }
        let inspection = provider.inspect(home: operation.destination)
        guard inspection.support == .supportedChatGPT,
              let identity = inspection.identity, identity.isResolved else {
            throw AIManagerError.credentialConflict
        }
        var registry = try loadRegistry()
        let verification = VerificationResult(
            state: .imported,
            checkedAt: Date(),
            detail: "The current credential was retained during recovery and passed the offline check."
        )
        let savedCredential = credentialFile(for: accountID)
        if CoreSupport.entryExists(savedCredential) {
            let saved = provider.inspect(credentialFile: savedCredential)
            guard saved.support == .supportedChatGPT,
                  let savedIdentity = saved.identity,
                  provider.sameIdentity(identity, savedIdentity) else {
                throw AIManagerError.credentialConflict
            }
            if saved.digest != inspection.digest {
                let preserved = operation.backup.appending(path: "recovery-conflict/saved-credential-before-reconcile.json")
                if !CoreSupport.entryExists(preserved) { try copyPortable(savedCredential, to: preserved) }
                try CoreSupport.atomicWrite(inspection.data, to: savedCredential, fileManager: fileManager)
            }
        } else {
            try CoreSupport.atomicWrite(inspection.data, to: savedCredential, fileManager: fileManager)
        }
        if let index = registry.accounts.firstIndex(where: { $0.id == accountID }) {
            let expectedHome = accountsRoot.appending(path: accountID.uuidString)
                .appending(path: "home", directoryHint: .isDirectory)
            guard CoreSupport.sameLocation(registry.accounts[index].home, expectedHome),
                  CoreSupport.sameLocation(operation.destination, expectedHome) else {
                throw AIManagerError.unsafePath("managed account home is outside the private account root")
            }
            guard provider.sameIdentity(registry.accounts[index].identity, identity) else {
                throw AIManagerError.credentialConflict
            }
            registry.accounts[index].identity = identity
            registry.accounts[index].credentialFile = savedCredential
            registry.accounts[index].source = operation.source
            registry.accounts[index].verification = verification
            registry.accounts[index].credentialDigest = inspection.digest
        } else {
            guard !registry.accounts.contains(where: { provider.sameIdentity($0.identity, identity) }) else {
                throw AIManagerError.credentialConflict
            }
            let expectedHome = accountsRoot.appending(path: accountID.uuidString)
                .appending(path: "home", directoryHint: .isDirectory)
            guard CoreSupport.sameLocation(operation.destination, expectedHome) else {
                throw AIManagerError.unsafePath("managed account home is outside the private account root")
            }
            registry.accounts.append(.init(
                id: accountID,
                identity: identity,
                credentialFile: savedCredential,
                home: operation.destination,
                source: operation.source,
                importedAt: Date(),
                verification: verification,
                credentialDigest: inspection.digest
            ))
        }
        if operation.setsDefaultAccount == true {
            let live = provider.inspect(home: paths.defaultHome)
            guard live.support == .supportedChatGPT,
                  let liveIdentity = live.identity,
                  provider.sameIdentity(identity, liveIdentity),
                  live.digest == inspection.digest else {
                throw AIManagerError.credentialConflict
            }
            registry.defaultAccountID = accountID
        }
        try saveRegistry(registry)
    }

    private func reconcileGrokImportRegistryKeepingCurrent(
        _ operation: RecoveryOperation
    ) throws {
        guard let accountID = operation.registryAccountID else {
            throw AIManagerError.invalidSource(
                "Grok import recovery is missing its account identifier.")
        }
        let inspection = grokProvider.inspect(home: operation.destination)
        guard inspection.support == .supportedOAuth,
              let identity = inspection.identity, identity.isResolved else {
            throw AIManagerError.credentialConflict
        }
        var registry = try loadRegistry()
        let savedCredential = credentialFile(for: accountID, providerID: .grokBuild)
        if CoreSupport.entryExists(savedCredential) {
            let saved = grokProvider.inspect(credentialFile: savedCredential)
            if saved.digest != inspection.digest {
                let preserved = operation.backup.appending(
                    path: "recovery-conflict/saved-credential-before-reconcile.json")
                if !CoreSupport.entryExists(preserved) {
                    try copyPortable(savedCredential, to: preserved)
                }
                try CoreSupport.atomicWrite(
                    inspection.data, to: savedCredential, fileManager: fileManager)
            }
        } else {
            try CoreSupport.atomicWrite(
                inspection.data, to: savedCredential, fileManager: fileManager)
        }
        let verification = VerificationResult(
            state: .imported,
            checkedAt: Date(),
            detail: "The current Grok credential was retained during recovery and passed the offline check.")
        if let index = registry.accounts.firstIndex(where: { $0.id == accountID }) {
            guard registry.accounts[index].identity.providerID == .grokBuild,
                  grokProvider.sameIdentity(registry.accounts[index].identity, identity) else {
                throw AIManagerError.credentialConflict
            }
            registry.accounts[index].identity = identity
            registry.accounts[index].credentialFile = savedCredential
            registry.accounts[index].source = operation.source
            registry.accounts[index].verification = verification
            registry.accounts[index].credentialDigest = inspection.digest
        } else {
            registry.accounts.append(.init(
                id: accountID,
                identity: identity,
                credentialFile: savedCredential,
                home: operation.destination,
                source: operation.source,
                importedAt: Date(),
                verification: verification,
                credentialDigest: inspection.digest))
        }
        try saveRegistry(registry)
    }

    private func reconcileSwitchRegistryKeepingCurrent(_ operation: RecoveryOperation) throws {
        guard let accountID = operation.registryAccountID else {
            throw AIManagerError.invalidSource("Switch recovery is missing its account identifier.")
        }
        let currentDefault = provider.inspect(home: paths.defaultHome)
        guard currentDefault.support == .supportedChatGPT,
              let currentIdentity = currentDefault.identity, currentIdentity.isResolved else {
            throw AIManagerError.credentialConflict
        }
        var registry = try loadRegistry()
        try refreshManagedCredentialsTouched(by: operation, registry: &registry)
        guard let selectedIndex = registry.accounts.firstIndex(where: { $0.id == accountID }),
              provider.sameIdentity(registry.accounts[selectedIndex].identity, currentIdentity) else {
            throw AIManagerError.credentialConflict
        }
        if currentDefault.digest != registry.accounts[selectedIndex].credentialDigest {
            try CoreSupport.atomicWrite(
                currentDefault.data,
                to: registry.accounts[selectedIndex].credentialFile,
                fileManager: fileManager
            )
            registry.accounts[selectedIndex].credentialDigest = currentDefault.digest
        }
        try provider.validateManagedCredential(registry.accounts[selectedIndex])
        registry.setDefaultAccountID(accountID, for: .codex)
        registry.accounts[selectedIndex].lastUsedAt = Date()
        try saveRegistry(registry)
    }

    private func reconcileGrokSwitchRegistryKeepingCurrent(
        _ operation: RecoveryOperation
    ) throws {
        guard let accountID = operation.registryAccountID else {
            throw AIManagerError.invalidSource(
                "Grok switch recovery is missing its account identifier.")
        }
        let current = grokProvider.inspect(home: paths.grokHome)
        guard current.support == .supportedOAuth,
              let currentIdentity = current.identity, currentIdentity.isResolved else {
            throw AIManagerError.credentialConflict
        }
        var registry = try loadRegistry()
        try refreshManagedGrokCredentialsTouched(by: operation, registry: &registry)
        guard let selectedIndex = registry.accounts.firstIndex(where: { $0.id == accountID }),
              grokProvider.sameIdentity(
                registry.accounts[selectedIndex].identity, currentIdentity) else {
            throw AIManagerError.credentialConflict
        }
        if current.digest != registry.accounts[selectedIndex].credentialDigest {
            try CoreSupport.atomicWrite(
                current.data,
                to: registry.accounts[selectedIndex].credentialFile,
                fileManager: fileManager)
            registry.accounts[selectedIndex].credentialDigest = current.digest
        }
        try grokProvider.validateManagedCredential(registry.accounts[selectedIndex])
        registry.setDefaultAccountID(accountID, for: .grokBuild)
        registry.accounts[selectedIndex].lastUsedAt = Date()
        try saveRegistry(registry)
    }

    private func refreshManagedCredentialsTouched(
        by operation: RecoveryOperation,
        registry: inout Registry
    ) throws {
        let verification = VerificationResult(
            state: .imported,
            checkedAt: Date(),
            detail: "The current credential was retained during recovery and passed the offline check."
        )
        for target in try recoveryTargets(operation) {
            guard let index = registry.accounts.firstIndex(where: {
                CoreSupport.sameLocation($0.credentialFile, target.destination)
            }) else { continue }
            let inspection = provider.inspect(credentialFile: registry.accounts[index].credentialFile)
            guard inspection.support == .supportedChatGPT,
                  let identity = inspection.identity, identity.isResolved,
                  provider.sameIdentity(registry.accounts[index].identity, identity) else {
                throw AIManagerError.credentialConflict
            }
            registry.accounts[index].identity = identity
            registry.accounts[index].verification = verification
            registry.accounts[index].credentialDigest = inspection.digest
        }
    }

    private func refreshManagedGrokCredentialsTouched(
        by operation: RecoveryOperation,
        registry: inout Registry
    ) throws {
        let verification = VerificationResult(
            state: .imported,
            checkedAt: Date(),
            detail: "The current Grok credential was retained during recovery and passed the offline check.")
        for target in try recoveryTargets(operation) {
            guard let index = registry.accounts.firstIndex(where: {
                $0.identity.providerID == .grokBuild
                    && CoreSupport.sameLocation($0.credentialFile, target.destination)
            }) else { continue }
            let inspection = grokProvider.inspect(
                credentialFile: registry.accounts[index].credentialFile)
            guard inspection.support == .supportedOAuth,
                  let identity = inspection.identity, identity.isResolved,
                  grokProvider.sameIdentity(registry.accounts[index].identity, identity) else {
                throw AIManagerError.credentialConflict
            }
            registry.accounts[index].identity = identity
            registry.accounts[index].verification = verification
            registry.accounts[index].credentialDigest = inspection.digest
        }
    }

    private func preserveRecoveryTargets(_ targets: [RecoveryTarget], under backup: URL) throws {
        let root = backup.appending(path: "recovery-conflict/current", directoryHint: .isDirectory)
        for (index, target) in targets.enumerated() where CoreSupport.entryExists(target.destination) {
            try CoreSupport.privateDirectory(root, fileManager: fileManager)
            let staged = root.appending(path: ".\(UUID().uuidString).recovery")
            let preserved = root.appending(path: "\(index)-\(UUID().uuidString)")
            try fileManager.copyItem(at: target.destination, to: staged)
            try CoreSupport.publish(staged, replacing: preserved, fileManager: fileManager)
        }
    }

    private func registryCommitted(_ operation: RecoveryOperation, registry: Registry) -> Bool {
        if ["switch", "switch-grok", "switch-droid"].contains(operation.kind) {
            let providerID: ProviderID = operation.kind == "switch-droid" ? .droid : operation.kind == "switch-grok" ? .grokBuild : .codex
            return registry.defaultAccountID(for: providerID) == operation.registryAccountID
        }
        guard let accountID = operation.registryAccountID,
              let expectedCredential = operation.registryCredentialDigest else { return false }
        let accountMatches = registry.accounts.first(where: { $0.id == accountID })?.credentialDigest
            == expectedCredential
        let defaultMatches = operation.setsDefaultAccount != true
            || registry.defaultAccountID(for: operation.kind == "import-droid" ? .droid : .codex) == accountID
        return accountMatches && defaultMatches
    }

    private func publishedRecoveryTargetsMatch(_ operation: RecoveryOperation) throws -> Bool {
        for item in operation.touchedItems ?? [] {
            if item.expectedDigest == "absent" {
                guard !CoreSupport.entryExists(item.destination) else { return false }
                continue
            }
            if let temporary = item.temporary, CoreSupport.entryExists(temporary) { return false }
            guard !item.expectedDigest.isEmpty,
                  CoreSupport.entryExists(item.destination),
                  try treeDigest(item.destination) == item.expectedDigest else { return false }
        }
        return true
    }

    private func restoreRegistry(_ operation: RecoveryOperation, registry: inout Registry) {
        if ["switch", "switch-grok", "switch-droid"].contains(operation.kind) {
            let providerID: ProviderID = operation.kind == "switch-droid" ? .droid : operation.kind == "switch-grok" ? .grokBuild : .codex
            registry.setDefaultAccountID(operation.previousDefaultAccountID, for: providerID)
            if let previous = operation.previousAccount,
               let index = registry.accounts.firstIndex(where: { $0.id == previous.id }) {
                registry.accounts[index] = previous
            }
        } else if let accountID = operation.registryAccountID {
            if operation.setsDefaultAccount == true {
                registry.setDefaultAccountID(operation.previousDefaultAccountID, for: operation.kind == "import-droid" ? .droid : .codex)
            }
            if let previous = operation.previousAccount,
               let index = registry.accounts.firstIndex(where: { $0.id == accountID }) {
                registry.accounts[index] = previous
            } else {
                registry.accounts.removeAll { $0.id == accountID }
            }
        }
    }

    private func recoverOperation(_ operation: RecoveryOperation) throws -> RecoveryResult {
        if operation.kind == "usage-credential-refresh" {
            return try recoverUsageCredentialRefresh(operation)
        }
        if operation.kind == "delete-account" {
            return try recoverDeleteAccount(operation)
        }
        var operation = operation
        var registry = try loadRegistry()
        let registryCommitted = registryCommitted(operation, registry: registry)
        let currentDigest = fileManager.fileExists(atPath: operation.destination.path) ? try? treeDigest(operation.destination) : nil
        if registryCommitted, currentDigest == operation.expectedDigest {
            if try publishedRecoveryTargetsMatch(operation) {
                try finishOperation(&operation)
                return .init(operationID: operation.id, outcome: .completed, message: "The published files and registry agree; recovery finalized the operation.")
            }
            operation.phase = .conflicted
            try saveOperation(operation)
            return .init(
                operationID: operation.id,
                outcome: .conflict,
                message: "A published file changed after the registry commit; the current and protected versions were preserved."
            )
        }

        try validateRecoveryBackups(recoveryTargets(operation))

        if let expected = operation.expectedDigest {
            if currentDigest == expected {
                if fileManager.fileExists(atPath: operation.destination.path) { try fileManager.removeItem(at: operation.destination) }
            } else if currentDigest != nil, currentDigest != operation.previousDigest {
                operation.phase = .conflicted
                try saveOperation(operation)
                return .init(operationID: operation.id, outcome: .conflict, message: "Later edits were preserved; choose a recovery version.")
            }
        }

        var conflict = false
        for item in (operation.touchedItems ?? []).reversed() {
            if let temporary = item.temporary, fileManager.fileExists(atPath: temporary.path) {
                let preserved = operation.backup.appending(path: "interrupted-staging/\(UUID().uuidString)-\(temporary.lastPathComponent)")
                try CoreSupport.privateDirectory(preserved.deletingLastPathComponent(), fileManager: fileManager)
                do { try fileManager.moveItem(at: temporary, to: preserved) }
                catch { try copyPortable(temporary, to: preserved); try fileManager.removeItem(at: temporary) }
            }
            if fileManager.fileExists(atPath: item.destination.path) {
                let current = try? treeDigest(item.destination)
                if current == item.expectedDigest { try fileManager.removeItem(at: item.destination) }
                else if current == item.previousDigest { continue }
                else { conflict = true; continue }
            }
            if let backup = item.backup, fileManager.fileExists(atPath: backup.path) {
                try copyPortable(backup, to: item.destination)
            }
        }
        if operation.expectedDigest != nil {
            if !conflict, !fileManager.fileExists(atPath: operation.destination.path) {
                let prior = operation.backup.appending(
                    path: ["switch", "switch-grok"].contains(operation.kind)
                        ? "auth.json" : "account-home")
                if fileManager.fileExists(atPath: prior.path) {
                    if ["import", "import-grok"].contains(operation.kind) {
                        try fileManager.copyItem(at: prior, to: operation.destination)
                    }
                    else { try copyPortable(prior, to: operation.destination) }
                }
            }
        }
        guard !conflict else {
            operation.phase = .conflicted; try saveOperation(operation)
            return .init(operationID: operation.id, outcome: .conflict, message: "Later edits were preserved; choose a recovery version.")
        }
        if registryCommitted {
            restoreRegistry(operation, registry: &registry)
            try saveRegistry(registry)
        }
        let staging = paths.applicationSupport.appending(path: "staging/\(operation.id.uuidString)")
        if fileManager.fileExists(atPath: staging.path) { try fileManager.removeItem(at: staging) }
        operation.phase = .rolledBack
        try saveOperation(operation)
        try? fileManager.removeItem(at: operationItemsURL(operation.id))
        return .init(operationID: operation.id, outcome: .rolledBack, message: "The incomplete operation was rolled back.")
    }

    private func recoverUsageCredentialRefresh(
        _ pending: RecoveryOperation
    ) throws -> RecoveryResult {
        var operation = pending
        guard let accountID = operation.registryAccountID,
              let expectedDigest = operation.expectedDigest,
              let previousDigest = operation.previousDigest else {
            throw AIManagerError.invalidSource("Usage credential recovery is incomplete.")
        }
        var registry = try loadRegistry()
        guard registry.defaultAccountID == accountID,
              let index = registry.accounts.firstIndex(where: { $0.id == accountID }),
              [previousDigest, expectedDigest].contains(registry.accounts[index].credentialDigest) else {
            throw AIManagerError.credentialConflict
        }
        let account = registry.accounts[index]
        let liveAuth = paths.defaultHome.appending(path: "auth.json")
        try provider.validatePrivateCredentialFile(liveAuth)
        let live = provider.inspect(home: paths.defaultHome)
        guard live.support == .supportedChatGPT,
              let liveIdentity = live.identity,
              provider.sameIdentity(account.identity, liveIdentity),
              live.digest == expectedDigest else {
            operation.phase = .conflicted
            try saveOperation(operation)
            return .init(
                operationID: operation.id,
                outcome: .conflict,
                message: "The live credential changed again; recovery preserved every version."
            )
        }

        let saved = provider.inspect(credentialFile: account.credentialFile)
        guard saved.support == .supportedChatGPT,
              let savedIdentity = saved.identity,
              provider.sameIdentity(account.identity, savedIdentity),
              [previousDigest, expectedDigest].contains(saved.digest) else {
            operation.phase = .conflicted
            try saveOperation(operation)
            return .init(
                operationID: operation.id,
                outcome: .conflict,
                message: "The saved credential changed; recovery preserved every version."
            )
        }
        if saved.digest != expectedDigest {
            try CoreSupport.atomicWrite(
                live.data, to: account.credentialFile, fileManager: fileManager)
        }
        try provider.validatePrivateCredentialFile(account.credentialFile)
        guard provider.inspect(credentialFile: account.credentialFile).digest == expectedDigest else {
            throw AIManagerError.credentialConflict
        }
        registry.accounts[index].credentialDigest = expectedDigest
        try saveRegistry(registry)
        for item in operation.touchedItems ?? [] {
            if let temporary = item.temporary, CoreSupport.entryExists(temporary) {
                try? fileManager.removeItem(at: temporary)
            }
        }
        try finishOperation(&operation)
        return .init(
            operationID: operation.id,
            outcome: .completed,
            message: "Recovery saved the refreshed live credential."
        )
    }

    private func recoverDeleteAccount(
        _ pending: RecoveryOperation
    ) throws -> RecoveryResult {
        var operation = pending
        guard let account = operation.previousAccount,
              operation.registryAccountID == account.id else {
            throw AIManagerError.invalidSource("Account deletion recovery is incomplete.")
        }
        try validateDeleteTargets(account)
        let targets = try recoveryTargets(operation)
        let expected = [
            account.home.standardizedFileURL.path,
            account.credentialFile.standardizedFileURL.path,
        ]
        guard Set(targets.map { $0.destination.standardizedFileURL.path }).isSubset(of: Set(expected)) else {
            throw AIManagerError.unsafePath("Account deletion recovery contains an unmanaged target.")
        }

        let registry = try loadRegistry()
        if registry.accounts.contains(where: { $0.id == account.id }) {
            for target in targets {
                if CoreSupport.entryExists(target.destination) {
                    guard try treeDigest(target.destination) == target.previousDigest else {
                        operation.phase = .conflicted
                        try saveOperation(operation)
                        return .init(
                            operationID: operation.id,
                            outcome: .conflict,
                            message: "A managed account file changed during deletion recovery."
                        )
                    }
                } else if let backup = target.backup,
                          let digest = target.previousDigest,
                          CoreSupport.entryExists(backup),
                          try treeDigest(backup) == digest {
                    try copyPortable(backup, to: target.destination)
                } else {
                    throw AIManagerError.operationFailed("A protected account deletion backup is missing.")
                }
            }
            try? fileManager.removeItem(at: operation.backup)
            operation.phase = .rolledBack
            try saveOperation(operation)
            try? fileManager.removeItem(at: operationItemsURL(operation.id))
            return .init(
                operationID: operation.id,
                outcome: .rolledBack,
                message: "The incomplete account deletion was rolled back."
            )
        }

        let providerID = operation.previousAccount?.identity.providerID ?? .codex
        guard registry.defaultAccountID(for: providerID) == operation.previousDefaultAccountID else {
            operation.phase = .conflicted
            try saveOperation(operation)
            return .init(
                operationID: operation.id,
                outcome: .conflict,
                message: "The account registry changed during deletion recovery."
            )
        }
        for target in targets where CoreSupport.entryExists(target.destination) {
            guard try treeDigest(target.destination) == target.previousDigest else {
                operation.phase = .conflicted
                try saveOperation(operation)
                return .init(
                    operationID: operation.id,
                    outcome: .conflict,
                    message: "A managed account file changed after its registry record was removed."
                )
            }
            try fileManager.removeItem(at: target.destination)
        }
        try? fileManager.removeItem(at: operation.backup)
        try finishOperation(&operation)
        return .init(
            operationID: operation.id,
            outcome: .completed,
            message: "Recovery finished deleting the managed account files."
        )
    }

    private func resolveDeleteAccountConflict(
        _ pending: RecoveryOperation,
        choice: RecoveryConflictChoice
    ) throws -> RecoveryResult {
        var operation = pending
        guard let account = operation.previousAccount,
              operation.registryAccountID == account.id else {
            throw AIManagerError.invalidSource("Account deletion recovery is incomplete.")
        }
        try validateDeleteTargets(account)
        let targets = try recoveryTargets(operation)
        try validateRecoveryBackups(targets)
        _ = choice
        try preserveRecoveryTargets(targets, under: operation.backup)
        for target in targets {
            guard let backup = target.backup else {
                throw AIManagerError.operationFailed("A protected account deletion backup is missing.")
            }
            if CoreSupport.entryExists(target.destination) {
                try fileManager.removeItem(at: target.destination)
            }
            try copyPortable(backup, to: target.destination)
        }
        var registry = try loadRegistry()
        if !registry.accounts.contains(where: { $0.id == account.id }) {
            registry.accounts.append(account)
            try saveRegistry(registry)
        }
        operation.phase = .rolledBack
        try saveOperation(operation)
        try? fileManager.removeItem(at: operationItemsURL(operation.id))
        return .init(
            operationID: operation.id,
            outcome: .rolledBack,
            message: "The account deletion was cancelled and its managed files were restored."
        )
    }
}

private struct VersionedLoginSession: Codable {
    var version: Int
    var session: AccountLoginSession
    var retiredAt: Date? = nil
}
