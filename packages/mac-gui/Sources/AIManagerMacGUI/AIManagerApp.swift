import AppKit
import AIManagerCore
import Combine

@MainActor
private final class AIManagerAppDelegate: NSObject, NSApplicationDelegate {
    private let model = AccountViewModel(paths: .environment())
    private var windowController: AIManagerWindowController<AccountWindow>?
    private var statusItemController: AIManagerStatusItemController?
    private var menuController: AIManagerMenuController?
    private var instanceActivationObserver: NSObjectProtocol?
    private var appearanceObserver: NSObjectProtocol?
    private var modelObservers = Set<AnyCancellable>()
    private var quotaNotifier: QuotaNotifier?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AIMNativeFocusPolicy.install()
        NSApp.disableRelaunchOnLogin()
        AIManagerBrand.installApplicationIcon()
        let controller = AIManagerWindowController(
            title: AIManagerBrand.bundleDisplayName(),
            rootView: AccountWindow(model: model)
        )
        windowController = controller
        quotaNotifier = QuotaNotifier(model: model) {
            controller.present()
            NSApp.activate(ignoringOtherApps: true)
        }
        model.messagePoster = ActionMessage.post
        instanceActivationObserver = DistributedNotificationCenter.default().addObserver(
            forName: AIManagerSingleInstance.activationNotification(
                bundleIdentifier: AIManagerSingleInstance.bundleIdentifier()),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.windowController?.present()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        let statusItemController = AIManagerStatusItemController(
            snapshot: menuBarSnapshot(
                status: model.status,
                usageSnapshots: model.usageSnapshots,
                dailyUsage: model.retainedDailyUsage,
                apiPrice: model.apiPrice),
            actions: MenuBarPopoverActions(
                openMainWindow: {
                    controller.present()
                    NSApp.activate(ignoringOtherApps: true)
                },
                switchAccount: { [weak self] accountID in
                    guard let self else { throw MenuBarActionError.appUnavailable }
                    try await self.switchAccountFromMenuBar(accountID)
                },
                refreshUsage: { [weak self] in await self?.refreshEnabledUsage() },
                openSettings: { [weak self] in self?.menuController?.showSettings(nil) },
                quit: { NSApp.terminate(nil) },
                openTool: { [weak self] accountID in await self?.model.openAccount(accountID) },
                refreshAccount: { [weak self] accountID in await self?.refreshUsage(of: accountID) },
                signInAccount: { [weak self] accountID in await self?.model.beginSignIn(for: accountID) }
            ))
        self.statusItemController = statusItemController
        GlobalShortcut.shared.onTrigger = { [weak statusItemController] in
            statusItemController?.togglePopoverFromShortcut()
        }
        GlobalShortcut.shared.apply(GlobalShortcutPreferences.load())
        applyAppearance()
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self, weak statusItemController] _ in
            Task { @MainActor [weak self, weak statusItemController] in
                guard let self else { return }
                self.applyAppearance()
                statusItemController?.update(snapshot: self.menuBarSnapshot(
                    status: self.model.status,
                    usageSnapshots: self.model.usageSnapshots,
                    dailyUsage: self.model.retainedDailyUsage,
                    apiPrice: self.model.apiPrice))
            }
        }
        model.$status
            .sink { [weak self, weak statusItemController] status in
                guard let self else { return }
                statusItemController?.update(snapshot: self.menuBarSnapshot(
                    status: status,
                    usageSnapshots: self.model.usageSnapshots,
                    dailyUsage: self.model.retainedDailyUsage,
                    apiPrice: self.model.apiPrice))
            }
            .store(in: &modelObservers)
        model.$usageSnapshots
            .sink { [weak self, weak statusItemController] usageSnapshots in
                guard let self else { return }
                statusItemController?.update(snapshot: self.menuBarSnapshot(
                    status: self.model.status,
                    usageSnapshots: usageSnapshots,
                    dailyUsage: self.model.retainedDailyUsage,
                    apiPrice: self.model.apiPrice))
            }
            .store(in: &modelObservers)
        model.$retainedDailyUsage
            .sink { [weak self, weak statusItemController] dailyUsage in
                guard let self else { return }
                statusItemController?.update(snapshot: self.menuBarSnapshot(
                    status: self.model.status,
                    usageSnapshots: self.model.usageSnapshots,
                    dailyUsage: dailyUsage,
                    apiPrice: self.model.apiPrice))
            }
            .store(in: &modelObservers)
        model.$providerUsage
            .sink { [weak self, weak statusItemController] providerUsage in
                guard let self else { return }
                statusItemController?.update(snapshot: self.menuBarSnapshot(
                    status: self.model.status,
                    usageSnapshots: self.model.usageSnapshots,
                    dailyUsage: self.model.retainedDailyUsage,
                    apiPrice: self.model.apiPrice,
                    providerUsage: providerUsage))
            }
            .store(in: &modelObservers)
        model.$apiPrice
            .sink { [weak self, weak statusItemController] apiPrice in
                guard let self else { return }
                statusItemController?.update(snapshot: self.menuBarSnapshot(
                    status: self.model.status,
                    usageSnapshots: self.model.usageSnapshots,
                    dailyUsage: self.model.retainedDailyUsage,
                    apiPrice: apiPrice))
            }
            .store(in: &modelObservers)
        Timer.publish(
            every: AccountViewModel.usageRefreshInterval,
            on: .main,
            in: .common
        )
        .autoconnect()
        .sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.model.refreshAutomaticUsage(onCadence: true)
            }
        }
        .store(in: &modelObservers)
        // Other providers keep their own five-minute cadence.
        Timer.publish(every: ProviderUsagePolicy.interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.model.refreshProviderUsage(onCadence: true)
                }
            }
            .store(in: &modelObservers)
        let menuController = AIManagerMenuController(
            applicationName: AIManagerBrand.bundleDisplayName(),
            addAccount: { [weak self] in self?.addAccountFromMenuBar() },
            advancedImport: { [weak self] in self?.advancedImport() },
            closeWindow: { [weak self] in self?.windowController?.window?.close() },
            minimizeWindow: { [weak self] in
                AIManagerWindowBehavior.minimize(self?.windowController?.window)
            },
            presentWindow: { [weak self] in self?.windowController?.present() },
            canChangeAccounts: { [weak self] in self?.model.isBusy == false },
            refreshNow: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if !self.model.isBusy { await self.model.refresh() }
                    await self.refreshEnabledUsage()
                }
            }
        )
        self.menuController = menuController
        menuController.install()
        if !AIManagerLaunchContext.launchedAsLoginItem() { controller.present() }
        Task { await model.load() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await model.reloadAfterActivation() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController?.present() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.savePlacement()
        if let instanceActivationObserver {
            DistributedNotificationCenter.default().removeObserver(instanceActivationObserver)
        }
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
    }

    /// The popover's refresh: usage for every account that shows in the menu bar.
    private func refreshEnabledUsage() async {
        let accounts = model.status?.accounts.filter {
            MenuBarUsagePreferences.showsUsage(for: $0.id)
        } ?? []
        for account in accounts where account.identity.providerID == .codex {
            await model.refreshUsage(accountID: account.id)
        }
        await model.refreshProviderUsage(accountIDs: accounts.filter {
            $0.identity.providerID != .codex
                && ProviderCatalog.spec($0.identity.providerID) != nil
        }.map(\.id))
    }

    /// The popover row menu's refresh: one account.
    private func refreshUsage(of accountID: UUID) async {
        guard let account = model.status?.accounts.first(where: { $0.id == accountID }) else { return }
        if account.identity.providerID == .codex {
            await model.refreshUsage(accountID: accountID)
        } else if ProviderCatalog.spec(account.identity.providerID) != nil {
            await model.refreshProviderUsage(accountIDs: [accountID])
        }
    }

    private func advancedImport() {
        guard !model.isBusy else { return }
        Task { await model.beginAdvancedImport() }
    }

    private func addAccountFromMenuBar() {
        guard !model.isBusy else { return }
        Task { await model.beginAddAccount() }
    }

    private func applyAppearance() {
        let mode = AppearanceOverride.mode
        let appearance: NSAppearance?
        let usesDarkIcon: Bool?
        switch mode {
        case "light":
            appearance = NSAppearance(named: .aqua)
            usesDarkIcon = false
        case "dark":
            appearance = NSAppearance(named: .darkAqua)
            usesDarkIcon = true
        default:
            appearance = nil
            usesDarkIcon = nil
        }
        NSApp.appearance = appearance
        statusItemController?.updateAppearance(appearance)
        AIManagerBrand.installApplicationIcon(dark: usesDarkIcon)
    }

    private func switchAccountFromMenuBar(_ accountID: UUID) async throws {
        guard let account = model.status?.accounts.first(where: {
            $0.id == accountID && Self.canSwitch($0)
        }) else {
            throw MenuBarActionError.accountUnavailable
        }
        if model.status?.defaultAccountID(for: account.identity.providerID) == accountID { return }
        await model.switchDefault(to: accountID)
        guard model.status?.defaultAccountID(for: account.identity.providerID) == accountID else {
            throw MenuBarActionError.switchFailed(model.errorMessage)
        }
    }

    private func menuBarSnapshot(
        status: ManagerStatus?,
        usageSnapshots: [UUID: CodexAccountUsageSnapshot],
        dailyUsage: [UUID: [CodexDailyUsageSnapshot]],
        apiPrice: CodexAPIPrice?,
        providerUsage: [UUID: ProviderUsageState]? = nil
    ) -> MenuBarSnapshot {
        guard let status else { return .empty }
        let providerUsage = providerUsage ?? model.providerUsage
        return MenuBarSnapshot(
            accounts: status.accounts.map { account in
                let providerID = account.identity.providerID
                let isCodex = providerID == .codex
                let state = providerUsage[account.id]
                // Claude profiles join once their usage arrives; other providers always have a spec.
                let supportsUsage = isCodex || ProviderCatalog.spec(providerID) != nil
                    || state?.usage != nil
                let showsUsage = supportsUsage && MenuBarUsagePreferences.showsUsage(for: account.id)
                let usage: MenuBarUsageSnapshot?
                if !showsUsage {
                    usage = nil
                } else if isCodex {
                    usage = menuBarUsage(
                        for: account.id,
                        status: status,
                        usageSnapshots: usageSnapshots,
                        dailyUsage: dailyUsage,
                        apiPrice: apiPrice)
                } else if let providerUsage = state?.usage, state?.needsSignIn != true,
                          account.verification.state != .needsSignIn {
                    usage = MenuBarUsageSnapshot(
                        providerUsage: HiddenUsageRows.applying(to: providerUsage, for: account.id))
                } else {
                    usage = nil
                }
                return MenuBarAccountSnapshot(
                    id: account.id,
                    identity: account.identity.notificationLabel,
                    detail: Self.accountDetail(account),
                    isVerified: Self.canSwitch(account),
                    isActive: status.isDefault(account),
                    usage: usage,
                    showsUsage: showsUsage,
                    providerID: providerID, identityIsFormatted: true)
            },
            lastRefreshedAt: (usageSnapshots.values.map(\.fetchedAt)
                + providerUsage.values.compactMap { $0.usage?.fetchedAt }).max())
    }

    private func menuBarUsage(
        for accountID: UUID,
        status: ManagerStatus,
        usageSnapshots: [UUID: CodexAccountUsageSnapshot],
        dailyUsage: [UUID: [CodexDailyUsageSnapshot]],
        apiPrice: CodexAPIPrice?
    ) -> MenuBarUsageSnapshot? {
        guard status.accounts.first(where: { $0.id == accountID })?.verification.state != .needsSignIn,
              let snapshot = usageSnapshots[accountID],
              let limits = snapshot.rateLimits,
              let bucket = limits.defaultBucket ?? limits.buckets.sorted(by: { $0.key < $1.key }).first?.value else { return nil }
        let rows = dailyUsage[accountID] ?? snapshot.dailyUsage
        let period = MenuBarTokenPeriod.selected()
        return MenuBarUsageSnapshot(
            bucket: bucket,
            additionalBuckets: limits.buckets,
            extras: snapshot.extras,
            fetchedAt: snapshot.fetchedAt,
            tokenPeriodLabel: rows.isEmpty ? nil : period.summaryLabel,
            tokens: rows.isEmpty ? nil : period.tokens(in: rows, usage: snapshot),
            apiPrice: apiPrice)
    }

    private static func accountDetail(_ account: AccountRecord) -> String {
        let workspace = account.identity.workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [account.identity.providerID.guiName, workspace]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    private static func canSwitch(_ account: AccountRecord) -> Bool {
        switch account.verification.state {
        case .imported, .verifiedLocally, .verifiedWithCodex: return true
        case .needsSignIn, .unsupported: return false
        }
    }

}

private enum MenuBarActionError: LocalizedError {
    case appUnavailable
    case accountUnavailable
    case switchFailed(String?)

    var errorDescription: String? {
        switch self {
        case .appUnavailable:
            return "Switch is unavailable."
        case .accountUnavailable:
            return "Check this account before switching."
        case .switchFailed(let detail):
            return detail ?? "Switch could not change the account."
        }
    }
}

@main
enum AIManagerApp {
    @MainActor
    static func main() {
        let bundleIdentifier = AIManagerSingleInstance.bundleIdentifier()
        guard let instanceLock = AIManagerSingleInstance.acquireOrActivate(
            bundleIdentifier: bundleIdentifier) else { return }
        let application = NSApplication.shared
        let delegate = AIManagerAppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime((delegate, instanceLock)) {
            application.run()
        }
    }
}
