import AIManagerCore
import AppKit
import Combine
import Foundation
import SwiftUI

#if !AI_MANAGER_PREVIEW
#error("AcceptanceApp requires AI_MANAGER_PREVIEW")
#endif

private struct WindowContractReceipt: Codable {
    let passed: Bool
    let failures: [String]
    let window: WindowContractObservation?
    var hierarchy: [AIManagerNativeViewSnapshot] = []
}

private struct WindowContractObservation: Codable {
    let stage: String
    let windowClass: String
    let windowNumber: Int
    /// The Add Account or Advanced Import sheet, when one is open, for sheet screenshots.
    let sheetWindowNumber: Int?
    let frameX: Double
    let frameY: Double
    let frameWidth: Double
    let frameHeight: Double
    let appearance: String?
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
        sheetWindowNumber = window.attachedSheet?.windowNumber
        frameX = window.frame.origin.x
        frameY = window.frame.origin.y
        frameWidth = window.frame.size.width
        frameHeight = window.frame.size.height
        appearance = window.appearance?.name.rawValue
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

/// `AI_MANAGER_RENDER_SCALE=1|2` renders every snapshot at that pixel density and tells SwiftUI the
/// same `displayScale`, so a 1x display and a 2x display can both be checked on one Mac.
enum RenderScale {
    static var value: CGFloat? {
        ProcessInfo.processInfo.environment["AI_MANAGER_RENDER_SCALE"].flatMap(Double.init).map { CGFloat($0) }
    }

