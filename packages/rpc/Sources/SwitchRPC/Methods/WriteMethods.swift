import Foundation
import AIManagerCore
import SwitchAppModel

/// An inbound secret (architecture.md 2.8): decoded from a string, printed as `<redacted>`, never echoed.
struct SecretString: Decodable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: String
    init(from decoder: Decoder) throws { value = try decoder.singleValueContainer().decode(String.self) }
    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }
}

private struct AccountActionParams: Decodable {
    let accountID: String
    let name: String?
}

private struct ProviderParams: Decodable {
    let providerID: String
    let fields: [String: SecretString]?
}

private struct DroidImportParams: Decodable {
    let name: String
    let apiKey: SecretString?
}

private struct LoginStartParams: Decodable {
    let providerID: String?
    let accountID: String?
}

private struct LoginParams: Decodable {
    let sessionID: String
    let credentialChoice: ConflictChoice?
    let droidName: String?
    let droidAPIKey: SecretString?
    let code: SecretString?
}

private struct ImportParams: Decodable {
    let source: String?
    let mode: ImportMode?
    let planID: String?
    let relativePath: String?
    let decisions: [String: ConflictChoice]?
}

private struct ConfirmParams: Decodable { let confirm: String? }
private struct ReorderParams: Decodable { let accountIDs: [String] }
private struct EnabledParams: Decodable { let enabled: Bool }
/// `key` null or empty removes the saved key.
private struct UsageKeyParams: Decodable {
    let accountID: String
    let key: SecretString?
}
private struct ResolveParams: Decodable {
    let operationID: String
    let choice: RecoveryConflictChoice
}
private struct RepairParams: Decodable {
    let accountID: String
    let relativePath: String
    let fingerprint: String
}
private struct MissionParams: Decodable {
    let missionID: String
    let accountID: String?
}
private struct ForceParams: Decodable { let force: Bool? }
private struct PermissionParams: Decodable { let status: String }
private struct DismissParams: Decodable { let which: String? }

/// User actions of architecture.md section 2.9. Each goes through the engine's action lane (`-32001` while another
/// runs) and replies `{status, notice?, error?, confirmation?, accountID?, login?, plan?}`.
extension RPCServer {
    static let writeMethods = [
        "accounts.setDefault", "accounts.check", "usage.refresh", "accounts.rename", "accounts.delete",
        "providers.add", "providers.importLive", "droid.import",
        "login.start", "login.check", "login.submitCode", "login.cancel",
        "import.plan", "import.reviewExternal", "import.commit", "import.discard",
        "accounts.open", "accounts.reorder", "app.refresh", "tray.opened", "claude.shellIntegration.set",
        "droid.setUsageKey", "recovery.recover", "recovery.resolve", "accounts.repairLink", "usage.clearCache",
        "history.reindex", "history.clearIndex", "providerStatus.refresh", "activity.refresh", "droid.setMissionOwner",
        "droid.resumeMission", "droid.startMissionHere", "droid.refreshConversations", "providers.detectSignedIn",
        "notifications.setPermission", "notices.dismiss",
    ]
    static let confirmationLifetime: TimeInterval = 120

