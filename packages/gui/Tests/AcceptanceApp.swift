import AppKit
import Combine
import Foundation
import SwiftUI

private struct WindowContractReceipt: Codable {
    let passed: Bool
    let failures: [String]
    let window: WindowContractObservation?
    var hierarchy: [AIManagerNativeViewSnapshot] = []
    var titleHitPath: [String] = []
}

private struct WindowContractObservation: Codable {
    let stage: String
    let windowClass: String
    let windowNumber: Int
    let frameX: Double
    let frameY: Double
    let frameWidth: Double
    let frameHeight: Double
    let appearance: String?
    let configuredScrollViews: Int
    let minWidth: Double
    let minHeight: Double
    let maxWidth: Double
    let maxHeight: Double
    let contentMinWidth: Double
    let contentMinHeight: Double
    let contentMaxWidth: Double
    let contentMaxHeight: Double

    @MainActor init(stage: String, window: NSWindow) {
        self.stage = stage
        windowClass = NSStringFromClass(type(of: window))
        windowNumber = window.windowNumber
        frameX = window.frame.origin.x
        frameY = window.frame.origin.y
        frameWidth = window.frame.size.width
        frameHeight = window.frame.size.height
        appearance = window.appearance?.name.rawValue
        configuredScrollViews = window.contentView.map { AIManagerNativeContract.configuredScrollViewCount(in: $0) } ?? 0
        minWidth = window.minSize.width
        minHeight = window.minSize.height
        maxWidth = window.maxSize.width
        maxHeight = window.maxSize.height
        contentMinWidth = window.contentMinSize.width
        contentMinHeight = window.contentMinSize.height
        contentMaxWidth = window.contentMaxSize.width
        contentMaxHeight = window.contentMaxSize.height
    }

    @MainActor static func signature(for window: NSWindow) -> String {
        "\(NSStringFromRect(window.frame))|\(window.appearance?.name.rawValue ?? "none")"
    }
}

private enum AcceptanceConfiguration {
    static var appearance: ColorScheme? {
        if CommandLine.arguments.contains("--dark") { return .dark }
        if CommandLine.arguments.contains("--light") { return .light }
        switch Bundle.main.object(forInfoDictionaryKey: "AIManagerGUIAppearance") as? String {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    static let initialSize = NSSize(width: 1120, height: 740)
    static var contractOnly: Bool { CommandLine.arguments.contains("--contract-only") }
    static var persistedAppearanceMode: String? {
        if CommandLine.arguments.contains("--persisted-dark") { return "dark" }
        if CommandLine.arguments.contains("--persisted-light") { return "light" }
        if CommandLine.arguments.contains("--persisted-system") { return "system" }
        return nil
    }
    static var opensImport: Bool { CommandLine.arguments.contains("--import") }
    static var showsAllStates: Bool { CommandLine.arguments.contains("--all-states") }
    static var initialPageIndex: Int {
        if CommandLine.arguments.contains("--settings") { return 1 }
        if CommandLine.arguments.contains("--history") { return 2 }
        if CommandLine.arguments.contains("--recovery") { return 3 }
        return 0
    }
}

@MainActor
private final class AcceptanceAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let receipts = AcceptanceReceipts()
    private let model = AccountViewModel(
        scenario: AcceptanceConfiguration.showsAllStates ? .allStates : .demo)
    private var windowController: AIManagerWindowController<AnyView>?
    private var statusItemController: AIManagerStatusItemController?
    private var instanceActivationObserver: NSObjectProtocol?
    private var priorAppearanceMode: Any?
    var hasStatusItem: Bool { statusItemController?.isPresent == true }
    private var modelObservers = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DemoFonts.register()
        AIManagerBrand.installApplicationIcon()
        if let mode = AcceptanceConfiguration.persistedAppearanceMode {
            priorAppearanceMode = UserDefaults.standard.object(forKey: "appearanceMode")
            UserDefaults.standard.set(mode, forKey: "appearanceMode")
        }
        if let appearance = AcceptanceConfiguration.appearance {
            NSApp.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        }
        receipts.model = model
        model.$selectedAccountID
            .dropFirst()
            .sink { [receipts] _ in checkWindowContract(receipts: receipts, stage: "after-account-change") }
            .store(in: &modelObservers)
        model.$showImport
            .dropFirst()
            .sink { [receipts] _ in checkWindowContract(receipts: receipts, stage: "after-import-state-change") }
            .store(in: &modelObservers)
        let content = AnyView(
            AccountWindow(model: model, initialPageIndex: AcceptanceConfiguration.initialPageIndex)
                .preferredColorScheme(AcceptanceConfiguration.appearance)
                .task { [receipts, model] in
                    guard !AcceptanceConfiguration.contractOnly else { return }
                    receipts.observeWindowEvents()
                    await model.load()
                    if AcceptanceConfiguration.opensImport { await model.beginImport() }
                    try? await Task.sleep(for: .milliseconds(300))
                    checkWindowContract(receipts: receipts, stage: "after-load")
                }
        )

        let title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Switch GUI Acceptance"
        let controller = AIManagerWindowController(
            title: title,
            rootView: content
        )
        windowController = controller
        if AcceptanceConfiguration.contractOnly {
            controller.window?.orderOut(nil)
            Task { await runContractOnly(in: controller.window) }
            return
        }
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
        installMainMenu(title: title)
        controller.present()
    }

