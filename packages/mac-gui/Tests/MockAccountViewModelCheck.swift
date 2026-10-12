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
        let genericCount = DemoData.genericAccounts.count
        precondition(genericCount == 4)
        precondition(model.status?.accounts.count == 3 + genericCount)
        precondition(model.providerUsage.count == genericCount, "Generic demo accounts lack usage")
        precondition(model.providerUsage.values.allSatisfy { $0.usage != nil })
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
        precondition(model.selectedChat?.messages.count == 10)
        precondition(model.renderedChatMessages.count == 10)
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
        precondition(Array(model.providers.map(\.id).prefix(4)) == [.codex, .grokBuild, .droid, .claudeCode])
        precondition(model.providers.allSatisfy { $0.availability == .enabled })
        precondition(Set(model.providers.map(\.id)).isSuperset(of: ProviderCatalog.addable.map(\.id)))
        let choices = ProviderChoices.all(descriptors: model.providers)
        precondition(Array(choices.map(\.id).prefix(4)) == [.codex, .grokBuild, .droid, .claudeCode])
        let generic = Array(choices.dropFirst(4))
        precondition(generic.count == ProviderCatalog.addable.count)
        precondition(generic.map(\.name) == generic.map(\.name).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }, "Generic providers are not alphabetical")
        precondition(ProviderChoices.filter(choices, query: "open").contains { $0.id.rawValue == "openrouter" })
        precondition(ProviderChoices.filter(choices, query: "GEMINI-cli").map(\.id) == [.geminiCLI])
        precondition(ProviderChoices.filter(choices, query: "zzzz-no-such").isEmpty)
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
        precondition(model.status?.accounts.count == 4 + genericCount)
        let firstImportedID = model.importResult?.account.id

        model.resetImport()
        model.importMode = .authOnly
        model.selectedSourceID = "orca-team"
        await model.reviewImport()
        await model.commitImport()
        precondition(model.importResult?.importedChats == 0)
        precondition(model.status?.accounts.count == 5 + genericCount)
        precondition(model.importResult?.account.id != firstImportedID)
        let secondImportedID = model.importResult?.account.id

        model.resetImport()
        await model.reviewImport()
        await model.commitImport()
        precondition(model.importResult?.account.id == secondImportedID)
        precondition(model.status?.accounts.count == 5 + genericCount)
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

        // Generic providers: add, import, sign in, dashboard, reorder across providers.
        model.reset(to: .demo)
        let groq = ProviderID(rawValue: "groq")
        let beforeGeneric = model.status!.accounts.count
        let addedGroq = await model.addProviderAccount(providerID: groq, fields: ["apiKey": "demo"])
        precondition(addedGroq)
        precondition(model.status!.accounts.count == beforeGeneric + 1)
        precondition(model.selectedAccount?.identity.providerID == groq)
        precondition(model.accountLoginState == .completed)
        precondition(model.providerUsage[model.selectedAccountID!]?.usage != nil)
        precondition(model.status!.defaultAccountID(for: groq) == model.selectedAccountID)
        await model.detectSignedInProviders()
        precondition(model.signedInProviderIDs == [.geminiCLI, ProviderID(rawValue: "cursor"), ProviderID(rawValue: "kilo")],
            "Preview detection of signed-in providers changed")
        let liveGemini = await model.liveProviderIdentity(.geminiCLI)
        precondition(liveGemini?.email == "ada.lovelace@example.test")
        let importedGemini = await model.importLiveProviderAccount(providerID: .geminiCLI)
        precondition(importedGemini)
        precondition(model.status!.accounts.count == beforeGeneric + 1, "Importing a saved login duplicated it")
        model.selectedProviderID = ProviderID(rawValue: "windsurf")
        await model.startAccountLogin()
        precondition(model.accountLoginSession?.providerID.rawValue == "windsurf")
        await model.checkAccountLogin()
        precondition(model.accountLoginState == .completed)
        precondition(model.selectedAccount?.identity.providerID.rawValue == "windsurf")
        model.openDashboard(URL(string: "https://example.test/dashboard")!)
        precondition(model.notice?.contains("Preview") == true)
        let before = model.status!.accounts.map(\.id)
        let genericIDs = DemoData.genericAccounts.map(\.id)
        await model.moveAccount(genericIDs[3], to: genericIDs[0])
        precondition(model.status!.accounts.map(\.id) != before)
        precondition(Set(model.status!.accounts.map(\.id)) == Set(before))
        precondition(model.status!.accounts.firstIndex { $0.id == genericIDs[3] }!
            < model.status!.accounts.firstIndex { $0.id == genericIDs[0] }!)
        await model.refreshProviderUsage(accountID: genericIDs[1])
        precondition(model.notice?.contains("No provider was contacted") == true)
        let zai = genericIDs[3]
        precondition(model.providerUsage[zai]?.isOutdated == true, "The outdated tag state is missing")
        precondition(!model.canDeleteAccount(genericIDs[2]), "A provider's only default can be deleted")
        precondition(model.providerUsage[genericIDs[2]] != nil)

        // Provider status dots and Claude activity use synthetic data and never contact a provider.
        model.reset(to: .demo)
        precondition(model.providerStatus[.codex]?.incident.severity == .warning)
        precondition(model.providerStatus[.geminiCLI]?.incident.severity == .critical)
        precondition(model.providerStatus[ProviderID(rawValue: "cursor")] == nil)
        await model.refreshProviderStatus()
        precondition(model.providerStatus.count == 3, "A demo status refresh changed the synthetic incidents")
        precondition(model.claudeActivity == nil)
        let claude = model.addDemoProviderAccount(.claudeCode)
        precondition(claude.identity.providerID == .claudeCode)
        precondition(model.claudeActivity?.rows.map(\.label) == ["Today", "Yesterday", "Last 30 days"])
        await model.refreshClaudeActivity(force: true)
        precondition(!model.isClaudeActivityLoading && model.claudeActivity?.rows.count == 3)
        await model.setClaudeShellIntegration(true)
        precondition(model.claudeShellIntegrationOn, "The demo shell integration toggle did not turn on")
        await model.setClaudeShellIntegration(false)
        precondition(!model.claudeShellIntegrationOn)

        model.reset(to: .empty)
        precondition(model.providerStatus.isEmpty && model.claudeActivity == nil)
        precondition(model.status?.accounts.isEmpty == true)
        precondition(model.providerUsage.isEmpty)
        precondition(model.discoveries.isEmpty)
        model.reset()
        precondition(model.status?.accounts.count == 3 + genericCount)
        precondition(!FileManager.default.fileExists(atPath: root.path), "Mock actions wrote to disk")
        print("MOCK_ACCOUNT_VIEW_MODEL_PASS")
    }
}
