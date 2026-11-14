import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchRPC

/// Drives `RPCServer.serve` through an in-memory pipe with synthetic accounts in a temporary home.
final class RPCRuntimeTests: XCTestCase {
    private var root: URL!
    private var paths: ManagerPaths!
    private var logLines: [String] = []
    private let canary = "sk-canary-\(UUID().uuidString)"
    private let provider = ProviderID(rawValue: "test-rpc")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "RPCRuntimeTests-\(UUID().uuidString)")
        paths = .init(applicationSupport: root.appending(path: "support"),
                      credentialStore: root.appending(path: "user/.switch/codex"),
                      defaultHome: root.appending(path: "user/.codex"),
                      sharedRoot: root.appending(path: "user/.codex"),
                      orcaAccountsRoot: root.appending(path: "orca"), isolationRoot: root)
    }

    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    private func manager() throws -> AccountManager {
        let usage = ProviderUsage(windows: [UsageWindow(id: "session", title: "Session", usedPercent: 40)],
                                  plan: "Pro", email: "rpc@example.test")
        let spec = ProviderSpec(id: provider.rawValue, name: "RPC Test", style: .secret,
                                fields: [.apiKey("TEST_RPC_KEY")], fetch: { _ in FetchResult(usage) })
        return try AccountManager(paths: paths, writerCheck: { _ in .inactive }, providerSpecs: [spec])
    }

    /// Writes the lines into a pipe, closes it, serves to the end, and returns each reply as a JSON object.
    private func run(_ lines: [String], manager: AccountManager? = nil) async throws -> (raw: [String], replies: [[String: Any]]) {
        let server = RPCServer(manager: try manager ?? self.manager(), paths: paths, version: "test-version",
                               log: { self.logLines.append($0) })
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(lines.map { $0 + "\n" }.joined().utf8))
        try pipe.fileHandleForWriting.close()
        var output = Data()
        await server.serve(input: pipe.fileHandleForReading) { output.append($0) }
        let raw = String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init)
        let replies = try raw.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        return (raw, replies)
    }

    private func errorCode(_ reply: [String: Any]) -> Int? { (reply["error"] as? [String: Any])?["code"] as? Int }
    private func result(_ reply: [String: Any]) -> [String: Any]? { reply["result"] as? [String: Any] }

    func testInitializeReportsVersionPlatformAndMethods() async throws {
        let (_, replies) = try await run([#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"#])
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0]["id"] as? Int, 1)
        XCTAssertEqual(replies[0]["jsonrpc"] as? String, "2.0")
        let value = try XCTUnwrap(result(replies[0]))
        XCTAssertEqual(value["protocolVersion"] as? Int, 1)
        XCTAssertEqual(value["serverVersion"] as? String, "test-version")
        XCTAssertTrue(["macos", "linux", "windows"].contains(value["platform"] as? String ?? ""))
        XCTAssertEqual(value["methods"] as? [String], RPCServer.methods)
    }

    func testUnknownMethodEchoesStringID() async throws {
        let (_, replies) = try await run([#"{"jsonrpc":"2.0","id":"abc","method":"no.such"}"#])
        XCTAssertEqual(replies[0]["id"] as? String, "abc")
        XCTAssertEqual(errorCode(replies[0]), -32601)
    }

    func testParseErrorKeepsServing() async throws {
        let (_, replies) = try await run(["{not json", #"{"jsonrpc":"2.0","id":2,"method":"initialize"}"#])
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(errorCode(replies[0]), -32700)
        XCTAssertTrue(replies[0]["id"] is NSNull)
        XCTAssertEqual(replies[1]["id"] as? Int, 2)
        XCTAssertNotNil(result(replies[1]))
    }

    func testInvalidRequestsAndParams() async throws {
        let (_, replies) = try await run([
            #"{"jsonrpc":"1.0","id":3,"method":"initialize"}"#,
            "[1,2]",
            #"{"jsonrpc":"2.0","id":{"a":1},"method":"initialize"}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"usage.detail","params":{"accountID":"not-a-uuid"}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"usage.detail"}"#,
        ])
        XCTAssertEqual(replies.map(errorCode), [-32600, -32600, -32600, -32602, -32602])
        XCTAssertEqual(replies[0]["id"] as? Int, 3)
        XCTAssertTrue(replies[1]["id"] is NSNull)
        XCTAssertTrue(replies[2]["id"] is NSNull)
    }

    func testNotificationsGetNoReplyAndShutdownStopsReading() async throws {
        let (_, replies) = try await run([
            #"{"jsonrpc":"2.0","method":"initialized"}"#,
            #"{"jsonrpc":"2.0","method":"no.such"}"#,
            "",
            #"{"jsonrpc":"2.0","id":6,"method":"shutdown"}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"initialize"}"#,
        ])
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0]["id"] as? Int, 6)
        XCTAssertTrue(replies[0]["result"] is NSNull)
    }

    func testAccountsStatusAndUsageDetailForSyntheticAccount() async throws {
        let manager = try manager()
        let account = try await manager.addProviderAccount(providerID: provider, fields: ["apiKey": canary])
        let id = account.id.uuidString.lowercased()
        let (_, replies) = try await run([
            #"{"jsonrpc":"2.0","id":1,"method":"accounts.status"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"usage.detail","params":{"accountID":"\#(id)"}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"usage.detail","params":{"accountID":"\#(UUID().uuidString)"}}"#,
        ], manager: manager)
        let accounts = try XCTUnwrap(result(replies[0])?["accounts"] as? [[String: Any]])
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0]["id"] as? String, id)
        XCTAssertEqual((accounts[0]["identity"] as? [String: Any])?["providerID"] as? String, "test-rpc")
        XCTAssertNil(accounts[0]["credentialDigest"])
        let usage = try XCTUnwrap(result(replies[1])?["usage"] as? [String: Any])
        XCTAssertEqual((usage["windows"] as? [[String: Any]])?.first?["usedPercent"] as? Double, 40)
        XCTAssertEqual(errorCode(replies[2]), -32003)
    }

    /// The canary key must not reach any reply line or log line, whatever method runs.
    func testCanaryKeyNeverLeavesTheServer() async throws {
        let manager = try manager()
        let account = try await manager.addProviderAccount(providerID: provider, fields: ["apiKey": canary])
        let digest = try await manager.status().accounts[0].credentialDigest
        let id = account.id.uuidString.lowercased()
        let (raw, replies) = try await run([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"accounts.status"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"usage.detail","params":{"accountID":"\#(id)","force":true}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"usage.detail","params":{"accountID":"\#(id)","extra":"x"}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"no.such"}"#,
            "{broken",
        ], manager: manager)
        XCTAssertEqual(replies.count, 6)
        let everything = (raw + logLines).joined(separator: "\n")
        XCTAssertTrue(everything.contains(id), "the account must be in the output, or this test proves nothing")
        XCTAssertFalse(everything.contains(canary))
        XCTAssertFalse(everything.contains("sk-canary"))
        XCTAssertFalse(digest.isEmpty)
        XCTAssertFalse(everything.contains(digest))
    }

    /// `scripts/release-macos.sh` reads the version with awk from this exact file and line shape.
    func testReleaseScriptCanReadTheVersionSource() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: repository.appending(path: "packages/core/Sources/AIManagerCore/BuildInfo.swift"),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("static let version = \"\(AIManagerBuildInfo.version)\""))
    }
}
