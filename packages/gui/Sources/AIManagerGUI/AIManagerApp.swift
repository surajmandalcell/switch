import AppKit
import AIManagerCore

@MainActor
private final class AIManagerAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let model = AccountViewModel(paths: .environment())
    private var windowController: AIManagerWindowController<AccountWindow>?
    private var statusItemController: AIManagerStatusItemController?
    private var instanceActivationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DemoFonts.register()
        AIManagerBrand.installApplicationIcon()
        let controller = AIManagerWindowController(
            title: "IIA Directeur",
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
        statusItemController = AIManagerStatusItemController {
            controller.present()
            NSApp.activate(ignoringOtherApps: true)
        }
        installMainMenu()
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
        if let instanceActivationObserver {
            DistributedNotificationCenter.default().removeObserver(instanceActivationObserver)
        }
    }

    @objc private func importAccount() {
        guard !model.isBusy else { return }
        Task { await model.beginImport() }
    }

    @objc private func closeWindow() { NSApp.keyWindow?.close() }
    @objc private func minimizeWindow() { AIManagerWindowBehavior.minimize(windowController?.window) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(importAccount) ? !model.isBusy : true
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        mainMenu.addItem(menuItem(title: "IIA Directeur", items: [
            NSMenuItem(title: "About IIA Directeur", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: "Hide IIA Directeur", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h", modifiers: [.command, .option]),
            NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: "Quit IIA Directeur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        ]))
        mainMenu.addItem(menuItem(title: "File", items: [
            NSMenuItem(title: "Import Account…", action: #selector(importAccount), keyEquivalent: "i", target: self),
            .separator(),
            NSMenuItem(title: "Close Window", action: #selector(closeWindow), keyEquivalent: "w", target: self)
        ]))
        mainMenu.addItem(menuItem(title: "Edit", items: [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"),
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        ]))
        mainMenu.addItem(menuItem(title: "Window", items: [
            NSMenuItem(title: "Minimize", action: #selector(minimizeWindow), keyEquivalent: "m", target: self),
            NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        ]))
        NSApp.mainMenu = mainMenu
    }

    private func menuItem(title: String, items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        items.forEach(submenu.addItem)
        parent.submenu = submenu
        return parent
    }
}

private extension NSMenuItem {
    convenience init(title: String, action: Selector?, keyEquivalent: String, target: AnyObject? = nil, modifiers: NSEvent.ModifierFlags = .command) {
        self.init(title: title, action: action, keyEquivalent: keyEquivalent)
        self.target = target
        keyEquivalentModifierMask = modifiers
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
