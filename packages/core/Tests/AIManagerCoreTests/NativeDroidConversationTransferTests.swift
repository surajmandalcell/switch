import Foundation
import XCTest
@testable import AIManagerCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

final class NativeDroidConversationTransferTests: XCTestCase {
    func testSwitchCreatesAnAccountOwnedConversationUsingTheNativeCLI() async throws {
        guard let binary = ProcessInfo.processInfo.environment["SWITCH_TEST_DROID_EXECUTABLE"] else {
            throw XCTSkip("Set SWITCH_TEST_DROID_EXECUTABLE for the isolated native CLI check.")
        }
        let scratch = ProcessInfo.processInfo.environment["AGENT_DATA_DIR"]
            ?? ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path
        let root = URL(fileURLWithPath: scratch).appending(path: "switch/SwitchNativeDroid-\(UUID())")
        try CoreSupport.privateDirectory(root, fileManager: .default)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appending(path: "user")
        let factory = user.appending(path: ".factory")
        let project = root.appending(path: "project")
        try CoreSupport.privateDirectory(project, fileManager: .default)
        let paths = ManagerPaths(applicationSupport: root.appending(path: "support"),
            credentialStore: user.appending(path: ".switch/codex"), defaultHome: user.appending(path: ".codex"),
            sharedRoot: user.appending(path: ".codex"), orcaAccountsRoot: root.appending(path: "orca"),
            droidHome: factory, droidExecutable: URL(fileURLWithPath: binary), isolationRoot: root)
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive },
            providerSpecs: [], droidProcessLister: { [] })
        try writeLogin(home: factory, organization: "org_switch_native_source")
        let source = try await manager.importDroidAccount(name: "Synthetic source")
        try writeLogin(home: factory, organization: "org_switch_native_target")
        let target = try await manager.importDroidAccount(name: "Synthetic target")
        _ = try await manager.switchDefault(to: source.id)
        let originalID = UUID()
        let original = factory.appending(path: "sessions/-original/\(originalID.uuidString.lowercased()).jsonl")
        let header: [String: Any] = ["type": "session_start", "id": originalID.uuidString.lowercased(),
            "cwd": project.path, "title": "Native transfer canary", "organizationId": "org_switch_native_source",
            "owner": "synthetic-user", "hostId": UUID().uuidString, "version": 2]
        let body = try line(["type": "message", "id": UUID().uuidString,
            "timestamp": "2026-10-01T00:00:00.000Z", "message": ["role": "user",
                "content": [["type": "text", "text": "Retain the exact native transfer canary."]]]])
        let originalData = try line(header) + body
        try CoreSupport.atomicWrite(originalData, to: original, fileManager: .default)
        let switched = try await manager.switchDefault(to: target.id)
        let report = try XCTUnwrap(switched.droidConversationTransfer)
        XCTAssertEqual(report.warnings, [])
        XCTAssertEqual(report.transferredCount, 1)
        XCTAssertEqual(try Data(contentsOf: original), originalData)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: factory.appending(path: "sessions"),
            includingPropertiesForKeys: nil))
        let copies = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" && $0 != original }
        XCTAssertEqual(copies.count, 1)
        let imported = try Data(contentsOf: XCTUnwrap(copies.first))
        let split = try XCTUnwrap(imported.firstIndex(of: 10))
        let native = try XCTUnwrap(JSONSerialization.jsonObject(with: imported.prefix(upTo: split)) as? [String: Any])
        XCTAssertEqual(native["organizationId"] as? String, "org_switch_native_target")
        XCTAssertNotEqual(native["id"] as? String, originalID.uuidString.lowercased())
        XCTAssertEqual(imported.suffix(from: imported.index(after: split)), body)
    }

    private func writeLogin(home: URL, organization: String) throws {
        let claims: [String: Any] = ["sub": "user_\(organization)", "external_org_id": organization,
            "email": "lab@example.invalid", "exp": 4_102_444_800, "iat": 1_700_000_000]
        let unsigned = base64URL(Data("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".utf8)) + "."
            + base64URL(try JSONSerialization.data(withJSONObject: claims))
        let signingKey = SymmetricKey(data: Data("switch-native-test-only".utf8))
        let token = unsigned + "." + base64URL(Data(HMAC<SHA256>.authenticationCode(for: Data(unsigned.utf8), using: signingKey)))
        let clear = try JSONSerialization.data(withJSONObject: ["access_token": token,
            "refresh_token": "synthetic-refresh", "active_organization_id": organization])
        let key = Data(repeating: 7, count: 32)
        let sealed = try AES.GCM.seal(clear, using: SymmetricKey(data: key),
            nonce: AES.GCM.Nonce(data: Data(repeating: 9, count: 16)))
        let encrypted = [Data(sealed.nonce), sealed.tag, sealed.ciphertext].map { $0.base64EncodedString() }.joined(separator: ":")
        try CoreSupport.atomicWrite(Data(key.base64EncodedString().utf8), to: home.appending(path: "auth.v2.key"), fileManager: .default)
        try CoreSupport.atomicWrite(Data(encrypted.utf8), to: home.appending(path: "auth.v2.file"), fileManager: .default)
    }

    private func line(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data([10])
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
