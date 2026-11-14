import Foundation
import AIManagerCore

/// A dialog the user must accept before the action runs (architecture.md 2.6). The helper adds the token.
public struct ConfirmationRequest: Codable, Equatable, Sendable {
    /// What the user allows: `droidRunning`, `droidDuplicate`, `droidSignIn`, or `delete`. The helper's token
    /// carries every kind allowed so far, so a second confirmation keeps the first.
    public enum Kind: String, Codable, Sendable { case droidRunning, droidDuplicate, droidSignIn, delete }
    public var kind: Kind
    public var token: String?
    public var title: String
    public var message: String
    public var action: String

    static func droid(_ error: DroidAccountError, _ text: String) -> ConfirmationRequest? {
        switch error {
        case .running: ConfirmationRequest(kind: .droidRunning, title: "Droid is running", message: text, action: "Switch")
        case .duplicateIdentity: ConfirmationRequest(kind: .droidDuplicate, title: "Add this Droid account again?",
                                                     message: text, action: "Add anyway")
        case .confirmSignIn: ConfirmationRequest(kind: .droidSignIn, title: "Sign in to this Droid account?",
                                                 message: text, action: "Sign in")
        default: nil
        }
    }
}

/// A sign-in session after `login.start`, `login.check`, or `login.submitCode`.
public struct LoginStatus: Codable, Equatable, Sendable {
    public var sessionID: String
    public var providerID: String
    /// `waitingForLogin`, `needsAttention`, `credentialChoiceRequired`, or `completed`.
    public var state: String
    public var message: String
}

/// The reply of a user action (architecture.md 2.2).
public struct ActionResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case done, needsConfirmation }
    public var status: Status
    public var notice: String?
    /// A check that ran and found a problem: the red-bar text. The action itself did not fail.
    public var error: String?
    public var confirmation: ConfirmationRequest?
    /// The account the action saved.
    public var accountID: String?
    public var login: LoginStatus?
    public var plan: ImportPlanSummary?

    public static func done(notice: String? = nil, error: String? = nil) -> ActionResult {
        ActionResult(status: .done, notice: notice, error: error)
    }

    static func confirm(_ request: ConfirmationRequest) -> ActionResult {
        ActionResult(status: .needsConfirmation, confirmation: request)
    }
}

/// User actions. Each runs in the action lane, calls the AccountManager API the Mac app calls, and copies its
/// failure to `notices`, as `AccountViewModel` does. `confirmed` holds the kinds the user already allowed.
extension AppEngine {
    /// The Mac `switchDefault`. A running Factory app needs a confirmation first.
    public func setDefault(_ id: UUID, confirmed: Set<ConfirmationRequest.Kind> = []) async throws -> ActionResult {
        let manager = manager
        return try await perform(failure: "Couldn’t change the default account.",
                                 recovery: "Resolve any item in Backup, then try again.") {
            guard let manager else { throw AppEngineError.unavailable }
            let providerID = try await self.account(id).identity.providerID
            let result: SwitchResult
            do {
                result = try await manager.switchDefault(to: id, allowRunningDroid: confirmed.contains(.droidRunning))
            } catch let error as DroidAccountError {
                guard case .running = error, let request = ConfirmationRequest.droid(error, self.describe(error)) else {
                    throw error
                }
                return .confirm(request)
            }
            await self.reloadAccounts()
            var notice = Self.switchNotice(providerID, result)
            // The Mac posts this as its own notification; the helper has no notify.post yet, so it joins the notice.
            if providerID == .droid, let missions = await self.unfinishedMissionsNotice(result, manager) {
                notice += " " + missions
            }
            await self.setNotice(notice)
            return .done(notice: notice)
        }
    }

    /// The Mac `checkAccount`: verify the saved files (and Codex usage). A failed check goes to the red bar.
    public func checkAccount(_ id: UUID) async throws -> ActionResult {
        let manager = manager
        return try await perform(failure: "Couldn’t check the account files.", recovery: "Try the check again.") {
            guard let manager else { throw AppEngineError.unavailable }
            _ = try await self.account(id)
            let result = await manager.checkAccount(accountID: id)
            if let usage = result.usage { try await self.codexCache?.upsertSuccess(accountID: id, snapshot: usage) }
            await self.reloadAccounts()
            switch result.verification.state {
            case .verifiedLocally, .verifiedWithCodex:
                await self.setNotice("Account checked.")
                return .done(notice: "Account checked.")
            default:
                let detail = self.masked(result.verification.detail)
                await self.setError(detail)
                return .done(error: detail)
            }
        }
    }

    /// Refreshes one account's usage now, ignoring age and cooldown. A user action, so the read is interactive:
    /// a rejected key is sent again and the Droid key may come from the login Keychain. The result lands on the
    /// row; a test home without `setRefreshesInIsolation` reads nothing, as on the Mac.
    public func refreshUsage(_ id: UUID) async throws -> ActionResult {
        try await perform {
            let providerID = try await self.account(id).identity.providerID
            guard await self.refreshes else { return .done() }
            if providerID == .codex {
                await self.refreshCodexAccount(id)
            } else {
                await self.refreshProviderAccounts([id], interactive: true)
            }
            return .done()
        }
    }

    /// Leaving a Droid account that owns unfinished missions: "2 unfinished Droid missions stay with <label>." The
    /// missions stay with it (Mac `announceUnfinishedMissions`).
    func unfinishedMissionsNotice(_ result: SwitchResult, _ manager: AccountManager) async -> String? {
        guard let previous = status?.accounts.first(where: { $0.id == result.previousAccountID }),
              let count = try? await manager.unfinishedDroidMissions(after: result), count > 0 else { return nil }
        return DroidMissionReader.unfinishedNotice(
            count: count, owner: AccountPresentation.label(previous.identity, PrivacySettings(settings)))
    }

    /// The saved account, loading the list first when `initialized` has not run yet.
    func account(_ id: UUID) async throws -> AccountRecord {
        if status == nil { await reloadAccounts() }
        guard let account = status?.accounts.first(where: { $0.id == id }) else { throw AIManagerError.accountNotFound }
        return account
    }

    /// The notice the Mac shows after a switch (`AccountViewModel.switchDefault`).
    static func switchNotice(_ providerID: ProviderID, _ result: SwitchResult) -> String {
        let name = AccountPresentation.providerName(providerID)
        let count = result.droidSessionBinding.map { $0.updatedCount + $0.unchangedCount } ?? 0
        let updated = "\(count) \(count == 1 ? "conversation" : "conversations") ready to resume."
        if let binding = result.droidSessionBinding, binding.pending {
            return "Account switched. Conversation updates are pending and will retry automatically. \(binding.warnings.joined(separator: " "))"
        }
        if let binding = result.droidSessionBinding, !binding.warnings.isEmpty {
            return "Account switched. \(updated) \(binding.warnings.joined(separator: " "))"
        }
        if ProviderCatalog.spec(providerID)?.style == .secret { return "\(name) usage checks will use this account." }
        if ![ProviderID.codex, .grokBuild, .droid, .claudeCode].contains(providerID) {
            return "\(name) sign-in files updated. Reopen the tool to load this account."
        }
        return count > 0 ? "New \(name) sessions will use this account. \(updated)"
            : "New \(name) sessions will use this account."
    }
}
