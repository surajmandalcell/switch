import Foundation

public struct ManagerPaths: Sendable {
    public var applicationSupport: URL
    public var credentialStore: URL
    public var defaultHome: URL
    public var sharedRoot: URL {
        get { defaultHome }
        set { defaultHome = newValue }
    }
    public var orcaAccountsRoot: URL
    public var codexExecutable: URL?
    public var grokHome: URL
    public var grokCredentialStore: URL
    public var grokExecutable: URL?
    public var claudeExecutable: URL?
    public var isolationRoot: URL?

    public init(
        applicationSupport: URL,
        credentialStore: URL? = nil,
        defaultHome: URL,
        sharedRoot: URL,
        orcaAccountsRoot: URL,
        codexExecutable: URL? = nil,
        grokHome: URL? = nil,
        grokCredentialStore: URL? = nil,
        grokExecutable: URL? = nil,
        claudeExecutable: URL? = nil,
        isolationRoot: URL? = nil
    ) {
        self.applicationSupport = applicationSupport
        self.credentialStore = credentialStore
            ?? applicationSupport.appending(path: "credential-store/codex", directoryHint: .isDirectory)
        self.defaultHome = defaultHome
        _ = sharedRoot
        self.orcaAccountsRoot = orcaAccountsRoot
        self.codexExecutable = codexExecutable
        self.grokHome = grokHome
            ?? defaultHome.deletingLastPathComponent().appending(path: ".grok", directoryHint: .isDirectory)
        self.grokCredentialStore = grokCredentialStore
            ?? applicationSupport.appending(path: "credential-store/grok-build", directoryHint: .isDirectory)
        self.grokExecutable = grokExecutable
        self.claudeExecutable = claudeExecutable
        self.isolationRoot = isolationRoot
    }

    public static func standard(fileManager: FileManager = .default) -> Self {
        let home = fileManager.homeDirectoryForCurrentUser
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return .init(
            applicationSupport: support.appending(path: "AI Manager", directoryHint: .isDirectory),
            credentialStore: home.appending(path: ".switch/codex", directoryHint: .isDirectory),
            defaultHome: home.appending(path: ".codex", directoryHint: .isDirectory),
            sharedRoot: home.appending(path: ".codex", directoryHint: .isDirectory),
            orcaAccountsRoot: support.appending(path: "Orca/codex-accounts", directoryHint: .isDirectory),
            grokHome: home.appending(path: ".grok", directoryHint: .isDirectory),
            grokCredentialStore: home.appending(path: ".switch/grok-build", directoryHint: .isDirectory)
        )
    }

    public static func environment(_ environment: [String: String] = ProcessInfo.processInfo.environment, fileManager: FileManager = .default) -> Self {
        var paths = standard(fileManager: fileManager)
        func url(_ key: String) -> URL? {
            environment[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        }
        if let value = url("AI_MANAGER_ROOT") {
            paths.isolationRoot = value
            paths.applicationSupport = value.appending(path: "application-support", directoryHint: .isDirectory)
            paths.credentialStore = value.appending(path: ".switch/codex", directoryHint: .isDirectory)
            paths.defaultHome = value.appending(path: "default-home", directoryHint: .isDirectory)
            paths.grokHome = value.appending(path: "grok-home", directoryHint: .isDirectory)
            paths.grokCredentialStore = value.appending(path: ".switch/grok-build", directoryHint: .isDirectory)
            paths.orcaAccountsRoot = value.appending(path: "orca-accounts", directoryHint: .isDirectory)
        }
        if let value = url("AI_MANAGER_SHARED_ROOT"), url("AI_MANAGER_DEFAULT_HOME") == nil,
           paths.isolationRoot == nil || CoreSupportForPaths.contains(value, in: paths.isolationRoot!) {
            paths.defaultHome = value
        }
        if let value = url("AI_MANAGER_DEFAULT_HOME"), paths.isolationRoot == nil || CoreSupportForPaths.contains(value, in: paths.isolationRoot!) { paths.defaultHome = value }
        if let value = url("AI_MANAGER_CREDENTIAL_STORE"), paths.isolationRoot == nil || CoreSupportForPaths.contains(value, in: paths.isolationRoot!) { paths.credentialStore = value }
        if let value = url("AI_MANAGER_GROK_HOME"), paths.isolationRoot == nil || CoreSupportForPaths.contains(value, in: paths.isolationRoot!) { paths.grokHome = value }
        if let value = url("AI_MANAGER_GROK_CREDENTIAL_STORE"), paths.isolationRoot == nil || CoreSupportForPaths.contains(value, in: paths.isolationRoot!) { paths.grokCredentialStore = value }
        if let value = url("AI_MANAGER_ORCA_ACCOUNTS_ROOT"), paths.isolationRoot == nil || CoreSupportForPaths.contains(value, in: paths.isolationRoot!) { paths.orcaAccountsRoot = value }
        if let value = url("AI_MANAGER_CODEX_EXECUTABLE") { paths.codexExecutable = value }
        if let value = url("AI_MANAGER_GROK_EXECUTABLE") { paths.grokExecutable = value }
        if let value = url("AI_MANAGER_CLAUDE_EXECUTABLE") { paths.claudeExecutable = value }
        return paths
    }
}

private enum CoreSupportForPaths {
    static func contains(_ child: URL, in parent: URL) -> Bool {
        let childParts = CoreSupport.canonical(child).pathComponents
        let parentParts = CoreSupport.canonical(parent).pathComponents
        return childParts.count >= parentParts.count && Array(childParts.prefix(parentParts.count)) == parentParts
    }
}

public struct ProviderID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let codex = ProviderID(rawValue: "codex")
    public static let grokBuild = ProviderID(rawValue: "grok-build")

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(rawValue)
    }
}

