import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchAppModel
@testable import SwitchRPC

/// `state.subscribe`, `state.unsubscribe`, and `state.changed` over a pipe that stays open.
extension RPCRuntimeTests {
    final class Session: @unchecked Sendable {
        let server: RPCServer
        private let pipe = Pipe()
        private let lock = NSLock()
        private var data = Data()
        private var serving: Task<Void, Never>!

        init(_ server: RPCServer) {
            self.server = server
            serving = Task { [pipe] in
                await server.serve(input: pipe.fileHandleForReading) { [weak self] in self?.append($0) }
            }
        }

        private func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }

        var frames: [[String: Any]] {
            lock.lock()
            let text = String(decoding: data, as: UTF8.self)
            lock.unlock()
            return text.split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }

        var raw: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }

        func send(_ line: String) { pipe.fileHandleForWriting.write(Data((line + "\n").utf8)) }

        /// Polls the output for up to `seconds` of real time.
        func wait(_ seconds: TimeInterval = 5, until condition: ([[String: Any]]) -> Bool) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(frames) {
                guard Date() < deadline else {
                    XCTFail("timed out; frames: \(frames)")
                    throw CancellationError()
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        func close() async throws {
            try pipe.fileHandleForWriting.close()
            await serving.value
        }
    }

    func session(manager: AccountManager? = nil, clock: any AppClock = SystemClock()) throws -> Session {
        Session(RPCServer(manager: try manager ?? self.manager(), paths: paths, version: "test-version", clock: clock,
                          log: { _ in }))
    }

    func changes(_ frames: [[String: Any]], _ topic: String) -> [[String: Any]] {
        frames.filter { $0["method"] as? String == "state.changed" }
            .compactMap { $0["params"] as? [String: Any] }
            .filter { $0["topic"] as? String == topic }
    }

    func testSubscribeReturnsSnapshotThenChangesWithNextRev() async throws {
        let session = try session()
        session.send(#"{"jsonrpc":"2.0","id":1,"method":"state.subscribe","params":{"topics":["app","notices"]}}"#)
        try await session.wait { $0.contains { $0["id"] as? Int == 1 } }
        let snapshot = try XCTUnwrap(result(try reply(session.frames, 1)))
        let app = try XCTUnwrap(snapshot["app"] as? [String: Any])
        XCTAssertEqual(app["rev"] as? Int, 0)
        XCTAssertEqual((app["value"] as? [String: Any])?["hasLoaded"] as? Bool, false)
        XCTAssertEqual((app["value"] as? [String: Any])?["dataLocation"] as? String, paths.applicationSupport.path)
        let locations = (app["value"] as? [String: Any])?["dataLocations"] as? [[String: Any]] ?? []
        XCTAssertEqual(locations.map { $0["id"] as? String }, ["data.codex", "data.codex-vault", "data.grok", "data.grok-vault"])
        XCTAssertEqual(locations.map { $0["path"] as? String },
                       [paths.defaultHome, paths.credentialStore, paths.grokHome, paths.grokCredentialStore].map(\.path))
        XCTAssertEqual(locations.first?["title"] as? String, "Codex home")
        XCTAssertEqual((snapshot["notices"] as? [String: Any])?["rev"] as? Int, 0)

        session.send(#"{"jsonrpc":"2.0","method":"initialized"}"#)
        try await session.wait { self.changes($0, "app").count == 1 }
        let change = changes(session.frames, "app")[0]
        XCTAssertEqual(change["rev"] as? Int, 1)
        XCTAssertEqual((change["value"] as? [String: Any])?["hasLoaded"] as? Bool, true)
        XCTAssertNil(session.frames.first { $0["method"] as? String == "state.changed" }?["id"])

        // A second `initialized` changes nothing, so no change is sent.
        session.send(#"{"jsonrpc":"2.0","id":2,"method":"initialized"}"#)
        session.send(#"{"jsonrpc":"2.0","id":3,"method":"state.subscribe","params":{"topics":["app"]}}"#)
        try await session.wait { $0.contains { $0["id"] as? Int == 3 } }
        XCTAssertEqual((result(try reply(session.frames, 3))?["app"] as? [String: Any])?["rev"] as? Int, 1)
        try await session.close()
        XCTAssertEqual(changes(session.frames, "app").count, 1)
    }

    func testUnsubscribedTopicsSendNoChanges() async throws {
        let session = try session()
        session.send(#"{"jsonrpc":"2.0","id":1,"method":"state.subscribe","params":{"topics":["app"]}}"#)
        // Requests run concurrently, so the unsubscribe waits for the subscribe reply.
        try await session.wait { $0.contains { $0["id"] as? Int == 1 } }
        session.send(#"{"jsonrpc":"2.0","id":2,"method":"state.unsubscribe","params":{"topics":["app"]}}"#)
        try await session.wait { $0.contains { $0["id"] as? Int == 2 } }
        session.send(#"{"jsonrpc":"2.0","id":3,"method":"initialized"}"#)
        try await session.wait { $0.contains { $0["id"] as? Int == 3 } }
        try await Task.sleep(nanoseconds: 300_000_000)
        try await session.close()
        XCTAssertTrue(changes(session.frames, "app").isEmpty)
    }

    func testUnknownTopicIsInvalidParams() async throws {
        let (_, replies) = try await run([
            #"{"jsonrpc":"2.0","id":1,"method":"state.subscribe","params":{"topics":["app","nope"]}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"state.subscribe"}"#,
        ])
        XCTAssertEqual(errorCode(try reply(replies, 1)), -32602)
        XCTAssertEqual(errorCode(try reply(replies, 2)), -32602)
    }

    func testUnavailableHelperPublishesTheReason() async throws {
        let session = Session(RPCServer(manager: nil, paths: paths, version: "test-version", log: { _ in }))
        session.send(#"{"jsonrpc":"2.0","id":1,"method":"state.subscribe","params":{"topics":["app","notices"]}}"#)
        try await session.wait { $0.contains { $0["id"] as? Int == 1 } }
        let app = (result(try reply(session.frames, 1))?["app"] as? [String: Any])?["value"] as? [String: Any]
        XCTAssertEqual(app?["isUnavailable"] as? Bool, true)
        session.send(#"{"jsonrpc":"2.0","method":"initialized"}"#)
        try await session.wait { !self.changes($0, "notices").isEmpty }
        let notices = changes(session.frames, "notices")[0]["value"] as? [String: Any]
        XCTAssertEqual(notices?["error"] as? String, AppEngine.unavailableText)
        try await session.close()
    }

    /// The accounts topic carries the presented row and never the key or its digest.
    func testAccountsTopicSendsRowsWithoutSecrets() async throws {
        let manager = try manager()
        let account = try await manager.addProviderAccount(providerID: provider, fields: ["apiKey": canary])
        let digest = try await manager.status().accounts[0].credentialDigest
        let session = try session(manager: manager)
        session.send(#"{"jsonrpc":"2.0","id":1,"method":"state.subscribe","params":{"topics":["accounts"]}}"#)
        session.send(#"{"jsonrpc":"2.0","method":"initialized"}"#)
        try await session.wait { !self.changes($0, "accounts").isEmpty }
        try await session.close()
        let rows = try XCTUnwrap((changes(session.frames, "accounts")[0]["value"] as? [String: Any])?["rows"]
            as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["id"] as? String, account.id.uuidString.lowercased())
        XCTAssertEqual(rows[0]["providerID"] as? String, "test-rpc")
        XCTAssertEqual(rows[0]["isDefault"] as? Bool, true)
        XCTAssertFalse(session.raw.contains(canary))
        XCTAssertFalse(session.raw.contains("sk-canary"))
        XCTAssertFalse(session.raw.contains(digest))
    }

    func testEngineErrorsMapToRPCCodes() {
        XCTAssertEqual(RPCError.failed(AppEngineError.busy).code, -32001)
        XCTAssertEqual(RPCError.failed(AppEngineError.busy).data.retryable, true)
        XCTAssertEqual(RPCError.failed(AppEngineError.unavailable).code, -32002)
    }
}
