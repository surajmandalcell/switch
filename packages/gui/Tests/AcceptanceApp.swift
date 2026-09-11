import AppKit
import Combine
import Foundation
import SwiftUI

private struct WindowContractReceipt: Codable {
    let passed: Bool
    let failures: [String]
    let window: WindowContractObservation?
}

private struct WindowContractObservation: Codable {
    let stage: String
    let windowClass: String
    let windowNumber: Int
    let minWidth: Double
    let minHeight: Double
    let maxWidth: Double
    let maxHeight: Double
    let contentMinWidth: Double
    let contentMinHeight: Double
    let contentMaxWidth: Double
    let contentMaxHeight: Double

    init(stage: String, window: NSWindow) {
        self.stage = stage
        windowClass = NSStringFromClass(type(of: window))
        windowNumber = window.windowNumber
        minWidth = window.minSize.width
        minHeight = window.minSize.height
        maxWidth = window.maxSize.width
        maxHeight = window.maxSize.height
        contentMinWidth = window.contentMinSize.width
        contentMinHeight = window.contentMinSize.height
        contentMaxWidth = window.contentMaxSize.width
        contentMaxHeight = window.contentMaxSize.height
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

    static var initialSize: NSSize {
        isEnabled(argument: "--narrow", infoKey: "AIManagerGUINarrow")
            ? NSSize(width: 720, height: 500)
            : NSSize(width: 1120, height: 740)
    }

    static func isEnabled(argument: String, infoKey: String) -> Bool {
        CommandLine.arguments.contains(argument) || (Bundle.main.object(forInfoDictionaryKey: infoKey) as? Bool == true)
    }
}

@MainActor
private final class AcceptanceAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let receipts = AcceptanceReceipts()
    private let model = AccountViewModel()
    private var windowController: AIManagerWindowController<AnyView>?
    private var modelObservers = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DemoFonts.register()
        model.$selectedAccountID
            .dropFirst()
            .sink { [receipts] _ in checkWindowContract(receipts: receipts, stage: "after-account-change") }
            .store(in: &modelObservers)
        model.$showImport
            .dropFirst()
            .sink { [receipts] _ in checkWindowContract(receipts: receipts, stage: "after-import-state-change") }
            .store(in: &modelObservers)
        let content = AnyView(
            AccountWindow(model: model)
                .preferredColorScheme(AcceptanceConfiguration.appearance)
                .task { [receipts, model] in
                    receipts.observeWindowEvents()
                    await model.load()
                    try? await Task.sleep(for: .milliseconds(300))
                    checkWindowContract(receipts: receipts, stage: "after-load")
                }
        )

        let title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "AI Manager GUI Acceptance"
        let controller = AIManagerWindowController(
            title: title,
            initialSize: AcceptanceConfiguration.initialSize,
            rootView: content
        )
        windowController = controller
        installMainMenu(title: title)
        controller.present()
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
    @objc private func minimizeWindow() { windowController?.window?.miniaturize(nil) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(importAccount) ? !model.isBusy : true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController?.present() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
enum AIManagerGUIAcceptanceApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AcceptanceAppDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) {
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
    expect(window.styleMask.contains(.resizable), "Acceptance window is not resizable")
    expect(window.styleMask.contains(.closable), "Acceptance window is not closable")
    expect(window.styleMask.contains(.miniaturizable), "Acceptance window is not miniaturizable")
    expect(window.collectionBehavior.contains(.fullScreenNone), "Acceptance window allows fullscreen")
    expect(
        window.minSize == NSSize(width: 720, height: 500),
        "Acceptance window minimum changed to \(NSStringFromSize(window.minSize))"
    )
    expect(
        window.maxSize == NSSize(width: 1840, height: 1240),
        "Acceptance window size cap changed to \(NSStringFromSize(window.maxSize))"
    )
    expect(window.standardWindowButton(.closeButton) == nil, "Native close button exists")
    expect(window.standardWindowButton(.miniaturizeButton) == nil, "Native minimize button exists")
    expect(window.standardWindowButton(.zoomButton) == nil, "Native zoom button exists")
    expect(NSFont(name: "Geist-Regular", size: 13) != nil, "Geist font is unavailable")
    expect(NSFont(name: "GeistMono-Regular", size: 13) != nil, "Geist Mono font is unavailable")
    let commands = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []
    expect(commands.contains {
        $0.keyEquivalent == "q" && $0.action == #selector(NSApplication.terminate(_:))
    }, "Preview Quit command is missing")
    let receipt = WindowContractReceipt(
        passed: failures.isEmpty,
        failures: failures,
        window: WindowContractObservation(stage: stage, window: window)
    )
    receipts.writeWindowContract(receipt)
    receipts.report(failures: failures)
}

@MainActor
private final class AcceptanceReceipts {
    private static let stableDirectory = URL(
        fileURLWithPath: "/private/tmp/ai-manager-build/gui-acceptance/artifacts",
        isDirectory: true
    )
    private let directory: URL?
    private var windowObservers: [NSObjectProtocol] = []

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
    }

    func writeWindowContract(_ receipt: WindowContractReceipt) {
        guard let directory else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(receipt) else { return }
        try? data.write(to: directory.appending(path: "window-contract.json"), options: .atomic)
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
        for name in ["window-contract.json", "window-did-miniaturize", "window-will-close"] {
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
