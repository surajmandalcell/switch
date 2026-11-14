import Foundation
import AIManagerCore

/// An import plan as a client sees it: no digest, backup path, or credential path.
public struct ImportPlanSummary: Codable, Equatable, Sendable {
    public struct Conflict: Codable, Equatable, Sendable {
        public var relativePath: String
        public var affectsAllAccounts: Bool
        public var externalTarget: String?
        public var externalTargetBytes: Int64?
    }

    public var planID: String
    public var label: String
    public var mode: String
    public var source: String
    public var files: Int
    public var requiredBytes: Int64
    public var conflicts: [Conflict]
    public var warnings: [String]

    init(_ plan: ImportPlan, label: String) {
        planID = plan.id.uuidString.lowercased()
        self.label = label
        mode = plan.mode.rawValue
        source = plan.source.path
        files = plan.manifest.count
        requiredBytes = plan.requiredBytes
        conflicts = plan.conflicts.map {
            Conflict(relativePath: $0.relativePath, affectsAllAccounts: $0.affectsAllAccounts,
                     externalTarget: $0.externalTarget?.path, externalTargetBytes: $0.externalTargetBytes)
        }
        warnings = plan.warnings
    }
}

/// Adding, signing in, renaming, deleting, and importing accounts: the Mac `AccountViewModel` flows, with its texts.
extension AppEngine {
    nonisolated func requireManager() throws -> AccountManager {
        guard let manager else { throw AppEngineError.unavailable }
        return manager
    }

    nonisolated func label(_ identity: AccountIdentity) -> String {
        AccountPresentation.label(identity, PrivacySettings(settings))
    }

    // MARK: Adding

    /// A secret-provider account from its fields (API key and the like).
    public func addProviderAccount(_ providerID: ProviderID, fields: [String: String]) async throws -> ActionResult {
        try await perform(failure: "Couldn’t save the account.", recovery: "Check the credentials and try again.") {
            let record = try await self.requireManager().addProviderAccount(providerID: providerID, fields: fields)
            return await self.saved(record)
        }
    }

    /// The sign-in the provider's own app or CLI holds now.
    public func importLiveAccount(_ providerID: ProviderID) async throws -> ActionResult {
        try await perform(failure: "Couldn’t import the current sign-in.",
                          recovery: "Sign in with the official app or CLI, then try again.") {
            let record = try await self.requireManager().importLiveProviderAccount(providerID: providerID)
            return await self.saved(record)
        }
    }

    /// The current Droid login under `name`. Saving the same identity again needs a confirmation.
    public func importDroidAccount(name: String, apiKey: String?,
                                   confirmed: Set<ConfirmationRequest.Kind> = []) async throws -> ActionResult {
        try await perform(failure: "Could not import Droid.", recovery: "Enter a name and check that Factory is signed in.") {
            let record: AccountRecord
            do {
                record = try await self.requireManager().importDroidAccount(
                    name: name, apiKey: apiKey, allowDuplicate: confirmed.contains(.droidDuplicate))
            } catch let error as DroidAccountError {
                guard case .duplicateIdentity = error, let request = ConfirmationRequest.droid(error, self.describe(error)) else {
                    throw error
                }
                return .confirm(request)
            }
            return await self.saved(record, notice: "Droid account saved.")
        }
    }

    /// Reloads, posts the notice, and reads the new account's usage in the background, as the Mac does.
    private func saved(_ record: AccountRecord, notice: String? = nil) async -> ActionResult {
        await reloadAccounts()
        let text = notice ?? "\(AccountPresentation.providerName(record.identity.providerID)) account was saved."
        setNotice(text)
        if refreshes {
            Task {
                if record.identity.providerID == .codex { await self.refreshCodexAccount(record.id) }
                else { await self.refreshProviderAccounts([record.id], interactive: false) }
            }
        }
        var result = ActionResult.done(notice: text)
        result.accountID = record.id.uuidString.lowercased()
        return result
    }

    // MARK: Rename and delete

    public func renameAccount(_ id: UUID, to name: String) async throws -> ActionResult {
        try await perform(failure: "Couldn’t rename the account.") {
            _ = try await self.requireManager().renameDroidAccount(id, to: name)
            await self.reloadAccounts()
            return .done()
        }
    }

