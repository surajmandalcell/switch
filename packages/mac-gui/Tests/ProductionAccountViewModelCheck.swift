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

private final class FireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private struct SilentChatHistoryMonitor: ChatHistoryMonitoring {
    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

@main
struct ProductionAccountViewModelCheck {
    @MainActor
    static func main() async throws {
        // The remembered selection and Maintenance source live in this binary's own defaults domain,
        // which is the real user's. Start and end without them so a second run behaves like the first.
        let defaultsDomain = ProcessInfo.processInfo.processName
        UserDefaults.standard.removePersistentDomain(forName: defaultsDomain)
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsDomain) }
        try expect(AccountViewModel.usageRefreshInterval == 3 * 60,
                   "Usage refresh cadence is not three minutes")
        let refreshClock = Date(timeIntervalSince1970: 10_000)
        try expect(!AccountViewModel.automaticUsageRefreshIsDue(
            fetchedAt: refreshClock.addingTimeInterval(-179), failedAt: nil, now: refreshClock),
            "Fresh usage was scheduled before three minutes")
        try expect(AccountViewModel.automaticUsageRefreshIsDue(
            fetchedAt: refreshClock.addingTimeInterval(-180), failedAt: nil, now: refreshClock),
            "Three-minute-old usage was not scheduled")
        try expect(AccountViewModel.automaticUsageRefreshIsDue(
            fetchedAt: refreshClock, failedAt: nil, onCadence: true, now: refreshClock),
            "The fixed cadence skipped fresh cached usage")
        try expect(!AccountViewModel.automaticUsageRefreshIsDue(
            fetchedAt: nil, failedAt: refreshClock.addingTimeInterval(-299),
            onCadence: true, now: refreshClock),
            "A failed refresh ignored its five-minute cooldown")
        try await FeatureLogicChecks.run()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(
            path: "iia-directeur-gui-check-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try await checkAccountScopedSignIn(root: root)
        try await checkDroidAccounts(root: root)
        print("ACCOUNT_SCOPED_SIGN_IN_PASS")

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
        for _ in 0..<1_000 where await countingHistory.refreshCount() == 0 {
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

        // The debouncer alone, with no fseventsd: a burst of pokes inside the quiet window fires
        // once, and a poke after the window fires again.
        let debounceQueue = DispatchQueue(label: "com.switch.debounce-check")
        let debounceFires = FireCounter()
        let debouncer = ChatHistoryDebouncer(queue: debounceQueue, quiet: .milliseconds(400)) {
            debounceFires.increment()
        }
        for _ in 0..<8 {
            debounceQueue.sync { debouncer.poke() }
            usleep(10_000)
        }
        try await Task.sleep(for: .milliseconds(900))
        try expect(debounceFires.value == 1,
                   "A burst of pokes did not fire the debouncer once (\(debounceFires.value))")
        debounceQueue.sync { debouncer.poke() }
        try await Task.sleep(for: .milliseconds(900))
        try expect(debounceFires.value == 2,
                   "A poke after a quiet window did not fire the debouncer (\(debounceFires.value))")
        debounceQueue.sync { debouncer.poke(); debouncer.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        try expect(debounceFires.value == 2, "A cancelled debouncer still fired")

        let eventHistory = CountingChatHistoryProvider()
        let eventHistoryModel = AccountViewModel(
            paths: paths, manager: manager, chatHistoryProvider: eventHistory)
        let eventWatch = Task { await eventHistoryModel.watchActivity() }
        for _ in 0..<1_000 where await eventHistory.refreshCount() == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let initialEventRefreshCount = await eventHistory.refreshCount()
        try Data("irrelevant".utf8).write(
            to: paths.sharedRoot.appending(path: "history-event-probe"))
        try await Task.sleep(for: .milliseconds(750))
        let afterIrrelevantEventCount = await eventHistory.refreshCount()
        try expect(afterIrrelevantEventCount == initialEventRefreshCount,
                   "An unrelated shared-home write refreshed Chat History")
        let eventDirectory = paths.sharedRoot.appending(
            path: "sessions/2026/09/14", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: eventDirectory, withIntermediateDirectories: true)
        let eventFile = eventDirectory.appending(path: "history-event.jsonl")
        try Data().write(to: eventFile)
        let eventHandle = try FileHandle(forWritingTo: eventFile)
        // Eight writes in quick succession. The exact refresh count for them is up to fseventsd,
        // which can deliver the batches of one burst more than the 500 ms quiet window apart on a
        // busy machine (750 ms seen under disk load). The debouncer check above pins the exact
        // coalescing; here the real monitor must refresh at least once and must coalesce.
        let burstWrites = 8
        for index in 0..<burstWrites {
            try eventHandle.seekToEnd()
            try eventHandle.write(contentsOf: Data("{\"event\":\(index)}\n".utf8))
            usleep(5_000)
        }
        try eventHandle.close()
        // Wait for the first refresh, then for a quiet period longer than the monitor's debounce
        // and the event latency. Both waits end at a bounded deadline (10 s), not at a fixed sleep.
        for _ in 0..<1_000 where await eventHistory.refreshCount() < initialEventRefreshCount + 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        var lastRefreshCount = await eventHistory.refreshCount()
        var quietTicks = 0
        for _ in 0..<1_000 where quietTicks < 150 {
            try await Task.sleep(for: .milliseconds(10))
            let count = await eventHistory.refreshCount()
            if count == lastRefreshCount { quietTicks += 1 } else { lastRefreshCount = count; quietTicks = 0 }
        }
        let eventRefreshCount = lastRefreshCount - initialEventRefreshCount
        eventWatch.cancel()
        await eventWatch.value
        try expect(eventRefreshCount >= 1 && eventRefreshCount < burstWrites,
                   "A burst of conversation writes did not coalesce into a few history refreshes (\(eventRefreshCount))")
        try fileManager.removeItem(at: eventFile)

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
            model.chatPresentations.values.contains { presentation in
                presentation.blocks.contains {
                    if case let .paragraph(_, text) = $0 { return String(text.characters) == "The synthetic chat is readable." }
                    return false
                }
            },
            "Production chat detail did not prepare Markdown before publication")

        // Maintenance source picker: one shared Codex home, with the chosen source remembered.
        let maintenance = model.maintenance
        maintenance.refreshSources()
        let codexSource = try expect(maintenance.sources.first { $0.id == "codex" },
                                     "The source picker has no shared Codex home")
        try expect(codexSource.title == "Codex CLI" && codexSource.home.standardizedFileURL == paths.sharedRoot.standardizedFileURL,
                   "The Codex source does not point at the shared home")
        maintenance.sourceID = "codex"
        try expect(UserDefaults.standard.string(forKey: MaintenancePlace.sourceKey) == "codex",
                   "The chosen Maintenance source was not remembered")

        // A file written in the last five minutes is a running session and is never listed.
        for url in [sessions.appending(path: "shared.jsonl"), sessions] {
            try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: url.path)
        }
        func cleanupConversations() async throws -> [CleanupItem] {
            try await model.cleanupScan(codexSource).categories.first { $0.id == "conversations" }?.selectable ?? []
        }
        let found = try await cleanupConversations()
        try expect(found.count == 1, "Cleanup inventory missed the shared conversation")
        let scanned = try await model.cleanupScan(codexSource).categories.flatMap(\.items)
        try expect(!scanned.contains { ["config.toml", "auth.json"].contains(($0.path as NSString).lastPathComponent) },
                   "Cleanup listed a settings or login file")
        let cleanupPlan = try await model.reviewCleanup(codexSource, found)
        try await model.applyCleanup(codexSource, plan: cleanupPlan, samples: [], clearIndex: false)
        let trashed = try await model.cleanupTrash(codexSource)
        let leftover = try await cleanupConversations()
        try expect(leftover.isEmpty && trashed.count == 1,
                   "Production Cleanup did not expose recoverable conversation trash")
        try await model.restoreCleanup(codexSource, trashed[0].id)
        let restoredTrash = try await model.cleanupTrash(codexSource)
        let restoredItems = try await cleanupConversations()
        try expect(restoredItems.count == 1 && restoredTrash.isEmpty,
                   "Production Cleanup did not restore the original conversation")

        // Backup through the model: two snapshots, the second links what did not change, and a restore
        // into a folder reproduces the files.
        let drive = root.appending(path: "backup-drive", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: drive, withIntermediateDirectories: true)
        let backupSet = try expect(await maintenance.createSet(for: codexSource, destination: drive),
                                   "Backup could not create a set for the Codex source")
        try expect(!backupSet.includeLogins, "A new backup set includes login files")
        let agentsFile = paths.sharedRoot.appending(path: "AGENTS.md")
        try Data("first version".utf8).write(to: agentsFile)
        await maintenance.backUp(backupSet)
        try Data("second version".utf8).write(to: agentsFile)
        await maintenance.backUp(backupSet)
        let backups = (maintenance.status(for: backupSet)?.snapshots ?? []).sorted { $0.date < $1.date }
        try expect(backups.count == 2, "Two backups did not leave two snapshots (\(backups.count))")
        func inode(_ snapshot: BackupSnapshot, _ path: String) throws -> NSNumber? {
            try fileManager.attributesOfItem(atPath: snapshot.folder.appending(path: "files/" + path).path)[.systemFileNumber] as? NSNumber
        }
        try expect(try inode(backups[0], "sessions/shared.jsonl") == inode(backups[1], "sessions/shared.jsonl"),
                   "The second backup copied an unchanged file instead of linking it")
        try expect(try inode(backups[0], "config.toml") == inode(backups[1], "config.toml"),
                   "The second backup copied the unchanged settings file")
        try expect(try inode(backups[0], "AGENTS.md") != inode(backups[1], "AGENTS.md"),
                   "The second backup linked a file that changed")
        try expect(!backups[1].manifest.entries.contains { $0.path.hasSuffix("auth.json") },
                   "A backup without login files contains auth.json")
        let restoreFolder = root.appending(path: "restored", directoryHint: .isDirectory)
        await maintenance.restore(backups[0], set: backupSet, items: nil, to: restoreFolder)
        try expect(try Data(contentsOf: restoreFolder.appending(path: "sessions/shared.jsonl"))
                   == Data(contentsOf: sessions.appending(path: "shared.jsonl")),
                   "Restoring into a folder did not reproduce the session file")
        try expect(try String(contentsOf: restoreFolder.appending(path: "AGENTS.md"), encoding: .utf8) == "first version",
                   "Restoring the first backup did not bring back the first version of a file")
        try fileManager.removeItem(at: agentsFile)
        try expect(maintenance.recent.count == 2 && maintenance.recent.allSatisfy { $0.source == backupSet.name },
                   "The recent backups list does not show both snapshots")
        var waitingSet = backupSet
        waitingSet.destination = URL(fileURLWithPath: "/Volumes/SwitchCheckMissingDrive/Backups")
        await maintenance.update(waitingSet)
        if case .waiting(let volume)? = maintenance.status(for: waitingSet)?.state {
            try expect(volume == "SwitchCheckMissingDrive", "The waiting state names the wrong volume")
        } else { throw CheckFailure(message: "A missing destination did not show the waiting state") }

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

        try await checkSignedInDetection(model)
        try await checkProviderUsage(root: root)
        try await checkUnavailableState(root: root)
        try await checkDefaultDeletion(root: root)
        print("PRODUCTION_ACCOUNT_VIEW_MODEL_PASS")
    }