    @MainActor static func png(of view: NSView) -> Data? {
        let bitmap: NSBitmapImageRep?
        if let scale = value {
            bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale),
                pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            bitmap?.size = view.bounds.size
        } else {
            bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        }
        guard let bitmap else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}

extension View {
    @ViewBuilder func renderScaled() -> some View {
        if let scale = RenderScale.value { environment(\.displayScale, scale) } else { self }
    }
}

private enum AcceptanceConfiguration {
    static var appearance: ColorScheme? {
        if CommandLine.arguments.contains("--dark") { return .dark }
        if CommandLine.arguments.contains("--light") { return .light }
        switch Bundle.main.object(forInfoDictionaryKey: "AIManagerMacGUIAppearance") as? String {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    static var contractOnly: Bool { CommandLine.arguments.contains("--contract-only") }
    static var snapshotOnly: Bool { CommandLine.arguments.contains("--snapshot-only") }
    static var persistedAppearanceMode: String? {
        if CommandLine.arguments.contains("--persisted-dark") { return "dark" }
        if CommandLine.arguments.contains("--persisted-light") { return "light" }
        if CommandLine.arguments.contains("--persisted-system") { return "system" }
        return nil
    }
    static var opensImport: Bool { CommandLine.arguments.contains("--import") }
    static var opensAdd: Bool {
        CommandLine.arguments.contains("--add") || CommandLine.arguments.contains("--add-signin")
    }
    static var opensAddSignIn: Bool { CommandLine.arguments.contains("--add-signin") }
    static var showsAllStates: Bool { CommandLine.arguments.contains("--all-states") }
    static var stressesHistory: Bool { CommandLine.arguments.contains("--history-stress") }
    /// Index into `AIManagerPage.allCases`: Overview (default), Accounts, Settings, Maintenance,
    /// Conversations.
    static var initialPageIndex: Int {
        if CommandLine.arguments.contains("--accounts") { return 1 }
        if CommandLine.arguments.contains("--settings") { return 2 }
        if CommandLine.arguments.contains("--backup")
            || CommandLine.arguments.contains("--recovery")
            || CommandLine.arguments.contains("--cleanup") { return 3 }
        if CommandLine.arguments.contains("--history") { return 4 }
        return 0
    }
    /// The page the run asked for and the page the window shows now; empty when they match.
    @MainActor static func pageMismatch() -> String? {
        let wanted = AIManagerPage.allCases[initialPageIndex]
        if AIMPlace.visiblePage != wanted {
            return "The window shows \(AIMPlace.visiblePage?.rawValue ?? "no page"), not the requested \(wanted.rawValue)"
        }
        if wanted == .maintenance, AIMPlace.visibleMaintenance != initialMaintenance {
            return "The window shows the \(AIMPlace.visibleMaintenance?.rawValue ?? "no") tab, not the requested \(initialMaintenance.rawValue)"
        }
        return nil
    }
    static var conversationsIndex: Int { AIManagerPage.allCases.firstIndex(of: .conversations) ?? 4 }
    static var initialMaintenance: MaintenanceSection {
        CommandLine.arguments.contains("--cleanup") ? .cleanup : .backup
    }
}

@MainActor
private final class AcceptanceAppDelegate: NSObject, NSApplicationDelegate {
    private let receipts = AcceptanceReceipts()
    private let model = AccountViewModel(
        scenario: AcceptanceConfiguration.stressesHistory
            ? .historyStress
            : (AcceptanceConfiguration.showsAllStates ? .allStates : .demo))
    private var windowController: AIManagerWindowController<AnyView>?
    private(set) var offscreenSheet: NSWindow?
    private var statusItemController: AIManagerStatusItemController?
    private var menuController: AIManagerMenuController?
    private var instanceActivationObserver: NSObjectProtocol?
    private var priorAppearanceMode: Any?
    var hasStatusItem: Bool { statusItemController?.isPresent == true }
    var menuNavigationFailures: [String] = []
    private var modelObservers = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AIMNativeFocusPolicy.install()
        AIManagerBrand.installApplicationIcon()
        if let mode = AcceptanceConfiguration.persistedAppearanceMode {
            priorAppearanceMode = UserDefaults.standard.object(forKey: "windowAppearance")
            UserDefaults.standard.set(mode, forKey: "windowAppearance")
        }
        if let appearance = AcceptanceConfiguration.appearance {
            NSApp.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        }
        receipts.model = model
        model.$selectedAccountID
            .dropFirst()
            .sink { [receipts] _ in
                if !AcceptanceConfiguration.contractOnly { checkWindowContract(receipts: receipts, stage: "after-account-change") }
            }
            .store(in: &modelObservers)
        model.$showImport
            .dropFirst()
            .sink { [receipts] _ in
                if !AcceptanceConfiguration.contractOnly { checkWindowContract(receipts: receipts, stage: "after-import-state-change") }
            }
            .store(in: &modelObservers)
        let content = AnyView(
            AccountWindow(
                model: model, initialPageIndex: AcceptanceConfiguration.initialPageIndex,
                initialMaintenance: AcceptanceConfiguration.initialMaintenance)
                .preferredColorScheme(AcceptanceConfiguration.appearance)
                .renderScaled()
                .task { [receipts, model] in
                    guard !AcceptanceConfiguration.contractOnly else { return }
                    receipts.observeWindowEvents()
                    await model.load()
                    await self.configureAccountModal()
                    try? await Task.sleep(for: .milliseconds(300))
                    checkWindowContract(receipts: receipts, stage: "after-load")
                }
        )

        let title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Switch Mac GUI Acceptance"
        let controller = AIManagerWindowController(
            title: title,
            rootView: content
        )
        windowController = controller
        if CommandLine.arguments.contains("--ui-lint"), let window = controller.window {
            UILintStore.shared.appearance = window.effectiveAppearance
        }
        let menuController = AIManagerMenuController(
            applicationName: title,
            addAccount: { [weak self] in self?.addAccount() },
            advancedImport: { [weak self] in self?.importAccount() },
            closeWindow: { [weak self] in self?.windowController?.window?.close() },
            minimizeWindow: { [weak self] in
                AIManagerWindowBehavior.minimize(self?.windowController?.window)
            },
            presentWindow: { [weak self] in
                if !AcceptanceConfiguration.contractOnly { self?.windowController?.present() }
            },
            canChangeAccounts: { [weak self] in self?.model.isBusy == false },
            refreshNow: { AIManagerNativeContract.menuRefreshCalls += 1 },
            activateApplication: {
                if !AcceptanceConfiguration.contractOnly { NSApp.activate(ignoringOtherApps: true) }
            }
        )
        self.menuController = menuController
        menuController.install()
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
        let statusItemController = AIManagerStatusItemController(
            snapshot: MenuBarPopoverPreviewData.fullSnapshot,
            actions: MenuBarPopoverActions(
                openMainWindow: {
                    controller.present()
                    NSApp.activate(ignoringOtherApps: true)
                },
                switchAccount: { [weak self] accountID in
                    guard let self else { return }
                    await self.model.switchDefault(to: accountID)
                },
                openSettings: { [weak self] in self?.menuController?.showSettings(nil) }
            ))
        self.statusItemController = statusItemController
        if let appearance = AcceptanceConfiguration.appearance {
            statusItemController.updateAppearance(NSAppearance(named: appearance == .dark ? .darkAqua : .aqua))
        }
        controller.present()
        // `--scroll=0.5` scrolls the page's tallest scroll view, for screenshots of long pages.
        if let raw = PreviewArguments.value("scroll"), let fraction = Double(raw) {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1_500))
                var best: NSScrollView?
                func visit(_ view: NSView) {
                    if let scroll = view as? NSScrollView, let document = scroll.documentView,
                       document.frame.height > scroll.contentView.bounds.height,
                       document.frame.height > (best?.documentView?.frame.height ?? 0) { best = scroll }
                    view.subviews.forEach(visit)
                }
                if let content = controller.window?.contentView { visit(content) }
                if let scroll = best, let document = scroll.documentView {
                    let travel = document.frame.height - scroll.contentView.bounds.height
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: travel * min(max(fraction, 0), 1)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }
        if CommandLine.arguments.contains("--popover") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                statusItemController.showPopoverForPreview()
            }
        }
    }

    private func runContractOnly(in window: NSWindow?) async {
        if CommandLine.arguments.contains("--ui-lint"), let window {
            UILintStore.shared.appearance = window.effectiveAppearance
        }
        // `--height=1500` renders a taller window, to see every card of a long page.
        if let raw = PreviewArguments.value("height"), let height = Double(raw), let window {
            window.setContentSize(NSSize(width: AIManagerWindow.defaultSize.width, height: height))
        }
        await model.load()
        await configureAccountModal()
        if model.showImport { openOffscreenSheet() }
        if CommandLine.arguments.contains("--focus-search") {
            NotificationCenter.default.post(name: AIManagerNavigation.focusSearch, object: nil)
        }
        try? await Task.sleep(for: .milliseconds(220))
        window?.contentView?.layoutSubtreeIfNeeded()
        if !CommandLine.arguments.contains("--ui-lint"), let window {
            receipts.prepareMenuBarSnapshot(appearance: window.effectiveAppearance)
            try? await Task.sleep(for: .milliseconds(220))
        }
        if CommandLine.arguments.contains("--ui-lint"), let window, let view = window.contentView {
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
            }
            try? await Task.sleep(for: .milliseconds(220))
            // The Cleanup tab lints as its own page, named "cleanup".
            let page = CommandLine.arguments.contains("--cleanup")
                ? "cleanup" : AIManagerPage.allCases[AcceptanceConfiguration.initialPageIndex].rawValue.lowercased()
            let appearance = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
            if let mismatch = AcceptanceConfiguration.pageMismatch() {
                FileHandle.standardError.write(Data("UI_LINT_WRONG_PAGE: \(mismatch)\n".utf8))
                exit(2)
            }
            do {
                guard let path = ProcessInfo.processInfo.environment["AI_MANAGER_ACCEPTANCE_ARTIFACTS"] else {
                    throw CocoaError(.fileNoSuchFile)
                }
                try UILintStore.shared.write(to: URL(fileURLWithPath: path)
                    .appendingPathComponent("ui-lint-\(page)-\(appearance).json"),
                    size: view.bounds.size, page: page, appearance: appearance)
            } catch {
                FileHandle.standardError.write(Data("UI_LINT_EXPORT_FAIL: \(error)\n".utf8))
                exit(2)
            }
            NSApp.terminate(nil)
            return
        }
        if !AcceptanceConfiguration.snapshotOnly {
            menuNavigationFailures = AIManagerNativeContract.exerciseMenuNavigation(in: window, offscreen: true)
            menuNavigationFailures.append(contentsOf: await AIManagerNativeContract.menuBarRefreshFailures())
            menuNavigationFailures.append(contentsOf: await AIManagerMenuBarContract.failures())
            menuNavigationFailures.append(contentsOf: await AIManagerNativeContract.appFeatureFailures())
            // The menu check ends on the last page; show the requested one again before the snapshot.
            NotificationCenter.default.post(
                name: AIManagerNavigation.request, object: AIManagerPage.allCases[AcceptanceConfiguration.initialPageIndex])
            try? await Task.sleep(for: .milliseconds(220))
            window?.contentView?.layoutSubtreeIfNeeded()
            if let view = window?.contentView {
                menuNavigationFailures.append(contentsOf: await scrollEdgeFailures(in: view))
            }
            menuNavigationFailures.append(contentsOf: await everySurfaceScrollFailures())
        }
        checkWindowContract(receipts: receipts, stage: "contract-only")
        NSApp.terminate(nil)
    }

    /// Open both sheet entry points with their parent ordered out. Also walk all pages and
    /// windows, including the AppKit field editor, rather than checking only the current page.
    private func everySurfaceScrollFailures() async -> [String] {
        var failures: [String] = []
        func inspect(_ surface: String) {
            AIMNativeFocusPolicy.install()
            if AIMNativeFocusPolicy.observerCount != 4 {
                failures.append("\(surface): native focus policy must have exactly one four-observer set")
            }
            if NSApp.isActive { failures.append("\(surface): offscreen acceptance activated the app") }
            for window in NSApp.windows {
                if window.isVisible { failures.append("\(surface): offscreen acceptance showed a window") }
                window.contentView?.layoutSubtreeIfNeeded()
                if let root = window.contentView {
                    failures += AIManagerNativeContract.scrollPolicyFailures(in: root).map { "\(surface): \($0)" }
                    failures += AIManagerNativeContract.focusRingFailures(in: root, requiresFullKeyboardAccess: false).map { "\(surface): \($0)" }
                }
                for sheet in window.sheets {
                    if let root = sheet.contentView {
                        failures += AIManagerNativeContract.scrollPolicyFailures(in: root).map { "\(surface) sheet: \($0)" }
                    }
                }
            }
        }
        for page in AIManagerPage.allCases {
            NotificationCenter.default.post(name: AIManagerNavigation.request, object: page)
            try? await Task.sleep(for: .milliseconds(250))
            inspect(page.rawValue)
        }
        for importing in [false, true] {
            if importing { await model.beginAdvancedImport() } else { await model.beginAddAccount() }
            openOffscreenSheet()
            try? await Task.sleep(for: .milliseconds(350))
            inspect(importing ? "Import" : "Add Account")
            if offscreenSheet?.contentView == nil { failures.append("Sheet scroll check did not open its sheet") }
            if importing {
                model.selectedSourceID = model.discoveries.first(where: { $0.support == .supportedChatGPT })?.id
                await model.reviewImport()
                try? await Task.sleep(for: .milliseconds(250))
                inspect("Import review")
                if let plan = model.importPlan {
                    for conflict in plan.conflicts { model.conflictChoices[conflict.relativePath] = .keepShared }
                    await model.commitImport()
                    try? await Task.sleep(for: .milliseconds(250))
                    inspect("Import result")
                } else { failures.append("Import review did not open") }
            } else {
                await model.startAccountLogin()
                try? await Task.sleep(for: .milliseconds(250))
                inspect("Sign-in")
                await model.checkAccountLogin()
                try? await Task.sleep(for: .milliseconds(250))
                inspect("Add Account complete")
                await model.cancelAccountLogin()
            }
            model.closeAccountModal()
            offscreenSheet?.close()
            offscreenSheet = nil
            try? await Task.sleep(for: .milliseconds(250))
        }
        for id in [ProviderID(rawValue: "openrouter"), .geminiCLI] {
            guard let spec = ProviderCatalog.spec(id) else { failures.append("Missing credential form fixture"); continue }
            let content = spec.style == .secret
                ? AnyView(SecretCredentialsPage(spec: spec, model: model, back: {}))
                : AnyView(FilesCredentialsPage(spec: spec, model: model, back: {}))
            openOffscreenSheet(content)
            try? await Task.sleep(for: .milliseconds(250))
            inspect("\(id.rawValue) credentials")
            offscreenSheet?.close()
            offscreenSheet = nil
        }
        let broken = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        broken.hasVerticalScroller = true
        if AIManagerNativeContract.scrollPolicyFailures(in: broken).isEmpty {
            failures.append("Scroll contract accepted a system scroller")
        }
        NotificationCenter.default.post(name: AIManagerNavigation.request,
            object: AIManagerPage.allCases[AcceptanceConfiguration.initialPageIndex])
        try? await Task.sleep(for: .milliseconds(250))
        return failures
    }

    /// Host the production sheet content without beginSheet, orderFront, or application activation.
    private func openOffscreenSheet(_ supplied: AnyView? = nil) {
        offscreenSheet?.close()
        let content: AnyView = supplied ?? (model.accountModalMode == .add
            ? AnyView(AddAccountFlow(model: model)) : AnyView(ImportFlow(model: model)))
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.appearance = windowController?.window?.effectiveAppearance
        sheet.contentView = NSHostingView(rootView: content
            .frame(width: 680, height: 600).tint(AIMTheme.passiveIcon)
            .background(AIMTheme.page)
            .renderScaled())
        sheet.orderOut(nil)
        offscreenSheet = sheet
        sheet.contentView?.layoutSubtreeIfNeeded()
    }

    /// After a page round trip, every card and the top bar end at W-20 and no scroll view reserves a
    /// strip for a system scroller: in the hierarchy and in the rendered window. Run with
    /// `--scrollers=always` (legacy scrollers) and `--scrollers=overlay`.
    private func scrollEdgeFailures(in view: NSView) async -> [String] {
        var failures: [String] = []
        if let want = PreviewArguments.value("scrollers"),
           NSScroller.preferredScrollerStyle != (want == "always" ? .legacy : .overlay) {
            failures.append("The run did not get the requested \(want) scroller style")
        }
        for page in [AIManagerPage.settings, AIManagerPage.allCases[AcceptanceConfiguration.initialPageIndex]] {
            NotificationCenter.default.post(name: AIManagerNavigation.request, object: page)
            try? await Task.sleep(for: .milliseconds(300))
            view.layoutSubtreeIfNeeded()
            var found: [NSScrollView] = []
            func visit(_ node: NSView) {
                if let scroll = node as? NSScrollView { found.append(scroll) }
                node.subviews.forEach(visit)
            }
            visit(view)
            for scroll in found where String(describing: type(of: scroll)).contains("HostingScrollView") {
                if abs(scroll.contentView.frame.width - scroll.frame.width) > 0.5 {
                    failures.append("\(page.rawValue): a scroll view reserves \(Int(scroll.frame.width - scroll.contentView.frame.width)) pt for a system scroller")
                }
            }
            for scroll in found where String(describing: type(of: scroll)).contains("HostingScrollView") {
                if let document = scroll.documentView, abs(document.frame.width - scroll.contentView.frame.width) > 0.5 {
                    failures.append("\(page.rawValue): the page content is \(document.frame.width) pt wide in a \(scroll.contentView.frame.width) pt clip")
                }
            }
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
            let width = view.bounds.width
            func rightEdge(row: CGFloat) -> CGFloat? {
                func color(_ x: CGFloat) -> NSColor? {
                    bitmap.colorAt(x: Int(x * scale), y: Int(row * scale))?.usingColorSpace(.sRGB)
                }
                // The page color left of the cards; the right gutter holds our thin bar.
                guard let background = color(AIMTheme.sidebarWidth + 8) else { return nil }
                var x = width - 18
                while x > AIMTheme.sidebarWidth + 20 {
                    if let c = color(x), abs(c.redComponent - background.redComponent) > 0.015
                        || abs(c.greenComponent - background.greenComponent) > 0.015
                        || abs(c.blueComponent - background.blueComponent) > 0.015 { return x + 1 / scale }
                    x -= 1 / scale
                }
                return nil
            }
            let wanted = width - AIMTheme.pageMargin
            for (name, row) in [("top bar", CGFloat(26)), ("first card", CGFloat(100))] {
                if let edge = rightEdge(row: row) {
                    if abs(edge - wanted) > 1.5 {
                        failures.append("\(page.rawValue): the \(name) ends at \(edge) pt, not \(wanted) pt")
                    }
                } else {
                    failures.append("\(page.rawValue): the \(name) right edge was not found")
                }
            }
        }
        return failures
    }

    private func importAccount() {
        guard !model.isBusy else { return }
        Task { await model.beginAdvancedImport() }
    }

    private func addAccount() {
        guard !model.isBusy else { return }
        Task { await model.beginAddAccount() }
    }

    private func configureAccountModal() async {
        if let provider = PreviewArguments.value("select") {
            // A provider the demo lacks, such as `--select=claude-code` or `--select=openrouter`, gets a synthetic account.
            let account = model.status?.accounts.first(where: { $0.identity.providerID.rawValue == provider })
                ?? model.addDemoProviderAccount(ProviderID(rawValue: provider))
            model.selectedAccountID = account.id
        }
        if AcceptanceConfiguration.opensImport {
            await model.beginAdvancedImport()
        } else if AcceptanceConfiguration.opensAdd {
            await model.beginAddAccount()
            if AcceptanceConfiguration.opensAddSignIn {
                await model.startAccountLogin()
            }
        }
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
        if AcceptanceConfiguration.persistedAppearanceMode != nil {
            if let priorAppearanceMode {
                UserDefaults.standard.set(priorAppearanceMode, forKey: "windowAppearance")
            } else {
                UserDefaults.standard.removeObject(forKey: "windowAppearance")
            }
        }
    }
}

