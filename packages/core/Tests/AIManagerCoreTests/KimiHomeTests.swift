import Foundation
import XCTest
@testable import AIManagerCore

final class KimiHomeTests: XCTestCase {
    func testCustomRootImportsAndSwitchesWithoutChangingDefaultHomeOrHistory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "KimiHomeTests-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let user = root.appending(path: "user")
        let custom = root.appending(path: "custom-kimi")
        let paths = ManagerPaths(applicationSupport: root.appending(path: "support"),
            credentialStore: user.appending(path: ".switch/codex"),
            defaultHome: user.appending(path: ".codex"),
            sharedRoot: user.appending(path: ".codex"),
            orcaAccountsRoot: root.appending(path: "orca"), isolationRoot: root)
        let decoy = user.appending(path: ".kimi-code/credentials/kimi-code.json")
        let live = custom.appending(path: "credentials/kimi-code.json")
        try write(login("default-A"), to: decoy)
        try write(login("custom-B"), to: live)
        let session = custom.appending(path: "sessions/project/original-session")
        let state = session.appending(path: "state.json")
        let stateBytes = Data(#"{"createdAt":"2026-05-20T05:59:51.085Z","updatedAt":"2026-05-21T03:12:08.000Z","title":"Synthetic retained task","isCustomTitle":false,"lastPrompt":"Keep this prompt","agents":{"main":{"type":"main","parentAgentId":null}},"custom":{}}"#.utf8)
        try write(stateBytes, to: state)
        let history = session.appending(path: "agents/main/wire.jsonl")
        let transcript = Data("""
        {"type":"metadata","protocol_version":"1.1","created_at":1779256791085}
        {"type":"context.append_message","message":{"role":"user","content":[{"type":"text","text":"Keep this prompt"}],"toolCalls":[]},"time":1779256800001}
        {"type":"context.append_message","message":{"role":"assistant","content":[{"type":"text","text":"Keep this reply"}],"toolCalls":[]},"time":1779256800002}
        {"type":"context.append_message","message":{"role":"tool","content":[{"type":"text","text":"Keep this result"}],"toolCallId":"tool-1"},"time":1779256800003}
        """.utf8)
        try write(transcript, to: history)
        let index = custom.appending(path: "session_index.jsonl")
        let indexBytes = Data(#"{"sessionId":"original-session","workDirKey":"project","title":"Synthetic retained task"}"#.utf8)
        try write(indexBytes, to: index)
        let device = custom.appending(path: "device_id")
        let deviceBytes = Data("synthetic-device-B\n".utf8)
        try write(deviceBytes, to: device)
        let decoyBytes = try Data(contentsOf: decoy)
        let store = try ProviderAccountStore(paths: paths,
            environment: ["KIMI_CODE_HOME": custom.path], specs: [ProviderCatalog.agentKimi])

        let b = try store.importLive(ProviderID(rawValue: "kimi"))
        XCTAssertEqual(b.identity.userID, "custom-B")
        try write(login("custom-C"), to: live)
        let c = try store.importLive(ProviderID(rawValue: "kimi"))
        XCTAssertEqual(c.identity.userID, "custom-C")
        XCTAssertNotEqual(b.id, c.id)

        _ = try store.makeDefault(b.id)

        XCTAssertEqual(store.liveIdentity(ProviderID(rawValue: "kimi"))?.key, "custom-B")
        XCTAssertEqual(try Data(contentsOf: live), login("custom-B"))
        XCTAssertEqual(try Data(contentsOf: decoy), decoyBytes)
        XCTAssertEqual(try Data(contentsOf: device), deviceBytes)
        XCTAssertEqual(try Data(contentsOf: state), stateBytes)
        XCTAssertEqual(try Data(contentsOf: index), indexBytes)
        XCTAssertEqual(try Data(contentsOf: history), transcript)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any])
        XCTAssertEqual(saved["lastPrompt"] as? String, "Keep this prompt")
        let events = try String(decoding: Data(contentsOf: history), as: UTF8.self).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let messages = events.compactMap { $0["message"] as? [String: Any] }
        XCTAssertEqual(messages.compactMap { $0["role"] as? String }, ["user", "assistant", "tool"])
        XCTAssertEqual(messages.compactMap { ($0["content"] as? [[String: String]])?.first?["text"] },
                       ["Keep this prompt", "Keep this reply", "Keep this result"])
    }

    func testNestedRootStagingExportsRootAndRejectsUnsafeSubpaths() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "KimiHomeStaging-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = testPaths(root)
        let valid = ProviderSpec(id: "nested-root", name: "Nested Root", style: .files,
            files: [LiveFile(".kimi-code/credentials/kimi-code.json", homeEnv: "TEST_KIMI_ROOT",
                             homeEnvSubpath: "credentials/kimi-code.json")],
            login: ["true"], usage: { _ in ProviderUsage() })
        let store = try ProviderAccountStore(paths: paths, environment: ["PATH": "/usr/bin:/bin"], specs: [valid])
        let start = try store.startLogin(valid.id)
        let staging = try XCTUnwrap(start.launchSpec.environment["HOME"])
        XCTAssertEqual(start.launchSpec.environment["TEST_KIMI_ROOT"], staging + "/.kimi-code")
        let unsafe = ProviderSpec(id: "unsafe-root", name: "Unsafe Root", style: .files,
            files: [LiveFile(".kimi-code/credentials/kimi-code.json", homeEnv: "TEST_KIMI_ROOT",
                             homeEnvSubpath: "../escape.json")],
            login: ["true"], usage: { _ in ProviderUsage() })
        let rejected = try ProviderAccountStore(paths: paths,
            environment: ["PATH": "/usr/bin:/bin", "TEST_KIMI_ROOT": root.appending(path: "custom").path],
            specs: [unsafe])
        XCTAssertThrowsError(try rejected.startLogin(unsafe.id))
        XCTAssertThrowsError(try rejected.importLive(unsafe.id))
    }

    func testOverrideOutsideIsolationCannotFallBackToDefaultCredential() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "KimiHomeIsolation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = testPaths(root)
        let decoy = paths.userHome.appending(path: ".kimi-code/credentials/kimi-code.json")
        let bytes = login("default-decoy")
        try write(bytes, to: decoy)
        let store = try ProviderAccountStore(paths: paths,
            environment: ["KIMI_CODE_HOME": root.deletingLastPathComponent().appending(path: "outside-kimi-\(UUID())").path],
            specs: [ProviderCatalog.agentKimi])
        XCTAssertNil(store.liveIdentity(ProviderID(rawValue: "kimi")))
        XCTAssertThrowsError(try store.importLive(ProviderID(rawValue: "kimi")))
        XCTAssertEqual(try Data(contentsOf: decoy), bytes)
    }

    private func testPaths(_ root: URL) -> ManagerPaths {
        let user = root.appending(path: "user")
        return ManagerPaths(applicationSupport: root.appending(path: "support"),
            credentialStore: user.appending(path: ".switch/codex"), defaultHome: user.appending(path: ".codex"),
            sharedRoot: user.appending(path: ".codex"), orcaAccountsRoot: root.appending(path: "orca"),
            isolationRoot: root)
    }

    private func login(_ subject: String) -> Data {
        let claims = Data("{\"sub\":\"\(subject)\"}".utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return Data("{\"access_token\":\"header.\(claims).signature\",\"refresh_token\":\"synthetic-\(subject)\"}".utf8)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
