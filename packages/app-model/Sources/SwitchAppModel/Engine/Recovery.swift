import Foundation
import AIManagerCore

// shortcut: written from AccountViewModel.recover, resolveRecoveryConflict, and repairLinkedSetting beside the Mac
// copies; delete those when the Mac app adopts SwitchAppModel (needs the window gates).
/// Interrupted operations and linked-settings repair, as the Mac Backup page and account sheet do them.
extension AppEngine {
    /// The Mac `recover`: finish every pending operation. A running Factory app asks first.
    public func recover(confirmed: Set<ConfirmationRequest.Kind> = []) async throws -> ActionResult {
        try await perform(failure: "Couldn’t finish the interrupted operation.",
                          recovery: "Review the pending item and its protected backup before retrying.") {
            let manager = try self.requireManager()
            let results: [RecoveryResult]
            do {
                results = try await manager.recover(allowRunningDroid: confirmed.contains(.droidRunning))
            } catch let error as DroidAccountError {
                guard case .running = error, var request = ConfirmationRequest.droid(error, self.describe(error)) else {
                    throw error
                }
                request.action = "Recover"
                return .confirm(request)
            }
            await self.reloadAccounts()
            let notice = results.isEmpty ? "No backup work was needed."
                : results.contains { $0.outcome == .conflict } ? "Backup work needs your choice." : "Backup work finished."
            await self.setNotice(notice)
            return .done(notice: notice)
        }
    }

    /// The Mac `resolveRecoveryConflict`: keep the current files or restore the protected backup.
    public func resolveRecovery(_ id: UUID, choice: RecoveryConflictChoice,
                                confirmed: Set<ConfirmationRequest.Kind> = []) async throws -> ActionResult {
        try await perform(failure: "Couldn’t resolve the backup conflict.",
                          recovery: "Confirm that Codex is closed, then review the protected backup and retry.") {
            let manager = try self.requireManager()
            do {
                _ = try await manager.resolveRecoveryConflict(operationID: id, choice: choice,
                                                              allowRunningDroid: confirmed.contains(.droidRunning))
            } catch let error as DroidAccountError {
                guard case .running = error, var request = ConfirmationRequest.droid(error, self.describe(error)) else {
                    throw error
                }
                request.action = "Recover"
                return .confirm(request)
            }
            await self.reloadAccounts()
            let notice = choice == .preserveCurrent ? "Current files kept." : "Protected backup restored."
            await self.setNotice(notice)
            return .done(notice: notice)
        }
    }

    /// The Mac `repairLinkedSetting`: put back the linked entry the account sheet showed. `fingerprint` is the one
    /// `accounts.inspectLinks` returned, so an entry that changed again since the user reviewed it fails.
    public func repairLink(_ accountID: UUID, relativePath: String, fingerprint: String) async throws -> ActionResult {
        try await perform(failure: "Couldn’t repair the account data.",
                          recovery: "Refresh the account and review the changed entry again.") {
            _ = try await self.requireManager().repairLinkedSetting(accountID: accountID, relativePath: relativePath,
                                                                    reviewedFingerprint: fingerprint)
            await self.reloadAccounts()
            await self.setNotice("Account data restored.")
            return .done(notice: "Account data restored.")
        }
    }
}