@main
enum AIManagerMacGUIAcceptanceApp {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--ui-lint") && !AcceptanceConfiguration.contractOnly {
            FileHandle.standardError.write(Data("UI lint requires --contract-only; refusing to show a window.\n".utf8))
            exit(3)
        }
        if AcceptanceConfiguration.contractOnly, ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] == nil {
            FileHandle.standardError.write(Data("A contract run needs CFFIXED_USER_HOME on a temporary home; refusing to use real defaults.\n".utf8))
            exit(3)
        }
        if AcceptanceConfiguration.contractOnly, let domain = Bundle.main.bundleIdentifier {
            // A contract run starts from empty defaults, so no remembered page or setting carries over.
            UserDefaults.standard.removePersistentDomain(forName: domain)
            // `--scrollers=always` (legacy scrollers, as with a mouse) or `--scrollers=overlay`
            // sets the system scroll bar choice for this run, before AppKit reads it.
            if let style = PreviewArguments.value("scrollers") {
                UserDefaults.standard.set(style == "always" ? "Always" : "WhenScrolling", forKey: "AppleShowScrollBars")
            }
        }
        let bundleIdentifier = AIManagerSingleInstance.bundleIdentifier()
        let instanceLock: AIManagerInstanceLock?
        if AcceptanceConfiguration.contractOnly {
            // Ordered-out checks never activate another instance or need a desktop instance lock.
            instanceLock = nil
        } else {
            let lock = AIManagerSingleInstance.acquireOrActivate(bundleIdentifier: bundleIdentifier)
            guard let lock else { return }
            instanceLock = lock
        }
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
    if let mismatch = AcceptanceConfiguration.pageMismatch() { failures.append(mismatch) }
    failures.append(contentsOf: AIManagerNativeContract.presentationContractFailures())
    failures.append(contentsOf: AIManagerNativeContract.accountActionFailures())
    failures.append(contentsOf: AIManagerNativeContract.chatPresentationFailures())
    failures.append(contentsOf: AIManagerNativeContract.providerUIFailures())
    failures.append(contentsOf: AIManagerNativeContract.featureUIFailures())
    if let mode = AcceptanceConfiguration.persistedAppearanceMode {
        expect(
            UserDefaults.standard.string(forKey: "windowAppearance") == mode,
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
    failures.append(contentsOf: AIManagerNativeContract.windowChromeFailures(window))
    if AcceptanceConfiguration.contractOnly {
        expect(!NSApp.isActive && !window.isVisible, "Offscreen acceptance activated or showed the app")
    }
    expect(
        window.contentRect(forFrameRect: window.frame).size.width >= AIManagerWindow.minimumSize.width,
        "Acceptance window is smaller than its minimum size"
    )
    failures.append(contentsOf: AIManagerNativeContract.windowPlacementFailures())
    if let mode = AcceptanceConfiguration.persistedAppearanceMode {
        if mode == "system" {
            expect(window.appearance == nil, "System appearance was not inherited from macOS")
        } else {
            let expected: NSAppearance.Name = mode == "dark" ? .darkAqua : .aqua
            expect(window.appearance?.name == expected, "Persisted appearance was not applied to the window")
        }
    }
    failures.append(contentsOf: AIManagerBrand.acceptanceFailures())
    failures.append(contentsOf: AIManagerNativeContract.menuFailures(
        in: NSApp.mainMenu,
        applicationName: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "Switch Mac GUI Acceptance"
    ))
    failures.append(contentsOf: (NSApp.delegate as? AcceptanceAppDelegate)?.menuNavigationFailures ?? [])
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
        if stage == "after-load" || stage == "contract-only" {
            receipts.writeSnapshot(of: contentView)
            receipts.writeMenuBarSnapshot(appearance: window.effectiveAppearance)
        }
        expect(
            AIManagerNativeContract.scrollAppearancesMatch(in: contentView, appearance: window.effectiveAppearance),
            "Acceptance scroll content appearance differs from the window"
        )
        failures.append(contentsOf: AIManagerNativeContract.nativeStructureFailures(
            in: contentView, pageIndex: AcceptanceConfiguration.initialPageIndex))
        // The Add Account and Import sheets are their own windows.
        let sheetRoot = window.attachedSheet?.contentView
            ?? (NSApp.delegate as? AcceptanceAppDelegate)?.offscreenSheet?.contentView
        for root in [contentView] + (sheetRoot.map { [$0] } ?? []) {
            failures.append(contentsOf: AIManagerNativeContract.scrollPolicyFailures(in: root))
            failures.append(contentsOf: AIManagerNativeContract.focusRingFailures(
                in: root,
                requiresFullKeyboardAccess: CommandLine.arguments.contains("--require-full-keyboard-access")))
        }
        if AcceptanceConfiguration.initialPageIndex == AcceptanceConfiguration.conversationsIndex {
            expect(
                AIManagerNativeContract.historySearchFieldsMatch(in: contentView),
                "Chat History does not expose separate thread and message search fields"
            )
            expect(
                AIManagerNativeContract.virtualHistoryScrollCount(in: contentView) == 1,
                "Chat History is not a thread list beside one virtual message list"
            )
            if AcceptanceConfiguration.stressesHistory {
                expect(
                    receipts.model?.chatHistory.threads.count == 1_717,
                    "Chat History stress fixture did not contain 1,717 threads"
                )
                let realizedRows = AIManagerNativeContract.realizedVirtualRowCount(in: contentView)
                expect(
                    realizedRows > 0 && realizedRows < 100,
                    "Chat History realized \(realizedRows) rows for the 1,717-thread fixture"
                )
            }
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            expect(
                AIManagerNativeContract.hasVisualEffect(in: contentView),
                "Acceptance window has no visual-effect backdrop"
            )
        }
    } else {
        failures.append("Acceptance window content view did not resolve")
    }
    var receipt = WindowContractReceipt(
        passed: failures.isEmpty,
        failures: failures,
        window: WindowContractObservation(stage: stage, window: window)
    )
    if (["after-load", "contract-only"].contains(stage) || !failures.isEmpty), let root = window.contentView {
        receipt.hierarchy = AIManagerNativeContract.hierarchySnapshot(in: root)
    }
    receipts.writeWindowContract(receipt)
    receipts.report(failures: failures)
}

