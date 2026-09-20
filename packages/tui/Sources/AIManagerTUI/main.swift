import Foundation
import AIManagerCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private enum TerminalKey {
    case up
    case down
    case left
    case right
    case home
    case end
    case enter
    case escape
    case character(Character)
}

private enum TerminalScreen {
    case accounts
    case accountActions
}

private enum TerminalMainAction: CaseIterable, Equatable {
    case addAccount
    case importAccount
    case checkLogin
    case cancelLogin
    case discover
    case recover
    case quit
}

private enum TerminalAccountAction: CaseIterable, Equatable {
    case setDefault
    case openCodex
    case refreshLimits
    case verifyFiles
    case back
}

private struct TerminalMainActionResult {
    let pendingSessions: [AccountLoginSession]
    let message: String?
    let shouldQuit: Bool
}

@main
struct AIManagerCLI {
    static func main() async {
        do {
            let command = try CommandLineInput(Array(CommandLine.arguments.dropFirst()))
            if ["help", "--help", "-h"].contains(command.command) {
                print(usage)
                return
            }
            let manager = try AccountManager(paths: command.paths)
            try await run(command, manager: manager)
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run(_ input: CommandLineInput, manager: AccountManager) async throws {
        switch input.command {
        case "providers": await output(AccountManager.providerCatalog, json: input.json)
        case "refresh", "adopt": try await refreshAccounts(input, manager: manager)
        case "add", "start-login": try await startLogin(input, manager: manager)
        case "check-login": try await checkLogin(input, manager: manager)
        case "cancel-login":
            let id = try input.requiredLoginSessionID()
            try confirm(input, "Cancel this account login and remove its isolated staging files?")
            try await manager.cancelAccountLogin(id: id)
            await output(LoginCancellationOutput(sessionID: id), json: input.json)
        case "status":
            let snapshot = try await manager.refreshAccounts(includeDiscoveries: false)
            await output(SafeStatusSnapshot(snapshot), json: input.json)
        case "discover": await output(manager.discover(explicit: input.path), json: input.json)
        case "plan":
            let path = try input.requiredPath()
            var plan = try await manager.planImport(source: path, mode: input.mode)
            plan = try await reviewExternalSettings(plan, decisions: input.decisions, approvedPaths: input.externalReviews, manager: manager, report: false)
            await output(plan, json: input.json)
        case "import", "advanced-import": try await importAccount(input, manager: manager)
        case "use":
            let id = try input.requiredAccountID()
            try confirm(input, "Use this account for new Codex sessions? Existing sessions will not change.")
            await output(try await manager.switchDefault(to: id), json: input.json)
        case "open":
            let id = try input.requiredAccountID()
            let code = try await manager.activateAndRun(
                accountID: id, arguments: input.forwardedArguments)
            if code != 0 { throw CLIError.message("Codex exited with status \(code).") }
        case "saved-auth":
            let id = try input.requiredAccountID()
            let status = try await manager.status()
            guard let account = status.accounts.first(where: { $0.id == id }) else { throw AIManagerError.accountNotFound }
            print(account.credentialFile.path)
        case "remove", "delete-account":
            let id = try input.requiredAccountID()
            let replacement = try input.optionalAccountID("--replacement")
            let status = try await manager.status()
            guard let account = status.accounts.first(where: { $0.id == id }) else {
                throw AIManagerError.accountNotFound
            }
            try confirm(
                input,
                "Remove \(displayName(account.identity)) from Switch and delete its private saved files?"
            )
            await output(
                try await manager.deleteAccount(
                    accountID: id,
                    replacementDefaultAccountID: replacement
                ),
                json: input.json
            )
        case "profile":
            throw CLIError.message("The profile command was removed. Use saved-auth to print the saved auth file, or open to start Codex.")
        case "verify":
            await output(manager.verifyLocal(accountID: try input.requiredAccountID()), json: input.json)
        case "recover":
            try confirm(input, "Recover pending operations from their journals and backups?")
            await output(try await manager.recover(), json: input.json)
        case "resolve-recovery":
            let id = try input.requiredOperationID()
            let choice = try input.requiredRecoveryChoice()
            let status = try await manager.status()
            guard let operation = status.pendingRecovery.first(where: { $0.id == id }) else {
                throw CLIError.message("Recovery operation not found.")
            }
            guard operation.phase == .conflicted else {
                throw CLIError.message("Recovery operation is not conflicted.")
            }
            let prompt = choice == .preserveCurrent
                ? "Keep the current data and finish recovery? The protected backup will remain at \(operation.backup.path)."
                : "Restore the protected backup from \(operation.backup.path)? The current data will be preserved inside that backup."
            try confirm(input, prompt)
            await output(
                try await manager.resolveRecoveryConflict(operationID: id, choice: choice),
                json: input.json)
        case "inspect-links":
            let status = try await manager.status()
            let issues: [LinkedSettingsDivergence]
            if let value = input.positional.first {
                guard let id = UUID(uuidString: value) else { throw CLIError.message("A valid account UUID is required.") }
                issues = status.linkedSettingsDivergences.filter { $0.accountID == id }
            } else {
                issues = status.linkedSettingsDivergences
            }
            await output(issues, json: input.json)
        case "repair-link":
            let accountID = try input.requiredAccountID()
            guard input.positional.count > 1 else { throw CLIError.message("A shared settings path is required.") }
            let relativePath = input.positional[1]
            guard let fingerprint = input.option("--fingerprint") else {
                throw CLIError.message("Inspect the link first, then pass its exact --fingerprint value.")
            }
            let status = try await manager.status()
            guard let issue = status.linkedSettingsDivergences.first(where: { $0.accountID == accountID && $0.relativePath == relativePath }) else {
                throw CLIError.message("That account has no reviewed divergence at \(relativePath).")
            }
            guard issue.localFingerprint == fingerprint else { throw AIManagerError.sourceChanged }
            try confirm(input, "Back up \(issue.localPath.path) under \(issue.backupRoot.path) and restore its link to \(issue.intendedTarget.path)?")
            await output(try await manager.repairLinkedSetting(accountID: accountID, relativePath: relativePath, reviewedFingerprint: fingerprint), json: input.json)
        case "interactive": try await interactive(manager, paths: input.paths)
        default: throw CLIError.message("Unknown command '\(input.command)'. Run ai-manager help.")
        }
    }

    static func refreshAccounts(_ input: CommandLineInput, manager: AccountManager) async throws {
        let status = try await manager.status()
        if !status.pendingRecovery.isEmpty || status.accounts.isEmpty {
            try confirm(input, "Recover pending work and adopt a valid live Codex account if one is available?")
        }
        await output(SafeAccountSnapshot(try await manager.refreshAccounts()), json: input.json)
    }

    static func startLogin(_ input: CommandLineInput, manager: AccountManager) async throws {
        let provider = try input.providerID()
        guard AccountManager.providerCatalog.first(where: { $0.id == provider })?.availability == .enabled else {
            let reason = AccountManager.providerCatalog.first(where: { $0.id == provider })?.unavailableReason
            throw AIManagerError.unsupportedSource(reason ?? "This provider is unavailable.")
        }
        try confirm(input, "Start an isolated \(providerName(provider)) account login?")
        await output(SafeLoginStart(try await manager.startAccountLogin(providerID: provider)), json: input.json)
    }

    static func checkLogin(_ input: CommandLineInput, manager: AccountManager) async throws {
        let id = try input.requiredLoginSessionID()
        try confirm(input, "Check this login and save the account if sign-in is complete?")
        let checked = try await manager.checkAccountLogin(id: id, credentialChoice: input.loginCredentialChoice)
        await output(SafeLoginCheck(checked), json: input.json)
    }

    static func importAccount(_ input: CommandLineInput, manager: AccountManager) async throws {
        var plan = try await manager.planImport(source: try input.requiredPath(), mode: input.mode)
        if input.json && !input.confirmed { await output(plan, json: true); throw CLIError.confirmationRequired }
        if !input.json { printPlan(plan) }
        var decisions = input.decisions
        for conflict in plan.conflicts where decisions[conflict.relativePath] == nil {
            guard !input.confirmed else { throw CLIError.message("Missing conflict choice for \(conflict.relativePath).") }
            decisions[conflict.relativePath] = try askConflict(conflict.relativePath)
        }
        plan = try await reviewExternalSettings(plan, decisions: decisions, approvedPaths: input.externalReviews, manager: manager, report: true)
        let target = plan.mode == .full
            ? "Save account access at \(plan.credentialDestination.path) and merge reviewed data into \(plan.sharedDestination.path)"
            : "Save account access at \(plan.credentialDestination.path)"
        try confirm(input, "\(target) with backup at \(plan.backup.path)?")
        let result = try await manager.importAccount(plan: plan, decisions: decisions)
        await output(result, json: input.json)
        if !result.unresolved.isEmpty {
            throw CLIError.message("Import completed with unresolved items; review the reported paths before using this account.")
        }
    }

    static func interactive(_ manager: AccountManager, paths: ManagerPaths) async throws {
        let menu = TerminalMenu()
        var pendingSessions = try await menu.loading("Loading accounts") {
            try await manager.refreshAccounts(includeDiscoveries: false).pendingLoginSessions
        }
        let terminal = TerminalInput()
        defer { terminal.restore() }
        let usageCache = try? CodexUsageStatisticsCache(
            databaseURL: paths.applicationSupport.appending(path: "cache/account-usage.sqlite"),
            activityDatabaseURL: paths.applicationSupport.appending(path: "activity/daily.sqlite"))
        var selectedAccountID: UUID?
        var screen = TerminalScreen.accounts
        var mainFocus = 0
        var accountActionFocus = 0
        var tokenPeriod = CodexTokenPeriod.today
        var initializedFocus = false
        var message: String?
        while true {
            let status = try await manager.status()
            if !status.accounts.contains(where: { $0.id == selectedAccountID }) {
                selectedAccountID = status.defaultAccountID ?? status.accounts.first?.id
            }
            let mainActions = TerminalMenu.mainActions(hasPendingLogins: !pendingSessions.isEmpty)
            let mainItemCount = status.accounts.count + mainActions.count
            if !initializedFocus {
                mainFocus = status.accounts.firstIndex { $0.id == selectedAccountID } ?? 0
                initializedFocus = true
            }
            mainFocus = min(max(0, mainFocus), max(0, mainItemCount - 1))
            accountActionFocus = min(accountActionFocus, TerminalAccountAction.allCases.count - 1)
            if screen == .accounts, status.accounts.indices.contains(mainFocus) {
                selectedAccountID = status.accounts[mainFocus].id
            }
            let usage = await cachedUsage(usageCache, accountIDs: status.accounts.map(\.id))
            let dailyUsage = await cachedDailyUsage(
                usageCache, accountIDs: status.accounts.map(\.id))
            menu.render(
                status: status,
                selectedAccountID: selectedAccountID,
                usage: usage,
                dailyUsage: dailyUsage,
                tokenPeriod: tokenPeriod,
                pendingLoginCount: pendingSessions.count,
                screen: screen,
                mainActions: mainActions,
                mainFocus: mainFocus,
                accountActionFocus: accountActionFocus,
                message: message)
            message = nil
            guard var key = terminal.readKey() else { return }
            do {
                let selectedAccount = selectedAccountID.flatMap { id in
                    status.accounts.first { $0.id == id }
                }

                if terminal.acceptsLegacyCommands, case let .character(character) = key {
                    let value = String(character).lowercased()
                    if let number = Int(value), status.accounts.indices.contains(number - 1) {
                        mainFocus = number - 1
                        selectedAccountID = status.accounts[mainFocus].id
                        continue
                    }
                    if value == "q" { return }
                    let mainAction: TerminalMainAction? = switch value {
                    case "a": .addAccount
                    case "m", "i": .importAccount
                    case "c": .checkLogin
                    case "x": .cancelLogin
                    case "d": .discover
                    case "r": .recover
                    default: nil
                    }
                    if let mainAction, let index = mainActions.firstIndex(of: mainAction) {
                        screen = .accounts
                        mainFocus = status.accounts.count + index
                        key = .enter
                    } else {
                        let accountAction: TerminalAccountAction? = switch value {
                        case "u": .setDefault
                        case "o": .openCodex
                        case "f": .refreshLimits
                        case "v": .verifyFiles
                        default: nil
                        }
                        if let accountAction,
                           let index = TerminalAccountAction.allCases.firstIndex(of: accountAction) {
                            screen = .accountActions
                            accountActionFocus = index
                            key = .enter
                        }
                    }
                }

                switch screen {
                case .accounts:
                    switch key {
                    case .up:
                        mainFocus = (mainFocus + mainItemCount - 1) % mainItemCount
                    case .down:
                        mainFocus = (mainFocus + 1) % mainItemCount
                    case .home:
                        mainFocus = 0
                    case .end:
                        mainFocus = mainItemCount - 1
                    case .enter, .right:
                        if status.accounts.indices.contains(mainFocus) {
                            selectedAccountID = status.accounts[mainFocus].id
                            accountActionFocus = 0
                            screen = .accountActions
                        } else if case .enter = key {
                            let action = mainActions[mainFocus - status.accounts.count]
                            let result = try await performMainAction(
                                action,
                                manager: manager,
                                terminal: terminal,
                                pendingSessions: pendingSessions)
                            pendingSessions = result.pendingSessions
                            message = result.message
                            if result.shouldQuit { return }
                        }
                    case .escape:
                        return
                    case .left, .character:
                        break
                    }
                case .accountActions:
                    switch key {
                    case .up:
                        accountActionFocus = (accountActionFocus + TerminalAccountAction.allCases.count - 1)
                            % TerminalAccountAction.allCases.count
                    case .down:
                        accountActionFocus = (accountActionFocus + 1) % TerminalAccountAction.allCases.count
                    case .home:
                        accountActionFocus = 0
                    case .end:
                        accountActionFocus = TerminalAccountAction.allCases.count - 1
                    case .left, .escape:
                        screen = .accounts
                    case .enter, .right:
                        let action = TerminalAccountAction.allCases[accountActionFocus]
                        if action == .back {
                            screen = .accounts
                        } else if let selectedAccount {
                            message = try await performAccountAction(
                                action,
                                account: selectedAccount,
                                manager: manager,
                                terminal: terminal,
                                menu: menu,
                                usageCache: usageCache)
                        }
                    case let .character(character):
                        if character.lowercased() == "w",
                           let index = CodexTokenPeriod.allCases.firstIndex(of: tokenPeriod) {
                            tokenPeriod = CodexTokenPeriod.allCases[
                                (index + 1) % CodexTokenPeriod.allCases.count]
                        }
                    }
                }
            } catch {
                message = "Error: \(error.localizedDescription)"
            }
        }
    }

    private static func performMainAction(
        _ action: TerminalMainAction,
        manager: AccountManager,
        terminal: TerminalInput,
        pendingSessions: [AccountLoginSession]
    ) async throws -> TerminalMainActionResult {
        var sessions = pendingSessions
        var message: String?
        switch action {
        case .addAccount:
            if let session = try await terminal.withCookedInput({
                try await interactiveAddAccount(manager, terminal: terminal)
            }) {
                sessions.append(session)
            }
        case .importAccount:
            try await terminal.withCookedInput {
                try await interactiveImport(manager, terminal: terminal)
            }
        case .checkLogin:
            try await terminal.withCookedInput {
                if let session = chooseLoginSession(sessions, terminal: terminal) {
                    var result = try await manager.checkAccountLogin(id: session.id)
                    if result.state == .credentialChoiceRequired {
                        let credentialChoice = terminal.choose(
                            "Credential",
                            options: ["Keep saved", "Use this login"]
                        ) {
                            print("Credential: [k] Keep saved  [l] Use this login:", terminator: " ")
                            switch readLine()?.lowercased() {
                            case "k": return 0
                            case "l": return 1
                            default: return nil
                            }
                        }.map { $0 == 0 ? ConflictChoice.keepShared : .useImported }
                        if let credentialChoice {
                            result = try await manager.checkAccountLogin(
                                id: session.id, credentialChoice: credentialChoice)
                        }
                    }
                    await output(SafeLoginCheck(result), json: false)
                    message = result.message
                    if result.state == .completed { sessions.removeAll { $0.id == session.id } }
                }
            }
        case .cancelLogin:
            try await terminal.withCookedInput {
                if let session = chooseLoginSession(sessions, terminal: terminal),
                   askYes("Cancel this login and remove its isolated staging files?", terminal: terminal) {
                    try await manager.cancelAccountLogin(id: session.id)
                    sessions.removeAll { $0.id == session.id }
                    message = "Account login cancelled."
                }
            }
        case .discover:
            await terminal.withCookedInput {
                await printDiscovery(manager.discover())
                print("Press Return to continue.", terminator: " ")
                _ = readLine()
            }
        case .recover:
            try await terminal.withCookedInput {
                try await interactiveRecovery(manager, terminal: terminal)
            }
            message = "Recovery review finished."
        case .quit:
            return TerminalMainActionResult(
                pendingSessions: sessions, message: nil, shouldQuit: true)
        }
        return TerminalMainActionResult(
            pendingSessions: sessions, message: message, shouldQuit: false)
    }

    private static func performAccountAction(
        _ action: TerminalAccountAction,
        account: AccountRecord,
        manager: AccountManager,
        terminal: TerminalInput,
        menu: TerminalMenu,
        usageCache: CodexUsageStatisticsCache?
    ) async throws -> String? {
        switch action {
        case .setDefault:
            _ = try await manager.switchDefault(to: account.id)
            return "Using \(displayName(account.identity)) as default."
        case .openCodex:
            _ = try await terminal.withCookedInput {
                try await manager.activateAndRun(accountID: account.id)
            }
            return "Codex closed."
        case .refreshLimits:
            let result = try await menu.loading("Refreshing limits") {
                await manager.checkAccount(accountID: account.id)
            }
            if let snapshot = result.usage {
                try? await usageCache?.upsertSuccess(accountID: account.id, snapshot: snapshot)
            }
            return result.verification.detail
        case .verifyFiles:
            return await manager.verifyLocal(accountID: account.id).detail
        case .back:
            return nil
        }
    }

    static func cachedUsage(
        _ cache: CodexUsageStatisticsCache?, accountIDs: [UUID]
    ) async -> [UUID: CodexAccountUsageSnapshot] {
        guard let cache,
              let entries = try? await cache.latest(for: accountIDs) else { return [:] }
        return Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            entry.snapshot.map { (entry.accountID, $0) }
        })
    }

