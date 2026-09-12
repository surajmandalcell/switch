import Foundation

public struct ManagerPaths: Sendable {
    public var applicationSupport: URL
    public var defaultHome: URL
    public var sharedRoot: URL
    public var orcaAccountsRoot: URL
    public var codexExecutable: URL?
    public var isolationRoot: URL?

    public init(
        applicationSupport: URL,
        defaultHome: URL,
        sharedRoot: URL,
        orcaAccountsRoot: URL,
        codexExecutable: URL? = nil,
        isolationRoot: URL? = nil
    ) {
        self.applicationSupport = applicationSupport
        self.defaultHome = defaultHome
        self.sharedRoot = sharedRoot
        self.orcaAccountsRoot = orcaAccountsRoot
        self.codexExecutable = codexExecutable
        self.isolationRoot = isolationRoot
    }

    public static func standard(fileManager: FileManager = .default) -> Self {
        let home = fileManager.homeDirectoryForCurrentUser
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return .init(
            applicationSupport: support.appending(path: "AI Manager", directoryHint: .isDirectory),
            defaultHome: home.appending(path: ".codex", directoryHint: .isDirectory),
            sharedRoot: home.appending(path: ".codex", directoryHint: .isDirectory),
            orcaAccountsRoot: support.appending(path: "Orca/codex-accounts", directoryHint: .isDirectory)
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
            paths.defaultHome = value.appending(path: "default-home", directoryHint: .isDirectory)
            paths.sharedRoot = value.appending(path: "shared-root", directoryHint: .isDirectory)
            paths.orcaAccountsRoot = value.appending(path: "orca-accounts", directoryHint: .isDirectory)
        }
        if let value = url("AI_MANAGER_DEFAULT_HOME"), paths.isolationRoot == nil || CoreSupportForPaths.contains(value, in: paths.isolationRoot!) { paths.defaultHome = value }
        if let value = url("AI_MANAGER_SHARED_ROOT"), paths.isolationRoot == nil || CoreSupportForPaths.contains(value, in: paths.isolationRoot!) { paths.sharedRoot = value }
        if let value = url("AI_MANAGER_ORCA_ACCOUNTS_ROOT"), paths.isolationRoot == nil || CoreSupportForPaths.contains(value, in: paths.isolationRoot!) { paths.orcaAccountsRoot = value }
        if let value = url("AI_MANAGER_CODEX_EXECUTABLE") { paths.codexExecutable = value }
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
        providerID == .codex && authMode == .chatGPT && userID != nil && accountID != nil
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

public struct VerificationResult: Codable, Sendable {
    public var state: VerificationState
    public var checkedAt: Date?
    public var detail: String

    public init(state: VerificationState, checkedAt: Date? = nil, detail: String) {
        self.state = state
        self.checkedAt = checkedAt
        self.detail = detail
    }
}

public struct AccountRecord: Identifiable, Codable, Sendable {
    public var id: UUID
    public var identity: AccountIdentity
    public var home: URL
    public var source: URL
    public var importedAt: Date
    public var verification: VerificationResult
    public var lastUsedAt: Date?
    public var credentialDigest: String

    public init(id: UUID, identity: AccountIdentity, home: URL, source: URL, importedAt: Date, verification: VerificationResult, lastUsedAt: Date? = nil, credentialDigest: String) {
        self.id = id
        self.identity = identity
        self.home = home
        self.source = source
        self.importedAt = importedAt
        self.verification = verification
        self.lastUsedAt = lastUsedAt
        self.credentialDigest = credentialDigest
    }
}

public struct HistorySummary: Codable, Sendable {
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
    public var source: URL
    public var destination: URL
    public var backup: URL
    public var mode: ImportMode
    public var identity: AccountIdentity
    public var sourceAuthDigest: String
    public var reviewedDataDigest: String
    public var manifest: [ManifestEntry]
    public var conflicts: [SettingConflict]
    public var warnings: [String]
    public var requiredBytes: Int64

    public init(id: UUID, source: URL, destination: URL, backup: URL, mode: ImportMode, identity: AccountIdentity, sourceAuthDigest: String, reviewedDataDigest: String, manifest: [ManifestEntry], conflicts: [SettingConflict], warnings: [String], requiredBytes: Int64) {
        self.id = id
        self.source = source
        self.destination = destination
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

public enum RecoveryPhase: String, Codable, Sendable { case prepared, backedUp, staged, published, registryCommitted, completed, rolledBack, conflicted }

public enum RecoveryConflictChoice: String, Codable, Sendable {
    case preserveCurrent
    case restoreBackup
}

public struct RecoveryItem: Codable, Sendable {
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

public struct RecoveryOperation: Identifiable, Codable, Sendable {
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

    public init(id: UUID, kind: String, phase: RecoveryPhase, source: URL, destination: URL, backup: URL, expectedDigest: String? = nil, touchedItems: [RecoveryItem]? = nil, previousDigest: String? = nil, registryAccountID: UUID? = nil, previousDefaultAccountID: UUID? = nil, registryCredentialDigest: String? = nil, previousAccount: AccountRecord? = nil) {
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

public struct LinkedSettingsDivergence: Identifiable, Codable, Sendable {
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

public struct ManagerStatus: Codable, Sendable {
    public var accounts: [AccountRecord]
    public var defaultAccountID: UUID?
    public var sharedRoot: URL
    public var pendingRecovery: [RecoveryOperation]
    public var linkedSettingsDivergences: [LinkedSettingsDivergence]

    public init(accounts: [AccountRecord], defaultAccountID: UUID?, sharedRoot: URL, pendingRecovery: [RecoveryOperation], linkedSettingsDivergences: [LinkedSettingsDivergence] = []) {
        self.accounts = accounts
        self.defaultAccountID = defaultAccountID
        self.sharedRoot = sharedRoot
        self.pendingRecovery = pendingRecovery
        self.linkedSettingsDivergences = linkedSettingsDivergences
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
        case .cliNotFound: "Codex CLI was not found."
        case .operationFailed(let value): value
        }
    }
}
