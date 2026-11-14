import Foundation
import AIManagerCore

/// The page actions the Qt client needs beyond the account lifecycle: reorder, open in a terminal, refresh all,
/// the Claude shell line, and the Droid usage key. Each runs in the action lane like the Mac `perform`.
extension AppEngine {
    /// Accounts drag order (`reorderAccounts`), the full list of ids.
    public func reorderAccounts(_ ids: [UUID]) async throws -> ActionResult {
        try await perform(failure: "Couldn’t save the account order.") {
            _ = try await self.requireManager().reorderAccounts(ids)
            await self.reloadAccounts()
            return .done()
        }
    }

    /// The Mac `openAccount`: switch first when needed (a running Factory app asks first), then open the tool in a
    /// terminal. A test home writes the launch file and opens nothing.
    public func openAccount(_ id: UUID, confirmed: Set<ConfirmationRequest.Kind> = []) async throws -> ActionResult {
        let providerID = try await account(id).identity.providerID
        let name = AccountPresentation.providerName(providerID)
        return try await perform(failure: "Couldn’t open \(name).", recovery: "Check the saved account, then try again.") {
            let manager = try self.requireManager()
            if await self.status?.defaultAccountIDs[providerID.rawValue] != id {
                do {
                    _ = try await manager.switchDefault(to: id, allowRunningDroid: confirmed.contains(.droidRunning))
                } catch let error as DroidAccountError {
                    guard case .running = error, let request = ConfirmationRequest.droid(error, self.describe(error)) else {
                        throw error
                    }
                    return .confirm(request)
                }
                await self.reloadAccounts()
            }
            let notice = try await self.launch(try await manager.launchSpec(accountID: id), file: "open.sh",
                                               what: "\(name) opens in a terminal", isolated: "Account launch file",
                                               opened: "\(name) opened in Terminal.")
            await self.setNotice(notice)
            return .done(notice: notice)
        }
    }

    /// Writes `Launch/<file>` and opens it in a terminal; a test home writes the file and opens nothing.
    func launch(_ spec: LaunchSpec, file: String, what: String, isolated: String, opened: String) async throws -> String {
        var keys = ["CODEX_HOME", "GROK_HOME", "CLAUDE_CONFIG_DIR", "FACTORY_HOME_OVERRIDE", "FACTORY_DISABLE_KEYRING"]
        if paths.isolationRoot != nil { keys.append("HOME") }
        let script = TerminalLaunch.script(command: [spec.executable.path] + spec.arguments,
                                           exports: spec.environment.filter { keys.contains($0.key) },
                                           workingDirectory: spec.workingDirectory?.path)
        let url = paths.applicationSupport.appending(path: "Launch/\(file)")
        if paths.isolationRoot != nil {
            try TerminalLaunch.write(script, at: url)
            return "\(isolated) prepared for isolated validation. Terminal was not opened."
        }
        do { try openTerminal(script, at: url) } catch { throw Self.terminalError(error, what) }
        return opened
    }

    /// Toolbar Refresh (the Mac `refreshAllUsage`): every account's usage now, Codex one at a time. A test home
    /// reads nothing.
    public func refreshAll() async throws -> ActionResult {
        try await perform {
            await self.reloadAccounts()
            guard await self.refreshes else { return .done() }
            let accounts = await self.status?.accounts ?? []
            for account in accounts where account.identity.providerID == .codex { await self.refreshCodexAccount(account.id) }
            await self.refreshProviderAccounts(accounts.filter { $0.identity.providerID != .codex }.map(\.id), interactive: false)
            await self.refreshSideChecks(force: true)
            await self.bumpHistoryVersion()
            return .done()
        }
    }

    /// The popover opened: Refresh when `refreshWhenMenuOpens` is on.
    public func trayOpened() async throws -> ActionResult {
        settings.effective("refreshWhenMenuOpens") == .bool(true) ? try await refreshAll() : .done()
    }

    /// Settings > Claude: the shell-profile line that makes terminals use the selected Claude account.
    public func setClaudeShellIntegration(_ enabled: Bool) async throws -> ActionResult {
        try await perform(failure: "Couldn’t change the shell profile.") {
            try await self.requireManager().setClaudeShellIntegration(enabled)
            return .done()
        }
    }

    /// Saves the Droid usage key of an account; an empty key removes it. The key is never echoed.
    public func setDroidUsageKey(_ id: UUID, key: String) async throws -> ActionResult {
        try await perform(failure: "Couldn’t save the Droid usage key.") {
            try await self.requireManager().setDroidUsageAPIKey(accountID: id, apiKey: key)
            await self.reloadAccounts()
            return .done()
        }
    }
}