    /// Nil when `method` is not a write method.
    func writeMethod(_ method: String, frame: Data) async throws -> (any Encodable)? {
        guard Self.writeMethods.contains(method) else { return nil }
        switch method {
        case "accounts.open":
            let id = try accountID(try params(AccountActionParams.self, method: method, frame: frame).accountID)
            return try await confirmable(method, frame) { try await self.engine.openAccount(id, confirmed: $0) }
        case "accounts.reorder":
            let ids = try params(ReorderParams.self, method: method, frame: frame).accountIDs.map(accountID)
            return try await engine.reorderAccounts(ids)
        case "app.refresh": return try await engine.refreshAll()
        case "tray.opened": return try await engine.trayOpened()
        case "claude.shellIntegration.set":
            return try await engine.setClaudeShellIntegration(try params(EnabledParams.self, method: method, frame: frame).enabled)
        case "droid.setUsageKey":
            let params = try params(UsageKeyParams.self, method: method, frame: frame)
            return try await engine.setDroidUsageKey(try accountID(params.accountID), key: params.key?.value ?? "")
        case "recovery.recover":
            return try await confirmable(method, frame) { try await self.engine.recover(confirmed: $0) }
        case "recovery.resolve":
            let params = try params(ResolveParams.self, method: method, frame: frame)
            guard let id = UUID(uuidString: params.operationID) else {
                throw RPCError(-32602, "invalidParams", "operationID must be a pending recovery id.")
            }
            return try await confirmable(method, frame) {
                try await self.engine.resolveRecovery(id, choice: params.choice, confirmed: $0)
            }
        case "accounts.repairLink":
            let params = try params(RepairParams.self, method: method, frame: frame)
            return try await engine.repairLink(try accountID(params.accountID), relativePath: params.relativePath,
                                               fingerprint: params.fingerprint)
        case "usage.clearCache": return try await engine.clearUsageCache()
        case "history.reindex": return try await engine.reindexHistory()
        case "history.clearIndex": return try await engine.clearHistoryIndex()
        case "providerStatus.refresh": return await engine.refreshProviderStatusNow()
        case "activity.refresh":
            await engine.refreshActivity(force: (try? params(ForceParams.self, method: method, frame: frame))?.force ?? false)
            return await engine.activityValue()
        case "droid.setMissionOwner", "droid.resumeMission", "droid.startMissionHere":
            let params = try params(MissionParams.self, method: method, frame: frame)
            switch method {
            case "droid.setMissionOwner":
                guard let owner = params.accountID else { throw RPCError(-32602, "invalidParams", "Name the accountID.") }
                return try await engine.setMissionOwner(params.missionID, accountID: try accountID(owner))
            case "droid.resumeMission":
                return try await confirmable(method, frame) { try await self.engine.resumeMission(params.missionID, confirmed: $0) }
            default:
                return try await confirmable(method, frame) { try await self.engine.startMissionHere(params.missionID, confirmed: $0) }
            }
        case "droid.refreshConversations":
            // Nil (no Droid account, or nothing to do) answers as an empty report.
            return await engine.refreshDroidConversations() ?? DroidSessionBindingReport()
        case "providers.detectSignedIn": return await engine.detectSignedIn()
        case "notifications.setPermission":
            let status = try params(PermissionParams.self, method: method, frame: frame).status
            guard ["authorized", "denied"].contains(status) else {
                throw RPCError(-32602, "invalidParams", "status must be authorized or denied.")
            }
            setNotificationPermission(status == "authorized")
            return ActionResult.done()
        case "notices.dismiss":
            let which = (try? params(DismissParams.self, method: method, frame: frame))?.which
            guard [nil, "error", "notice"].contains(which) else {
                throw RPCError(-32602, "invalidParams", "which must be error or notice, or absent for both.")
            }
            await engine.dismissNotices(error: which != "notice", notice: which != "error")
            return ActionResult.done()
        case "accounts.setDefault", "accounts.check", "usage.refresh", "accounts.rename", "accounts.delete":
            let params = try params(AccountActionParams.self, method: method, frame: frame)
            let id = try accountID(params.accountID)
            switch method {
            case "accounts.setDefault": return try await confirmable(method, frame) { try await self.engine.setDefault(id, confirmed: $0) }
            case "accounts.check": return try await engine.checkAccount(id)
            case "usage.refresh": return try await engine.refreshUsage(id)
            case "accounts.delete": return try await confirmable(method, frame) { try await self.engine.deleteAccount(id, confirmed: $0) }
            default:
                guard let name = params.name else { throw RPCError(-32602, "invalidParams", "accounts.rename needs a name.") }
                return try await engine.renameAccount(id, to: name)
            }
        case "providers.add", "providers.importLive":
            let params = try params(ProviderParams.self, method: method, frame: frame)
            let provider = ProviderID(rawValue: params.providerID)
            guard method == "providers.add" else { return try await engine.importLiveAccount(provider) }
            return try await engine.addProviderAccount(provider, fields: (params.fields ?? [:]).mapValues(\.value))
        case "droid.import":
            let params = try params(DroidImportParams.self, method: method, frame: frame)
            return try await confirmable(method, frame) {
                try await self.engine.importDroidAccount(name: params.name, apiKey: params.apiKey?.value, confirmed: $0)
            }
        case "login.start":
            let params = try params(LoginStartParams.self, method: method, frame: frame)
            let account = try params.accountID.map(accountID)
            return try await confirmable(method, frame) {
                try await self.engine.startLogin(providerID: params.providerID.map(ProviderID.init(rawValue:)),
                                                 accountID: account, confirmed: $0)
            }
        case "login.check", "login.submitCode", "login.cancel":
            let params = try params(LoginParams.self, method: method, frame: frame)
            guard let session = UUID(uuidString: params.sessionID) else {
                throw RPCError(-32602, "invalidParams", "sessionID must be a sign-in session UUID.")
            }
            switch method {
            case "login.check":
                return try await confirmable(method, frame) {
                    try await self.engine.checkLogin(session, credentialChoice: params.credentialChoice,
                                                     droidName: params.droidName, droidAPIKey: params.droidAPIKey?.value,
                                                     confirmed: $0)
                }
            case "login.submitCode":
                guard let code = params.code else { throw RPCError(-32602, "invalidParams", "login.submitCode needs a code.") }
                return try await engine.submitLoginCode(session, code: code.value)
            default: return try await engine.cancelLogin(session)
            }
        default:
            let params = try params(ImportParams.self, method: method, frame: frame)
            if method == "import.plan" {
                guard let source = params.source else { throw RPCError(-32602, "invalidParams", "import.plan needs a source.") }
                return try await engine.planImport(source: URL(fileURLWithPath: source), mode: params.mode ?? .full)
            }
            guard let plan = params.planID.flatMap(UUID.init(uuidString:)) else {
                throw RPCError(-32602, "invalidParams", "\(method) needs the planID from import.plan.")
            }
            switch method {
            case "import.reviewExternal":
                guard let path = params.relativePath else { throw RPCError(-32602, "invalidParams", "Name the relativePath.") }
                return try await engine.reviewExternalSetting(planID: plan, relativePath: path)
            case "import.commit": return try await engine.commitImport(planID: plan, decisions: params.decisions ?? [:])
            default:
                try await engine.discardImport(planID: plan)
                return ActionResult.done()
            }
        }
    }