    static func cachedDailyUsage(
        _ cache: CodexUsageStatisticsCache?, accountIDs: [UUID]
    ) async -> [UUID: [CodexDailyUsageSnapshot]] {
        guard let cache else { return [:] }
        var result: [UUID: [CodexDailyUsageSnapshot]] = [:]
        for accountID in accountIDs {
            if let rows = try? await cache.dailyUsage(for: accountID), !rows.isEmpty {
                result[accountID] = rows
            }
        }
        return result
    }

    private static func interactiveAddAccount(
        _ manager: AccountManager,
        terminal: TerminalInput
    ) async throws -> AccountLoginSession? {
        print("Add Account")
        let providers = AccountManager.providerCatalog
        if !terminal.usesArrowNavigation {
            for (index, provider) in providers.enumerated() {
                let availability = provider.availability == .enabled ? "Available" : "Unavailable"
                print("  \(index + 1). \(providerName(provider.id)) [\(availability)]")
            }
        }
        let selectedProvider = terminal.choose(
            "Provider",
            options: providers.map { provider in
                let suffix = provider.availability == .enabled ? "" : " (unavailable)"
                return providerName(provider.id) + suffix
            }
        ) {
            print("Provider number:", terminator: " ")
            guard let value = readLine(), let number = Int(value) else { return nil }
            return number - 1
        }
        guard let index = selectedProvider, providers.indices.contains(index) else {
            print("Account login cancelled.")
            return nil
        }
        let provider = providers[index]
        guard provider.availability == .enabled else {
            print("Unavailable. \(provider.unavailableReason ?? "This provider cannot be added yet.")")
            return nil
        }
        guard askYes("Start an isolated \(providerName(provider.id)) login?", terminal: terminal) else {
            print("Account login cancelled.")
            return nil
        }
        let started = try await manager.startAccountLogin(providerID: provider.id)
        await output(SafeLoginStart(started), json: false)
        print("Finish sign-in, then choose Check Login.")
        return started.session
    }

