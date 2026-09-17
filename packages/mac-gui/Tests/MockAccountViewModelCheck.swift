import Foundation
import AIManagerCore

#if !AI_MANAGER_PREVIEW
#error("MockAccountViewModelCheck requires AI_MANAGER_PREVIEW")
#endif

@main
struct MockAccountViewModelCheck {
    @MainActor
    static func main() async {
        let root = URL(fileURLWithPath: "/private/tmp/ai-manager-mock-check-\(UUID().uuidString)", isDirectory: true)
        let paths = ManagerPaths(
            applicationSupport: root.appending(path: "support", directoryHint: .isDirectory),
            defaultHome: root.appending(path: "default", directoryHint: .isDirectory),
            sharedRoot: root.appending(path: "shared", directoryHint: .isDirectory),
            orcaAccountsRoot: root.appending(path: "orca", directoryHint: .isDirectory)
        )
        precondition(!FileManager.default.fileExists(atPath: root.path))

        let model = AccountViewModel(scenario: .allStates, demoPaths: paths)
        precondition(model.hasLoaded)
        precondition(model.isDemo)
        precondition(!model.isUnavailable)
        precondition(model.selectedProviderID == .codex)
        precondition(model.status?.accounts.count == 3)
        precondition(model.status?.pendingRecovery.count == 2)
        precondition(model.status?.linkedSettingsDivergences.count == 1)
        let nonselectedAccount = model.status!.accounts.first { $0.id != model.selectedAccountID }!
        await model.checkAccount(nonselectedAccount.id)
        precondition(model.selectedAccountID == nonselectedAccount.id)
        precondition(model.selectedAccount?.verification.state == .verifiedWithCodex)
        model.reset(to: .allStates)
        await model.refreshChatHistory(query: "")
        precondition(model.chatHistory.totalThreadCount == 3)
        let initialChatID = model.selectedChatID
        await model.searchChatHistory(query: "account import")
        precondition(model.chatHistory.matchingThreadCount == 1)
        precondition(model.selectedChat?.messages.count == 6)
        precondition(model.renderedChatMessages.count == 6)
        await model.searchChatHistory(query: "no-such-chat")
        precondition(model.chatHistory.matchingThreadCount == 0)
        precondition(model.selectedChatID == initialChatID)
        precondition(model.selectedChat != nil)
        await model.searchChatHistory(query: "")
        precondition(model.selectedChat != nil)

        await model.beginAddAccount()
        precondition(model.showImport)
        precondition(model.accountModalMode == .add)
        let modalAccountCount = model.status?.accounts.count
        await model.reloadAfterActivation()
        precondition(model.showImport, "Returning to the app dismissed or reloaded the account dialog")
        precondition(model.status?.accounts.count == modalAccountCount)
        precondition(model.providers.map(\.id) == [.codex, .claudeCode, .geminiCLI, .antigravityCLI])
        precondition(model.providers.map(\.availability) == [.enabled, .disabled, .disabled, .disabled])
        await model.startAccountLogin()
        precondition(model.accountLoginSession != nil)
        precondition(model.accountLoginState == .waitingForLogin)
        await model.checkAccountLogin()
        precondition(model.accountLoginState == .completed)
        model.closeAccountModal()
        precondition(!model.showImport)

        model.isBusy = true
        await model.beginImport()
        precondition(!model.showImport)
        model.isBusy = false
        await model.beginImport()
        await model.chooseSource()
        precondition(model.selectedSourceID == "chosen-home")
        await model.discover()
        precondition(model.discoveries.count == 4)
        model.importMode = .full
        await model.reviewImport()
        precondition(model.importPlan?.conflicts.count == 2)
        await model.commitImport()
        precondition(model.errorMessage?.contains("Choose how to resolve") == true)

        guard let conflicts = model.importPlan?.conflicts else { preconditionFailure("Missing demo conflicts") }
        for conflict in conflicts { model.conflictChoices[conflict.relativePath] = .keepShared }
        model.conflictChoices["rules"] = .useImported
        await model.reviewExternalSetting("rules")
        precondition(model.importPlan?.conflicts.first(where: { $0.relativePath == "rules" })?.externalTargetBytes == 12_480)
        await model.commitImport()
        precondition(model.importResult?.importedChats == 248)
        precondition(model.status?.accounts.count == 4)
        let firstImportedID = model.importResult?.account.id

        model.resetImport()
        model.importMode = .authOnly
        model.selectedSourceID = "orca-team"
        await model.reviewImport()
        await model.commitImport()
        precondition(model.importResult?.importedChats == 0)
        precondition(model.status?.accounts.count == 5)
        precondition(model.importResult?.account.id != firstImportedID)
        let secondImportedID = model.importResult?.account.id

        model.resetImport()
        await model.reviewImport()
        await model.commitImport()
        precondition(model.importResult?.account.id == secondImportedID)
        precondition(model.status?.accounts.count == 5)
        await model.switchDefault()
        precondition(model.status?.defaultAccountID == model.selectedAccountID)
        let accountCountBeforeRefresh = model.status?.accounts.count
        let defaultBeforeRefresh = model.status?.defaultAccountID
        let selectionBeforeRefresh = model.selectedAccountID
        await model.refresh()
        precondition(model.status?.accounts.count == accountCountBeforeRefresh)
        precondition(model.status?.defaultAccountID == defaultBeforeRefresh)
        precondition(model.selectedAccountID == selectionBeforeRefresh)
        precondition(model.refreshedAt != nil)
        precondition(model.notice?.contains("refreshed") == true)
        await model.verify()
        precondition(model.selectedAccount?.verification.state == .verifiedWithCodex)
        model.copySavedAuthPath()
        precondition(model.copyPath("/Demo/Shared"))
        model.copyWarnings(["First warning", "Second warning"])
        precondition(model.notice == "2 warnings ready to copy in the production app.")
        model.showDataLocation(model.paths.defaultHome, name: "Codex home")
        await model.openAccount()
        if let issue = model.status?.linkedSettingsDivergences.first {
            await model.repairLinkedSetting(issue)
        }
        precondition(model.status?.linkedSettingsDivergences.isEmpty == true)
        guard let conflict = model.status?.pendingRecovery.first(where: { $0.phase == .conflicted }) else {
            preconditionFailure("Missing demo recovery conflict")
        }
        await model.resolveRecoveryConflict(conflict, choice: .restoreBackup)
        precondition(model.status?.pendingRecovery.count == 1)
        await model.recover()
        precondition(model.status?.pendingRecovery.isEmpty == true)

        guard let defaultAccountID = model.status?.defaultAccountID,
              let deletableAccount = model.status?.accounts.first(where: {
                $0.id != defaultAccountID && $0.verification.state != .needsSignIn
              }) else {
            preconditionFailure("Missing a non-default demo account to delete")
        }
        let countBeforeDeletion = model.status?.accounts.count
        await model.deleteAccount(deletableAccount.id)
        precondition(model.status?.accounts.contains(where: { $0.id == deletableAccount.id }) == false)
        precondition(model.status?.accounts.count == countBeforeDeletion.map { $0 - 1 })
        precondition(model.status?.defaultAccountID == defaultAccountID)
        model.showDemoError()
        precondition(model.errorMessage?.contains("needs sign-in") == true)

        model.selectedAccountID = model.status?.accounts.first(where: { $0.verification.state == .needsSignIn })?.id
        model.notice = nil
        let pendingAction = Task { await model.openAccount() }
        await Task.yield()
        precondition(model.isBusy)
        await model.verify()
        precondition(model.selectedAccount?.verification.state == .needsSignIn)
        model.resetImport()
        await pendingAction.value
        precondition(model.notice == nil, "A reset action completed with stale state")

        model.reset(to: .demo)
        let demoDefault = model.status!.defaultAccountID!
        let demoReplacement = model.status!.accounts.first {
            $0.id != demoDefault && $0.verification.state != .needsSignIn
        }!
        model.selectedAccountID = demoReplacement.id
        model.selectedAccountID = demoDefault
        await model.deleteAccount(demoDefault)
        precondition(model.status?.defaultAccountID == demoReplacement.id)
        precondition(model.selectedAccountID == demoReplacement.id)
        precondition(!model.canDeleteAccount(demoReplacement.id))

        model.reset(to: .empty)
        precondition(model.status?.accounts.isEmpty == true)
        precondition(model.discoveries.isEmpty)
        model.reset()
        precondition(model.status?.accounts.count == 3)
        precondition(!FileManager.default.fileExists(atPath: root.path), "Mock actions wrote to disk")
        print("MOCK_ACCOUNT_VIEW_MODEL_PASS")
    }
}
