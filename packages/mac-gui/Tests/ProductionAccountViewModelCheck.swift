import AppKit
import Combine
import Foundation
import AIManagerCore

private actor CountingChatHistoryProvider: ChatHistoryProviding {
    private var refreshes = 0

    func refresh(query: String) async throws -> ChatHistorySnapshot {
        refreshes += 1
        return ChatHistorySnapshot()
    }

    func search(query: String) async -> ChatHistorySnapshot { ChatHistorySnapshot() }
    func detail(for id: String) async throws -> ChatThreadDetail? { nil }
    func clearCache() async throws {}
    func refreshCount() -> Int { refreshes }
}

private struct SilentChatHistoryMonitor: ChatHistoryMonitoring {
    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

@main
struct ProductionAccountViewModelCheck {
    @MainActor
    static func main() async throws {
        try expect(AccountViewModel.usageRefreshInterval == 3 * 60,
                   "Usage refresh cadence is not three minutes")
        let refreshClock = Date(timeIntervalSince1970: 10_000)
        try expect(!AccountViewModel.automaticUsageRefreshIsDue(
            fetchedAt: refreshClock.addingTimeInterval(-179), failedAt: nil, now: refreshClock),
            "Fresh usage was scheduled before three minutes")
        try expect(AccountViewModel.automaticUsageRefreshIsDue(
            fetchedAt: refreshClock.addingTimeInterval(-180), failedAt: nil, now: refreshClock),
            "Three-minute-old usage was not scheduled")
        try expect(!AccountViewModel.automaticUsageRefreshIsDue(
            fetchedAt: nil, failedAt: refreshClock.addingTimeInterval(-299), now: refreshClock),
            "A failed refresh ignored its five-minute cooldown")
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
        try Data(
            """
            {"timestamp":"2026-09-13T04:00:00Z","type":"session_meta","payload":{"id":"shared","cwd":"/Projects/Switch"}}
            {"timestamp":"2026-09-13T04:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"Inspect the shared chat library"}}
            {"timestamp":"2026-09-13T04:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"The synthetic chat is **readable**."}]}}

            """.utf8)
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
        let countingHistory = CountingChatHistoryProvider()
        let stableHistoryModel = AccountViewModel(
            paths: paths,
            manager: manager,
            chatHistoryProvider: countingHistory,
            chatHistoryMonitor: SilentChatHistoryMonitor())
        let historyWatch = Task { await stableHistoryModel.watchActivity() }
        for _ in 0..<100 where await countingHistory.refreshCount() == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let initialRefreshCount = await countingHistory.refreshCount()
        try expect(initialRefreshCount == 1,
                   "Chat History did not perform its initial scan")
        try await Task.sleep(for: .milliseconds(40))
        var idlePublicationCount = 0
        let idlePublication = stableHistoryModel.objectWillChange.sink {
            idlePublicationCount += 1
        }
        try await Task.sleep(for: .milliseconds(1_600))
        historyWatch.cancel()
        await historyWatch.value
        let idleRefreshCount = await countingHistory.refreshCount()
        try expect(idleRefreshCount == 1,
                   "Chat History refreshed an unchanged library on a timer")
        try expect(idlePublicationCount == 0,
                   "Chat History republished its view while the library was unchanged")
        withExtendedLifetime(idlePublication) {}

        let eventHistory = CountingChatHistoryProvider()
        let eventHistoryModel = AccountViewModel(
            paths: paths, manager: manager, chatHistoryProvider: eventHistory)
        let eventWatch = Task { await eventHistoryModel.watchActivity() }
        for _ in 0..<100 where await eventHistory.refreshCount() == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(350))
        try Data("event".utf8).write(to: paths.sharedRoot.appending(path: "history-event-probe"))
        for _ in 0..<200 where await eventHistory.refreshCount() < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let eventRefreshCount = await eventHistory.refreshCount()
        eventWatch.cancel()
        await eventWatch.value
        try expect(eventRefreshCount >= 2,
                   "Chat History did not refresh after a file-system change")

        let model = AccountViewModel(paths: paths, manager: manager)
        try expect(!model.isUnavailable, "Production model was unavailable")
        try expect(model.selectedProviderID == .codex, "Codex was not the selected provider")
        try expect(!model.hasLoaded, "Production model should begin in a loading state")
        await model.load()
        try expect(model.hasLoaded, "Production model did not leave its loading state")
        try expect(model.status?.accounts.isEmpty == true, "Production registry was not initially empty")
        var activationDisabledControls = false
        let activationBusy = model.$isBusy.dropFirst().sink {
            activationDisabledControls = activationDisabledControls || $0
        }
        await model.reloadAfterActivation()
        withExtendedLifetime(activationBusy) {}
        try expect(!activationDisabledControls,
                   "Returning to the app disables controls and resets their hover colors")
        var activationPublications = 0
        let activationUpdates = model.objectWillChange.sink { activationPublications += 1 }
        await model.reloadAfterActivation()
        withExtendedLifetime(activationUpdates) {}
        try expect(activationPublications == 0,
                   "Unchanged activation republishes the interface \(activationPublications) times")
        await model.refreshChatHistory(query: "shared chat")
        try expect(model.chatHistory.totalThreadCount == 1, "Production chat index missed its transcript")
        try expect(model.chatHistory.matchingThreadCount == 1, "Production chat search missed its transcript")
        try expect(model.selectedChat?.messages.map(\.role) == [.user, .assistant],
                   "Production chat detail did not decode user and assistant messages")
        try expect(
            model.renderedChatMessages.values.contains {
                String($0.characters) == "The synthetic chat is readable."
            },
            "Production chat detail did not prepare Markdown before publication")

