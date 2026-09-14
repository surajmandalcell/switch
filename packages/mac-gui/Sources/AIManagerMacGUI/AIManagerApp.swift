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
    private var modelObservers = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppFonts.register()
        AIManagerBrand.installApplicationIcon()
        let controller = AIManagerWindowController(
            title: AIManagerBrand.bundleDisplayName(),
            rootView: AccountWindow(model: model)
        )
        windowController = controller
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
            snapshot: menuBarSnapshot(),
            actions: MenuBarPopoverActions(
                openMainWindow: {
                    controller.present()
                    NSApp.activate(ignoringOtherApps: true)
                },
                addAccount: { [weak self] in self?.addAccountFromMenuBar() },
                quit: { NSApp.terminate(nil) },
                switchAccount: { [weak self] accountID in
                    guard let self else { throw MenuBarActionError.appUnavailable }
                    try await self.switchAccountFromMenuBar(accountID)
                }
            ))
        self.statusItemController = statusItemController
        model.$status
            .sink { [weak self, weak statusItemController] _ in
                guard let self else { return }
                statusItemController?.update(snapshot: self.menuBarSnapshot())
            }
            .store(in: &modelObservers)
        let menuController = AIManagerMenuController(
            applicationName: AIManagerBrand.bundleDisplayName(),
            importAccount: { [weak self] in self?.importAccount() },
            closeWindow: { [weak self] in self?.windowController?.window?.close() },
            minimizeWindow: { [weak self] in
                AIManagerWindowBehavior.minimize(self?.windowController?.window)
            },
            presentWindow: { [weak self] in self?.windowController?.present() },
            canImport: { [weak self] in self?.model.isBusy == false }
        )
        self.menuController = menuController
        menuController.install()
        controller.present()
        Task { await model.load() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await model.load() }
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
    }

    private func importAccount() {
        guard !model.isBusy else { return }
        Task { await model.beginImport() }
    }

    private func addAccountFromMenuBar() {
        guard !model.isBusy else { return }
        Task { await model.beginAddAccount() }
    }

    private func switchAccountFromMenuBar(_ accountID: UUID) async throws {
        guard model.status?.accounts.contains(where: {
            $0.id == accountID && $0.verification.state == .verifiedWithCodex
        }) == true else {
            throw MenuBarActionError.accountUnavailable
        }
        if model.status?.defaultAccountID == accountID { return }
        await model.switchDefault(to: accountID)
        guard model.status?.defaultAccountID == accountID else {
            throw MenuBarActionError.switchFailed(model.errorMessage)
        }
    }

    private func menuBarSnapshot() -> MenuBarSnapshot {
        guard let status = model.status else { return .empty }
        return MenuBarSnapshot(
            accounts: status.accounts.map { account in
                MenuBarAccountSnapshot(
                    id: account.id,
                    identity: account.identity.email ?? "Codex account",
                    detail: Self.accountDetail(account),
                    isVerified: account.verification.state == .verifiedWithCodex,
                    isActive: account.id == status.defaultAccountID)
            },
            primaryUsedPercentage: nil)
    }

    private static func accountDetail(_ account: AccountRecord) -> String {
        let workspace = account.identity.workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let verification: String
        switch account.verification.state {
        case .verifiedWithCodex: verification = "Verified"
        case .verifiedLocally: verification = "Locally verified"
        case .needsSignIn: verification = "Sign-in required"
        case .imported: verification = "Check required"
        case .unsupported: verification = "Unavailable"
        }
        return [workspace, verification]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
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
            return "This account must be verified before switching."
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
