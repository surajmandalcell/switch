import Foundation
import XCTest
@testable import AIManagerCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class NativeDroidSessionBindingTests: XCTestCase {
    func testSwitchKeepsOriginalConversationResumableUsingTheNativeCLI() async throws {
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
        let report = try XCTUnwrap(switched.droidSessionBinding)
        XCTAssertEqual(report.warnings, [])
        XCTAssertEqual(report.updatedCount, 1)
        let expected = Data(String(decoding: originalData, as: UTF8.self)
            .replacingOccurrences(of: "\"org_switch_native_source\"", with: "\"org_switch_native_target\"").utf8)
        XCTAssertEqual(try Data(contentsOf: original), expected)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: factory.appending(path: "sessions"),
            includingPropertiesForKeys: nil))
        let copies = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" && $0 != original }
        XCTAssertEqual(copies.count, 0)
        let loaded = try load(sessionID: originalID, executable: URL(fileURLWithPath: binary), home: factory, root: root)
        XCTAssertNil(loaded["error"], "The native CLI rejected the original session ID after switching.")
        let result = try XCTUnwrap(loaded["result"] as? [String: Any])
        let text = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        XCTAssertTrue(text.contains("Retain the exact native transfer canary."), "Native resume lost the original messages.")
    }

    private func load(sessionID: UUID, executable: URL, home: URL, root: URL) throws -> [String: Any] {
        let requestID = UUID().uuidString
        let output = root.appending(path: "resume-output.jsonl")
        let settings = root.appending(path: "resume-settings.json")
        try CoreSupport.atomicWrite(Data(), to: output, fileManager: .default)
        try CoreSupport.atomicWrite(Data("{\"cloudSessionSync\":false,\"hooksDisabled\":true}".utf8), to: settings, fileManager: .default)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let input = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["exec", "--input-format", "stream-jsonrpc", "-o", "stream-jsonrpc", "--settings", settings.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.deletingLastPathComponent().path
        environment["FACTORY_HOME_OVERRIDE"] = home.deletingLastPathComponent().path
        environment["FACTORY_DISABLE_KEYRING"] = "1"
        environment.removeValue(forKey: "FACTORY_API_KEY")
        for key in ["FACTORY_API_BASE_URL", "FACTORY_WORKOS_BASE_URL", "FACTORY_TELEMETRY_INGEST_BASE_URL"] {
            environment[key] = "http://127.0.0.1:9"
        }
        environment["FACTORY_DISABLE_DYNAMIC_CONFIG"] = "true"
        environment["DO_NOT_TRACK"] = "1"
        process.environment = environment
        process.currentDirectoryURL = home
        process.standardInput = input
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        let request: [String: Any] = ["type": "request", "jsonrpc": "2.0", "factoryApiVersion": "1.0.0",
            "factoryProtocolVersion": "1.0.0", "id": requestID, "method": "droid.load_session",
            "params": ["sessionId": sessionID.uuidString.lowercased(), "loadAllMessages": true,
                "messageLimit": 100_000, "disableBuiltinSkills": true, "autoRejectPermissionRequests": true]]
        try input.fileHandleForWriting.write(contentsOf: line(request))
        let deadline = Date().addingTimeInterval(20)
        repeat {
            let data = try Data(contentsOf: output)
            guard data.count <= 8 * 1_024 * 1_024 else { throw DroidSessionRPCError.outputTooLarge }
            for record in data.split(separator: 10) {
                if let response = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
                   response["id"] as? String == requestID { return response }
            }
            if !process.isRunning { throw DroidSessionRPCError.invalidResponse }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        throw DroidSessionRPCError.timedOut
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
