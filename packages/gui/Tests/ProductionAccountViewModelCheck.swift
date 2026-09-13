import AppKit
import Foundation
import AIManagerCore

@main
struct ProductionAccountViewModelCheck {
    @MainActor
    static func main() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(
            path: "iia-directeur-gui-check-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let launched = root.appending(path: "codex-was-launched")
        let executable = root.appending(path: "bin/codex")
        try fileManager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\ntouch '\(launched.path)'\n".utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let paths = ManagerPaths(
            applicationSupport: root.appending(path: "support", directoryHint: .isDirectory),
            defaultHome: root.appending(path: "user/.codex", directoryHint: .isDirectory),
            sharedRoot: root.appending(path: "user/.codex", directoryHint: .isDirectory),
            orcaAccountsRoot: root.appending(path: "orca", directoryHint: .isDirectory),
            codexExecutable: executable,
            isolationRoot: root
        )
        try fileManager.createDirectory(at: paths.defaultHome, withIntermediateDirectories: true)
        let sessions = paths.sharedRoot.appending(path: "sessions", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"shared\"}}\n".utf8)
            .write(to: sessions.appending(path: "shared.jsonl"))
        try Data("shared-setting".utf8).write(to: paths.sharedRoot.appending(path: "config.toml"))
        let sharedRules = paths.sharedRoot.appending(path: "rules", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: sharedRules, withIntermediateDirectories: true)
        try Data("shared-rule".utf8).write(to: sharedRules.appending(path: "rule.md"))

