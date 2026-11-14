import Foundation
import AIManagerCore

// Outbound shapes. Built from core values the same way the CLI `Safe*` wrappers are:
// no credential digest, token, cookie, key, or auth-file content. Ids are lowercase UUID strings, paths are plain paths.

struct InitializeResult: Encodable {
    let protocolVersion: Int
    let serverVersion: String
    let platform: String
    let methods: [String]
}

struct UsageDetailParams: Decodable {
    let accountID: String
    let force: Bool?
}

struct WireStatus: Encodable {
    let accounts: [WireAccount]
    let defaultAccountIDs: [String: String]
    let sharedRoot: String
    let pendingRecovery: [WireRecovery]
    let linkedSettingsDivergences: [WireDivergence]

    init(_ status: ManagerStatus) {
        accounts = status.accounts.map { WireAccount($0, isDefault: status.isDefault($0)) }
        defaultAccountIDs = status.defaultAccountIDs.mapValues { $0.uuidString.lowercased() }
        sharedRoot = status.sharedRoot.path
        pendingRecovery = status.pendingRecovery.map(WireRecovery.init)
        linkedSettingsDivergences = status.linkedSettingsDivergences.map(WireDivergence.init)
    }
}

struct WireAccount: Encodable {
    let id: String
    let identity: AccountIdentity
    let isDefault: Bool
    let autoImported: Bool
    let verification: VerificationResult
    let importedAt: Date
    let lastUsedAt: Date?
    let home: String
    let source: String
    let credentialFile: String

    init(_ account: AccountRecord, isDefault: Bool) {
        id = account.id.uuidString.lowercased()
        identity = account.identity
        self.isDefault = isDefault
        autoImported = account.autoImported
        verification = account.verification
        importedAt = account.importedAt
        lastUsedAt = account.lastUsedAt
        home = account.home.path
        source = account.source.path
        credentialFile = account.credentialFile.path
    }
}

struct WireRecovery: Encodable {
    let id: String
    let kind: String
    let phase: RecoveryPhase
    let source: String
    let destination: String
    let backup: String

    init(_ operation: RecoveryOperation) {
        id = operation.id.uuidString.lowercased()
        kind = operation.kind
        phase = operation.phase
        source = operation.source.path
        destination = operation.destination.path
        backup = operation.backup.path
    }
}

struct WireDivergence: Encodable {
    let accountID: String
    let relativePath: String
    let localPath: String
    let intendedTarget: String

    init(_ divergence: LinkedSettingsDivergence) {
        accountID = divergence.accountID.uuidString.lowercased()
        relativePath = divergence.relativePath
        localPath = divergence.localPath.path
        intendedTarget = divergence.intendedTarget.path
    }
}

/// Lossless usage for one account: `codex` (every bucket, extras, daily rows) for Codex, `usage` for the rest.
struct WireUsage: Encodable {
    let accountID: String
    let providerID: String
    let usage: ProviderUsage?
    let codex: CodexAccountUsageSnapshot?

    init(_ account: AccountRecord, usage: ProviderUsage? = nil, codex: CodexAccountUsageSnapshot? = nil) {
        accountID = account.id.uuidString.lowercased()
        providerID = account.identity.providerID.rawValue
        self.usage = usage
        self.codex = codex
    }
}