public enum AuthMode: String, Codable, Sendable {
    case chatGPT
    case oauth
    case apiKey
    case unknown
}

public struct AccountIdentity: Codable, Hashable, Sendable {
    public var providerID: ProviderID
    public var email: String?
    public var userID: String?
    public var accountID: String?
    public var workspaceID: String?
    public var authMode: AuthMode

    public init(providerID: ProviderID = .codex, email: String? = nil, userID: String? = nil, accountID: String? = nil, workspaceID: String? = nil, authMode: AuthMode) {
        self.providerID = providerID
        self.email = email
        self.userID = userID
        self.accountID = accountID
        self.workspaceID = workspaceID
        self.authMode = authMode
    }

    public var isResolved: Bool {
        switch providerID {
        case .codex:
            authMode == .chatGPT && userID != nil && accountID != nil
        case .grokBuild:
            authMode == .oauth && userID != nil && accountID != nil
        case .claudeCode:
            authMode == .oauth && email != nil
        default:
            false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case providerID, email, userID, accountID, workspaceID, authMode
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try values.decodeIfPresent(ProviderID.self, forKey: .providerID) ?? .codex
        email = try values.decodeIfPresent(String.self, forKey: .email)
        userID = try values.decodeIfPresent(String.self, forKey: .userID)
        accountID = try values.decodeIfPresent(String.self, forKey: .accountID)
        workspaceID = try values.decodeIfPresent(String.self, forKey: .workspaceID)
        authMode = try values.decode(AuthMode.self, forKey: .authMode)
    }
}

public enum VerificationState: String, Codable, Sendable {
    case imported
    case needsSignIn
    case verifiedLocally
    case verifiedWithCodex
    case unsupported
}

public struct VerificationResult: Codable, Equatable, Sendable {
    public var state: VerificationState
    public var checkedAt: Date?
    public var detail: String

    public init(state: VerificationState, checkedAt: Date? = nil, detail: String) {
        self.state = state
        self.checkedAt = checkedAt
        self.detail = detail
    }
}

public struct AccountRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var identity: AccountIdentity
    public var credentialFile: URL
    public var home: URL
    public var source: URL
    public var importedAt: Date
    public var verification: VerificationResult
    public var lastUsedAt: Date?
    public var credentialDigest: String

    public init(id: UUID, identity: AccountIdentity, credentialFile: URL? = nil, home: URL, source: URL, importedAt: Date, verification: VerificationResult, lastUsedAt: Date? = nil, credentialDigest: String) {
        self.id = id
        self.identity = identity
        self.credentialFile = credentialFile ?? home.appending(path: "auth.json")
        self.home = home
        self.source = source
        self.importedAt = importedAt
        self.verification = verification
        self.lastUsedAt = lastUsedAt
        self.credentialDigest = credentialDigest
    }