    /// The account that becomes the default when the default account is deleted (Mac `deletionReplacement`, without
    /// a selection): the most recently used usable account of the same provider, else the first.
    func deletionReplacement(_ account: AccountRecord) -> AccountRecord? {
        let candidates = (status?.accounts ?? []).filter {
            $0.id != account.id && $0.identity.providerID == account.identity.providerID
                && $0.verification.state != .needsSignIn && $0.verification.state != .unsupported
        }
        return candidates.filter { $0.lastUsedAt != nil }.max {
            ($0.lastUsedAt ?? .distantPast) < ($1.lastUsedAt ?? .distantPast)
        } ?? candidates.first
    }

    /// Asks first (the Mac alert text), then deletes; a default account hands its role to `deletionReplacement`.
    public func deleteAccount(_ id: UUID, confirmed: Set<ConfirmationRequest.Kind> = []) async throws -> ActionResult {
        try await perform(failure: "Couldn’t delete the account.", recovery: "Refresh accounts, then try again.") {
            let manager = try self.requireManager()
            let account = try await self.account(id)
            let isDefault = await self.status?.isDefault(account) == true
            let replacement = await self.deletionReplacement(account)
            if isDefault, replacement == nil {
                throw AIManagerError.operationFailed("No saved account is available as a replacement.")
            }
            let name = self.label(account.identity)
            guard confirmed.contains(.delete) else {
                var message = "Remove this account's saved sign-in from Switch. Conversations and settings stay."
                if isDefault, let replacement {
                    message += " \(self.label(replacement.identity)) will become the default for new "
                        + "\(AccountPresentation.providerName(account.identity.providerID)) sessions."
                }
                return .confirm(ConfirmationRequest(kind: .delete, title: "Delete \(name)?", message: message,
                                                    action: "Delete account"))
            }
            do {
                if let usage = await self.providerUsage[id]?.usage {
                    try await manager.retainProviderUsage(accountID: id, usage: usage)
                }
                _ = try await manager.deleteAccount(accountID: id, replacementDefaultAccountID: isDefault ? replacement?.id : nil)
            } catch {
                await self.reloadAccounts()
                throw error
            }
            await self.reloadAccounts()
            await self.setNotice("\(name) deleted.")
            return .done(notice: "\(name) deleted.")
        }
    }

    // MARK: Sign-in sessions

    /// A new sign-in for a provider, or again for a saved account (Droid asks first). Codex and Grok run their
    /// login in the background; a provider that signs in inside a terminal needs TerminalLaunch (plan P10).
    public func startLogin(providerID: ProviderID?, accountID: UUID?,
                           confirmed: Set<ConfirmationRequest.Kind> = []) async throws -> ActionResult {
        var provider = providerID
        if let accountID { provider = try await account(accountID).identity.providerID }
        guard let provider else { throw AIManagerError.operationFailed("Choose a provider or an account to sign in.") }
        let name = AccountPresentation.providerName(provider)
        return try await perform(failure: "Couldn’t start sign-in.",
                                 recovery: "Confirm that \(name) is installed, then try again.") {
            let manager = try self.requireManager()
            let start: AccountLoginStart
            do {
                if let accountID {
                    start = try await manager.startAccountLogin(accountID: accountID,
                                                                confirmDroidAccount: confirmed.contains(.droidSignIn))
                } else {
                    start = try await manager.startAccountLogin(providerID: provider)
                }
            } catch let error as DroidAccountError {
                guard case .confirmSignIn = error, let request = ConfirmationRequest.droid(error, self.describe(error)) else {
                    throw error
                }
                return .confirm(request)
            }
            var message = "Finish signing in to \(name), then return here and choose Check Now."
            if start.opensInTerminal {
                let script = Self.signInScript(start.launchSpec, provider)
                let file = self.paths.applicationSupport.appending(path: "Launch/sign-in.sh")
                if self.paths.isolationRoot != nil {
                    try TerminalLaunch.write(script, at: file)
                    message = "Sign-in file prepared for isolated validation. Terminal was not opened."
                } else {
                    do {
                        try await self.openTerminal(script, at: file)
                    } catch {
                        try? await manager.cancelAccountLogin(id: start.session.id)
                        throw Self.terminalError(error, "\(name) signs in inside a terminal")
                    }
                    message = provider == .droid
                        ? "Terminal opened. Type /login, finish signing in, then exit Droid. Switch checks this temporary login automatically."
                        : "Terminal opened. Finish signing in to \(name) there, then return here and choose Check Now."
                }
            }
            var result = ActionResult.done()
            let login = LoginStatus(sessionID: start.session.id.uuidString.lowercased(), providerID: provider.rawValue,
                                    state: AccountLoginState.waitingForLogin.rawValue, message: message)
            result.login = login
            await self.trackLogin(login)
            return result
        }
    }

