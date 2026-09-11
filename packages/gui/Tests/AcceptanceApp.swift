import AppKit
import Combine
import Foundation
import SwiftUI
import AIManagerCore

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
            : NSSize(width: 920, height: 620)
    }

    static func isEnabled(argument: String, infoKey: String) -> Bool {
        CommandLine.arguments.contains(argument) || (Bundle.main.object(forInfoDictionaryKey: infoKey) as? Bool == true)
    }
}

@MainActor
private final class AcceptanceAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let fixture: AcceptanceFixture?
    let model: AccountViewModel?
    let errorMessage: String?
    private var windowController: AIManagerWindowController<AnyView>?
    private var modelObservers = Set<AnyCancellable>()

    override init() {
        do {
            let fixture = try AcceptanceFixture()
            let model = AccountViewModel(paths: fixture.paths, manager: fixture.manager)
            self.fixture = fixture
            self.model = model
            errorMessage = nil
        } catch {
            fixture = nil
            model = nil
            errorMessage = "The isolated preview data could not be created. Rebuild the preview and try again."
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content: AnyView
        if let model, let fixture {
            model.$selectedAccountID
                .dropFirst()
                .sink { _ in checkWindowContract(fixture: fixture, stage: "after-account-change") }
                .store(in: &modelObservers)
            model.$showImport
                .dropFirst()
                .sink { _ in checkWindowContract(fixture: fixture, stage: "after-import-state-change") }
                .store(in: &modelObservers)
            content = AnyView(
                AccountWindow(model: model)
                    .preferredColorScheme(AcceptanceConfiguration.appearance)
                    .task {
                        fixture.observeWindowEvents()
                        if AcceptanceConfiguration.isEnabled(argument: "--seeded", infoKey: "AIManagerGUISeeded") {
                            await fixture.seed(model: model)
                        }
                        await model.load()
                        try? await Task.sleep(for: .milliseconds(300))
                        checkWindowContract(fixture: fixture, stage: "after-seed")
                    }
            )
        } else {
            content = AnyView(
                VStack(alignment: .leading, spacing: 10) {
                    Text("Preview could not start").font(.title2.weight(.semibold))
                    Text(errorMessage ?? "The isolated preview data is unavailable.")
                        .foregroundStyle(.secondary)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .preferredColorScheme(AcceptanceConfiguration.appearance)
            )
        }

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
        guard let model, !model.isBusy else { return }
        Task { await model.beginImport() }
    }

    @objc private func closeWindow() { windowController?.window?.close() }
    @objc private func minimizeWindow() { windowController?.window?.miniaturize(nil) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(importAccount) ? model?.isBusy == false : true
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
private func checkWindowContract(fixture: AcceptanceFixture, stage: String) {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }
    guard let window = NSApp.windows.first(where: { $0 is AIManagerWindow }) else {
        fixture.writeWindowContract(WindowContractReceipt(
            passed: false,
            failures: ["Acceptance AIManagerWindow did not resolve"],
            window: nil
        ))
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
    let commands = NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []
    expect(commands.contains {
        $0.keyEquivalent == "q" && $0.action == #selector(NSApplication.terminate(_:))
    }, "Preview Quit command is missing")
    let receipt = WindowContractReceipt(
        passed: failures.isEmpty,
        failures: failures,
        window: WindowContractObservation(stage: stage, window: window)
    )
    fixture.writeWindowContract(receipt)
    let status = failures.isEmpty ? "WINDOW_CONTRACT_PASS\n" : "WINDOW_CONTRACT_FAIL: \(failures.joined(separator: "; "))\n"
    FileHandle.standardError.write(Data(status.utf8))
}

@MainActor
private final class AcceptanceFixture {
    let paths: ManagerPaths
    let manager: AccountManager

    private let firstSource: URL
    private let secondSource: URL
    private let windowEventsRoot: URL
    private var windowObservers: [NSObjectProtocol] = []

    init() throws {
        let fileManager = FileManager.default
        let base = URL(fileURLWithPath: "/private/tmp/ai-manager-gui-tests", isDirectory: true)
        try Self.validateBase(base, fileManager: fileManager)
        let root = base.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try Self.makePrivateDirectory(root, fileManager: fileManager)
        windowEventsRoot = root

        let fakeCodex = root.appending(path: "fake-codex")
        let launchLog = root.appending(path: "launch.log")
        try "#!/bin/sh\nprintf '%s\\n' \"$CODEX_HOME\" >> '\(launchLog.path)'\n"
            .write(to: fakeCodex, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodex.path)

        paths = ManagerPaths(
            applicationSupport: root.appending(path: "application-support", directoryHint: .isDirectory),
            defaultHome: root.appending(path: ".codex", directoryHint: .isDirectory),
            sharedRoot: root.appending(path: "shared-root", directoryHint: .isDirectory),
            orcaAccountsRoot: root.appending(path: "orca-accounts", directoryHint: .isDirectory),
            codexExecutable: fakeCodex,
            isolationRoot: root
        )
        firstSource = paths.defaultHome
        secondSource = root.appending(path: ".codex2", directoryHint: .isDirectory)

        try Self.makePrivateDirectory(paths.sharedRoot, fileManager: fileManager)
        try Data("model = \"shared\"\n".utf8).write(to: paths.sharedRoot.appending(path: "config.toml"), options: .atomic)
        try Self.writeTranscript(
            home: paths.sharedRoot,
            id: "22222222-2222-4222-8222-222222222222",
            marker: "shared-version",
            fileManager: fileManager
        )

        try Self.writeSource(
            firstSource,
            account: "synthetic-one",
            workspace: "workspace-blue",
            email: "blue@example.test",
            transcript: "11111111-1111-4111-8111-111111111111",
            marker: "blue-source",
            config: "model = \"blue\"\n",
            fileManager: fileManager
        )
        try Self.writeSource(
            secondSource,
            account: "synthetic-two",
            workspace: "workspace-green",
            email: "green@example.test",
            transcript: "22222222-2222-4222-8222-222222222222",
            marker: "green-divergent-version",
            config: "model = \"green\"\n",
            fileManager: fileManager
        )
        let externalRules = root.appending(path: "external-rules", directoryHint: .isDirectory)
        try Self.makePrivateDirectory(externalRules, fileManager: fileManager)
        try Data("Synthetic acceptance rule.\n".utf8).write(to: externalRules.appending(path: "README.md"), options: .atomic)
        try fileManager.createSymbolicLink(at: secondSource.appending(path: "rules"), withDestinationURL: externalRules)
        manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
    }

    func observeWindowEvents() {
        guard windowObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for (name, marker) in [
            (NSWindow.didMiniaturizeNotification, "window-did-miniaturize"),
            (NSWindow.willCloseNotification, "window-will-close"),
        ] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [windowEventsRoot] notification in
                guard let window = notification.object as? NSWindow, !(window is NSPanel) else { return }
                try? Data("PASS\n".utf8).write(to: windowEventsRoot.appending(path: marker), options: .atomic)
            }
            windowObservers.append(observer)
        }
    }

    func writeWindowContract(_ receipt: WindowContractReceipt) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(receipt) else { return }
        try? data.write(to: windowEventsRoot.appending(path: "window-contract.json"), options: .atomic)
    }

    func seed(model: AccountViewModel) async {
        do {
            if try await manager.status().accounts.isEmpty {
                var importedIDs: [UUID] = []
                for source in [firstSource, secondSource] {
                    let plan = try await manager.planImport(source: source, mode: .full)
                    let decisions = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.relativePath, ConflictChoice.keepShared) })
                    importedIDs.append(try await manager.importAccount(plan: plan, decisions: decisions).account.id)
                }
                if let first = importedIDs.first { _ = try await manager.switchDefault(to: first) }
            }
            await model.load()
        } catch {
            model.errorMessage = "The isolated GUI fixture failed. \(error.localizedDescription)"
        }
    }

    private static func writeSource(
        _ home: URL,
        account: String,
        workspace: String,
        email: String,
        transcript: String,
        marker: String,
        config: String,
        fileManager: FileManager
    ) throws {
        try makePrivateDirectory(home, fileManager: fileManager)
        let claims = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_account_id": account,
            "workspace_id": workspace
        ])
        let payload = claims.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        let auth: [String: Any] = [
            "last_refresh": "2026-01-01T00:00:00Z",
            "tokens": [
                "access_token": "header.\(payload).signature",
                "account_id": account,
                "refresh_token": "synthetic"
            ]
        ]
        let authData = try JSONSerialization.data(withJSONObject: auth, options: [.sortedKeys])
        let authURL = home.appending(path: "auth.json")
        try authData.write(to: authURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)

        try Data(config.utf8).write(to: home.appending(path: "config.toml"), options: .atomic)
        try writeTranscript(home: home, id: transcript, marker: marker, fileManager: fileManager)
    }

    private static func writeTranscript(home: URL, id: String, marker: String, fileManager: FileManager) throws {
        let sessionDirectory = home.appending(path: "sessions/2026/01/01", directoryHint: .isDirectory)
        try makePrivateDirectory(sessionDirectory, fileManager: fileManager)
        let session = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\"}}\n{\"type\":\"event\",\"payload\":{\"marker\":\"\(marker)\"}}\n"
        try Data(session.utf8).write(to: sessionDirectory.appending(path: "\(id).jsonl"), options: .atomic)
    }

    private static func validateBase(_ base: URL, fileManager: FileManager) throws {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: base.path)) == nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: base.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CocoaError(.fileWriteInvalidFileName) }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        } else {
            try makePrivateDirectory(base, fileManager: fileManager)
        }
    }

    private static func makePrivateDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