    private enum CodingKeys: String, CodingKey {
        case id, identity, credentialFile, home, source, importedAt, verification, lastUsedAt, credentialDigest
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        identity = try values.decode(AccountIdentity.self, forKey: .identity)
        home = try values.decode(URL.self, forKey: .home)
        credentialFile = try values.decodeIfPresent(URL.self, forKey: .credentialFile)
            ?? home.appending(path: "auth.json")
        source = try values.decode(URL.self, forKey: .source)
        importedAt = try values.decode(Date.self, forKey: .importedAt)
        verification = try values.decode(VerificationResult.self, forKey: .verification)
        lastUsedAt = try values.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        credentialDigest = try values.decode(String.self, forKey: .credentialDigest)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(identity, forKey: .identity)
        try values.encode(credentialFile, forKey: .credentialFile)
        try values.encode(home, forKey: .home)
        try values.encode(source, forKey: .source)
        try values.encode(importedAt, forKey: .importedAt)
        try values.encode(verification, forKey: .verification)
        try values.encodeIfPresent(lastUsedAt, forKey: .lastUsedAt)
        try values.encode(credentialDigest, forKey: .credentialDigest)
    }
}

public struct HistorySummary: Codable, Equatable, Sendable {
    public var activeTranscripts: Int
    public var archivedTranscripts: Int
    public var hasIndexes: Bool

    public init(activeTranscripts: Int = 0, archivedTranscripts: Int = 0, hasIndexes: Bool = false) {
        self.activeTranscripts = activeTranscripts
        self.archivedTranscripts = archivedTranscripts
        self.hasIndexes = hasIndexes
    }
}

public enum SourceSupport: String, Codable, Sendable {
    case supportedChatGPT
    case supportedOAuth
    case apiKey
    case missingAuth
    case malformedAuth
    case keychainOnly
    case unknown
}

public struct DiscoveredSource: Identifiable, Codable, Sendable {
    public var id: String
    public var providerID: ProviderID
    public var path: URL
    public var identity: AccountIdentity?
    public var support: SourceSupport
    public var settings: [String]
    public var history: HistorySummary
    public var inspectionError: String?

    public init(id: String, providerID: ProviderID = .codex, path: URL, identity: AccountIdentity?, support: SourceSupport, settings: [String], history: HistorySummary, inspectionError: String? = nil) {
        self.id = id
        self.providerID = providerID
        self.path = path
        self.identity = identity
        self.support = support
        self.settings = settings
        self.history = history
        self.inspectionError = inspectionError
    }
}

public enum ImportMode: String, Codable, Sendable { case authOnly, full }
public enum ConflictChoice: String, Codable, Sendable { case keepShared, useImported }

public enum DataCategory: String, Codable, Sendable {
    case credential, setting, transcript, historyIndex, database, durableAuxiliary, runtime, installation, hostOwned, unknown
}

public struct ManifestEntry: Identifiable, Codable, Sendable {
    public var id: String { relativePath }
    public var relativePath: String
    public var category: DataCategory
    public var byteCount: Int64
    public var selected: Bool
    public var disposition: String

    public init(relativePath: String, category: DataCategory, byteCount: Int64, selected: Bool, disposition: String) {
        self.relativePath = relativePath
        self.category = category
        self.byteCount = byteCount
        self.selected = selected
        self.disposition = disposition
    }
}

public struct SettingConflict: Identifiable, Codable, Sendable {
    public var id: String { relativePath }
    public var relativePath: String
    public var importedDigest: String
    public var sharedDigest: String
    public var affectsAllAccounts: Bool
    public var externalTarget: URL?
    public var externalTargetBytes: Int64?

    public init(relativePath: String, importedDigest: String, sharedDigest: String, affectsAllAccounts: Bool = true, externalTarget: URL? = nil, externalTargetBytes: Int64? = nil) {
        self.relativePath = relativePath
        self.importedDigest = importedDigest
        self.sharedDigest = sharedDigest
        self.affectsAllAccounts = affectsAllAccounts
        self.externalTarget = externalTarget
        self.externalTargetBytes = externalTargetBytes
    }
}

public struct ImportPlan: Identifiable, Codable, Sendable {
    public var id: UUID
    public var operationID: UUID
    public var source: URL
    public var destination: URL
    public var credentialDestination: URL
    public var sharedDestination: URL
    public var backup: URL
    public var mode: ImportMode
    public var identity: AccountIdentity
    public var sourceAuthDigest: String
    public var reviewedDataDigest: String
    public var manifest: [ManifestEntry]
    public var conflicts: [SettingConflict]
    public var warnings: [String]
    public var requiredBytes: Int64