    /// Add Account marks a provider whose live login already exists, from a synthetic Kilo file in
    /// the temporary home, and leaves every other provider unmarked.
    @MainActor
    private static func checkSignedInDetection(_ model: AccountViewModel) async throws {
        await model.detectSignedInProviders()
        try expect(model.signedInProviderIDs.isEmpty, "A provider looked signed in on an empty home: \(model.signedInProviderIDs.map(\.rawValue))")
        let file = model.paths.userHome.appending(path: ".local/share/kilo/auth.json")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"kilo":{"type":"api","key":"synthetic-kilo-key"}}"#.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await model.detectSignedInProviders()
        try expect(model.signedInProviderIDs == [ProviderID(rawValue: "kilo")],
                   "Detection found \(model.signedInProviderIDs.map(\.rawValue))")
        let choices = ProviderChoices.all(descriptors: model.providers, signedIn: model.signedInProviderIDs)
        try expect(choices.dropFirst(ProviderChoices.builtIn.count).first?.id.rawValue == "kilo" && choices.dropFirst(ProviderChoices.builtIn.count).first?.signedInOnThisMac == true,
                   "A signed-in provider does not sort first")
    }

    /// Usage of non-Codex accounts: cadence, cooldown, private cache, instant load, cleanup.
    @MainActor
    private static func checkProviderUsage(root: URL) async throws {
        let now = Date(timeIntervalSince1970: 50_000)
        let fresh = ProviderUsage(windows: [UsageWindow(id: "s", title: "Session", usedPercent: 10)],
                                  fetchedAt: now.addingTimeInterval(-299))
        let stale = ProviderUsage(fetchedAt: now.addingTimeInterval(-300))
        func state(_ usage: ProviderUsage?, error: String? = nil, checked: Date? = nil,
                   refreshing: Bool = false) -> ProviderUsageState {
            ProviderUsageState(usage: usage, error: error, checkedAt: checked, isRefreshing: refreshing)
        }
        try expect(ProviderUsagePolicy.interval == 5 * 60 && ProviderUsagePolicy.failureCooldown == 5 * 60
                   && ProviderUsagePolicy.fetchTimeout == 60 && ProviderUsagePolicy.maxConcurrent == 4,
                   "Provider usage limits changed")
        try expect(ProviderUsagePolicy.isDue(nil, onCadence: false, now: now), "An unchecked account was not due")
        try expect(!ProviderUsagePolicy.isDue(state(fresh), onCadence: false, now: now),
                   "Usage under five minutes old was refreshed")
        try expect(ProviderUsagePolicy.isDue(state(stale), onCadence: false, now: now),
                   "Usage five minutes old was not refreshed")
        try expect(ProviderUsagePolicy.isDue(state(fresh), onCadence: true, now: now),
                   "The fixed tick skipped fresh cached usage")
        try expect(!ProviderUsagePolicy.isDue(
            state(fresh, error: "x", checked: now.addingTimeInterval(-299)), onCadence: true, now: now),
            "A failed account ignored its five-minute wait")
        try expect(ProviderUsagePolicy.isDue(
            state(fresh, error: "x", checked: now.addingTimeInterval(-300)), onCadence: true, now: now),
            "A failed account was never retried")
        try expect(!ProviderUsagePolicy.isDue(state(stale, refreshing: true), onCadence: true, now: now),
                   "An account already refreshing was started twice")
        try expect(ProviderUsagePolicy.failure(ProviderError.unauthorized("Sign in")).needsSignIn
                   && !ProviderUsagePolicy.failure(ProviderError.network("Offline")).needsSignIn,
                   "Only authorization failures ask for a new sign-in")
        do {
            _ = try await ProviderUsageCache.withTimeout(0.05) {
                try await Task.sleep(for: .seconds(5))
                return 1
            }
            throw CheckFailure(message: "A slow usage fetch did not time out")
        } catch is CheckFailure {
            throw CheckFailure(message: "A slow usage fetch did not time out")
        } catch {}
        let quick = try await ProviderUsageCache.withTimeout(5) { 7 }
        try expect(quick == 7, "A quick fetch lost its result")

        let fileManager = FileManager.default
        let testRoot = root.appending(path: "provider-usage")
        let paths = ManagerPaths(
            applicationSupport: testRoot.appending(path: "support"),
            defaultHome: testRoot.appending(path: "live"),
            sharedRoot: testRoot.appending(path: "live"),
            orcaAccountsRoot: testRoot.appending(path: "orca"),
            codexExecutable: URL(fileURLWithPath: "/usr/bin/true"), isolationRoot: testRoot)
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let model = AccountViewModel(paths: paths, manager: manager)
        await model.load()
        let saved = await model.addProviderAccount(
            providerID: ProviderID(rawValue: "openrouter"), fields: ["apiKey": "sk-or-synthetic-0001"])
        try expect(saved && model.errorMessage == nil, "Saving a typed credential failed: \(model.errorMessage ?? "")")
        let account = try expect(model.selectedAccount, "The saved provider account was not selected")
        try expect(account.identity.providerID.rawValue == "openrouter"
                   && model.accountLoginState == .completed
                   && model.status?.isDefault(account) == true,
                   "A saved provider account was not selected, completed, and made the provider default")
        try expect(account.identity.accountLabel.hasPrefix("OpenRouter ···"),
                   "A key-only account has no distinguishing label")
        let failed = await model.addProviderAccount(providerID: ProviderID(rawValue: "openrouter"), fields: [:])
        try expect(!failed && model.errorMessage?.contains("Enter the API key") == true,
                   "A missing credential did not report an inline error")
        model.errorMessage = nil
        let savedSecond = await model.addProviderAccount(
            providerID: ProviderID(rawValue: "openrouter"), fields: ["apiKey": "sk-or-synthetic-0002"])
        let second = try expect(model.selectedAccount, "The second provider account was not selected")
        try expect(savedSecond && second.id != account.id && model.status?.isDefault(second) == false,
                   "A second key replaced the provider default")

        // No network in isolation: a refresh leaves the state alone.
        await model.refreshProviderUsage(accountID: account.id)
        try expect(model.providerUsage[account.id]?.isRefreshing != true, "An isolated refresh started a fetch")

        // The cache is private and a new model shows it before any check.
        let cacheURL = ProviderUsageCache.url(in: paths.applicationSupport)
        let cached = ProviderUsage(
            windows: [UsageWindow(id: "s", title: "Session", usedPercent: 33, resetsAt: Date().addingTimeInterval(3_600),
                                  windowMinutes: 300, detail: "33 / 100 requests")],
            cost: UsageCost(balance: 4.2), plan: "Pro", fetchedAt: Date().addingTimeInterval(-60))
        try ProviderUsageCache.save([account.id: cached], to: cacheURL)
        let mode = try fileManager.attributesOfItem(atPath: cacheURL.path)[.posixPermissions] as? Int
        try expect(mode == 0o600, "The usage cache is not owner-private")
        try ProviderUsageCache.save([account.id: cached, second.id: cached, UUID(): stale], to: cacheURL)
        try expect(ProviderUsageCache.load(from: cacheURL).count == 3 && ProviderUsageCache.load(from: cacheURL)[account.id] == cached,
                   "The usage cache did not round-trip")
        try expect(try fileManager.contentsOfDirectory(atPath: cacheURL.deletingLastPathComponent().path)
                   .allSatisfy { !$0.hasSuffix(".tmp") }, "An atomic cache write left a temporary file")
        let reopened = AccountViewModel(paths: paths, manager: manager)
        await reopened.load()
        let shown = try expect(reopened.providerUsage[account.id], "Cached usage was not loaded at launch")
        try expect(shown.usage == cached && shown.error == nil && !shown.isRefreshing,
                   "Cached usage is not shown as last known values")
        try expect(reopened.providerUsage.count == 2, "Usage of an unknown account entered the model")
        var publications = 0
        let observation = reopened.objectWillChange.sink { publications += 1 }
        await reopened.refreshProviderUsage(accountID: account.id)
        await reopened.refreshProviderUsage()
        withExtendedLifetime(observation) {}
        try expect(publications == 0, "An isolated provider refresh republished the interface")
        await reopened.refreshProviderStatus()
        await reopened.refreshClaudeActivity(force: true)
        try expect(reopened.providerStatus.isEmpty && reopened.claudeActivity == nil
                   && !reopened.isClaudeActivityLoading, "An isolated model made status or activity requests")

        // Claude shell integration writes only inside the isolated home and keeps a backup.
        let zshrc = paths.userHome.appending(path: ".zshrc")
        try Data("export A=1\n".utf8).write(to: zshrc)
        await reopened.setClaudeShellIntegration(true)
        try expect(reopened.claudeShellIntegrationOn && reopened.claudeShellIntegrationError == nil
                   && (try String(contentsOf: zshrc, encoding: .utf8)).contains("# >>> switch claude >>>")
                   && fileManager.fileExists(atPath: zshrc.path + ".switch-backup"),
                   "Turning Claude shell integration on failed")
        await reopened.setClaudeShellIntegration(false)
        try expect(!reopened.claudeShellIntegrationOn
                   && (try String(contentsOf: zshrc, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines) == "export A=1",
                   "Turning Claude shell integration off left the rc file changed")

        await reopened.deleteAccount(second.id)
        try expect(reopened.errorMessage == nil, "Deleting a provider account failed: \(reopened.errorMessage ?? "")")
        try expect(reopened.providerUsage[second.id] == nil && reopened.providerUsage[account.id] != nil,
                   "Deleting an account kept its usage or dropped another account's")
        for _ in 0..<100 where ProviderUsageCache.load(from: cacheURL)[second.id] != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        try expect(ProviderUsageCache.load(from: cacheURL)[second.id] == nil
                   && ProviderUsageCache.load(from: cacheURL)[account.id] == cached,
                   "Deleting an account left its usage in the cache file")
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
    private static func checkAccountScopedSignIn(root: URL) async throws {
        let loginRoot = root.appending(path: "scoped-login")
        let paths = ManagerPaths(
            applicationSupport: loginRoot.appending(path: "support"),
            credentialStore: loginRoot.appending(path: "user/.switch/codex"),
            defaultHome: loginRoot.appending(path: "user/.codex"),
            sharedRoot: loginRoot.appending(path: "user/.codex"),
            orcaAccountsRoot: loginRoot.appending(path: "orca"),
            codexExecutable: URL(fileURLWithPath: "/usr/bin/true"), isolationRoot: loginRoot)
        let live = try writeSource(at: paths.defaultHome, account: "target", workspace: "personal")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.defaultHome.appending(path: "auth.json").path)
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive },
                                        loginRunner: .init(launch: { _, _ in }, cancel: { _ in
                                            fatalError("Account-scoped sign-in must not cancel a CLI")
                                        }))
        let model = AccountViewModel(paths: paths, manager: manager)
        await model.load()
        let account = try expect(model.status?.accounts.first, "No synthetic account was adopted: \(model.errorMessage ?? "no load error")")
        await model.beginSignIn(for: account.id)
        let session = try expect(model.accountLoginSession, "Account sign-in did not start")
        try expect(session.accountID == account.id, "Account sign-in lost its target")
        let home = paths.applicationSupport.appending(path: "account-login/\(session.id.uuidString)/home")
        _ = try writeSource(at: home, account: "other", workspace: "personal")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.appending(path: "auth.json").path)
        await model.checkAccountLogin()
        try expect(model.errorMessage?.contains("Signed in as other@example.test") == true,
                   "Identity mismatch did not reach the GUI")
        try expect(model.accountLoginSession == nil && model.pendingLoginSessions.isEmpty,
                   "The GUI kept a discarded sign-in session")
        try expect(try Data(contentsOf: account.credentialFile) == live,
                   "GUI mismatch changed the managed credential")
        try expect(try Data(contentsOf: paths.defaultHome.appending(path: "auth.json")) == live,
                   "GUI mismatch changed the live login")
        model.closeAccountModal()
        await model.beginSignIn(for: account.id)
        try expect(model.accountLoginSession?.accountID == account.id, "Account sign-in could not restart after mismatch")
        await model.cancelAccountLogin()
        model.closeAccountModal()
        await model.beginSignIn(for: ProviderID.codex)
        try expect(model.accountLoginSession?.accountID == nil, "Add account reused an existing-account target")
    }

    @MainActor
    private static func checkDroidAccounts(root: URL) async throws {
        let droidRoot = root.appending(path: "droid")
        let fm = FileManager.default
        try fm.createDirectory(at: droidRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fake = droidRoot.appending(path: "fake-droid")
        try """
        #!/bin/sh
        test "$1" = doctor && test "$2" = --auth && test "$3" = --json || exit 1
        test -z "${FACTORY_API_KEY:-}" || exit 1
        cat "$(dirname "$0")/doctor.json"
        """.write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        func doctor(_ hint: String) throws {
            let json = try JSONSerialization.data(withJSONObject: ["results": [
                ["id": "auth.verify", "status": "pass", "detail": "authenticated as \(hint) via stored login session"]
            ]])
            try json.write(to: droidRoot.appending(path: "doctor.json"))
        }
        try doctor("s***@gmail.com")
        let paths = ManagerPaths(applicationSupport: droidRoot.appending(path: "support"),
            credentialStore: droidRoot.appending(path: "user/.switch/codex"),
            defaultHome: droidRoot.appending(path: "user/.codex"), sharedRoot: droidRoot.appending(path: "user/.codex"),
            orcaAccountsRoot: droidRoot.appending(path: "orca"), droidExecutable: fake, isolationRoot: droidRoot)
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive }, providerSpecs: [],
            droidProcessLister: { [.init(pid: 42, bundleID: "com.electron.factory", home: paths.droidHome)] })
        let model = AccountViewModel(paths: paths, manager: manager)
        await model.load()
        // The login appears after launch: launch discovery would otherwise import it first.
        try fm.createDirectory(at: paths.droidHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let live = paths.droidHome.appending(path: "auth.v2.loginkeychain")
        try Data("synthetic-A".utf8).write(to: live)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: live.path)
        model.droidAccountName = "Droid personal"
        await model.importDroidAccount()
        let first = try expect(model.selectedAccount, "Droid import did not reach the GUI")
        try expect(first.identity.accountID == "Droid personal", "Droid ignored the owner's name")
        try expect(first.identity.email == "s***@gmail.com" && first.identity.accountLabel.hasPrefix("Droid personal · "), "Droid masked identity was not stored and displayed")
        model.closeAccountModal()
        await model.beginAddAccount()
        model.selectedProviderID = .droid
        model.droidAccountName = "Droid work"
        await model.startAccountLogin()
        let session = try expect(model.accountLoginSession, "Droid isolated login did not start")
        let staged = paths.applicationSupport.appending(path: "account-login/\(session.id.uuidString)/home/.factory")
        try fm.createDirectory(at: staged, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let auth = staged.appending(path: "auth.v2.loginkeychain")
        try Data("synthetic-B".utf8).write(to: auth)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
        try doctor("d***@gmail.com")
        await model.checkAccountLogin()
        let second = try expect(model.selectedAccount, "Droid login did not finish")
        try expect(second.id != first.id && second.identity.accountID == "Droid work", "Droid accounts were not separate")
        var prompts: [String] = []
        model.droidConfirmation = { message, _ in prompts.append(message); return false }
        await model.switchDefault(to: second.id)
        try expect(try Data(contentsOf: live) == Data("synthetic-A".utf8), "Cancel changed the Droid login")
        try expect(prompts.last == "Factory.app is running. Switching changes its account for new requests.", "The running-app warning did not reach the GUI")
        model.droidConfirmation = { message, _ in prompts.append(message); return true }
        await model.switchDefault(to: second.id)
        try expect(try Data(contentsOf: live) == Data("synthetic-B".utf8), "Confirmed Droid switch did not publish the login")
        model.closeAccountModal()
        await model.beginSignIn(for: first.id)
        try expect(model.accountLoginSession?.accountID == first.id, "Droid re-sign-in lost the target")
        try expect(prompts.last?.contains("Droid personal") == true, "Droid sign-in confirmation did not name the target")
        await model.cancelAccountLogin()
        model.closeAccountModal()
        await model.beginAddAccount()
        model.selectedProviderID = .droid
        model.droidAccountName = "Droid duplicate"
        await model.startAccountLogin()
        let duplicate = try expect(model.accountLoginSession, "Duplicate login did not start")
        let duplicateHome = paths.applicationSupport.appending(path: "account-login/\(duplicate.id.uuidString)/home/.factory")
        try fm.createDirectory(at: duplicateHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let duplicateAuth = duplicateHome.appending(path: "auth.v2.loginkeychain")
        try Data("synthetic-C".utf8).write(to: duplicateAuth)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: duplicateAuth.path)
        try doctor("s***@gmail.com")
        model.droidConfirmation = { message, _ in prompts.append(message); return false }
        await model.checkAccountLogin()
        try expect(prompts.last == "This looks like Droid personal (s***@gmail.com). Add it anyway?", "Duplicate warning did not reach the GUI")
        try expect(model.status?.accounts.count == 2 && model.accountLoginSession?.id == duplicate.id, "Cancel saved or discarded the duplicate")
        model.droidConfirmation = { message, _ in prompts.append(message); return true }
        await model.checkAccountLogin()
        try expect(model.status?.accounts.count == 3 && model.selectedAccount?.identity.accountID == "Droid duplicate", "Confirmed duplicate was not added")
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