    private func runContractOnly(in window: NSWindow?) async {
        await model.load()
        if AcceptanceConfiguration.opensImport { await model.beginImport() }
        try? await Task.sleep(for: .milliseconds(100))
        window?.contentView?.layoutSubtreeIfNeeded()
        checkWindowContract(receipts: receipts, stage: "contract-only")
        NSApp.terminate(nil)
    }

    private func installMainMenu(title: String) {
        let main = NSMenu()
        for (name, commands) in [
            (title, [("Quit \(title)", #selector(NSApplication.terminate(_:)), "q", NSApp as AnyObject)]),
            ("File", [
                ("Import Account…", #selector(importAccount), "i", self as AnyObject),
                ("Close Window", #selector(closeWindow), "w", self as AnyObject),
                ("Minimize", #selector(minimizeWindow), "m", self as AnyObject)
            ])
        ] {
            let parent = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: name)
            for (label, action, key, target) in commands {
                let item = NSMenuItem(title: label, action: action, keyEquivalent: key)
                item.target = target
                submenu.addItem(item)
            }
            parent.submenu = submenu
            main.addItem(parent)
        }
        NSApp.mainMenu = main
    }

    @objc private func importAccount() {
        guard !model.isBusy else { return }
        Task { await model.beginImport() }
    }

    @objc private func closeWindow() { windowController?.window?.close() }
    @objc private func minimizeWindow() { AIManagerWindowBehavior.minimize(windowController?.window) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(importAccount) ? !model.isBusy : true
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
        if AcceptanceConfiguration.persistedAppearanceMode != nil {
            if let priorAppearanceMode {
                UserDefaults.standard.set(priorAppearanceMode, forKey: "appearanceMode")
            } else {
                UserDefaults.standard.removeObject(forKey: "appearanceMode")
            }
        }
    }
}

@main
enum AIManagerGUIAcceptanceApp {
    @MainActor
    static func main() {
        let bundleIdentifier = AIManagerSingleInstance.bundleIdentifier()
        guard let instanceLock = AIManagerSingleInstance.acquireOrActivate(
            bundleIdentifier: bundleIdentifier) else { return }
        let application = NSApplication.shared
        let delegate = AcceptanceAppDelegate()
        application.setActivationPolicy(AcceptanceConfiguration.contractOnly ? .accessory : .regular)
        application.delegate = delegate
        withExtendedLifetime((delegate, instanceLock)) {
            application.run()
        }
    }
}

@MainActor
private func checkWindowContract(receipts: AcceptanceReceipts, stage: String) {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }
    expect(AIMTheme.windowControlSize == 48, "Custom controls are not 48 points square")
    expect(
        AIManagerNativeContract.windowControlGeometryMatches(),
        "Window controls, titlebar, or page insets do not match the chrome contract"
    )
    expect(AIMTheme.modalOuterInset == 24, "Modal outer content edge is not 24 points")
    expect(AIMTheme.panelContentInset == 16, "Panel content edge is not 16 points")
    if let mode = AcceptanceConfiguration.persistedAppearanceMode {
        expect(
            UserDefaults.standard.string(forKey: "appearanceMode") == mode,
            "Persisted appearance selection was not retained"
        )
    }
    expect(
        Bundle.main.object(forInfoDictionaryKey: "LSMultipleInstancesProhibited") as? Bool == true,
        "Launch Services does not prohibit duplicate app instances"
    )
    guard let window = NSApp.windows.first(where: { $0 is AIManagerWindow }) else {
        let receipt = WindowContractReceipt(
            passed: false,
            failures: ["Acceptance AIManagerWindow did not resolve"],
            window: nil
        )
        receipts.writeWindowContract(receipt)
        receipts.report(failures: receipt.failures)
        return
    }
    expect(window.canBecomeKey, "Acceptance window cannot become key")
    expect(window.canBecomeMain, "Acceptance window cannot become main")
    expect(!window.styleMask.contains(.titled), "Acceptance window is still titled")
    expect(!window.styleMask.contains(.resizable), "Acceptance window is resizable")
    expect(window.styleMask.contains(.closable), "Acceptance window is not closable")
    expect(window.styleMask.contains(.miniaturizable), "Acceptance window is not miniaturizable")
    if AcceptanceConfiguration.persistedAppearanceMode == "system" {
        expect(window.appearance == nil, "System appearance is pinned to a fixed Aqua appearance")
    }
    expect(window.collectionBehavior.contains(.fullScreenNone), "Acceptance window allows fullscreen")
    expect(!window.isOpaque, "Acceptance window is opaque")
    expect(window.backgroundColor.alphaComponent == 0, "Acceptance window background is not clear")
    expect(
        window.frame.size == AcceptanceConfiguration.initialSize,
        "Acceptance window frame changed to \(NSStringFromSize(window.frame.size))"
    )
    expect(
        window.minSize == AcceptanceConfiguration.initialSize,
        "Acceptance window minimum changed to \(NSStringFromSize(window.minSize))"
    )
    expect(
        window.maxSize == AcceptanceConfiguration.initialSize,
        "Acceptance window maximum changed to \(NSStringFromSize(window.maxSize))"
    )
    expect(
        window.contentMinSize == AcceptanceConfiguration.initialSize
            && window.contentMaxSize == AcceptanceConfiguration.initialSize,
        "Acceptance content size bounds are not fixed"
    )
    expect(window.standardWindowButton(.closeButton) == nil, "Native close button exists")
    expect(window.standardWindowButton(.miniaturizeButton) == nil, "Native minimize button exists")
    expect(window.standardWindowButton(.zoomButton) == nil, "Native zoom button exists")
    expect(
        window.frameAutosaveName == AIManagerWindow.frameAutosaveName,
        "Window position persistence is not configured"
    )
    if let mode = AcceptanceConfiguration.persistedAppearanceMode {
        if mode == "system" {
            expect(window.appearance == nil, "System appearance was not inherited from macOS")
        } else {
            let expected: NSAppearance.Name = mode == "dark" ? .darkAqua : .aqua
            expect(window.appearance?.name == expected, "Persisted appearance was not applied to the window")
        }
    }
    expect(NSFont(name: "Geist-Regular", size: 13) != nil, "Geist font is unavailable")
    expect(NSFont(name: "GeistMono-Regular", size: 13) != nil, "Geist Mono font is unavailable")
    failures.append(contentsOf: AIManagerBrand.acceptanceFailures())
    if !AcceptanceConfiguration.contractOnly {
        expect((NSApp.delegate as? AcceptanceAppDelegate)?.hasStatusItem == true, "Switch status item is unavailable")
    }
    let behaviorDomain = "com.mandalsuraj.ai-manager.acceptance.window-behavior"
    if let behaviorDefaults = UserDefaults(suiteName: behaviorDomain) {
        behaviorDefaults.set(true, forKey: AIManagerWindowBehavior.minimizeToTrayKey)
        expect(
            AIManagerWindowBehavior.hidesOnMinimize(defaults: behaviorDefaults),
            "Minimize-to-tray preference did not select window hiding"
        )
        behaviorDefaults.set(false, forKey: AIManagerWindowBehavior.minimizeToTrayKey)
        expect(
            !AIManagerWindowBehavior.hidesOnMinimize(defaults: behaviorDefaults),
            "Native minimize preference did not select miniaturization"
        )
        behaviorDefaults.removePersistentDomain(forName: behaviorDomain)
    } else {
        failures.append("Acceptance preference domain was unavailable")
    }
    for icon in AIMIcon.Name.allCases {
        expect(
            NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil) != nil,
            "AIM icon \(String(describing: icon)) is unavailable"
        )
    }
    if let contentView = window.contentView {
        expect(contentView.bounds.size == AcceptanceConfiguration.initialSize, "Acceptance content size changed")
        expect(
            AIManagerNativeContract.defaultFocusIndicatorsAreHidden(in: window),
            "A default focus ring is visible"
        )
        if stage == "after-load" || stage == "contract-only" {
            receipts.writeSnapshot(of: contentView)
            expect(
                AIManagerNativeContract.focusPolicyMatches(in: contentView, indicatorsEnabled: false),
                "Acceptance host focus policy is not disabled at startup"
            )
        }
        expect(
            AIManagerNativeContract.scrollBehaviorIsInstalled(in: contentView),
            "Acceptance scroll behavior is not installed after layout"
        )
        expect(
            AIManagerNativeContract.scrollAppearancesMatch(in: contentView, appearance: window.effectiveAppearance),
            "Acceptance scroll content appearance differs from the window"
        )
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            expect(
                AIManagerNativeContract.hasVisualEffect(in: contentView),
                "Acceptance window has no visual-effect backdrop"
            )
        }
        // The shared helper converts top-origin coordinates to AppKit hit-test coordinates.
        let titlePoint = NSPoint(x: 400, y: 28)
        if receipts.model?.showImport != true {
            expect(
                AIManagerNativeContract.titleDragTarget(in: window, at: titlePoint),
                "Title drag hit-test did not resolve AIMTitleDragView at (400, top 28)"
            )
        }
        let themeY = contentView.isFlipped ? contentView.bounds.maxY - 72 : 72
        let themePoint = NSPoint(x: 24, y: themeY)
        expect(
            !windowHelperResolves(at: themePoint, in: contentView),
            "Theme control hit-test resolves a window drag helper"
        )
    } else {
        failures.append("Acceptance window content view did not resolve")
    }
    let commands = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []
    if !AcceptanceConfiguration.contractOnly {
        expect(commands.contains {
            $0.keyEquivalent == "q" && $0.action == #selector(NSApplication.terminate(_:))
        }, "Preview Quit command is missing")
    }
    var receipt = WindowContractReceipt(
        passed: failures.isEmpty,
        failures: failures,
        window: WindowContractObservation(stage: stage, window: window)
    )
    if (["after-load", "contract-only"].contains(stage) || !failures.isEmpty), let root = window.contentView {
        receipt.hierarchy = AIManagerNativeContract.hierarchySnapshot(in: root)
        receipt.titleHitPath = AIManagerNativeContract.hitTestPath(in: window, atTopOriginPoint: NSPoint(x: 400, y: 28))
    }
    receipts.writeWindowContract(receipt)
    receipts.report(failures: failures)
}

private func windowHelperResolves(at point: NSPoint, in contentView: NSView) -> Bool {
    var view = contentView.hitTest(contentView.convert(point, to: contentView.superview))
    while let current = view {
        if current is AIMTitleDragView {
            return true
        }
        let className = NSStringFromClass(type(of: current))
        if className.contains("WindowResolver") || className.contains("DragView") {
            return true
        }
        view = current.superview
    }
    return false
}

@MainActor
private final class AcceptanceReceipts {
    weak var model: AccountViewModel?
    private static let stableDirectory = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["AI_MANAGER_ACCEPTANCE_ARTIFACTS"]
            ?? "/private/tmp/ai-manager-build/gui-acceptance/artifacts",
        isDirectory: true
    )
    private let directory: URL?
    private var windowObservers: [NSObjectProtocol] = []
    private var pendingMoveReceipt: DispatchWorkItem?
    private var lastEventSignatures: [String: String] = [:]
    private var didUpdateReceiptScheduled = false

    init() {
        directory = Self.prepareDirectory(Self.stableDirectory)
        clearReceipts()
    }

    func observeWindowEvents() {
        guard windowObservers.isEmpty, let directory else { return }
        let center = NotificationCenter.default
        for (name, marker) in [
            (NSWindow.didMiniaturizeNotification, "window-did-miniaturize"),
            (NSWindow.willCloseNotification, "window-will-close"),
        ] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [directory] notification in
                guard let window = notification.object as? NSWindow, window is AIManagerWindow else { return }
                try? Data("PASS\n".utf8).write(to: directory.appending(path: marker), options: .atomic)
            }
            windowObservers.append(observer)
        }
        for (name, stage) in [
            (NSWindow.didMoveNotification, "after-window-move"),
            (NSWindow.didBecomeKeyNotification, "after-window-key"),
            (NSWindow.didUpdateNotification, "after-window-update")
        ] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self,
                      let window = notification.object as? NSWindow,
                      window is AIManagerWindow else { return }
                Task { @MainActor in self.scheduleWindowContract(for: window, stage: stage) }
            }
            windowObservers.append(observer)
        }
    }

    private func scheduleWindowContract(for window: NSWindow, stage: String) {
        if stage == "after-window-update" {
            guard !didUpdateReceiptScheduled else { return }
            didUpdateReceiptScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self, weak window] in
                guard let self, let window else { return }
                self.didUpdateReceiptScheduled = false
                self.recordWindowContract(for: window, stage: stage)
            }
            return
        }

        if stage == "after-window-move" {
            pendingMoveReceipt?.cancel()
            let work = DispatchWorkItem { [weak self, weak window] in
                guard let self, let window else { return }
                self.recordWindowContract(for: window, stage: stage)
            }
            pendingMoveReceipt = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: work)
            return
        }

        recordWindowContract(for: window, stage: stage)
    }

    private func recordWindowContract(for window: NSWindow, stage: String) {
        guard let contentView = window.contentView else { return }
        let signature = WindowContractObservation.signature(for: window)
            + "|\(AIManagerNativeContract.scrollIdentity(in: contentView))"
            + "|\(AIManagerNativeContract.configuredScrollViewCount(in: contentView))"
            + "|\(model?.showImport ?? false)|\(window.contentView?.focusRingType.rawValue ?? 0)"
        guard lastEventSignatures[stage] != signature else { return }
        lastEventSignatures[stage] = signature
        checkWindowContract(receipts: self, stage: stage)
    }

    func writeWindowContract(_ receipt: WindowContractReceipt) {
        guard let directory else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(receipt) else { return }
        try? data.write(to: directory.appending(path: "window-contract.json"), options: .atomic)
    }

    func writeSnapshot(of view: NSView) {
        guard let directory,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: directory.appending(path: "window.png"), options: .atomic)
        let hierarchy = AIManagerNativeContract.hierarchySnapshot(in: view)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let hierarchyData = try? encoder.encode(hierarchy) {
            try? hierarchyData.write(
                to: directory.appending(path: "window-hierarchy.json"), options: .atomic)
        }
    }

    func report(failures: [String]) {
        let status = failures.isEmpty
            ? "WINDOW_CONTRACT_PASS\n"
            : "WINDOW_CONTRACT_FAIL: \(failures.joined(separator: "; "))\n"
        FileHandle.standardError.write(Data(status.utf8))
    }

    private func clearReceipts() {
        guard let directory else { return }
        let fileManager = FileManager.default
        for name in ["window-contract.json", "window.png", "window-hierarchy.json", "window-did-miniaturize", "window-will-close"] {
            try? fileManager.removeItem(at: directory.appending(path: name))
        }
    }

    private static func prepareDirectory(_ url: URL) -> URL? {
        let fileManager = FileManager.default
        let components = url.pathComponents
        guard url.isFileURL,
              url.path.hasPrefix("/private/tmp/"),
              !components.contains("."),
              !components.contains("..") else { return nil }

        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue,
                      (try? fileManager.destinationOfSymbolicLink(atPath: current.path)) == nil else { return nil }
            } else {
                do {
                    try fileManager.createDirectory(
                        at: current,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                } catch {
                    return nil
                }
            }
        }
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
