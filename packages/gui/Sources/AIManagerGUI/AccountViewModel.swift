import AppKit
import Foundation
import AIManagerCore

@MainActor
final class AccountViewModel: ObservableObject {
    @Published var status: ManagerStatus?
    @Published var selectedAccountID: UUID?
    @Published var discoveries: [DiscoveredSource] = []
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var showImport = false
    @Published var importMode: ImportMode = .authOnly
    @Published var selectedSourceID: String?
    @Published var importPlan: ImportPlan?
    @Published var conflictChoices: [String: ConflictChoice] = [:]
    @Published var importResult: ImportResult?

    let paths: ManagerPaths
    private let manager: AccountManager?

    init(paths: ManagerPaths, manager injectedManager: AccountManager? = nil) {
        self.paths = paths
        do {
            manager = try injectedManager ?? AccountManager(paths: paths)
        } catch {
            manager = nil
            errorMessage = "AI Manager could not open its private data folder. \(error.localizedDescription)"
        }
    }

    var selectedAccount: AccountRecord? {
        status?.accounts.first { $0.id == selectedAccountID }
    }

    func load() async {
        guard let manager else { return }
        await perform {
            let newStatus = try await manager.status()
            status = newStatus
            if selectedAccountID == nil { selectedAccountID = newStatus.defaultAccountID ?? newStatus.accounts.first?.id }
        }
    }

    func beginImport() async {
        showImport = true
        importPlan = nil
        importResult = nil
        await discover()
    }

    func discover(explicit: URL? = nil) async {
        guard let manager else { return }
        await perform {
            discoveries = await manager.discover(explicit: explicit)
            let normalizedExplicit = explicit.map { $0.lastPathComponent == "auth.json" ? $0.deletingLastPathComponent() : $0 }
            if let normalizedExplicit, let source = discoveries.first(where: { $0.path.standardizedFileURL == normalizedExplicit.standardizedFileURL }) {
                selectedSourceID = source.id
            } else if selectedSourceID == nil {
                selectedSourceID = discoveries.first(where: { $0.support == .supportedChatGPT })?.id
            }
        }
    }

    func chooseSource() async {
        let panel = NSOpenPanel()
        panel.title = "Choose a Codex home or auth.json"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await discover(explicit: url)
    }

    func reviewImport() async {
        guard let manager else { return }
        guard let source = discoveries.first(where: { $0.id == selectedSourceID }) else {
            errorMessage = "Choose a supported source."
            return
        }
        await perform {
            importPlan = try await manager.planImport(source: source.path, mode: importMode)
            conflictChoices = [:]
            importResult = nil
        }
    }

    func commitImport() async {
        guard let manager else { return }
        guard let plan = importPlan else { return }
        await perform {
            importResult = try await manager.importAccount(plan: plan, decisions: conflictChoices)
            status = try await manager.status()
            selectedAccountID = importResult?.account.id
        }
    }

    func reviewExternalSetting(_ relativePath: String) async {
        guard let manager, let plan = importPlan else { return }
        await perform {
            importPlan = try await manager.reviewExternalSetting(plan: plan, relativePath: relativePath)
        }
    }

    func switchDefault() async {
        guard let manager else { return }
        guard let id = selectedAccountID else { return }
        await perform {
            let result = try await manager.switchDefault(to: id)
            status = try await manager.status()
            notice = "Future default-home Codex sessions will use this account. Backup: \(result.backup.path)"
        }
    }

    func verify() async {
        guard let manager else { return }
        guard let id = selectedAccountID else { return }
        await perform {
            let result = await manager.verifyLocal(accountID: id)
            notice = result.detail
            status = try await manager.status()
        }
    }

    func openAccount() async {
        guard let manager else { return }
        guard let id = selectedAccountID else { return }
        await perform {
            let spec = try await manager.launchSpec(accountID: id)
            let script = try makeLaunchArtifact(spec)
            guard NSWorkspace.shared.open(script) else {
                throw AIManagerError.operationFailed("Terminal could not open the account launch file. Open the profile path from a terminal instead.")
            }
            notice = "Opened a new terminal session for this account. Existing sessions keep their current account."
        }
    }

    func repairLinkedSetting(_ issue: LinkedSettingsDivergence) async {
        guard let manager else { return }
        await perform {
            let result = try await manager.repairLinkedSetting(
                accountID: issue.accountID,
                relativePath: issue.relativePath,
                reviewedFingerprint: issue.localFingerprint
            )
            status = try await manager.status()
            notice = "The shared settings link was restored. The displaced local entry is preserved in \(result.backup.path)."
        }
    }

    func copyProfilePath() {
        guard let home = selectedAccount?.home.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(home, forType: .string)
        notice = "Profile path copied."
    }

    func showSharedRoot() {
        NSWorkspace.shared.activateFileViewerSelecting([paths.sharedRoot])
    }

    func recover() async {
        guard let manager else { return }
        await perform {
            let results = try await manager.recover()
            notice = results.isEmpty ? "No recovery was needed." : results.map(\.message).joined(separator: " ")
            status = try await manager.status()
        }
    }

    func resetImport() {
        importPlan = nil
        importResult = nil
        conflictChoices = [:]
    }

    private func perform(_ operation: () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do { try await operation() }
        catch { errorMessage = error.localizedDescription }
    }

    private func makeLaunchArtifact(_ spec: LaunchSpec) throws -> URL {
        let directory = paths.applicationSupport.appending(path: "Launch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: "Open AI Manager Account.command")
        var exports = spec.environment["CODEX_HOME"].map { ["export CODEX_HOME=\(shellQuote($0))"] } ?? []
        if paths.isolationRoot != nil, let home = spec.environment["HOME"] {
            exports.append("export HOME=\(shellQuote(home))")
        }
        let arguments = ([spec.executable.path] + spec.arguments).map(shellQuote).joined(separator: " ")
        let workingDirectory = spec.workingDirectory.map { "cd \(shellQuote($0.path))\n" } ?? ""
        let contents = (["#!/bin/zsh", "set -e", "unset OPENAI_API_KEY CODEX_ACCESS_TOKEN"] + exports + [workingDirectory + "exec \(arguments)"]).joined(separator: "\n") + "\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