    private static func chooseLoginSession(
        _ sessions: [AccountLoginSession],
        terminal: TerminalInput
    ) -> AccountLoginSession? {
        guard !sessions.isEmpty else { print("No pending account logins."); return nil }
        if !terminal.usesArrowNavigation {
            for (index, session) in sessions.enumerated() {
                print("  \(index + 1). \(providerName(session.providerID)) \(session.id.uuidString)")
            }
        }
        let selectedLogin = terminal.choose(
            "Login",
            options: sessions.map {
                "\(providerName($0.providerID)) \($0.id.uuidString.prefix(8))"
            }
        ) {
            print("Login number:", terminator: " ")
            guard let value = readLine(), let number = Int(value) else { return nil }
            return number - 1
        }
        guard let index = selectedLogin, sessions.indices.contains(index) else {
            print("Login selection cancelled.")
            return nil
        }
        return sessions[index]
    }

    private static func interactiveImport(_ manager: AccountManager, terminal: TerminalInput) async throws {
        print("Codex home or auth.json path:", terminator: " ")
        guard let value = readLine(), !value.isEmpty else { return }
        let selectedMode = terminal.choose(
            "Mode",
            options: ["Auth only", "Auth, settings, and chats"]
        ) {
            print("Mode: [1] Auth only  [2] Auth, settings, and chats:", terminator: " ")
            return readLine() == "2" ? 1 : 0
        }
        guard let modeIndex = selectedMode else {
            print("Import cancelled.")
            return
        }
        let mode: ImportMode = modeIndex == 1 ? .full : .authOnly
        var plan = try await manager.planImport(source: URL(fileURLWithPath: NSString(string: value).expandingTildeInPath), mode: mode)
        printPlan(plan)
        var decisions: [String: ConflictChoice] = [:]
        for conflict in plan.conflicts {
            guard conflict.externalTarget != nil else {
                decisions[conflict.relativePath] = try askConflict(conflict.relativePath, terminal: terminal)
                continue
            }
            plan = try await manager.reviewExternalSetting(plan: plan, relativePath: conflict.relativePath)
            guard let reviewed = plan.conflicts.first(where: { $0.relativePath == conflict.relativePath }),
                  let target = reviewed.externalTarget,
                  let bytes = reviewed.externalTargetBytes else {
                throw CLIError.message("Could not review linked setting \(conflict.relativePath).")
            }
            print("Reviewed linked setting \(conflict.relativePath):")
            print("  Target: \(target.path)")
            print("  Size: \(bytes) bytes")
            print("  Fingerprint: \(reviewed.importedDigest)")
            decisions[conflict.relativePath] = askYes(
                "Use this imported linked setting?", terminal: terminal
            ) ? .useImported : .keepShared
        }
        guard askYes("Import this reviewed plan?", terminal: terminal) else {
            print("Import cancelled.")
            return
        }
        let result = try await manager.importAccount(plan: plan, decisions: decisions)
        await output(result, json: false)
        if !result.unresolved.isEmpty {
            throw CLIError.message("Import completed with unresolved items; review the reported paths before using this account.")
        }
    }