        let authOnlySource = root.appending(path: "user/.codex2", directoryHint: .isDirectory)
        let authOnlyData = try writeSource(
            at: authOnlySource, account: "account-auth-only", workspace: "personal")
        let fullSource = root.appending(path: "chosen/full-source", directoryHint: .isDirectory)
        let fullData = try writeSource(
            at: fullSource, account: "account-full", workspace: "team")
        try Data("imported-setting".utf8).write(to: fullSource.appending(path: "config.toml"))
        let externalRules = root.appending(path: "external-rules", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: externalRules, withIntermediateDirectories: true)
        try Data("reviewed-external-rule".utf8).write(to: externalRules.appending(path: "rule.md"))
        try fileManager.createSymbolicLink(
            at: fullSource.appending(path: "rules"), withDestinationURL: externalRules)
        let fullSessions = fullSource.appending(path: "sessions", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: fullSessions, withIntermediateDirectories: true)
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"full\"}}\n".utf8)
            .write(to: fullSessions.appending(path: "full.jsonl"))

        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let model = AccountViewModel(paths: paths, manager: manager)
        try expect(!model.isUnavailable, "Production model was unavailable")
        try expect(model.selectedProviderID == .codex, "Codex was not the selected provider")
        try expect(!model.hasLoaded, "Production model should begin in a loading state")
        await model.load()
        try expect(model.hasLoaded, "Production model did not leave its loading state")
        try expect(model.status?.accounts.isEmpty == true, "Production registry was not initially empty")

        await model.beginImport()
        let discovered = try expect(
            model.discoveries.first { $0.path.standardizedFileURL == authOnlySource.standardizedFileURL },
            "Real discovery did not find .codex2")
        try expect(discovered.support == .supportedChatGPT, "Discovered auth source was unsupported")
        model.selectedSourceID = discovered.id
        model.importMode = .authOnly
        await model.reviewImport()
        try expect(model.importPlan?.mode == .authOnly, "Auth-only plan was not produced")
        try expect(
            model.importPlan?.manifest.contains { $0.relativePath == "auth.json" && $0.selected } == true,
            "Auth-only plan omitted credentials")
        await model.commitImport()
        try expect(model.errorMessage == nil, "Auth-only import failed: \(model.errorMessage ?? "unknown")")
        try expect(model.status?.accounts.count == 1, "Auth-only import did not add one account")
        try expect(model.importResult?.importedChats == 0, "Auth-only import copied chats")
        try expect(model.selectedAccount?.identity.accountID == "account-auth-only", "Wrong auth-only identity")
        try expect(try Data(contentsOf: authOnlySource.appending(path: "auth.json")) == authOnlyData,
                   "Auth-only import changed its source")

        await model.discover(explicit: fullSource)
        let explicit = try expect(
            model.discoveries.first { $0.path.standardizedFileURL == fullSource.standardizedFileURL },
            "Explicit full-import source was not discovered")
        await model.discover(explicit: fullSource.appending(path: "auth.json"))
        try expect(model.selectedSourceID == explicit.id,
                   "Choosing auth.json did not select its containing Codex folder")
        model.selectedSourceID = explicit.id
        model.importMode = .full
        await model.reviewImport()
        let initialPlan = try expect(model.importPlan, "Full import plan was not produced")
        try expect(initialPlan.manifest.contains { $0.category == .transcript && $0.selected },
                   "Full plan omitted chat data")
        try expect(initialPlan.conflicts.contains { $0.relativePath == "config.toml" },
                   "Full plan omitted the shared-setting conflict")
        try expect(initialPlan.conflicts.first { $0.relativePath == "rules" }?.externalTarget != nil,
                   "Full plan omitted the external-link conflict")

        await model.commitImport()
        try expect(model.errorMessage?.isEmpty == false, "Missing conflict choices did not reach failure UI")
        await model.reviewExternalSetting("rules")
        let reviewedPlan = try expect(model.importPlan, "External-link review discarded the plan")
        try expect(reviewedPlan.conflicts.first { $0.relativePath == "rules" }?.externalTargetBytes != nil,
                   "External-link review did not record target size")
        model.conflictChoices = Dictionary(
            uniqueKeysWithValues: reviewedPlan.conflicts.map { ($0.relativePath, .keepShared) })
        model.conflictChoices["rules"] = .useImported
        await model.commitImport()
        try expect(model.errorMessage == nil, "Full import failed: \(model.errorMessage ?? "unknown")")
        try expect(model.status?.accounts.count == 2, "Full import did not add a distinct account")
        try expect(model.selectedAccount?.identity.accountID == "account-full", "Wrong full-import identity")
        try expect(model.importResult?.importedChats == 1, "Full import did not merge one chat")
        try expect(try Data(contentsOf: sharedRules.appending(path: "rule.md")) == Data("reviewed-external-rule".utf8),
                   "Reviewed external rules were not imported")
        try expect(try Data(contentsOf: fullSource.appending(path: "auth.json")) == fullData,
                   "Full import changed its source")

        await model.switchDefault()
        try expect(model.status?.defaultAccountID == model.selectedAccountID, "Default account did not switch")
        try expect(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")) == fullData,
                   "Default switch published the wrong credential")
        try expect(try Data(contentsOf: paths.defaultHome.appending(path: "config.toml")) == Data("shared-setting".utf8),
                   "Default switch changed shared settings")

        await model.openAccount()
        let launchFile = paths.applicationSupport.appending(path: "Launch/Open Switch Account.command")
        let launchContents = try String(contentsOf: launchFile, encoding: .utf8)
        try expect(launchContents.contains("export CODEX_HOME="), "Launch file omitted CODEX_HOME")
        try expect(launchContents.contains(executable.path), "Launch file omitted the Codex executable")
        try expect(model.notice?.contains("Terminal was not opened") == true,
                   "Isolated launch did not report Terminal suppression")
        try expect(!fileManager.fileExists(atPath: launched.path), "The isolated launch started Codex")

        let coordinatedLaunch = try model.makeCoordinatedLaunchArtifact(
            accountID: selectedAccountID(model), helper: executable)
        let coordinatedContents = try String(contentsOf: coordinatedLaunch, encoding: .utf8)
        try expect(coordinatedContents.contains("'open' '\(selectedAccountID(model).uuidString)'"),
                   "The packaged launch file did not delegate activation to the CLI")
        try expect(!coordinatedContents.contains("export CODEX_HOME="),
                   "The packaged launch file captured a stale Codex home")

        let pasteboardChange = NSPasteboard.general.changeCount
        model.copySavedAuthPath()
        try expect(NSPasteboard.general.changeCount == pasteboardChange,
                   "The isolated profile action changed the clipboard")
        try expect(model.notice?.contains("clipboard was not changed") == true,
                   "Clipboard suppression was not reported")
        model.showSharedRoot()
        try expect(model.notice?.contains("Finder was not opened") == true,
                   "Finder suppression was not reported")

        let selected = try expect(model.selectedAccount, "The full account selection was lost")
        let localConfig = selected.home.appending(path: "config.toml")
        try fileManager.removeItem(at: localConfig)
        try Data("local-repair".utf8).write(to: localConfig)
        await model.refresh()
        let issue = try expect(
            model.status?.linkedSettingsDivergences.first { $0.accountID == selected.id },
            "Linked-setting divergence was not surfaced")
        await model.repairLinkedSetting(issue)
        try expect(model.errorMessage == nil, "Linked-setting repair failed")
        try expect(model.status?.linkedSettingsDivergences.isEmpty == true,
                   "Linked-setting repair did not clear the issue")
        try expect(try fileManager.destinationOfSymbolicLink(atPath: localConfig.path)
                   == paths.sharedRoot.appending(path: "config.toml").path,
                   "Linked-setting repair did not restore the shared link")

        try fileManager.removeItem(at: localConfig)
        let recoverableEdit = Data("recoverable-local-edit".utf8)
        try recoverableEdit.write(to: localConfig)
        let crashingManager = try AccountManager(
            paths: paths,
            writerCheck: { _ in .inactive },
            faultInjector: { point in
                if point == .afterHomePublication {
                    throw AIManagerError.operationFailed("synthetic linked-setting interruption")
                }
            })
        let crashingModel = AccountViewModel(paths: paths, manager: crashingManager)
        await crashingModel.load()
        let crashingIssue = try expect(
            crashingModel.status?.linkedSettingsDivergences.first { $0.accountID == selected.id },
            "Recoverable linked-setting issue was not surfaced")
        await crashingModel.repairLinkedSetting(crashingIssue)
        try expect(crashingModel.errorMessage?.contains("synthetic linked-setting interruption") == true,
                   "Injected repair failure did not reach failure UI")

        let recoveryManager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let recoveryModel = AccountViewModel(paths: paths, manager: recoveryManager)
        await recoveryModel.load()
        try expect(recoveryModel.status?.pendingRecovery.count == 1,
                   "Interrupted repair did not surface recovery work")
        await recoveryModel.recover()
        try expect(recoveryModel.errorMessage == nil, "Recovery failed")
        try expect(recoveryModel.status?.pendingRecovery.isEmpty == true,
                   "Recovery work remained pending")
        try expect(try Data(contentsOf: localConfig) == recoverableEdit,
                   "Recovery did not restore the local edit")

        try await checkUnavailableState(root: root)
        print("PRODUCTION_ACCOUNT_VIEW_MODEL_PASS")
    }

    @MainActor
    private static func checkUnavailableState(root: URL) async throws {
        let unavailableSupport = root.appending(path: "unavailable-support")
        try Data("not-a-directory".utf8).write(to: unavailableSupport)
        let unavailablePaths = ManagerPaths(
            applicationSupport: unavailableSupport,
            defaultHome: root.appending(path: "unavailable-default", directoryHint: .isDirectory),
            sharedRoot: root.appending(path: "unavailable-shared", directoryHint: .isDirectory),
            orcaAccountsRoot: root.appending(path: "unavailable-orca", directoryHint: .isDirectory),
            codexExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            isolationRoot: root
        )
        let unavailable = AccountViewModel(paths: unavailablePaths)
        let unavailableError = unavailable.errorMessage
        try expect(unavailable.isUnavailable, "Unavailable model did not fail closed")
        await unavailable.load()
        await unavailable.beginImport()
        await unavailable.openAccount()
        unavailable.copySavedAuthPath()
        unavailable.showSharedRoot()
        try expect(unavailable.errorMessage == unavailableError, "Unavailable actions changed the failure UI")
        try expect(unavailable.status == nil && unavailable.notice == nil,
                   "Unavailable actions produced usable state")
    }

    private static func writeSource(at home: URL, account: String, workspace: String) throws -> Data {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let data = try authData(account: account, workspace: workspace)
        try data.write(to: home.appending(path: "auth.json"))
        return data
    }

    @MainActor
    private static func selectedAccountID(_ model: AccountViewModel) throws -> UUID {
        try expect(model.selectedAccountID, "The selected account ID was missing")
    }

    private static func authData(account: String, workspace: String) throws -> Data {
        let claims = try JSONSerialization.data(withJSONObject: [
            "email": "\(account)@example.test",
            "chatgpt_user_id": "user-\(account)",
            "chatgpt_account_id": account,
            "workspace_id": workspace,
        ])
        let payload = claims.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return try JSONSerialization.data(withJSONObject: [
            "last_refresh": "2026-01-01T00:00:00Z",
            "tokens": [
                "access_token": "header.\(payload).signature",
                "account_id": account,
                "refresh_token": "synthetic",
            ],
        ], options: [.sortedKeys])
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw CheckFailure(message: message) }
    }

    private static func expect<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else { throw CheckFailure(message: message) }
        return value
    }
}

private struct CheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