    public init(id: UUID, operationID: UUID? = nil, source: URL, destination: URL, backup: URL, mode: ImportMode, identity: AccountIdentity, sourceAuthDigest: String, reviewedDataDigest: String, manifest: [ManifestEntry], conflicts: [SettingConflict], warnings: [String], requiredBytes: Int64, credentialDestination: URL? = nil, sharedDestination: URL? = nil) {
        self.id = id
        self.operationID = operationID ?? id
        self.source = source
        self.destination = destination
        self.credentialDestination = credentialDestination ?? destination.appending(path: "auth.json")
        self.sharedDestination = sharedDestination ?? destination
        self.backup = backup
        self.mode = mode
        self.identity = identity
        self.sourceAuthDigest = sourceAuthDigest
        self.reviewedDataDigest = reviewedDataDigest
        self.manifest = manifest
        self.conflicts = conflicts
        self.warnings = warnings
        self.requiredBytes = requiredBytes
    }

    private enum CodingKeys: String, CodingKey {
        case id, operationID, source, destination, credentialDestination, sharedDestination, backup, mode,
             identity, sourceAuthDigest, reviewedDataDigest, manifest, conflicts, warnings,
             requiredBytes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let destination = try values.decode(URL.self, forKey: .destination)
        self.id = try values.decode(UUID.self, forKey: .id)
        self.operationID = try values.decodeIfPresent(UUID.self, forKey: .operationID) ?? id
        self.source = try values.decode(URL.self, forKey: .source)
        self.destination = destination
        self.credentialDestination = try values.decodeIfPresent(URL.self, forKey: .credentialDestination)
            ?? destination.appending(path: "auth.json")
        self.sharedDestination = try values.decodeIfPresent(URL.self, forKey: .sharedDestination)
            ?? destination
        self.backup = try values.decode(URL.self, forKey: .backup)
        self.mode = try values.decode(ImportMode.self, forKey: .mode)
        self.identity = try values.decode(AccountIdentity.self, forKey: .identity)
        self.sourceAuthDigest = try values.decode(String.self, forKey: .sourceAuthDigest)
        self.reviewedDataDigest = try values.decode(String.self, forKey: .reviewedDataDigest)
        self.manifest = try values.decode([ManifestEntry].self, forKey: .manifest)
        self.conflicts = try values.decode([SettingConflict].self, forKey: .conflicts)
        self.warnings = try values.decode([String].self, forKey: .warnings)
        self.requiredBytes = try values.decode(Int64.self, forKey: .requiredBytes)
    }
}

public struct ImportResult: Codable, Sendable {
    public var account: AccountRecord
    public var backup: URL
    public var importedFiles: Int
    public var importedChats: Int
    public var unresolved: [String]
    public var verification: VerificationResult

    public init(account: AccountRecord, backup: URL, importedFiles: Int, importedChats: Int, unresolved: [String], verification: VerificationResult) {
        self.account = account
        self.backup = backup
        self.importedFiles = importedFiles
        self.importedChats = importedChats
        self.unresolved = unresolved
        self.verification = verification
    }
}

public struct SwitchResult: Codable, Sendable {
    public var accountID: UUID
    public var backup: URL
    public var previousAccountID: UUID?

    public init(accountID: UUID, backup: URL, previousAccountID: UUID?) {
        self.accountID = accountID
        self.backup = backup
        self.previousAccountID = previousAccountID
    }
}

public struct AccountDeletionResult: Codable, Sendable {
    public var accountID: UUID
    public var replacementDefaultAccountID: UUID?
    public var removedManagedHome: Bool
    public var removedCredential: Bool

    public init(
        accountID: UUID,
        replacementDefaultAccountID: UUID?,
        removedManagedHome: Bool,
        removedCredential: Bool
    ) {
        self.accountID = accountID
        self.replacementDefaultAccountID = replacementDefaultAccountID
        self.removedManagedHome = removedManagedHome
        self.removedCredential = removedCredential
    }
}

public enum RecoveryPhase: String, Codable, Sendable { case prepared, backedUp, staged, published, registryCommitted, completed, rolledBack, conflicted }