    private static func interactiveRecovery(_ manager: AccountManager, terminal: TerminalInput) async throws {
        await output(try await manager.recover(), json: false)
        let conflicts = try await manager.status().pendingRecovery.filter { $0.phase == .conflicted }
        for operation in conflicts {
            print("Recovery conflict \(operation.id.uuidString) (\(operation.kind))")
            print("  Current data: \(operation.destination.path)")
            print("  Protected backup: \(operation.backup.path)")
            let selection = terminal.choose(
                "Recovery",
                options: ["Keep current data", "Restore protected backup", "Skip"]
            ) {
                print("[k] Keep current data  [b] Restore protected backup  [s] Skip:", terminator: " ")
                switch readLine()?.lowercased() {
                case "k": return 0
                case "b": return 1
                default: return 2
                }
            }
            let choice: RecoveryConflictChoice
            switch selection {
            case 0: choice = .preserveCurrent
            case 1:
                guard askYes(
                    "Restore the protected backup? The current data will be preserved inside it.",
                    terminal: terminal
                ) else {
                    print("Recovery choice skipped.")
                    continue
                }
                choice = .restoreBackup
            default:
                print("Recovery choice skipped.")
                continue
            }
            await output(
                try await manager.resolveRecoveryConflict(operationID: operation.id, choice: choice),
                json: false)
        }
    }

    static func chooseAccount(_ accounts: [AccountRecord]) -> AccountRecord? {
        guard !accounts.isEmpty else { print("No imported accounts."); return nil }
        print("Account number:", terminator: " ")
        guard let value = readLine(), let index = Int(value), accounts.indices.contains(index - 1) else { print("Invalid account."); return nil }
        return accounts[index - 1]
    }

    static func printPlan(_ plan: ImportPlan) {
        print("Account: \(displayName(plan.identity))")
        print("Mode: \(plan.mode == .authOnly ? "auth only" : "auth, settings, and chats")")
        print("Saved auth: \(plan.credentialDestination.path)")
        if plan.mode == .full {
            print("Shared Codex home: \(plan.sharedDestination.path)")
            print("Imported account data: \(plan.destination.path)")
        }
        print("Backup: \(plan.backup.path)")
        print("Selected files: \(plan.manifest.filter(\.selected).count); conflicts: \(plan.conflicts.count)")
        for warning in plan.warnings { print("Warning: \(warning)") }
    }

    static func printDiscovery(_ sources: [DiscoveredSource]) {
        if sources.isEmpty { print("No Codex homes found."); return }
        for source in sources {
            print("\(displayName(source.identity))\t\(source.support.rawValue)\t\(source.path.path)")
            if let error = source.inspectionError { print("  Error: \(error)") }
        }
    }

    private static func askConflict(_ path: String, terminal: TerminalInput? = nil) throws -> ConflictChoice {
        if let terminal {
            let selection = terminal.choose(
                path,
                options: ["Keep existing", "Use imported"]
            ) {
                print("\(path): [k] Keep existing  [i] Use imported:", terminator: " ")
                switch readLine()?.lowercased() {
                case "k": return 0
                case "i": return 1
                default: return nil
                }
            }
            guard let selection else { throw CLIError.message("No choice made for \(path).") }
            return selection == 0 ? .keepShared : .useImported
        }
        print("\(path): [k] Keep existing  [i] Use imported:", terminator: " ")
        switch readLine()?.lowercased() {
        case "k": return .keepShared
        case "i": return .useImported
        default: throw CLIError.message("No choice made for \(path).")
        }
    }

    static func reviewExternalSettings(
        _ initialPlan: ImportPlan,
        decisions: [String: ConflictChoice],
        approvedPaths: Set<String>,
        manager: AccountManager,
        report: Bool
    ) async throws -> ImportPlan {
        var plan = initialPlan
        let paths = plan.conflicts.compactMap { conflict in
            conflict.externalTarget != nil && decisions[conflict.relativePath] == .useImported ? conflict.relativePath : nil
        }
        for path in paths {
            guard approvedPaths.contains(path) else {
                throw CLIError.message("Using linked setting \(path) requires explicit --review-external \(path) approval after reviewing its target path.")
            }
            plan = try await manager.reviewExternalSetting(plan: plan, relativePath: path)
            guard report, let conflict = plan.conflicts.first(where: { $0.relativePath == path }) else { continue }
            let message = "Reviewed linked setting \(path): \(conflict.externalTarget?.path ?? "unknown target"), \(conflict.externalTargetBytes ?? 0) bytes, fingerprint \(conflict.importedDigest).\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
        return plan
    }

    static func confirm(_ input: CommandLineInput, _ prompt: String) throws {
        if input.confirmed { return }
        if input.json { throw CLIError.confirmationRequired }
        guard askYes(prompt) else { throw CLIError.cancelled }
    }

    private static func askYes(_ prompt: String, terminal: TerminalInput? = nil) -> Bool {
        if let terminal {
            return terminal.choose(prompt, options: ["Yes", "Cancel"], defaultIndex: 1) {
                print("\(prompt) [y/N]", terminator: " ")
                return readLine()?.lowercased() == "y" ? 0 : 1
            } == 0
        }
        print("\(prompt) [y/N]", terminator: " ")
        return readLine()?.lowercased() == "y"
    }

    static func output<T: Encodable>(_ value: T, json: Bool) async {
        if json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            let data: Data?
            switch value {
            case let providers as [ProviderDescriptor]: data = try? encoder.encode(providers.map(SafeProvider.init))
            case let status as ManagerStatus: data = try? encoder.encode(StatusOutput(status))
            case let plan as ImportPlan: data = try? encoder.encode(PlanOutput(plan))
            case let result as ImportResult: data = try? encoder.encode(ImportOutput(result))
            default: data = try? encoder.encode(value)
            }
            if let data { print(String(decoding: data, as: UTF8.self)); return }
        }
        switch value {
        case let providers as [ProviderDescriptor]:
            for provider in providers {
                let availability = provider.availability == .enabled ? "Available" : "Unavailable"
                print("\(provider.id.rawValue)\t\(providerName(provider.id))\t\(availability)")
            }
        case let snapshot as SafeAccountSnapshot:
            print("Accounts: \(snapshot.status.accounts.count)")
            print("Pending account logins: \(snapshot.pendingLoginSessions.count)")
            print("Discovered Codex homes: \(snapshot.discoveries.count)")
        case let started as SafeLoginStart:
            print("Browser sign-in started for \(providerName(started.session.providerID)).")
            print("Login session: \(started.session.id.uuidString)")
            print("Check when sign-in finishes: \(started.checkCommand)")
            print("Cancel this login: \(started.cancelCommand)")
            print("Both commands keep working after Switch restarts.")
        case let checked as SafeLoginCheck:
            print("\(checked.state.rawValue): \(checked.message)")
            if let account = checked.account { print("Saved \(displayName(account.identity)).") }
        case let cancellation as LoginCancellationOutput:
            print("Cancelled account login \(cancellation.sessionID.uuidString).")
        case let status as ManagerStatus:
            print("Shared settings: \(status.sharedRoot.path)")
            print("Default account: \(status.defaultAccountID?.uuidString ?? "none")")
            for account in status.accounts { print("\(account.id.uuidString)\t\(displayName(account.identity))\t\(account.verification.state.rawValue)") }
            if !status.pendingRecovery.isEmpty { print("Pending recovery: \(status.pendingRecovery.count)") }
        case let snapshot as SafeStatusSnapshot:
            print("Shared settings: \(snapshot.sharedRoot.path)")
            print("Default account: \(snapshot.defaultAccountID?.uuidString ?? "none")")
            for account in snapshot.accounts {
                print("\(account.id.uuidString)\t\(displayName(account.identity))\t\(account.verification.state.rawValue)")
            }
            for session in snapshot.pendingLoginSessions {
                print("Pending \(providerName(session.providerID)) login: \(session.id.uuidString)")
                print("  Check: ai-manager check-login \(session.id.uuidString) --yes")
                print("  Cancel: ai-manager cancel-login \(session.id.uuidString) --yes")
            }
            if !snapshot.pendingRecovery.isEmpty { print("Pending recovery: \(snapshot.pendingRecovery.count)") }
        case let sources as [DiscoveredSource]: printDiscovery(sources)
        case let result as ImportResult:
            print("Saved \(displayName(result.account.identity)) at \(result.account.credentialFile.path).")
            print("Backup: \(result.backup.path); files: \(result.importedFiles); chats: \(result.importedChats)")
            for item in result.unresolved { print("Unresolved: \(item)") }
        case let result as SwitchResult: print("Default account changed to \(result.accountID.uuidString). Backup: \(result.backup.path)")
        case let result as AccountDeletionResult:
            print("Removed account \(result.accountID.uuidString) from Switch.")
            if let replacement = result.replacementDefaultAccountID {
                print("Default account changed to \(replacement.uuidString).")
            }
        case let result as VerificationResult: print("\(result.state.rawValue): \(result.detail)")
        case let results as [RecoveryResult]:
            if results.isEmpty { print("No recovery was needed.") }
            for result in results { print("\(result.operationID.uuidString)\t\(result.outcome.rawValue)\t\(result.message)") }
        case let result as RecoveryResult:
            print("\(result.operationID.uuidString)\t\(result.outcome.rawValue)\t\(result.message)")
        case let issues as [LinkedSettingsDivergence]:
            if issues.isEmpty { print("All managed shared settings links are intact.") }
            for issue in issues {
                print("\(issue.accountID.uuidString)\t\(issue.relativePath)")
                print("  Local: \(issue.localPath.path)")
                print("  Intended target: \(issue.intendedTarget.path)")
                print("  Fingerprint: \(issue.localFingerprint)")
                print("  Backup root: \(issue.backupRoot.path)")
            }
        case let result as LinkedSettingRepairResult:
            print("Repaired \(result.relativePath) for \(result.accountID.uuidString). Backup: \(result.backup.path)")
        case let plan as ImportPlan: printPlan(plan)
        default: print(String(describing: value))
        }
    }

