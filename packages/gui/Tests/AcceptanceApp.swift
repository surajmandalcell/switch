import Foundation
import SwiftUI
import AIManagerCore

@main
struct AIManagerGUIAcceptanceApp: App {
    @StateObject private var model: AccountViewModel
    private let fixture: AcceptanceFixture

    init() {
        do {
            let fixture = try AcceptanceFixture()
            self.fixture = fixture
            _model = StateObject(wrappedValue: AccountViewModel(paths: fixture.paths, manager: fixture.manager))
        } catch {
            fatalError("Could not create the isolated GUI fixture: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup("AI Manager GUI Acceptance", id: Self.isEnabled(argument: "--narrow", infoKey: "AIManagerGUINarrow") ? "narrow" : "standard") {
            AccountWindow(model: model)
                .frame(minWidth: 720, minHeight: 500)
                .preferredColorScheme(Self.appearance)
                .task {
                    if Self.isEnabled(argument: "--seeded", infoKey: "AIManagerGUISeeded") {
                        await fixture.seed(model: model)
                    }
                    await model.load()
                }
        }
        .defaultSize(width: Self.initialSize.width, height: Self.initialSize.height)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Account...") { Task { await model.beginImport() } }
                    .keyboardShortcut("i", modifiers: [.command])
                    .disabled(model.isBusy)
            }
        }
    }

    private static var appearance: ColorScheme? {
        if CommandLine.arguments.contains("--dark") { return .dark }
        if CommandLine.arguments.contains("--light") { return .light }
        switch Bundle.main.object(forInfoDictionaryKey: "AIManagerGUIAppearance") as? String {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    private static var initialSize: CGSize {
        isEnabled(argument: "--narrow", infoKey: "AIManagerGUINarrow")
            ? CGSize(width: 720, height: 500)
            : CGSize(width: 920, height: 620)
    }

    private static func isEnabled(argument: String, infoKey: String) -> Bool {
        CommandLine.arguments.contains(argument) || (Bundle.main.object(forInfoDictionaryKey: infoKey) as? Bool == true)
    }
}

@MainActor
private final class AcceptanceFixture {
    let paths: ManagerPaths
    let manager: AccountManager

    private let firstSource: URL
    private let secondSource: URL

    init() throws {
        let fileManager = FileManager.default
        let base = URL(fileURLWithPath: "/private/tmp/ai-manager-gui-tests", isDirectory: true)
        try Self.validateBase(base, fileManager: fileManager)
        let root = base.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try Self.makePrivateDirectory(root, fileManager: fileManager)

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