        let cleanupData = try await model.cleanupData()
        try expect(cleanupData.conversations.count == 1, "Cleanup inventory missed the shared conversation")
        let cleanupPlan = try await model.reviewConversationCleanup(cleanupData.conversations)
        try await model.applyCleanup(cleanupPlan, samples: [], clearIndex: false)
        let trashedData = try await model.cleanupData()
        try expect(trashedData.conversations.isEmpty && trashedData.trash.count == 1,
                   "Production Cleanup did not expose recoverable conversation trash")
        try await model.restoreCleanup(trashedData.trash[0].id)
        let restoredData = try await model.cleanupData()
        try expect(restoredData.conversations.count == 1 && restoredData.trash.isEmpty,
                   "Production Cleanup did not restore the original conversation")

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

        model.closeAccountModal()
        let orderBeforeActivation = model.status!.accounts.map(\.id)
        let selectionBeforeActivation = model.selectedAccountID
        _ = try await manager.reorderAccounts(Array(orderBeforeActivation.reversed()))
        await model.reloadAfterActivation()
        try expect(model.status?.accounts.map(\.id) == Array(orderBeforeActivation.reversed()),
                   "Activation ignored changed account data")
        try expect(model.selectedAccountID == selectionBeforeActivation,
                   "Activation changed the selected account")
        _ = try await manager.reorderAccounts(orderBeforeActivation)
        await model.reloadAfterActivation()

        await model.switchDefault()
        try expect(model.status?.defaultAccountID == model.selectedAccountID, "Default account did not switch")
        try expect(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")) == fullData,
                   "Default switch published the wrong credential")
        try expect(try Data(contentsOf: paths.defaultHome.appending(path: "config.toml")) == Data("shared-setting".utf8),
                   "Default switch changed shared settings")

        let fullAccountID = try selectedAccountID(model)
        let alternateAccountID = try expect(
            model.status?.accounts.first(where: { $0.id != fullAccountID })?.id,
            "A second account was unavailable for the Open Codex activation check")
        let originalOrder = model.status?.accounts.map(\.id) ?? []
        await model.moveAccount(originalOrder[0], to: originalOrder[1])
        try expect(model.errorMessage == nil, "Account reordering failed")
        try expect(model.status?.accounts.map(\.id) == [originalOrder[1], originalOrder[0]],
                   "Dragging to the next account did not move the account down")
        try expect(model.selectedAccountID == fullAccountID && model.status?.defaultAccountID == fullAccountID,
                   "Reordering changed selection or default")
        try expect(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")) == fullData,
                   "Reordering changed the live sign-in")
        try expect(model.adjacentAccountID(to: originalOrder[0], offset: -1) == originalOrder[1]
                   && model.adjacentAccountID(to: originalOrder[0], offset: 1) == nil,
                   "Move up/down actions target the wrong neighbor")
        let reorderedStatus = try await manager.status()
        try expect(reorderedStatus.accounts.map(\.id) == [originalOrder[1], originalOrder[0]],
                   "The app's account order did not reach the shared registry")
        await model.moveAccount(originalOrder[0], to: originalOrder[1])
        try expect(model.status?.accounts.map(\.id) == originalOrder,
                   "Dragging to a preceding account did not move the account up")
        await model.openAccount(alternateAccountID)
        try expect(model.status?.defaultAccountID == alternateAccountID,
                   "Open Codex did not activate its requested account before launch")
        await model.openAccount(fullAccountID)
        try expect(model.status?.defaultAccountID == fullAccountID,
                   "Open Codex did not restore the requested account before launch")
        let launchFile = paths.applicationSupport.appending(path: "Launch/Open Switch Account.command")
        let launchContents = try String(contentsOf: launchFile, encoding: .utf8)
        try expect(launchContents.contains("export CODEX_HOME="), "Launch file omitted CODEX_HOME")
        try expect(launchContents.contains(executable.path), "Launch file omitted the Codex executable")
        try expect(model.notice?.contains("Terminal was not opened") == true,
                   "Isolated launch did not report Terminal suppression")
        try expect(!fileManager.fileExists(atPath: launched.path), "The isolated launch started Codex")