    static func displayName(_ identity: AccountIdentity?) -> String {
        guard let identity else { return "Unresolved account" }
        if let email = identity.email, let workspace = identity.workspaceID { return "\(email) · \(workspace)" }
        return identity.email ?? identity.accountID ?? "Unresolved account"
    }

    static func providerName(_ id: ProviderID) -> String {
        id == .codex
            ? "Codex CLI"
            : AccountManager.providerCatalog.first(where: { $0.id == id })?.displayName ?? id.rawValue
    }

    static let usage = """
    Switch manages file-based Codex accounts without using Keychain.

    Usage:
      ai-manager providers [--json]
      ai-manager refresh [--yes] [--json]
      ai-manager adopt [--yes] [--json]                     Alias for refresh
      ai-manager add [codex] [--yes] [--json]               Start isolated browser sign-in
      ai-manager start-login [codex] [--yes] [--json]       Alias for add
      ai-manager check-login <session-uuid> [--keep-saved|--use-login] [--yes] [--json]
      ai-manager cancel-login <session-uuid> [--yes] [--json]
      ai-manager status [--json]                            Adopt first live account; list pending logins
      ai-manager discover [path] [--json]
      ai-manager plan <path> [--mode auth-only|full] [--use-imported path] [--review-external path] [--json]
      ai-manager advanced-import <path> [import options]     Import an existing Codex folder or auth.json
      ai-manager import <path> [--mode auth-only|full] [--keep-shared path] [--use-imported path] [--review-external path] [--yes] [--json]
      ai-manager use <account-uuid> [--yes] [--json]
      ai-manager open <account-uuid> [-- codex arguments]
      ai-manager saved-auth <account-uuid>
      ai-manager remove <account-uuid> [--replacement <account-uuid>] [--yes] [--json]
      ai-manager verify <account-uuid> [--json]
      ai-manager recover [--yes] [--json]
      ai-manager resolve-recovery <operation-uuid> (--keep-current|--restore-backup) [--yes] [--json]
      ai-manager inspect-links [account-uuid] [--json]
      ai-manager repair-link <account-uuid> <settings-path> --fingerprint <sha256> [--yes] [--json]
      ai-manager interactive

    Isolation overrides: AI_MANAGER_ROOT, AI_MANAGER_DEFAULT_HOME,
    AI_MANAGER_CREDENTIAL_STORE, AI_MANAGER_SHARED_ROOT,
    AI_MANAGER_CODEX_EXECUTABLE.

    Provider IDs: codex, claude-code, gemini-cli, antigravity-cli.
    Only Codex CLI is available in this release. Login sessions survive restarts;
    use status to recover their IDs, then check-login or cancel-login.
    """
}

private struct TerminalMenu {
    private struct UsageView {
        let session: CodexRateLimitWindowSnapshot?
        let weekly: CodexRateLimitWindowSnapshot?
    }

