import CryptoKit
import Foundation
import XCTest
@testable import AIManagerCore

/// Synthetic temporary home and fake keys only. Each test encrypts its own fixture with the Z Code scheme.
final class ZCodeImportTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!
    private let fm = FileManager.default
    private let zai = ProviderID(rawValue: "zai")

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appending(path: "ZCodeImportTests-\(UUID().uuidString)")
        try CoreSupport.privateDirectory(root, fileManager: fm)
        paths = .init(applicationSupport: root.appending(path: "support"),
            credentialStore: root.appending(path: "user/.switch/codex"),
            defaultHome: root.appending(path: "user/.codex"), sharedRoot: root.appending(path: "user/.codex"),
            orcaAccountsRoot: root.appending(path: "orca"), isolationRoot: root)
    }

    override func tearDownWithError() throws {
        if let root { try fm.removeItem(at: root) }
    }

    private func manager() throws -> AccountManager {
        try AccountManager(paths: paths, writerCheck: { _ in .inactive },
            providerSpecs: [ProviderCatalog.zai], droidProcessLister: { [] })
    }

    private func b64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Writes `~/.zcode/v2/credentials.json` with one encrypted api-key entry for each (plan, key).
    private func writeFile(_ entries: [(plan: String, key: String)], corruptTag: Bool = false) throws {
        let secret = "zcode-credential-fallback:darwin:\(paths.userHome.path):\(NSUserName())"
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        var values: [String: String] = ["oauth:zai:access_token": "enc:v1:ignored", "zcodejwttoken": "ignored"]
        for entry in entries {
            let box = try AES.GCM.seal(Data(entry.key.utf8), using: key)
            var tag = Data(box.tag)
            if corruptTag { tag[0] ^= 0xff }
            values["account-provider:coding-plan:account:zai-\(entry.plan)-coding-plan:account:\(UUID().uuidString):api-key"] =
                "enc:v1:" + [b64(Data(box.nonce)), b64(tag), b64(box.ciphertext)].joined(separator: ".")
        }
        let file = paths.userHome.appending(path: ".zcode/v2/credentials.json")
        try CoreSupport.privateDirectory(file.deletingLastPathComponent(), fileManager: fm)
        try JSONSerialization.data(withJSONObject: values).write(to: file)
    }

    func testImportsAPlanKeyOnceAsANamedAutoImportedDefault() async throws {
        try writeFile([("individual", "fake-key-one")])
        let manager = try manager()
        let first = await manager.importLiveLogins()
        let record = try XCTUnwrap(first.first)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(record.identity.providerID, zai)
        XCTAssertEqual(record.identity.accountID, "Z Code individual plan")
        XCTAssertTrue(record.autoImported)
        let status = try await manager.status()
        XCTAssertEqual(status.defaultAccountIDs["zai"], record.id)
        let saved = try Data(contentsOf: record.credentialFile)
        XCTAssertTrue(String(decoding: saved, as: UTF8.self).contains("fake-key-one"))
        let again = await manager.importLiveLogins()
        XCTAssertTrue(again.isEmpty)
    }

    func testSameKeyInBothPlansImportsOnceAndDistinctTeamKeyKeepsTheDefault() async throws {
        try writeFile([("individual", "fake-key-one"), ("team", "fake-key-one")])
        let manager = try manager()
        let shared = await manager.importLiveLogins()
        XCTAssertEqual(shared.map(\.identity.accountID), ["Z Code individual plan"])
        try writeFile([("individual", "fake-key-one"), ("team", "fake-key-two")])
        let team = await manager.importLiveLogins()
        XCTAssertEqual(team.map(\.identity.accountID), ["Z Code team plan"])
        let status = try await manager.status()
        XCTAssertEqual(status.accounts.count, 2)
        XCTAssertEqual(status.defaultAccountIDs["zai"], shared.first?.id)
    }

    func testDeletedPlanKeyIsNotImportedAgain() async throws {
        try writeFile([("individual", "fake-key-one")])
        let manager = try manager()
        let first = await manager.importLiveLogins()
        _ = try await manager.deleteAccount(accountID: try XCTUnwrap(first.first).id)
        let accounts = try await manager.status().accounts
        XCTAssertTrue(accounts.isEmpty)
        let again = await manager.importLiveLogins()
        XCTAssertTrue(again.isEmpty)
        let fresh = try self.manager()
        let freshAgain = await fresh.importLiveLogins()
        XCTAssertTrue(freshAgain.isEmpty)
    }

    func testBadTagAndMissingFileAreSkippedWithoutError() async throws {
        let manager = try manager()
        let missing = await manager.importLiveLogins()
        XCTAssertTrue(missing.isEmpty)
        try writeFile([("individual", "fake-key-one")], corruptTag: true)
        let bad = await manager.importLiveLogins()
        XCTAssertTrue(bad.isEmpty)
        let accounts = try await manager.status().accounts
        XCTAssertTrue(accounts.isEmpty)
    }
}