@MainActor
private final class AcceptanceReceipts {
    weak var model: AccountViewModel?
    private var menuBarHost: NSWindow?

    func prepareMenuBarSnapshot(appearance: NSAppearance) {
        let snapshot = MenuBarPopoverPreviewData.snapshot
        let store = MenuBarPopoverStore(snapshot: snapshot,
            actions: MenuBarPopoverActions(openMainWindow: {}, switchAccount: { _ in }))
        let size = AIManagerStatusItemController.contentSize(accounts: snapshot.accounts, visibleScreenHeight: 900)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = NSHostingView(rootView: MenuBarPopover(store: store)
            .background(AIMTheme.panel).renderScaled())
        window.orderOut(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        menuBarHost = window
    }
    private static let stableDirectory = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["AI_MANAGER_ACCEPTANCE_ARTIFACTS"]
            ?? "/private/tmp/ai-manager-build/mac-gui-acceptance/artifacts",
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
        let signature = WindowContractObservation.signature(for: window)
            + "|\(model?.showImport ?? false)"
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
        writeSnapshot(of: view, filename: "window.png")
        if let sheet = view.window?.attachedSheet?.contentView
            ?? (NSApp.delegate as? AcceptanceAppDelegate)?.offscreenSheet?.contentView {
            sheet.layoutSubtreeIfNeeded()
            writeSnapshot(of: sheet, filename: "sheet.png")
        }
        guard let directory else { return }
        let hierarchy = AIManagerNativeContract.hierarchySnapshot(in: view)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let hierarchyData = try? encoder.encode(hierarchy) {
            try? hierarchyData.write(
                to: directory.appending(path: "window-hierarchy.json"), options: .atomic)
        }
    }