        let pasteboardChange = NSPasteboard.general.changeCount
        model.copySavedAuthPath()
        try expect(NSPasteboard.general.changeCount == pasteboardChange,
                   "The isolated profile action changed the clipboard")
        try expect(model.notice?.contains("clipboard was not changed") == true,
                   "Clipboard suppression was not reported")
        model.copyWarnings(["First warning", "Second warning"])
        try expect(NSPasteboard.general.changeCount == pasteboardChange,
                   "The isolated warning action changed the clipboard")
        try expect(model.notice == "2 warnings validated in isolation. The clipboard was not changed.",
                   "Warning clipboard suppression was not reported")
        model.showDataLocation(model.paths.defaultHome, name: "Codex home")
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
        try expect(recoveryModel.errorMessage == nil, "Automatic recovery failed")
        try expect(recoveryModel.status?.pendingRecovery.isEmpty == true,
                   "Recoverable work remained pending after launch")
        try expect(try Data(contentsOf: localConfig) == recoverableEdit,
                   "Launch recovery did not restore the local edit")

        let deletionAccount = try expect(
            model.status?.accounts.first(where: { $0.id != model.status?.defaultAccountID }),
            "A non-default account was unavailable for deletion")
        let deletionCredential = deletionAccount.credentialFile
        let accountCountBeforeDeletion = try expect(model.status?.accounts.count, "Account count was unavailable")
        await model.deleteAccount(deletionAccount.id)
        try expect(model.errorMessage == nil, "Non-default account deletion failed")
        try expect(model.status?.accounts.count == accountCountBeforeDeletion - 1,
                   "Account deletion did not refresh the model")
        try expect(!fileManager.fileExists(atPath: deletionCredential.path),
                   "Account deletion left the saved credential in place")
        try expect(try Data(contentsOf: authOnlySource.appending(path: "auth.json")) == authOnlyData,
                   "Account deletion changed the original auth source")

        try await checkUnavailableState(root: root)
        try await checkDefaultDeletion(root: root)
        print("PRODUCTION_ACCOUNT_VIEW_MODEL_PASS")
    }

    @MainActor
    private static func checkDefaultDeletion(root: URL) async throws {
        let testRoot = root.appending(path: "default-deletion")
        let paths = ManagerPaths(
            applicationSupport: testRoot.appending(path: "support"),
            defaultHome: testRoot.appending(path: "live"),
            sharedRoot: testRoot.appending(path: "live"),
            orcaAccountsRoot: testRoot.appending(path: "orca"),
            codexExecutable: URL(fileURLWithPath: "/usr/bin/true"), isolationRoot: testRoot)
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        var accounts: [AccountRecord] = []
        for name in ["first", "previous", "recent"] {
            let source = testRoot.appending(path: name)
            _ = try writeSource(at: source, account: name, workspace: "personal")
            let plan = try await manager.planImport(source: source, mode: .authOnly)
            accounts.append(try await manager.importAccount(plan: plan).account)
        }
        _ = try await manager.switchDefault(to: accounts[2].id)
        _ = try await manager.switchDefault(to: accounts[0].id)
        let config = paths.defaultHome.appending(path: "config.toml")
        try Data("preserve shared settings".utf8).write(to: config)
        let model = AccountViewModel(paths: paths, manager: manager)
        await model.load()
        model.selectedAccountID = accounts[1].id
        model.selectedAccountID = accounts[0].id
        let replacementAuth = try Data(contentsOf: accounts[1].credentialFile)
        let liveAuth = paths.defaultHome.appending(path: "auth.json")
        let outgoingAuth = try Data(contentsOf: liveAuth)
        try Data("{}".utf8).write(to: accounts[1].credentialFile)
        await model.deleteAccount(accounts[0].id)
        try expect(model.errorMessage != nil, "Invalid replacement was accepted")
        try expect(model.status?.defaultAccountID == accounts[0].id,
                   "Failed replacement changed the default account")
        try expect(FileManager.default.fileExists(atPath: accounts[0].credentialFile.path),
                   "Failed replacement deleted the outgoing credential")
        try expect(try Data(contentsOf: liveAuth) == outgoingAuth,
                   "Failed replacement changed the live authentication")
        try replacementAuth.write(to: accounts[1].credentialFile)
        await model.deleteAccount(accounts[0].id)
        try expect(model.errorMessage == nil, "Default deletion failed: \(model.errorMessage ?? "unknown")")
        try expect(model.status?.defaultAccountID == accounts[1].id
                   && model.selectedAccountID == accounts[1].id,
                   "Default deletion did not activate and select the previous selection")
        try expect(model.status?.accounts.count == 2
                   && !FileManager.default.fileExists(atPath: accounts[0].credentialFile.path),
                   "Default deletion left the removed account or credential")
        try expect(try Data(contentsOf: liveAuth) == replacementAuth,
                   "Default deletion did not install the replacement authentication")
        try expect(try Data(contentsOf: config) == Data("preserve shared settings".utf8),
                   "Default deletion changed shared settings")
        await model.deleteAccount(accounts[2].id)
        try expect(!model.canDeleteAccount(accounts[1].id),
                   "The only remaining default can be deleted without a fallback")
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
        unavailable.showDataLocation(unavailable.paths.defaultHome, name: "Codex home")
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