public enum RecoveryConflictChoice: String, Codable, Sendable {
    case preserveCurrent
    case restoreBackup
}

public struct RecoveryItem: Codable, Equatable, Sendable {
    public var destination: URL
    public var backup: URL?
    public var expectedDigest: String
    public var previousDigest: String?
    public var temporary: URL?

    public init(destination: URL, backup: URL?, expectedDigest: String, previousDigest: String? = nil, temporary: URL? = nil) {
        self.destination = destination
        self.backup = backup
        self.expectedDigest = expectedDigest
        self.previousDigest = previousDigest
        self.temporary = temporary
    }
}

public struct RecoveryOperation: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: String
    public var phase: RecoveryPhase
    public var source: URL
    public var destination: URL
    public var backup: URL
    public var expectedDigest: String?
    public var touchedItems: [RecoveryItem]?
    public var previousDigest: String?
    public var registryAccountID: UUID?
    public var previousDefaultAccountID: UUID?
    public var registryCredentialDigest: String?
    public var previousAccount: AccountRecord?
    public var setsDefaultAccount: Bool?

    public init(id: UUID, kind: String, phase: RecoveryPhase, source: URL, destination: URL, backup: URL, expectedDigest: String? = nil, touchedItems: [RecoveryItem]? = nil, previousDigest: String? = nil, registryAccountID: UUID? = nil, previousDefaultAccountID: UUID? = nil, registryCredentialDigest: String? = nil, previousAccount: AccountRecord? = nil, setsDefaultAccount: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.phase = phase
        self.source = source
        self.destination = destination
        self.backup = backup
        self.expectedDigest = expectedDigest
        self.touchedItems = touchedItems
        self.previousDigest = previousDigest
        self.registryAccountID = registryAccountID
        self.previousDefaultAccountID = previousDefaultAccountID
        self.registryCredentialDigest = registryCredentialDigest
        self.previousAccount = previousAccount
        self.setsDefaultAccount = setsDefaultAccount
    }
}

public enum RecoveryOutcome: String, Codable, Sendable { case completed, rolledBack, conflict, noAction }

public struct RecoveryResult: Codable, Sendable {
    public var operationID: UUID
    public var outcome: RecoveryOutcome
    public var message: String

    public init(operationID: UUID, outcome: RecoveryOutcome, message: String) {
        self.operationID = operationID
        self.outcome = outcome
        self.message = message
    }
}

public struct LinkedSettingsDivergence: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(accountID.uuidString):\(relativePath)" }
    public var accountID: UUID
    public var relativePath: String
    public var localPath: URL
    public var intendedTarget: URL
    public var localFingerprint: String
    public var backupRoot: URL

    public init(accountID: UUID, relativePath: String, localPath: URL, intendedTarget: URL, localFingerprint: String, backupRoot: URL) {
        self.accountID = accountID
        self.relativePath = relativePath
        self.localPath = localPath
        self.intendedTarget = intendedTarget
        self.localFingerprint = localFingerprint
        self.backupRoot = backupRoot
    }
}

public struct LinkedSettingRepairResult: Codable, Sendable {
    public var accountID: UUID
    public var relativePath: String
    public var backup: URL

    public init(accountID: UUID, relativePath: String, backup: URL) {
        self.accountID = accountID
        self.relativePath = relativePath
        self.backup = backup
    }
}

public struct ManagerStatus: Codable, Equatable, Sendable {
    public var accounts: [AccountRecord]
    public var defaultAccountIDs: [String: UUID]
    public var sharedRoot: URL
    public var pendingRecovery: [RecoveryOperation]
    public var linkedSettingsDivergences: [LinkedSettingsDivergence]

    public init(
        accounts: [AccountRecord],
        defaultAccountID: UUID?,
        defaultAccountIDs: [String: UUID] = [:],
        sharedRoot: URL,
        pendingRecovery: [RecoveryOperation],
        linkedSettingsDivergences: [LinkedSettingsDivergence] = []
    ) {
        self.accounts = accounts
        self.defaultAccountIDs = defaultAccountIDs
        if let defaultAccountID,
           let providerID = accounts.first(where: { $0.id == defaultAccountID })?.identity.providerID,
           self.defaultAccountIDs[providerID.rawValue] == nil {
            self.defaultAccountIDs[providerID.rawValue] = defaultAccountID
        }
        self.sharedRoot = sharedRoot
        self.pendingRecovery = pendingRecovery
        self.linkedSettingsDivergences = linkedSettingsDivergences
    }