    private let usesStyles: Bool
    private let clearsScreen: Bool
    private let animatesLoader: Bool
    private let showsUsed: Bool
    private let width = 72
    private let reset = "\u{1B}[0m"

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let appDefaults = UserDefaults(suiteName: "com.mandalsuraj.ai-manager")
        let attached = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
        usesStyles = environment["AI_MANAGER_TUI_STYLE"] == "always"
            || (attached && environment["NO_COLOR"] == nil && environment["TERM"] != "dumb")
        clearsScreen = attached
        animatesLoader = attached || environment["AI_MANAGER_TUI_SPINNER"] == "always"
        showsUsed = environment["AI_MANAGER_TUI_PERCENTAGE"].map { $0 == "used" }
            ?? appDefaults?.bool(forKey: "showUsageAsUsed")
            ?? false
    }

    func loading<T>(_ message: String, operation: () async throws -> T) async throws -> T {
        guard animatesLoader else { return try await operation() }
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
        FileHandle.standardOutput.write(Data("\r\(frames[0]) \(message)…".utf8))
        let spinner = Task {
            var index = 1
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled else { break }
                FileHandle.standardOutput.write(Data("\r\(frames[index]) \(message)…".utf8))
                index = (index + 1) % frames.count
            }
        }
        do {
            let result = try await operation()
            spinner.cancel()
            await spinner.value
            FileHandle.standardOutput.write(Data("\r\u{1B}[2K".utf8))
            return result
        } catch {
            spinner.cancel()
            await spinner.value
            FileHandle.standardOutput.write(Data("\r\u{1B}[2K".utf8))
            throw error
        }
    }

    func render(
        status: ManagerStatus,
        selectedAccountID: UUID?,
        usage: [UUID: CodexAccountUsageSnapshot],
        dailyUsage: [UUID: [CodexDailyUsageSnapshot]],
        tokenPeriod: CodexTokenPeriod,
        pendingLoginCount: Int,
        screen: TerminalScreen,
        mainActions: [TerminalMainAction],
        mainFocus: Int,
        accountActionFocus: Int,
        message: String?
    ) {
        var lines: [String] = []
        lines.append(between("SWITCH", Self.timestamp(), width: width))
        lines.append("")
        switch screen {
        case .accounts:
            lines.append(status.accounts.isEmpty ? "No saved accounts" : "Accounts")
            lines.append("")
            for (index, account) in status.accounts.enumerated() {
                let marker = account.id == status.defaultAccountID ? "DEFAULT" : ""
                let snapshot = usage[account.id].map(Self.usageView)
                let window = snapshot?.weekly ?? snapshot?.session
                let scope = snapshot?.weekly == nil ? "session" : "weekly"
                let amount = window.flatMap { displayedPercentage($0.usedPercent) }
                let label = amount.map { "\($0)% \(scope) \(showsUsed ? "used" : "left")" }
                    ?? "usage unavailable"
                let row = "  \(padded(Self.accountName(account.identity), to: 32))"
                    + "\(padded(marker, to: 10))\(label)"
                lines.append(index == mainFocus ? selectedLine(row) : fitted(row))
            }
            if let account = status.accounts.first(where: { $0.id == selectedAccountID }) {
                lines.append("")
                lines.append(contentsOf: detailLines(
                    account: account, usage: usage[account.id],
                    dailyUsage: dailyUsage[account.id], tokenPeriod: tokenPeriod))
            }
            lines.append("")
            lines.append("Actions")
            for (index, action) in mainActions.enumerated() {
                let row = "  " + Self.mainActionLabel(action, pendingLoginCount: pendingLoginCount)
                lines.append(status.accounts.count + index == mainFocus ? selectedLine(row) : fitted(row))
            }
            if let message { lines.append(""); lines.append(accent(message)) }
            lines.append("")
            lines.append(muted("↑↓ move   →/Enter select   Esc quit"))
        case .accountActions:
            guard let account = status.accounts.first(where: { $0.id == selectedAccountID }) else { break }
            lines.append("Account")
            lines.append(accent(Self.accountName(account.identity)))
            lines.append("")
            lines.append(contentsOf: detailLines(
                account: account, usage: usage[account.id],
                dailyUsage: dailyUsage[account.id], tokenPeriod: tokenPeriod))
            lines.append("")
            lines.append("Actions")
            for (index, action) in TerminalAccountAction.allCases.enumerated() {
                let row = "  " + Self.accountActionLabel(action, isDefault: account.id == status.defaultAccountID)
                lines.append(index == accountActionFocus ? selectedLine(row) : fitted(row))
            }
            if let message { lines.append(""); lines.append(accent(message)) }
            lines.append("")
            lines.append(muted("↑↓ move   Enter run   w period   ←/Esc back"))
        }

        if clearsScreen { print("\u{1B}[2J\u{1B}[H", terminator: "") }
        print(lines.joined(separator: "\n"))
        if usesStyles { print(reset, terminator: "") }
        fflush(stdout)
    }

    static func mainActions(hasPendingLogins: Bool) -> [TerminalMainAction] {
        TerminalMainAction.allCases.filter {
            hasPendingLogins || ($0 != .checkLogin && $0 != .cancelLogin)
        }
    }

    private func detailLines(
        account: AccountRecord,
        usage: CodexAccountUsageSnapshot?,
        dailyUsage: [CodexDailyUsageSnapshot]?,
        tokenPeriod: CodexTokenPeriod
    ) -> [String] {
        let view = usage.map(Self.usageView)
        var lines: [String] = []
        if let session = view?.session { lines.append(limitLine("session", window: session)) }
        if let weekly = view?.weekly { lines.append(limitLine("weekly", window: weekly)) }
        if view?.session == nil && view?.weekly == nil {
            lines.append(muted("Usage has not been checked."))
        } else if let resetDate = view?.weekly?.resetsAt ?? view?.session?.resetsAt {
            lines.append("reset        : \(Self.resetLabel(until: resetDate))")
        }
        if let dailyUsage, !dailyUsage.isEmpty {
            lines.append("")
            lines.append("Token statistics")
            lines.append("[" + CodexTokenPeriod.allCases.map {
                $0 == tokenPeriod ? "• \($0.label)" : "  \($0.label)"
            }.joined(separator: "│") + "]")
            lines.append("\(tokenPeriod.label.lowercased())      : "
                + "\(tokenPeriod.tokens(in: dailyUsage, endingAt: Date()).formatted()) tokens")
        }
        return lines
    }

    private static func mainActionLabel(
        _ action: TerminalMainAction,
        pendingLoginCount: Int
    ) -> String {
        switch action {
        case .addAccount: "Add account"
        case .importAccount: "Advanced import"
        case .checkLogin: "Check pending login (\(pendingLoginCount))"
        case .cancelLogin: "Cancel pending login"
        case .discover: "Discover accounts"
        case .recover: "Recover interrupted work"
        case .quit: "Quit"
        }
    }

    private static func accountActionLabel(
        _ action: TerminalAccountAction,
        isDefault: Bool
    ) -> String {
        switch action {
        case .setDefault: isDefault ? "Set as default  ·  current" : "Set as default"
        case .openCodex: "Open Codex"
        case .refreshLimits: "Refresh limits"
        case .verifyFiles: "Check account files"
        case .back: "Back"
        }
    }

    private func selectedLine(_ value: String) -> String {
        let line = fitted(value)
        guard usesStyles else { return ">" + String(line.dropFirst()) }
        return "\u{1B}[7m" + line + reset
    }

    private func accent(_ value: String) -> String {
        usesStyles ? "\u{1B}[1m" + value + reset : value
    }

    private func muted(_ value: String) -> String {
        usesStyles ? "\u{1B}[2m" + value + reset : value
    }

    private func limitLine(_ name: String, window: CodexRateLimitWindowSnapshot) -> String {
        guard let amount = displayedPercentage(window.usedPercent) else {
            return "\(padded(name, to: 13)): unavailable"
        }
        let filled = Int((Double(amount) / 100 * 24).rounded())
        let meter = String(repeating: "█", count: filled) + String(repeating: "░", count: 24 - filled)
        return "\(padded(name + " " + (showsUsed ? "used" : "left"), to: 13)): "
            + "\(padded("\(amount)%", to: 5))" + accent(meter)
    }

    private func displayedPercentage(_ used: Int?) -> Int? {
        used.map { value in
            let clamped = min(max(value, 0), 100)
            return showsUsed ? clamped : 100 - clamped
        }
    }

    private func fitted(_ value: String) -> String { padded(value, to: width) }

    private func padded(_ value: String, to target: Int) -> String {
        let clipped = String(value.prefix(target))
        return clipped + String(repeating: " ", count: max(0, target - clipped.count))
    }

    private func between(_ leading: String, _ trailing: String, width: Int) -> String {
        leading + String(repeating: " ", count: max(1, width - leading.count - trailing.count)) + trailing
    }

    private static func usageView(_ snapshot: CodexAccountUsageSnapshot) -> UsageView {
        guard let bucket = snapshot.rateLimits?.defaultBucket else {
            return .init(session: nil, weekly: nil)
        }
        if bucket.primary?.windowDurationMinutes == 10_080 {
            return .init(session: bucket.secondary, weekly: bucket.primary)
        }
        return .init(session: bucket.primary, weekly: bucket.secondary)
    }

    private static func accountName(_ identity: AccountIdentity) -> String {
        identity.email ?? identity.accountID ?? "Unresolved account"
    }

    private static func timestamp(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd MMM  HH:mm"
        return formatter.string(from: now).uppercased()
    }

    private static func resetLabel(until reset: Date, now: Date = Date()) -> String {
        let minutes = Int(max(0, reset.timeIntervalSince(now)) / 60)
        if minutes == 0 { return reset > now ? "in <1m" : "now" }
        let days = minutes / 1_440
        let hours = (minutes % 1_440) / 60
        let remainingMinutes = minutes % 60
        if days > 0 { return "in \(days)d \(hours)h \(remainingMinutes)m" }
        if hours > 0 { return "in \(hours)h \(remainingMinutes)m" }
        return "in \(remainingMinutes)m"
    }

}