    /// The Mac sign-in launch file as a `/bin/sh` script: only the sign-in variables of `spec` are exported.
    static func signInScript(_ spec: LaunchSpec, _ provider: ProviderID) -> String {
        let catalog = ProviderCatalog.spec(provider)
        let keys = ["HOME", "FACTORY_HOME_OVERRIDE", "FACTORY_DISABLE_KEYRING"]
            + (catalog?.files.compactMap(\.homeEnv) ?? []) + (catalog?.loginEnv.keys.sorted() ?? [])
        return TerminalLaunch.script(command: [spec.executable.path] + spec.arguments,
                                     exports: spec.environment.filter { keys.contains($0.key) },
                                     workingDirectory: spec.workingDirectory?.path)
    }

    /// Opens a launch script in the terminal the `terminalEmulator` setting names, else the first one found.
    func openTerminal(_ script: String, at file: URL) throws {
        let preferred: String? = if case .string(let name) = settings.effective("terminalEmulator") { name } else { nil }
        try TerminalLaunch.launch(script, at: file, preferred: preferred)
    }

    /// The text for a terminal that could not open; `what` says why one was needed.
    static func terminalError(_ error: Error, _ what: String) -> Error {
        switch error as? TerminalLaunch.Failure {
        case .noEmulator?:
            AIManagerError.operationFailed("\(what), and Switch found no terminal app. Install one such as "
                + "xdg-terminal-exec or xterm, or choose one in Settings.")
        case .missing(let name)?:
            AIManagerError.operationFailed("\(what), and the terminal \(name) chosen in Settings is not installed.")
        case .unsupported?:
            AppEngineError.unsupported("\(what), and Switch cannot open a terminal on this system yet.")
        case nil: error
        }
    }

    /// Keeps the `login` topic: an open session replaces its earlier state; a finished or cancelled one leaves.
    func trackLogin(_ login: LoginStatus?, removing id: String? = nil) {
        let id = login?.sessionID ?? id
        let index = logins.firstIndex { $0.sessionID == id }
        if let login, login.state != AccountLoginState.completed.rawValue {
            if let index { logins[index] = login } else { logins.append(login) }
        } else if let index {
            logins.remove(at: index)
        }
        publish(.login, LoginValue(sessions: logins))
    }

    /// Check Now: saves the account once the login finished. Droid may ask twice (running, then duplicate).
    public func checkLogin(_ sessionID: UUID, credentialChoice: ConflictChoice?, droidName: String?, droidAPIKey: String?,
                           confirmed: Set<ConfirmationRequest.Kind> = []) async throws -> ActionResult {
        try await perform(failure: "Couldn’t complete sign-in.", recovery: "Finish the sign-in and choose Check Now again.") {
            let manager = try self.requireManager()
            let check: AccountLoginCheck
            do {
                check = try await manager.checkAccountLogin(
                    id: sessionID, credentialChoice: credentialChoice, droidName: droidName ?? "Droid 1",
                    allowRunningDroid: confirmed.contains(.droidRunning),
                    allowDuplicateDroid: confirmed.contains(.droidDuplicate))
            } catch let error as DroidAccountError {
                guard let request = ConfirmationRequest.droid(error, self.describe(error)), request.kind != .droidSignIn else {
                    throw error
                }
                return .confirm(request)
            }
            var result = ActionResult.done()
            result.login = LoginStatus(sessionID: sessionID.uuidString.lowercased(),
                                       providerID: check.session.providerID.rawValue,
                                       state: check.state.rawValue, message: self.masked(check.message))
            await self.trackLogin(check.account == nil ? result.login : nil, removing: sessionID.uuidString.lowercased())
            guard let account = check.account else { return result }
            if account.identity.providerID == .droid, let droidAPIKey, !droidAPIKey.isEmpty {
                try await manager.setDroidUsageAPIKey(accountID: account.id, apiKey: droidAPIKey)
            }
            await self.reloadAccounts()
            let name = self.label(account.identity)
            let provider = account.identity.providerID
            let providerName = AccountPresentation.providerName(provider)
            let isDefault = await self.status?.isDefault(account) == true
            let notice = if !isDefault {
                "\(name) saved."
            } else if ProviderCatalog.spec(provider)?.style == .secret {
                "\(providerName) usage checks will use \(name)."
            } else if ![ProviderID.codex, .grokBuild, .droid, .claudeCode].contains(provider) {
                "\(providerName) sign-in files updated for \(name). Reopen the tool to load this account."
            } else {
                "New \(providerName) sessions will use \(name)."
            }
            await self.setNotice(notice)
            result.notice = notice
            result.accountID = account.id.uuidString.lowercased()
            return result
        }
    }

