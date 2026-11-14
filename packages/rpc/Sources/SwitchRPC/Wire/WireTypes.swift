import Foundation
import AIManagerCore
import SwitchAppModel

// Outbound shapes. Built from core values the same way the CLI `Safe*` wrappers are:
// no credential digest, token, cookie, key, or auth-file content. Ids are lowercase UUID strings, paths are plain paths.

struct InitializeResult: Encodable {
    struct Features: Encodable {
        let autoSwitchRestart: Bool
        let claudeUsageProbe: Bool
    }

    let protocolVersion: Int
    let serverVersion: String
    /// major * 1,000,000 + minor * 1,000 + patch; 0 when the version is not three numbers.
    let buildNumber: Int
    let platform: String
    let methods: [String]
    let topics: [String]
    let settingsSchemaVersion: Int
    let features: Features
}

/// Embeds any encodable value, such as a topic value, in a reply.
struct AnyEncodable: Encodable {
    let value: any Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

struct StateParams: Decodable {
    let topics: [String]
}

struct SettingsGetParams: Decodable {
    let keys: [String]?
}

struct SettingsResetParams: Decodable {
    let group: String?
}

/// `value` null or missing removes the stored value, so the default applies again.
struct SettingsSetParams: Decodable {
    let key: String
    let value: SettingValue?
}

/// One topic in the `state.subscribe` reply.
struct WireTopicState: Encodable {
    let rev: Int
    let value: AnyEncodable
}

/// `state.changed` params.
struct WireTopicChange: Encodable {
    let topic: String
    let rev: Int
    let value: AnyEncodable
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
    /// A digest of the changed entry; `accounts.repairLink` sends it back so a newer change is not overwritten.
    let fingerprint: String

    init(_ divergence: LinkedSettingsDivergence) {
        accountID = divergence.accountID.uuidString.lowercased()
        relativePath = divergence.relativePath
        localPath = divergence.localPath.path
        intendedTarget = divergence.intendedTarget.path
        fingerprint = divergence.localFingerprint
    }
}

/// Lossless usage for one account: `codex` (every bucket, extras, daily rows) for Codex, `usage` for the rest.
struct WireUsage: Encodable {
    let accountID: String
    let providerID: String
    let usage: ProviderUsage?
    let codex: CodexAccountUsageSnapshot?
    /// Codex only: every cached day (the activity heatmap), merged across checks, oldest first.
    let daily: [CodexDailyUsageSnapshot]?

    init(_ account: AccountRecord, usage: ProviderUsage? = nil, codex: CodexAccountUsageSnapshot? = nil,
         daily: [CodexDailyUsageSnapshot]? = nil) {
        accountID = account.id.uuidString.lowercased()
        providerID = account.identity.providerID.rawValue
        self.usage = usage
        self.codex = codex
        self.daily = daily
    }
}