private final class TerminalInput {
    private var original = termios()
    private let attached: Bool
    private let byteMode: Bool
    private var hasOriginal = false
    private var rawEnabled = false
    let acceptsLegacyCommands: Bool
    var usesArrowNavigation: Bool { byteMode }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        attached = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
        byteMode = attached || environment["AI_MANAGER_TUI_KEYS"] == "always"
        acceptsLegacyCommands = !byteMode
        if attached, tcgetattr(STDIN_FILENO, &original) == 0 {
            hasOriginal = true
            enableRaw()
        }
    }

    deinit { restore() }

    func readKey() -> TerminalKey? {
        guard byteMode else {
            guard let line = readLine(strippingNewline: true) else { return nil }
            return line.first.map(TerminalKey.character) ?? .enter
        }
        guard let byte = readByte() else { return nil }
        switch byte {
        case 3, 27:
            guard byte == 27, let second = readByte(timeoutMilliseconds: 30) else { return .escape }
            guard second == 91 || second == 79,
                  let third = readByte(timeoutMilliseconds: 30) else { return .escape }
            switch third {
            case 65: return .up
            case 66: return .down
            case 67: return .right
            case 68: return .left
            case 72: return .home
            case 70: return .end
            case 49, 52, 55, 56:
                guard readByte(timeoutMilliseconds: 30) == 126 else { return .escape }
                return third == 49 || third == 55 ? .home : .end
            default: return .escape
            }
        case 10, 13:
            return .enter
        default:
            return .character(Character(String(UnicodeScalar(byte))))
        }
    }

    func withCookedInput<T>(_ operation: () async throws -> T) async rethrows -> T {
        let shouldResume = rawEnabled
        if shouldResume { restore() }
        defer { if shouldResume { enableRaw() } }
        return try await operation()
    }

    func choose(
        _ prompt: String,
        options: [String],
        defaultIndex: Int = 0,
        fallback: () -> Int?
    ) -> Int? {
        guard usesArrowNavigation, !options.isEmpty else { return fallback() }
        var index = min(max(0, defaultIndex), options.count - 1)
        enableRaw()
        defer { restore() }
        while true {
            let position = options.count > 1 ? "  \(index + 1)/\(options.count)" : ""
            print(
                "\r\u{1B}[2K\(prompt): ← \u{1B}[7m \(options[index]) \u{1B}[0m →\(position)",
                terminator: "")
            fflush(stdout)
            guard let key = readKey() else { return nil }
            switch key {
            case .up, .left:
                index = (index + options.count - 1) % options.count
            case .down, .right:
                index = (index + 1) % options.count
            case .home:
                index = 0
            case .end:
                index = options.count - 1
            case .enter:
                print("\r\u{1B}[2K\(prompt): \(options[index])")
                return index
            case .escape:
                print("\r\u{1B}[2K\(prompt): Cancelled")
                return nil
            case .character:
                break
            }
        }
    }

    func restore() {
        guard rawEnabled, hasOriginal else { return }
        var settings = original
        tcsetattr(STDIN_FILENO, TCSANOW, &settings)
        rawEnabled = false
    }

    private func enableRaw() {
        guard hasOriginal, !rawEnabled else { return }
        var settings = original
        cfmakeraw(&settings)
        withUnsafeMutableBytes(of: &settings.c_cc) { bytes in
            bytes[Int(VMIN)] = 1
            bytes[Int(VTIME)] = 0
        }
        rawEnabled = tcsetattr(STDIN_FILENO, TCSANOW, &settings) == 0
    }

    private func readByte(timeoutMilliseconds: Int32? = nil) -> UInt8? {
        if let timeoutMilliseconds {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            #if canImport(Darwin)
            let ready = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
            #else
            let ready = Glibc.poll(&descriptor, 1, timeoutMilliseconds)
            #endif
            guard ready > 0 else { return nil }
        }
        var byte: UInt8 = 0
        let count = withUnsafeMutableBytes(of: &byte) { buffer in
            #if canImport(Darwin)
            Darwin.read(STDIN_FILENO, buffer.baseAddress, 1)
            #else
            Glibc.read(STDIN_FILENO, buffer.baseAddress, 1)
            #endif
        }
        return count == 1 ? byte : nil
    }
}

private struct SafeProvider: Encodable {
    let id: ProviderID
    let displayName: String
    let availability: ProviderAvailability
    let unavailableReason: String?

    init(_ provider: ProviderDescriptor) {
        id = provider.id
        displayName = AIManagerCLI.providerName(provider.id)
        availability = provider.availability
        unavailableReason = provider.unavailableReason
    }
}

private struct SafeLoginSession: Encodable {
    let id: UUID
    let providerID: ProviderID
    let createdAt: Date

    init(_ session: AccountLoginSession) {
        id = session.id
        providerID = session.providerID
        createdAt = session.createdAt
    }
}

private struct SafeLoginStart: Encodable {
    let session: SafeLoginSession
    let stagingHome: URL?
    let checkCommand: String
    let cancelCommand: String

    init(_ start: AccountLoginStart) {
        session = SafeLoginSession(start.session)
        stagingHome = start.launchSpec.environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        checkCommand = "ai-manager check-login \(start.session.id.uuidString) --yes"
        cancelCommand = "ai-manager cancel-login \(start.session.id.uuidString) --yes"
    }
}

private struct SafeLoginCheck: Encodable {
    let session: SafeLoginSession
    let state: AccountLoginState
    let account: SafeAccount?
    let message: String

    init(_ check: AccountLoginCheck) {
        session = SafeLoginSession(check.session)
        state = check.state
        account = check.account.map(SafeAccount.init)
        message = check.message
    }
}

private struct LoginCancellationOutput: Encodable {
    let sessionID: UUID
    let state = "cancelled"
}

private struct SafeAccountSnapshot: Encodable {
    let status: StatusOutput
    let providers: [SafeProvider]
    let discoveries: [DiscoveredSource]
    let pendingLoginSessions: [SafeLoginSession]

    init(_ snapshot: AccountSnapshot) {
        status = StatusOutput(snapshot.status)
        providers = snapshot.providers.map(SafeProvider.init)
        discoveries = snapshot.discoveries
        pendingLoginSessions = snapshot.pendingLoginSessions.map(SafeLoginSession.init)
    }
}

private struct SafeStatusSnapshot: Encodable {
    let accounts: [SafeAccount]
    let defaultAccountID: UUID?
    let sharedRoot: URL
    let pendingRecovery: [SafeRecoveryOperation]
    let linkedSettingsDivergences: [LinkedSettingsDivergence]
    let pendingLoginSessions: [SafeLoginSession]

    init(_ snapshot: AccountSnapshot) {
        accounts = snapshot.status.accounts.map(SafeAccount.init)
        defaultAccountID = snapshot.status.defaultAccountID
        sharedRoot = snapshot.status.sharedRoot
        pendingRecovery = snapshot.status.pendingRecovery.map(SafeRecoveryOperation.init)
        linkedSettingsDivergences = snapshot.status.linkedSettingsDivergences
        pendingLoginSessions = snapshot.pendingLoginSessions.map(SafeLoginSession.init)
    }
}

private struct SafeAccount: Encodable {
    let id: UUID
    let identity: AccountIdentity
    let credentialFile: URL
    let home: URL
    let source: URL
    let importedAt: Date
    let verification: VerificationResult
    let lastUsedAt: Date?

    init(_ account: AccountRecord) {
        id = account.id
        identity = account.identity
        credentialFile = account.credentialFile
        home = account.home
        source = account.source
        importedAt = account.importedAt
        verification = account.verification
        lastUsedAt = account.lastUsedAt
    }
}