    /// The Grok authorization code or callback URL.
    public func submitLoginCode(_ sessionID: UUID, code: String) async throws -> ActionResult {
        try await perform(failure: "Couldn’t submit the Grok authorization code.",
                          recovery: "Start Grok sign-in again if the code expired.") {
            try await self.requireManager().submitAccountLoginCode(id: sessionID, input: code)
            var result = ActionResult.done()
            result.login = LoginStatus(sessionID: sessionID.uuidString.lowercased(), providerID: ProviderID.grokBuild.rawValue,
                                       state: AccountLoginState.waitingForLogin.rawValue,
                                       message: "Authorization code submitted. Waiting for Grok to finish signing in.")
            await self.trackLogin(result.login)
            return result
        }
    }

    public func cancelLogin(_ sessionID: UUID) async throws -> ActionResult {
        try await perform(failure: "Couldn’t cancel sign-in.", recovery: "Refresh and retry from the pending sign-in.") {
            try await self.requireManager().cancelAccountLogin(id: sessionID)
            await self.trackLogin(nil, removing: sessionID.uuidString.lowercased())
            return .done()
        }
    }

    // MARK: Import a Codex home

    /// Plans an import from a discovered folder. A new plan replaces the one under review.
    public func planImport(source: URL, mode: ImportMode) async throws -> ActionResult {
        try await perform(failure: "Couldn’t prepare the import.", recovery: "Choose the source again and review its files.") {
            let plan = try await self.requireManager().planImport(source: source, mode: mode)
            return await self.keep(plan)
        }
    }

    /// Reads the size of linked data outside the source before the user decides.
    public func reviewExternalSetting(planID: UUID, relativePath: String) async throws -> ActionResult {
        try await perform(failure: "Couldn’t review the linked data.",
                          recovery: "Check that the linked folder is connected, then review it again.") {
            let plan = try await self.currentPlan(planID)
            return await self.keep(try await self.requireManager().reviewExternalSetting(plan: plan, relativePath: relativePath))
        }
    }

    /// Imports the plan with a choice for each conflict (`keepShared` or `useImported`).
    public func commitImport(planID: UUID, decisions: [String: ConflictChoice]) async throws -> ActionResult {
        try await perform(failure: "Couldn’t import the account.",
                          recovery: "Open Backup before retrying if an interrupted operation is listed.") {
            let plan = try await self.currentPlan(planID)
            let imported = try await self.requireManager().importAccount(plan: plan, decisions: decisions)
            await self.discard(planID)
            return await self.saved(imported.account, notice: "\(self.label(imported.account.identity)) imported.")
        }
    }

    /// Drops the plan; its id is stale afterwards.
    public func discardImport(planID: UUID) async throws {
        _ = try currentPlan(planID)
        importPlan = nil
    }

    private func currentPlan(_ id: UUID) throws -> ImportPlan {
        guard let importPlan, importPlan.id == id else { throw AppEngineError.stale }
        return importPlan
    }

    private func discard(_ id: UUID) { if importPlan?.id == id { importPlan = nil } }

    private func keep(_ plan: ImportPlan) -> ActionResult {
        importPlan = plan
        var result = ActionResult.done()
        result.plan = ImportPlanSummary(plan, label: label(plan.identity))
        return result
    }
}