    public var defaultAccountID: UUID? {
        get { defaultAccountID(for: .codex) }
        set { setDefaultAccountID(newValue, for: .codex) }
    }

    public func defaultAccountID(for providerID: ProviderID) -> UUID? {
        defaultAccountIDs[providerID.rawValue]
    }

    public func isDefault(_ account: AccountRecord) -> Bool {
        defaultAccountID(for: account.identity.providerID) == account.id
    }

    public var firstDefaultAccountID: UUID? {
        accounts.first(where: isDefault)?.id
    }

    public mutating func setDefaultAccountID(_ accountID: UUID?, for providerID: ProviderID) {
        if let accountID {
            defaultAccountIDs[providerID.rawValue] = accountID
        } else {
            defaultAccountIDs.removeValue(forKey: providerID.rawValue)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case accounts, defaultAccountID, defaultAccountIDs, sharedRoot, pendingRecovery
        case linkedSettingsDivergences
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try values.decode([AccountRecord].self, forKey: .accounts)
        defaultAccountIDs = try values.decodeIfPresent(
            [String: UUID].self, forKey: .defaultAccountIDs) ?? [:]
        if let legacy = try values.decodeIfPresent(UUID.self, forKey: .defaultAccountID),
           let providerID = accounts.first(where: { $0.id == legacy })?.identity.providerID,
           defaultAccountIDs[providerID.rawValue] == nil {
            defaultAccountIDs[providerID.rawValue] = legacy
        }
        sharedRoot = try values.decode(URL.self, forKey: .sharedRoot)
        pendingRecovery = try values.decode([RecoveryOperation].self, forKey: .pendingRecovery)
        linkedSettingsDivergences = try values.decodeIfPresent(
            [LinkedSettingsDivergence].self, forKey: .linkedSettingsDivergences) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(accounts, forKey: .accounts)
        try values.encodeIfPresent(defaultAccountID, forKey: .defaultAccountID)
        try values.encode(defaultAccountIDs, forKey: .defaultAccountIDs)
        try values.encode(sharedRoot, forKey: .sharedRoot)
        try values.encode(pendingRecovery, forKey: .pendingRecovery)
        try values.encode(linkedSettingsDivergences, forKey: .linkedSettingsDivergences)
    }
}

public struct LaunchSpec: Codable, Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL?

    public init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

public struct AccountCheckResult: Sendable {
    public var verification: VerificationResult
    public var usage: CodexAccountUsageSnapshot?

    public init(
        verification: VerificationResult,
        usage: CodexAccountUsageSnapshot? = nil
    ) {
        self.verification = verification
        self.usage = usage
    }
}

public enum AIManagerError: LocalizedError, Equatable {
    case invalidSource(String)
    case unsupportedSource(String)
    case unresolvedIdentity
    case missingConflictDecisions([String])
    case sourceChanged
    case unsafePath(String)
    case activeCodexProcesses
    case writerStateUnknown
    case credentialConflict
    case recoveryRequired
    case accountNotFound
    case defaultAccountReplacementRequired
    case invalidReplacementAccount
    case cliNotFound
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSource(let value): "Invalid source: \(value)"
        case .unsupportedSource(let value): "Unsupported source: \(value)"
        case .unresolvedIdentity: "Account identity is unresolved. Sign in or choose a supported credential."
        case .missingConflictDecisions(let paths): "Choose how to resolve: \(paths.joined(separator: ", "))"
        case .sourceChanged: "The source changed after review. Review the import again."
        case .unsafePath(let value): "Unsafe path: \(value)"
        case .activeCodexProcesses: "A Codex process is using the default home. Stop it before switching."
        case .writerStateUnknown: "Could not establish whether the default home is in use."
        case .credentialConflict: "Credential copies diverged. Sign in again or resolve the conflict."
        case .recoveryRequired: "Finish recovery before starting another change."
        case .accountNotFound: "Account not found."
        case .defaultAccountReplacementRequired: "Choose another saved account before deleting the default account."
        case .invalidReplacementAccount: "The replacement account must be a different saved account."
        case .cliNotFound: "Codex CLI was not found."
        case .operationFailed(let value): value
        }
    }
}
