import Foundation
import XCTest
@testable import AIManagerCore

final class AccountManagerFeatureTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appending(path: "AccountManagerFeatureTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root.appending(path: "user/.codex"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fileManager.removeItem(at: root) }
    }

    func testClaudeShellIntegrationRoundTripsThroughTheManager() async throws {
        let paths = ManagerPaths(
            applicationSupport: root.appending(path: "support"),
            credentialStore: root.appending(path: "user/.switch/codex"),
            defaultHome: root.appending(path: "user/.codex"),
            sharedRoot: root.appending(path: "user/.codex"),
            orcaAccountsRoot: root.appending(path: "orca"),
            codexExecutable: URL(fileURLWithPath: "/usr/bin/true"))
        let manager = try AccountManager(paths: paths)
        let zshrc = root.appending(path: "user/.zshrc")
        try Data("export A=1\n".utf8).write(to: zshrc)

        let initial = await manager.claudeShellIntegrationInstalled()
        XCTAssertFalse(initial)

        try await manager.setClaudeShellIntegration(true)
        let installed = await manager.claudeShellIntegrationInstalled()
        XCTAssertTrue(installed)
        XCTAssertTrue(try String(contentsOf: zshrc, encoding: .utf8).contains("# >>> switch claude >>>"))
        XCTAssertTrue(fileManager.fileExists(atPath: zshrc.path + ".switch-backup"))

        try await manager.setClaudeShellIntegration(false)
        let removed = await manager.claudeShellIntegrationInstalled()
        XCTAssertFalse(removed)
        XCTAssertEqual(try String(contentsOf: zshrc, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), "export A=1")
    }
}
