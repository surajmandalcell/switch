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
public enum FaultPoint: Sendable, Equatable { case duringHistoryCopy, afterTemporaryCopy, afterHomePublication, afterDefaultCredentialPublication, afterRegistryCommit, afterRecoveryConflictRestore, afterProcessStart }

public actor AccountManager {
    public typealias WriterCheck = @Sendable (URL) async -> WriterState
    public typealias CapacityCheck = @Sendable (URL) -> Int64?

    private struct Registry: Codable {
        var accounts: [AccountRecord] = []
        var defaultAccountID: UUID?
    }

    private struct RecoveryTarget {
        var destination: URL
        var backup: URL?
        var previousDigest: String?
    }

    private let paths: ManagerPaths
    private let fileManager: FileManager
    private let provider: CodexProviderAdapter
    private let writerCheck: WriterCheck
    private let faultInjector: @Sendable (FaultPoint) throws -> Void
    private let verificationTimeout: TimeInterval
    private let capacityCheck: CapacityCheck
    private let loginRunner: AccountLoginRunner
    private let lock: OperationLock
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: ManagerPaths = .standard(), fileManager: FileManager = .default, writerCheck: WriterCheck? = nil, capacityCheck: CapacityCheck? = nil, verificationTimeout: TimeInterval = 10, loginRunner: AccountLoginRunner = .foundation, faultInjector: @escaping @Sendable (FaultPoint) throws -> Void = { _ in }) throws {
        self.paths = paths
        self.fileManager = fileManager
        self.provider = CodexProviderAdapter(fileManager: fileManager)
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
        return .init(
            accounts: registry.accounts,
            defaultAccountID: registry.defaultAccountID,
            sharedRoot: paths.sharedRoot,
            pendingRecovery: try pendingOperations(),
            linkedSettingsDivergences: try inspectLinkedSettings(accounts: codexAccounts)
        )
    }

    public static let providerCatalog: [ProviderDescriptor] = [
        .init(id: .codex, displayName: "Codex CLI", availability: .enabled),
        .init(
            id: .claudeCode, displayName: "Claude Code", availability: .disabled,
            unavailableReason: "Claude Code account setup is not available yet."),
        .init(
            id: .geminiCLI, displayName: "Gemini CLI", availability: .disabled,
            unavailableReason: "Gemini CLI account setup is not available yet."),
        .init(
            id: .antigravityCLI, displayName: "Antigravity CLI", availability: .disabled,
            unavailableReason: "Antigravity CLI account setup is not available yet."),
    ]

    public func refreshAccounts(includeDiscoveries: Bool = true) async throws -> AccountSnapshot {
        if try !pendingOperations().isEmpty {
            _ = try await recover()
        }
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
            providers: Self.providerCatalog,
            discoveries: includeDiscoveries ? await discover() : [],
            pendingLoginSessions: try loadLoginSessions()
        )
    }

    public func startAccountLogin(providerID: ProviderID) async throws -> AccountLoginStart {
        try ensureNoRecovery()
        guard Self.providerCatalog.first(where: { $0.id == providerID })?.availability == .enabled else {
            throw AIManagerError.unsupportedSource(
                Self.providerCatalog.first(where: { $0.id == providerID })?.unavailableReason
                    ?? "Provider \(providerID.rawValue) is not available.")
        }
        try provider.requireSupported(providerID)
        guard let executable = resolveExecutable() else { throw AIManagerError.cliNotFound }
        let session = AccountLoginSession(id: UUID(), providerID: providerID, createdAt: Date())
        let home = loginHome(session.id)
        try CoreSupport.privateDirectory(loginSessionsURL, fileManager: fileManager)
        try CoreSupport.privateDirectory(loginRoot(session.id), fileManager: fileManager)
        try CoreSupport.privateDirectory(home, fileManager: fileManager)
        try saveLoginSession(session)
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_ACCESS_TOKEN")
        environment["CODEX_HOME"] = home.path
        if let isolationRoot = paths.isolationRoot { environment["HOME"] = isolationRoot.path }
        let spec = LaunchSpec(
            executable: executable,
            arguments: ["-c", "cli_auth_credentials_store=\"file\"", "login"],
            environment: environment
        )
        try loginRunner.launch(session.id, spec)
        return .init(session: session, launchSpec: spec)
    }

    public func checkAccountLogin(
        id: UUID,
        credentialChoice: ConflictChoice? = nil
    ) async throws -> AccountLoginCheck {
        try ensureNoRecovery()
        let session = try loadLoginSession(id)
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
        let result = try await importAccount(plan: plan, decisions: decisions)
        try await switchDefaultIfUnset(to: result.account.id)
        loginRunner.cancel(id)
        try fileManager.removeItem(at: loginRoot(id))
        return .init(
            session: session,
            state: .completed,
            account: result.account,
            message: "Codex account access was saved."
        )
    }

    public func cancelAccountLogin(id: UUID) async throws {
        _ = try loadLoginSession(id)
        guard try !pendingOperations().contains(where: {
            CoreSupport.isContained($0.source, by: loginRoot(id))
        }) else { throw AIManagerError.recoveryRequired }
        loginRunner.cancel(id)
        try fileManager.removeItem(at: loginRoot(id))
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
            source: source,
            destination: destination,
            backup: paths.applicationSupport.appending(path: "backups/\(id.uuidString)", directoryHint: .isDirectory),
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

    public func switchDefault(to accountID: UUID) async throws -> SwitchResult {
        try await lock.withAsyncLock {
            try ensureNoRecovery()
            let registry = try loadRegistry()
            guard let selected = registry.accounts.first(where: { $0.id == accountID }) else {
                throw AIManagerError.accountNotFound
            }
            try provider.validateManagedCredential(selected)
            try await ensureWritersInactive([paths.defaultHome])
            return try performSwitch(to: accountID)
        }
    }

    private func switchDefaultIfUnset(to accountID: UUID) async throws {
        try await lock.withAsyncLock {
            try ensureNoRecovery()
            let registry = try loadRegistry()
            guard registry.defaultAccountID == nil else { return }
            guard let selected = registry.accounts.first(where: { $0.id == accountID }) else {
                throw AIManagerError.accountNotFound
            }
            try provider.validateManagedCredential(selected)
            try await ensureWritersInactive([paths.defaultHome])
            _ = try performSwitch(to: accountID)
        }
    }

    public func readCodexAccountUsage(
        accountID: UUID,
        reader: CodexAppServerAccountReader = .init(),
        limits: CodexAppServerLimits = .init()
    ) async throws -> CodexAccountUsageSnapshot {
        try await lock.withAsyncLock {
            try ensureNoRecovery()
            let registry = try loadRegistry()
            guard let account = registry.accounts.first(where: { $0.id == accountID }) else {
                throw AIManagerError.accountNotFound
            }
            guard registry.defaultAccountID == accountID else {
                throw AIManagerError.operationFailed("Use this account before refreshing usage.")
            }
            try provider.requireSupported(account.identity.providerID)
            guard account.identity.isResolved else { throw AIManagerError.unresolvedIdentity }
            try provider.validateManagedCredential(account)

            let liveAuth = paths.defaultHome.appending(path: "auth.json")
            try provider.validatePrivateCredentialFile(liveAuth)
            let live = provider.inspect(home: paths.defaultHome)
            guard live.support == .supportedChatGPT,
                  let liveIdentity = live.identity,
                  provider.sameIdentity(account.identity, liveIdentity),
                  live.digest == account.credentialDigest else {
                throw AIManagerError.credentialConflict
            }
            try await ensureWritersInactive([paths.defaultHome])
            guard let executable = resolveExecutable() else { throw AIManagerError.cliNotFound }

            let snapshot: CodexAccountUsageSnapshot
            do {
                snapshot = try await reader.read(
                    executable: executable,
                    source: .init(codexHome: paths.defaultHome, authFile: liveAuth),
                    limits: limits
                )
            } catch {
                let readError = error
                try synchronizeUsageCredential(accountID: accountID, baselineDigest: live.digest)
                throw readError
            }
            try synchronizeUsageCredential(accountID: accountID, baselineDigest: live.digest)
            return snapshot
        }
    }

    public func launchSpec(accountID: UUID, arguments: [String] = [], workingDirectory: URL? = nil) throws -> LaunchSpec {
        try ensureNoRecovery()
        let registry = try loadRegistry()
        guard let account = registry.accounts.first(where: { $0.id == accountID }) else { throw AIManagerError.accountNotFound }
        try provider.validateManagedCredential(account)
        guard registry.defaultAccountID == accountID else {
            throw AIManagerError.operationFailed("Use this account before opening Codex.")
        }
        let live = provider.inspect(home: paths.defaultHome)
        guard live.support == .supportedChatGPT,
              let liveIdentity = live.identity,
              provider.sameIdentity(account.identity, liveIdentity),
              live.digest == account.credentialDigest else {
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

    @discardableResult
    public func activateAndRun(
        accountID: UUID,
        arguments: [String] = [],
        workingDirectory: URL? = nil
    ) async throws -> Int32 {
        var launched: Process?
        try await lock.withAsyncLock {
            try ensureNoRecovery()
            let registry = try loadRegistry()
            guard let account = registry.accounts.first(where: { $0.id == accountID }) else {
                throw AIManagerError.accountNotFound
            }
            try provider.validateManagedCredential(account)
            let live = provider.inspect(home: paths.defaultHome)
            let alreadyActive = registry.defaultAccountID == accountID
                && live.digest == account.credentialDigest
                && live.identity.map { provider.sameIdentity(account.identity, $0) } == true
            if !alreadyActive {
                try await ensureWritersInactive([paths.defaultHome])
                _ = try performSwitch(to: accountID)
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
            throw AIManagerError.operationFailed("Codex did not start.")
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
        if let account = try? loadRegistry().accounts.first(where: { $0.id == accountID }), account.identity.providerID != provider.id {
            return .init(
                state: .unsupported,
                checkedAt: Date(),
                detail: "Provider \(account.identity.providerID.rawValue) is not supported by this release."
            )
        }
        var verificationHome: URL?
        do {
            let registry = try loadRegistry()
            guard let account = registry.accounts.first(where: { $0.id == accountID }) else {
                throw AIManagerError.accountNotFound
            }
            try provider.validateManagedCredential(account)
            guard let executable = resolveExecutable() else { throw AIManagerError.cliNotFound }
            let isolated = paths.applicationSupport.appending(path: "verification/\(UUID().uuidString)", directoryHint: .isDirectory)
            verificationHome = isolated
            try CoreSupport.privateDirectory(isolated, fileManager: fileManager)
            try copyPortable(account.credentialFile, to: isolated.appending(path: "auth.json"))
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "OPENAI_API_KEY")
            environment.removeValue(forKey: "CODEX_ACCESS_TOKEN")
            environment["CODEX_HOME"] = isolated.path
            if let isolationRoot = paths.isolationRoot { environment["HOME"] = isolationRoot.path }
            let spec = LaunchSpec(
                executable: executable,
                arguments: ["-c", "cli_auth_credentials_store=\"file\"", "login", "status"],
                environment: environment
            )
            let process = Process()
            process.executableURL = spec.executable
            process.arguments = spec.arguments
            process.environment = spec.environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(verificationTimeout)
            while process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning {
                process.terminate()
                let terminationDeadline = Date().addingTimeInterval(1)
                while process.isRunning, Date() < terminationDeadline { try await Task.sleep(for: .milliseconds(25)) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            try? fileManager.removeItem(at: isolated)
            verificationHome = nil
            let result = process.terminationStatus == 0
                ? VerificationResult(state: .verifiedLocally, checkedAt: Date(), detail: "Codex found file-based credentials. No online request was made.")
                : VerificationResult(state: .needsSignIn, checkedAt: Date(), detail: "Codex did not accept the local credential. Use Codex sign-in for this profile.")
            try recordVerification(result, accountID: accountID)
            return result
        } catch {
            if let verificationHome { try? fileManager.removeItem(at: verificationHome) }
            let result = VerificationResult(state: .needsSignIn, checkedAt: Date(), detail: "Local verification failed without making a model request.")
            try? recordVerification(result, accountID: accountID)
            return result
        }
    }

    public func recover() async throws -> [RecoveryResult] {
        try await lock.withAsyncLock {
            let reviewed = try pendingOperations()
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
            return try current.map { try recoverOperation($0) }
        }
    }

    public func resolveRecoveryConflict(
        operationID: UUID,
        choice: RecoveryConflictChoice
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
            return try resolveRecoveryConflict(current, choice: choice)
        }
    }
}

final class JSONLReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var offset = 0
    private var reachedEnd = false
    private let maximumRecordBytes: Int

    init(url: URL, maximumRecordBytes: Int = 64 * 1_024 * 1_024) throws {
        self.maximumRecordBytes = maximumRecordBytes
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit { try? handle.close() }

    func next() throws -> Data? {
        while true {
            if offset < buffer.count, let newline = buffer[offset...].firstIndex(of: 0x0A) {
                guard newline - offset <= maximumRecordBytes else {
                    throw AIManagerError.invalidSource("A JSONL record exceeds the validation limit.")
                }
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "codex"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            // pgrep establishes only that a Codex process exists somewhere on the
            // machine; it cannot attribute that process to this home.
            // ponytail: any Codex process blocks mutations because home ownership is unknown; use verified home-scoped writer detection when Codex exposes a reliable lock or probe.
            return process.terminationStatus == 0 ? .unknown : (process.terminationStatus == 1 ? .inactive : .unknown)
        } catch {
            return .unknown
        }
    }

    private var registryURL: URL { paths.applicationSupport.appending(path: "accounts.json") }
    private var accountsRoot: URL {
        paths.applicationSupport.appending(path: "accounts", directoryHint: .isDirectory)
    }
    private func credentialFile(for accountID: UUID) -> URL {
        paths.credentialStore.appending(path: "\(accountID.uuidString).json")
    }
    private var transactionsURL: URL { paths.applicationSupport.appending(path: "transactions", directoryHint: .isDirectory) }
    private var loginSessionsURL: URL {
        paths.applicationSupport.appending(path: "account-login", directoryHint: .isDirectory)
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
        return record.session
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
            return try loadLoginSession(id)
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
            let expectedCredential = credentialFile(for: account.id)
            let legacyCredential = account.home.appending(path: "auth.json")
            if account.credentialFile.standardizedFileURL.path == legacyCredential.standardizedFileURL.path {
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
                try provider.validatePrivateCredentialFile(account.credentialFile)
                let saved = provider.inspect(credentialFile: account.credentialFile)
                guard saved.support == .supportedChatGPT,
                      let savedIdentity = saved.identity,
                      provider.sameIdentity(account.identity, savedIdentity) else {
                    throw AIManagerError.credentialConflict
                }
            }
        }
        if let defaultID = registry.defaultAccountID,
           !registry.accounts.contains(where: { $0.id == defaultID }) {
            throw AIManagerError.invalidSource("The default account is missing from the registry.")
        }
        if migratedCredential { try saveRegistry(registry) }
        return registry
    }

    private func saveRegistry(_ registry: Registry) throws {
        try CoreSupport.atomicWrite(try encoder.encode(registry), to: registryURL, fileManager: fileManager)
    }

    private func recordVerification(_ result: VerificationResult, accountID: UUID) throws {
        try lock.withLock {
            var registry = try loadRegistry()
            guard let index = registry.accounts.firstIndex(where: { $0.id == accountID }) else { throw AIManagerError.accountNotFound }
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
            .appending(path: "backups/\(plan.id.uuidString)", directoryHint: .isDirectory)
        guard accountID == plan.id,
              CoreSupport.sameLocation(plan.destination, expectedDestination),
              CoreSupport.sameLocation(plan.backup, expectedBackup),
              CoreSupport.sameLocation(plan.sharedDestination, paths.sharedRoot),
              plan.credentialDestination.standardizedFileURL.path
                == credentialFile(for: accountID).standardizedFileURL.path else {
            throw AIManagerError.unsafePath("an import destination changed after review")
        }
        let destination = expectedDestination
        let staging = paths.applicationSupport.appending(path: "staging/\(plan.id.uuidString)/home", directoryHint: .isDirectory)
        var operation = RecoveryOperation(id: plan.id, kind: "import", phase: .prepared, source: plan.source, destination: destination, backup: plan.backup, touchedItems: [], registryAccountID: matching.map { registry.accounts[$0].id } ?? plan.id, previousDefaultAccountID: registry.defaultAccountID, registryCredentialDigest: keepExistingCredential ? registry.accounts[matching!].credentialDigest : plan.sourceAuthDigest, previousAccount: matching.map { registry.accounts[$0] }, setsDefaultAccount: setsDefaultAccount)
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

        let verification = VerificationResult(state: .imported, checkedAt: Date(), detail: "Credential format and private destination were verified offline.")
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

    private func performSwitch(to accountID: UUID) throws -> SwitchResult {
        var registry = try loadRegistry()
        guard let requested = registry.accounts.first(where: { $0.id == accountID }) else {
            throw AIManagerError.accountNotFound
        }
        try provider.validateManagedCredential(requested)

        let defaultAuth = paths.defaultHome.appending(path: "auth.json")
        let outgoingFileDigest = try credentialFingerprintIfPresent(defaultAuth)
        let outgoingInspection = provider.inspect(home: paths.defaultHome)
        var registeredOutgoingIndex: Int?
        var registeredOutgoingInspection: AuthInspection?
        if outgoingInspection.support == .supportedChatGPT, let identity = outgoingInspection.identity, identity.isResolved {
            if let currentID = registry.defaultAccountID,
               let index = registry.accounts.firstIndex(where: { $0.id == currentID }) {
                guard provider.sameIdentity(registry.accounts[index].identity, identity) else { throw AIManagerError.credentialConflict }
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
        } else if outgoingInspection.support == .supportedChatGPT, let identity = outgoingInspection.identity, identity.isResolved {
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

    private func synchronizeUsageCredential(accountID: UUID, baselineDigest: String) throws {
        var registry = try loadRegistry()
        guard registry.defaultAccountID == accountID,
              let index = registry.accounts.firstIndex(where: { $0.id == accountID }) else {
            throw AIManagerError.sourceChanged
        }
        let account = registry.accounts[index]
        try provider.validateManagedCredential(account)
        guard account.credentialDigest == baselineDigest else { throw AIManagerError.sourceChanged }

        let liveAuth = paths.defaultHome.appending(path: "auth.json")
        try provider.validatePrivateCredentialFile(liveAuth)
        let live = provider.inspect(home: paths.defaultHome)
        guard live.support == .supportedChatGPT,
              let identity = live.identity,
              provider.sameIdentity(account.identity, identity) else {
            throw AIManagerError.credentialConflict
        }
        guard live.digest != baselineDigest else { return }

        let id = UUID()
        let backup = paths.applicationSupport.appending(
            path: "backups/\(id.uuidString)", directoryHint: .isDirectory)
        var operation = RecoveryOperation(
            id: id,
            kind: "usage-credential-refresh",
            phase: .prepared,
            source: liveAuth,
            destination: account.credentialFile,
            backup: backup,
            expectedDigest: live.digest,
            touchedItems: [],
            previousDigest: baselineDigest,
            registryAccountID: accountID,
            previousDefaultAccountID: accountID,
            registryCredentialDigest: live.digest,
            previousAccount: account
        )
        try saveOperation(operation)
        try replaceRecoverably(
            source: liveAuth,
            destination: account.credentialFile,
            operation: &operation,
            backupName: "saved-credential.json"
        )
        try faultInjector(.afterDefaultCredentialPublication)
        operation.phase = .published
        try saveOperation(operation)

        registry.accounts[index].credentialDigest = live.digest
        try saveRegistry(registry)
        try faultInjector(.afterRegistryCommit)
        operation.phase = .registryCommitted
        try saveOperation(operation)
        try finishOperation(&operation)
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

    private func resolveExecutable() -> URL? {
        if let explicit = paths.codexExecutable, fileManager.isExecutableFile(atPath: explicit.path) { return explicit }
        if paths.isolationRoot != nil { return nil }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appending(path: "codex")
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
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
        guard ["import", "switch", "settings-link-repair", "usage-credential-refresh"].contains(operation.kind),
              CoreSupport.isContained(operation.backup, by: paths.applicationSupport) else {
            throw AIManagerError.invalidSource("Unknown or unsafe recovery operation.")
        }
        let registry = try loadRegistry()
        var candidates = [paths.defaultHome, paths.sharedRoot, paths.credentialStore]
            + registry.accounts.map(\.home)
        if let previous = operation.previousAccount { candidates.append(previous.home) }
        var homes: [URL] = []
        switch operation.kind {
        case "import":
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
            homes += matches
        }
        var seen = Set<String>()
        return homes.filter { seen.insert(CoreSupport.canonical($0).path).inserted }
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
                case "import": prior = operation.backup.appending(path: "account-home", directoryHint: .isDirectory)
                case "switch": prior = operation.backup.appending(path: "auth.json")
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
        case "import":
            try reconcileImportRegistryKeepingCurrent(operation)
        case "switch":
            try reconcileSwitchRegistryKeepingCurrent(operation)
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
            detail: "The current credential was retained during recovery and verified offline."
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
        registry.defaultAccountID = accountID
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
            detail: "The current credential was retained during recovery and verified offline."
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
        if operation.kind == "switch" {
            return registry.defaultAccountID == operation.registryAccountID
        }
        guard let accountID = operation.registryAccountID,
              let expectedCredential = operation.registryCredentialDigest else { return false }
        let accountMatches = registry.accounts.first(where: { $0.id == accountID })?.credentialDigest
            == expectedCredential
        let defaultMatches = operation.setsDefaultAccount != true
            || registry.defaultAccountID == accountID
        return accountMatches && defaultMatches
    }

    private func publishedRecoveryTargetsMatch(_ operation: RecoveryOperation) throws -> Bool {
        for item in operation.touchedItems ?? [] {
            if let temporary = item.temporary, CoreSupport.entryExists(temporary) { return false }
            guard !item.expectedDigest.isEmpty,
                  CoreSupport.entryExists(item.destination),
                  try treeDigest(item.destination) == item.expectedDigest else { return false }
        }
        return true
    }

    private func restoreRegistry(_ operation: RecoveryOperation, registry: inout Registry) {
        if operation.kind == "switch" {
            registry.defaultAccountID = operation.previousDefaultAccountID
            if let previous = operation.previousAccount,
               let index = registry.accounts.firstIndex(where: { $0.id == previous.id }) {
                registry.accounts[index] = previous
            }
        } else if let accountID = operation.registryAccountID {
            if operation.setsDefaultAccount == true {
                registry.defaultAccountID = operation.previousDefaultAccountID
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
                let prior = operation.backup.appending(path: operation.kind == "switch" ? "auth.json" : "account-home")
                if fileManager.fileExists(atPath: prior.path) {
                    if operation.kind == "import" { try fileManager.copyItem(at: prior, to: operation.destination) }
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
}

private struct VersionedLoginSession: Codable {
    var version: Int
    var session: AccountLoginSession
}
