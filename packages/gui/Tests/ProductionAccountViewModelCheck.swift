import Foundation
import AIManagerCore

@main
struct ProductionAccountViewModelCheck {
    @MainActor
    static func main() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(
            path: "iia-directeur-gui-check-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let paths = ManagerPaths(
            applicationSupport: root.appending(path: "support", directoryHint: .isDirectory),
            defaultHome: root.appending(path: "user/.codex", directoryHint: .isDirectory),
            sharedRoot: root.appending(path: "user/.codex", directoryHint: .isDirectory),
            orcaAccountsRoot: root.appending(path: "orca", directoryHint: .isDirectory),
            codexExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            isolationRoot: root
        )
        let source = root.appending(path: "user/.codex2", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: paths.defaultHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        let sessions = paths.sharedRoot.appending(path: "sessions", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: sessions.appending(path: "shared.jsonl"))
        try Data("shared-setting".utf8).write(to: paths.sharedRoot.appending(path: "config.toml"))
        let sourceAuth = try authData()
        try sourceAuth.write(to: source.appending(path: "auth.json"))

        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let model = AccountViewModel(paths: paths, manager: manager)
        precondition(!model.isDemo)
        await model.load()
        precondition(model.status?.accounts.isEmpty == true)

        await model.beginImport()
        let discoveredSource = model.discoveries.first { $0.support == .supportedChatGPT }
        precondition(discoveredSource?.path.standardizedFileURL == source.standardizedFileURL)
        model.selectedSourceID = discoveredSource?.id
        await model.reviewImport()
        precondition(model.importPlan?.mode == .authOnly)
        await model.commitImport()
        precondition(model.errorMessage == nil)
        precondition(model.status?.accounts.count == 1)
        precondition(model.selectedAccount?.identity.accountID == "account-production")
        precondition(model.selectedAccount.map { model.history(for: $0).activeTranscripts } == 1)
        let importedID = model.selectedAccountID
        model.reset(to: .allStates)
        model.showDemoError()
        precondition(model.selectedAccountID == importedID)
        precondition(model.status?.accounts.count == 1)
        precondition(model.errorMessage == nil)

        await model.switchDefault()
        precondition(model.errorMessage == nil)
        let defaultAuth = try Data(contentsOf: paths.defaultHome.appending(path: "auth.json"))
        let sharedSetting = try Data(contentsOf: paths.defaultHome.appending(path: "config.toml"))
        let unchangedSourceAuth = try Data(contentsOf: source.appending(path: "auth.json"))
        precondition(defaultAuth == sourceAuth)
        precondition(sharedSetting == Data("shared-setting".utf8))
        precondition(unchangedSourceAuth == sourceAuth)

        await model.verify()
        precondition(model.selectedAccount?.verification.state == .verifiedLocally)
        await model.refresh()
        precondition(model.refreshedAt != nil)
        precondition(model.status?.defaultAccountID == model.selectedAccountID)
        await model.recover()
        precondition(model.errorMessage == nil)
        print("PRODUCTION_ACCOUNT_VIEW_MODEL_PASS")
    }

    private static func authData() throws -> Data {
        let claims = try JSONSerialization.data(withJSONObject: [
            "email": "production@example.test",
            "chatgpt_user_id": "user-production",
            "chatgpt_account_id": "account-production",
            "workspace_id": "workspace-production",
        ])
        let payload = claims.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return try JSONSerialization.data(withJSONObject: [
            "last_refresh": "2026-01-01T00:00:00Z",
            "tokens": [
                "access_token": "header.\(payload).signature",
                "account_id": "account-production",
                "refresh_token": "synthetic",
            ],
        ])
    }
}