    /// Two-step confirmation (architecture.md 2.6). A valid `confirm` token grants every kind it carries; a new
    /// confirmation gets a fresh token that carries those kinds plus the new one.
    func confirmable(_ method: String, _ frame: Data,
                             _ run: (Set<ConfirmationRequest.Kind>) async throws -> ActionResult) async throws -> ActionResult {
        let binding = Self.binding(method, frame)
        let token = (try? params(ConfirmParams.self, method: method, frame: frame))?.confirm
        let granted = try token.map { try redeem($0, binding) } ?? []
        var result = try await run(granted)
        if let kind = result.confirmation?.kind { result.confirmation?.token = issue(binding, granted.union([kind])) }
        return result
    }

    /// The method and a hash of its params without `confirm`, so a token works only for the same request.
    private static func binding(_ method: String, _ frame: Data) -> Int {
        var params = ((try? JSONSerialization.jsonObject(with: frame)) as? [String: Any])?["params"] as? [String: Any] ?? [:]
        params["confirm"] = nil
        var hasher = Hasher()
        hasher.combine(method)
        hasher.combine((try? JSONSerialization.data(withJSONObject: params, options: .sortedKeys)) ?? Data())
        return hasher.finalize()
    }

    /// A single-use token, valid for 120 s.
    private func issue(_ binding: Int, _ grants: Set<ConfirmationRequest.Kind>) -> String {
        let token = "cf-\(UUID().uuidString.lowercased())"
        lock.lock()
        defer { lock.unlock() }
        let now = clock.now
        confirmations = confirmations.filter { $0.value.expires > now }
        confirmations[token] = (binding, grants, now.addingTimeInterval(Self.confirmationLifetime))
        return token
    }

    private func redeem(_ token: String, _ binding: Int) throws -> Set<ConfirmationRequest.Kind> {
        lock.lock()
        let entry = confirmations.removeValue(forKey: token)
        lock.unlock()
        guard let entry, entry.binding == binding, entry.expires > clock.now else {
            throw RPCError(-32004, "stale", "The confirmation expired or belongs to another request. Try the action again.")
        }
        return entry.grants
    }
}