private struct StatusOutput: Encodable {
    let accounts: [SafeAccount]
    let defaultAccountID: UUID?
    let sharedRoot: URL
    let pendingRecovery: [SafeRecoveryOperation]
    let linkedSettingsDivergences: [LinkedSettingsDivergence]

    init(_ status: ManagerStatus) {
        accounts = status.accounts.map(SafeAccount.init)
        defaultAccountID = status.defaultAccountID
        sharedRoot = status.sharedRoot
        pendingRecovery = status.pendingRecovery.map(SafeRecoveryOperation.init)
        linkedSettingsDivergences = status.linkedSettingsDivergences
    }
}

private struct SafeRecoveryOperation: Encodable {
    let id: UUID
    let kind: String
    let phase: RecoveryPhase
    let source: URL
    let destination: URL
    let backup: URL

    init(_ operation: RecoveryOperation) {
        id = operation.id
        kind = operation.kind
        phase = operation.phase
        source = operation.source
        destination = operation.destination
        backup = operation.backup
    }
}

private struct SafeConflict: Encodable {
    let relativePath: String
    let affectsAllAccounts: Bool
    let externalTarget: URL?
    let externalTargetBytes: Int64?
    let reviewedContentFingerprint: String?

    init(_ conflict: SettingConflict) {
        relativePath = conflict.relativePath
        affectsAllAccounts = conflict.affectsAllAccounts
        externalTarget = conflict.externalTarget
        externalTargetBytes = conflict.externalTargetBytes
        reviewedContentFingerprint = conflict.externalTargetBytes == nil ? nil : conflict.importedDigest
    }
}

private struct PlanOutput: Encodable {
    let id: UUID
    let source: URL
    let destination: URL
    let credentialDestination: URL
    let sharedDestination: URL
    let backup: URL
    let mode: ImportMode
    let identity: AccountIdentity
    let manifest: [ManifestEntry]
    let conflicts: [SafeConflict]
    let warnings: [String]
    let requiredBytes: Int64

    init(_ plan: ImportPlan) {
        id = plan.id
        source = plan.source
        destination = plan.destination
        credentialDestination = plan.credentialDestination
        sharedDestination = plan.sharedDestination
        backup = plan.backup
        mode = plan.mode
        identity = plan.identity
        manifest = plan.manifest
        conflicts = plan.conflicts.map(SafeConflict.init)
        warnings = plan.warnings
        requiredBytes = plan.requiredBytes
    }
}

private struct ImportOutput: Encodable {
    let account: SafeAccount
    let backup: URL
    let importedFiles: Int
    let importedChats: Int
    let unresolved: [String]
    let verification: VerificationResult

    init(_ result: ImportResult) {
        account = SafeAccount(result.account)
        backup = result.backup
        importedFiles = result.importedFiles
        importedChats = result.importedChats
        unresolved = result.unresolved
        verification = result.verification
    }
}

struct CommandLineInput {
    let command: String
    let values: [String]
    let json: Bool
    let confirmed: Bool
    let mode: ImportMode
    let decisions: [String: ConflictChoice]
    let externalReviews: Set<String>
    let recoveryChoice: RecoveryConflictChoice?
    let loginCredentialChoice: ConflictChoice?
    let forwardedArguments: [String]
    let paths: ManagerPaths

    init(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        command = arguments.first ?? "interactive"
        values = Array(arguments.dropFirst())
        json = arguments.contains("--json")
        confirmed = arguments.contains("--yes")
        let modeValue = Self.option("--mode", in: arguments)
        guard modeValue == nil || modeValue == "auth-only" || modeValue == "full" else { throw CLIError.message("Mode must be auth-only or full.") }
        mode = modeValue == "full" ? .full : .authOnly
        var choices: [String: ConflictChoice] = [:]
        Self.options("--keep-shared", in: arguments).forEach { choices[$0] = .keepShared }
        Self.options("--use-imported", in: arguments).forEach { choices[$0] = .useImported }
        decisions = choices
        externalReviews = Set(Self.options("--review-external", in: arguments))
        let recoveryChoices = arguments.filter { ["--keep-current", "--restore-backup"].contains($0) }
        if command == "resolve-recovery" {
            guard recoveryChoices.count == 1 else {
                throw CLIError.message("Choose exactly one of --keep-current or --restore-backup.")
            }
        }
        recoveryChoice = recoveryChoices.first == "--keep-current" ? .preserveCurrent
            : recoveryChoices.first == "--restore-backup" ? .restoreBackup : nil
        let loginChoices = arguments.filter { ["--keep-saved", "--use-login"].contains($0) }
        guard loginChoices.count <= 1 else {
            throw CLIError.message("Choose at most one of --keep-saved or --use-login.")
        }
        loginCredentialChoice = loginChoices.first == "--keep-saved" ? .keepShared
            : loginChoices.first == "--use-login" ? .useImported : nil
        forwardedArguments = arguments.firstIndex(of: "--").map { Array(arguments.dropFirst($0 + 1)) } ?? []
        paths = ManagerPaths.environment(environment)
    }

    var path: URL? { positional.first.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) } }
    var positional: [String] {
        var result: [String] = []; var skip = false
        for value in values.prefix(while: { $0 != "--" }) {
            if skip { skip = false; continue }
            if ["--mode", "--keep-shared", "--use-imported", "--review-external", "--fingerprint", "--replacement"].contains(value) { skip = true; continue }
            if value.hasPrefix("--") { continue }
            result.append(value)
        }
        return result
    }

    func requiredPath() throws -> URL { guard let path else { throw CLIError.message("A source path is required.") }; return path }
    func requiredAccountID() throws -> UUID { guard let value = positional.first, let id = UUID(uuidString: value) else { throw CLIError.message("A valid account UUID is required.") }; return id }
    func requiredOperationID() throws -> UUID { guard let value = positional.first, let id = UUID(uuidString: value) else { throw CLIError.message("A valid recovery operation UUID is required.") }; return id }
    func requiredLoginSessionID() throws -> UUID { guard let value = positional.first, let id = UUID(uuidString: value) else { throw CLIError.message("A valid login session UUID is required.") }; return id }
    func optionalAccountID(_ name: String) throws -> UUID? {
        guard values.contains(name) else { return nil }
        guard let value = option(name) else {
            throw CLIError.message("A replacement account UUID is required after \(name).")
        }
        guard let id = UUID(uuidString: value) else {
            throw CLIError.message("A valid replacement account UUID is required.")
        }
        return id
    }
    func providerID() throws -> ProviderID {
        let value = positional.first ?? ProviderID.codex.rawValue
        guard let provider = AccountManager.providerCatalog.first(where: { $0.id.rawValue == value }) else {
            throw CLIError.message("Unknown provider '\(value)'. Run ai-manager providers.")
        }
        return provider.id
    }
    func requiredRecoveryChoice() throws -> RecoveryConflictChoice {
        guard let recoveryChoice else { throw CLIError.message("Choose exactly one of --keep-current or --restore-backup.") }
        return recoveryChoice
    }

    func option(_ name: String) -> String? { Self.option(name, in: values) }

    private static func option(_ name: String, in values: [String]) -> String? {
        guard let index = values.firstIndex(of: name), values.indices.contains(index + 1) else { return nil }
        return values[index + 1]
    }
    private static func options(_ name: String, in values: [String]) -> [String] {
        values.indices.compactMap { values[$0] == name && values.indices.contains($0 + 1) ? values[$0 + 1] : nil }
    }
}

enum CLIError: LocalizedError {
    case message(String), confirmationRequired, cancelled
    var errorDescription: String? {
        switch self {
        case .message(let value): value
        case .confirmationRequired: "This command can change account data. Review it, then repeat with --yes and any required choices."
        case .cancelled: "Cancelled. No changes were made."
        }
    }
}
