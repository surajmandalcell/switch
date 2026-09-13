import Foundation
import AIManagerCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

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
        case "status": await output(try await manager.status(), json: input.json)
        case "discover": await output(manager.discover(explicit: input.path), json: input.json)
        case "plan":
            let path = try input.requiredPath()
            var plan = try await manager.planImport(source: path, mode: input.mode)
            plan = try await reviewExternalSettings(plan, decisions: input.decisions, approvedPaths: input.externalReviews, manager: manager, report: false)
            await output(plan, json: input.json)
        case "import": try await importAccount(input, manager: manager)
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
        case "interactive": try await interactive(manager)
        default: throw CLIError.message("Unknown command '\(input.command)'. Run ai-manager help.")
        }
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

    static func interactive(_ manager: AccountManager) async throws {
        while true {
            let status = try await manager.status()
            print("\nSwitch")
            for (index, account) in status.accounts.enumerated() {
                let marker = account.id == status.defaultAccountID ? "default" : account.verification.state.rawValue
                print("  \(index + 1). \(displayName(account.identity)) [\(marker)]")
            }
            print("\n[d] Discover  [i] Import  [u] Use by default  [o] Open  [v] Verify  [r] Recover  [q] Quit")
            guard let choice = readLine(strippingNewline: true)?.lowercased() else { return }
            do {
                switch choice {
                case "d": await printDiscovery(manager.discover())
                case "i": try await interactiveImport(manager)
                case "u": if let account = chooseAccount(status.accounts) { await output(try await manager.switchDefault(to: account.id), json: false) }
                case "o": if let account = chooseAccount(status.accounts) { _ = try await manager.activateAndRun(accountID: account.id) }
                case "v": if let account = chooseAccount(status.accounts) { await output(manager.verifyLocal(accountID: account.id), json: false) }
                case "r": try await interactiveRecovery(manager)
                case "q": return
                default: print("Choose one of the shown letters.")
                }
            } catch {
                print("Error: \(error.localizedDescription)")
            }
        }
    }

    static func interactiveImport(_ manager: AccountManager) async throws {
        print("Codex home or auth.json path:", terminator: " ")
        guard let value = readLine(), !value.isEmpty else { return }
        print("Mode: [1] Auth only  [2] Auth, settings, and chats:", terminator: " ")
        let mode: ImportMode = readLine() == "2" ? .full : .authOnly
        var plan = try await manager.planImport(source: URL(fileURLWithPath: NSString(string: value).expandingTildeInPath), mode: mode)
        printPlan(plan)
        var decisions: [String: ConflictChoice] = [:]
        for conflict in plan.conflicts {
            guard conflict.externalTarget != nil else {
                decisions[conflict.relativePath] = try askConflict(conflict.relativePath)
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
            decisions[conflict.relativePath] = askYes("Use this imported linked setting?") ? .useImported : .keepShared
        }
        guard askYes("Import this reviewed plan?") else { print("Import cancelled."); return }
        let result = try await manager.importAccount(plan: plan, decisions: decisions)
        await output(result, json: false)
        if !result.unresolved.isEmpty {
            throw CLIError.message("Import completed with unresolved items; review the reported paths before using this account.")
        }
    }

    static func interactiveRecovery(_ manager: AccountManager) async throws {
        await output(try await manager.recover(), json: false)
        let conflicts = try await manager.status().pendingRecovery.filter { $0.phase == .conflicted }
        for operation in conflicts {
            print("Recovery conflict \(operation.id.uuidString) (\(operation.kind))")
            print("  Current data: \(operation.destination.path)")
            print("  Protected backup: \(operation.backup.path)")
            print("[k] Keep current data  [b] Restore protected backup  [s] Skip:", terminator: " ")
            let choice: RecoveryConflictChoice
            switch readLine()?.lowercased() {
            case "k": choice = .preserveCurrent
            case "b":
                guard askYes("Restore the protected backup? The current data will be preserved inside it.") else {
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

    static func askConflict(_ path: String) throws -> ConflictChoice {
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
        guard askYes(prompt) else { throw CLIError.cancelled }
    }

    static func askYes(_ prompt: String) -> Bool {
        print("\(prompt) [y/N]", terminator: " ")
        return readLine()?.lowercased() == "y"
    }

    static func output<T: Encodable>(_ value: T, json: Bool) async {
        if json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            let data: Data?
            switch value {
            case let status as ManagerStatus: data = try? encoder.encode(StatusOutput(status))
            case let plan as ImportPlan: data = try? encoder.encode(PlanOutput(plan))
            case let result as ImportResult: data = try? encoder.encode(ImportOutput(result))
            default: data = try? encoder.encode(value)
            }
            if let data { print(String(decoding: data, as: UTF8.self)); return }
        }
        switch value {
        case let status as ManagerStatus:
            print("Shared settings: \(status.sharedRoot.path)")
            print("Default account: \(status.defaultAccountID?.uuidString ?? "none")")
            for account in status.accounts { print("\(account.id.uuidString)\t\(displayName(account.identity))\t\(account.verification.state.rawValue)") }
            if !status.pendingRecovery.isEmpty { print("Pending recovery: \(status.pendingRecovery.count)") }
        case let sources as [DiscoveredSource]: printDiscovery(sources)
        case let result as ImportResult:
            print("Saved \(displayName(result.account.identity)) at \(result.account.credentialFile.path).")
            print("Backup: \(result.backup.path); files: \(result.importedFiles); chats: \(result.importedChats)")
            for item in result.unresolved { print("Unresolved: \(item)") }
        case let result as SwitchResult: print("Default account changed to \(result.accountID.uuidString). Backup: \(result.backup.path)")
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

    static let usage = """
    Switch manages file-based Codex accounts without using Keychain.

    Usage:
      ai-manager status [--json]
      ai-manager discover [path] [--json]
      ai-manager plan <path> [--mode auth-only|full] [--use-imported path] [--review-external path] [--json]
      ai-manager import <path> [--mode auth-only|full] [--keep-shared path] [--use-imported path] [--review-external path] [--yes] [--json]
      ai-manager use <account-uuid> [--yes] [--json]
      ai-manager open <account-uuid> [-- codex arguments]
      ai-manager saved-auth <account-uuid>
      ai-manager verify <account-uuid> [--json]
      ai-manager recover [--yes] [--json]
      ai-manager resolve-recovery <operation-uuid> (--keep-current|--restore-backup) [--yes] [--json]
      ai-manager inspect-links [account-uuid] [--json]
      ai-manager repair-link <account-uuid> <settings-path> --fingerprint <sha256> [--yes] [--json]
      ai-manager interactive

    Isolation overrides: AI_MANAGER_ROOT, AI_MANAGER_DEFAULT_HOME,
    AI_MANAGER_CREDENTIAL_STORE, AI_MANAGER_SHARED_ROOT,
    AI_MANAGER_CODEX_EXECUTABLE.
    """
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
        forwardedArguments = arguments.firstIndex(of: "--").map { Array(arguments.dropFirst($0 + 1)) } ?? []
        paths = ManagerPaths.environment(environment)
    }

    var path: URL? { positional.first.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) } }
    var positional: [String] {
        var result: [String] = []; var skip = false
        for value in values.prefix(while: { $0 != "--" }) {
            if skip { skip = false; continue }
            if ["--mode", "--keep-shared", "--use-imported", "--review-external", "--fingerprint"].contains(value) { skip = true; continue }
            if value.hasPrefix("--") { continue }
            result.append(value)
        }
        return result
    }

    func requiredPath() throws -> URL { guard let path else { throw CLIError.message("A source path is required.") }; return path }
    func requiredAccountID() throws -> UUID { guard let value = positional.first, let id = UUID(uuidString: value) else { throw CLIError.message("A valid account UUID is required.") }; return id }
    func requiredOperationID() throws -> UUID { guard let value = positional.first, let id = UUID(uuidString: value) else { throw CLIError.message("A valid recovery operation UUID is required.") }; return id }
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
        case .confirmationRequired: "Review the plan, then repeat with --yes and explicit choices for every conflict."
        case .cancelled: "Cancelled. No changes were made."
        }
    }
}