    func writeMenuBarSnapshot(appearance: NSAppearance) {
        let snapshot = MenuBarPopoverPreviewData.snapshot
        let store = MenuBarPopoverStore(
            snapshot: snapshot,
            actions: MenuBarPopoverActions(
                openMainWindow: {}, switchAccount: { _ in }))
        let view = menuBarHost?.contentView ?? NSHostingView(rootView: MenuBarPopover(store: store).renderScaled())
        view.appearance = appearance
        view.frame = NSRect(
            origin: .zero,
            size: AIManagerStatusItemController.contentSize(
                accounts: snapshot.accounts,
                visibleScreenHeight: 900))
        view.layoutSubtreeIfNeeded()
        writeSnapshot(of: view, filename: "menu-bar.png")

        let accounts = [ProviderID.codex, .claudeCode, .codex, .geminiCLI]
            .enumerated().map { index, provider in
                MenuBarAccountSnapshot(
                    id: UUID(), identity: "glyph-\(index)@example.test", detail: "",
                    isVerified: true, isActive: index == 0,
                    usage: MenuBarUsageSnapshot(usedPercentage: [0, 39, 96, 100][index]),
                    providerID: provider)
            }
        if let image = AIManagerBrand.statusImage(groups: MenuBarSnapshot(accounts: accounts).statusAccountGroups) {
            let strip = NSHostingView(rootView:
                Image(nsImage: image).foregroundStyle(.primary)
                    .padding(10).background(AIMTheme.panel))
            strip.appearance = appearance
            strip.frame = NSRect(x: 0, y: 0, width: image.size.width + 20, height: 42)
            strip.layoutSubtreeIfNeeded()
            writeSnapshot(of: strip, filename: "tray-glyphs.png")
        }
        let catalog = NSHostingView(rootView:
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(170), alignment: .leading), count: 3), spacing: 12) {
                ForEach(AIManagerBrand.providerGlyphNames.keys.sorted(), id: \.self) { id in
                    HStack(spacing: 8) {
                        if let image = AIManagerBrand.providerGlyph(for: ProviderID(rawValue: id)) {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: 18, height: 18)
                        }
                        Text(id).aimText(.secondary)
                    }
                }
            }.padding(12).foregroundStyle(.primary).background(AIMTheme.panel))
        catalog.appearance = appearance
        catalog.frame = NSRect(x: 0, y: 0, width: 560, height: 250)
        catalog.layoutSubtreeIfNeeded()
        writeSnapshot(of: catalog, filename: "provider-glyphs.png")

        // Every provider tile at 24 and 44 pt beside its dense-row glyph.
        let providerIDs = [ProviderID.codex] + ProviderCatalog.all.map(\.id)
        let columns = 4
        let sheet = NSHostingView(rootView:
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(250), alignment: .leading), count: columns), spacing: 10) {
                ForEach(providerIDs, id: \.self) { id in
                    HStack(spacing: 8) {
                        ProviderMark(providerID: id, size: 24)
                        ProviderMark(providerID: id, size: 44)
                        ProviderGlyph(providerID: id, size: 16).foregroundStyle(.primary)
                        Text(id.rawValue).aimText(.secondary).lineLimit(1)
                    }
                }
            }.padding(14).background(AIMTheme.panel))
        sheet.appearance = appearance
        sheet.frame = NSRect(x: 0, y: 0, width: 1060, height: CGFloat((providerIDs.count + columns - 1) / columns) * 54 + 28)
        sheet.layoutSubtreeIfNeeded()
        writeSnapshot(of: sheet, filename: "brand-sheet.png")
    }

    private func writeSnapshot(of view: NSView, filename: String) {
        guard let directory, let data = RenderScale.png(of: view) else { return }
        try? data.write(to: directory.appending(path: filename), options: .atomic)
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
        for name in ["window-contract.json", "window.png", "menu-bar.png", "tray-glyphs.png", "provider-glyphs.png", "brand-sheet.png", "window-hierarchy.json", "window-did-miniaturize", "window-will-close"] {
            try? fileManager.removeItem(at: directory.appending(path: name))
        }
    }

    private static func prepareDirectory(_ url: URL) -> URL? {
        let fileManager = FileManager.default
        let components = url.pathComponents
        guard url.isFileURL,
              ["/private/tmp/", "/Volumes/External1TB/tmp/", "/Volumes/External1TB/data/_custom/switch-build/"].contains(where: { url.path.hasPrefix($0) }),
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
