import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchAppModel
@testable import SwitchRPC

/// `settings.get`, `settings.set`, and the `settings` topic, stored in `<root>/settings.json`.
extension RPCRuntimeTests {
    func testSettingsGetSetAndValidation() async throws {
        let (raw, replies) = try await run([
            #"{"jsonrpc":"2.0","id":1,"method":"settings.get"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"settings.get","params":{"keys":["checkProviderStatus","timeFormat"]}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"settings.get","params":{"keys":["nope"]}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"settings.set","params":{"key":"autoSwitchThreshold","value":3}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"settings.set","params":{"key":"privacyMode","value":"yes"}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"settings.set","params":{"key":"nope","value":true}}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"settings.set","params":{"value":true}}"#,
        ])
        XCTAssertEqual(replies.count, 7)
        let all = try XCTUnwrap(result(try reply(replies, 1)))
        XCTAssertEqual(all["schemaVersion"] as? Int, 1)
        let values = try XCTUnwrap(all["values"] as? [String: Any])
        XCTAssertEqual(values["checkProviderStatus"] as? Bool, true)
        XCTAssertEqual(values["autoSwitchThreshold"] as? Int, 1)
        XCTAssertNil(values["lastPage"], "a key without a default and without a value is left out")
        let two = try XCTUnwrap(result(try reply(replies, 2))?["values"] as? [String: Any])
        XCTAssertEqual(Set(two.keys), ["checkProviderStatus", "timeFormat"])
        for id in 3...7 { XCTAssertEqual(errorCode(try reply(replies, id)), -32602, "id \(id)") }
        XCTAssertFalse(raw.joined().contains("\"yes\""), "the refused value is not echoed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "settings.json").path))
    }

    func testSettingsSetStoresPublishesAndRemoves() async throws {
        let session = try session()
        session.send(#"{"jsonrpc":"2.0","id":1,"method":"state.subscribe","params":{"topics":["settings"]}}"#)
        try await session.wait { $0.contains { $0["id"] as? Int == 1 } }
        let start = (result(try reply(session.frames, 1))?["settings"] as? [String: Any])
        XCTAssertEqual(start?["rev"] as? Int, 0)
        XCTAssertEqual((start?["value"] as? [String: Any]).flatMap { ($0["values"] as? [String: Any])?["timeFormat"] } as? String,
                       "auto")

        session.send(#"{"jsonrpc":"2.0","id":2,"method":"settings.set","params":{"key":"timeFormat","value":"24h"}}"#)
        try await session.wait { self.changes($0, "settings").count == 1 }
        XCTAssertEqual((result(try reply(session.frames, 2))?["values"] as? [String: Any])?["timeFormat"] as? String, "24h")
        let change = changes(session.frames, "settings")[0]
        XCTAssertEqual(change["rev"] as? Int, 1)
        XCTAssertEqual(((change["value"] as? [String: Any])?["values"] as? [String: Any])?["timeFormat"] as? String, "24h")
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "settings.json")))
            as? [String: Any])
        XCTAssertEqual((file["values"] as? [String: Any])?["timeFormat"] as? String, "24h")

        session.send(#"{"jsonrpc":"2.0","id":3,"method":"settings.set","params":{"key":"timeFormat","value":null}}"#)
        try await session.wait { self.changes($0, "settings").count == 2 }
        XCTAssertEqual((result(try reply(session.frames, 3))?["values"] as? [String: Any])?["timeFormat"] as? String, "auto")
        try await session.close()
    }

    /// A client that pipelines a write and a read of the same state always reads its own write.
    func testPipelinedSetThenGetAlwaysReadsTheNewValue() async throws {
        let session = try session()
        var lines: [String] = []
        for round in 0..<200 {
            lines.append(#"{"jsonrpc":"2.0","id":\#(round * 2),"method":"settings.set","params":{"key":"autoSwitchResumeMessage","value":"m\#(round)"}}"#)
            lines.append(#"{"jsonrpc":"2.0","id":\#(round * 2 + 1),"method":"settings.get","params":{"keys":["autoSwitchResumeMessage"]}}"#)
        }
        lines.forEach(session.send)
        try await session.wait(30) { $0.filter { $0["id"] != nil }.count == 400 }
        let frames = session.frames
        for round in 0..<200 {
            let value = (result(try reply(frames, round * 2 + 1))?["values"] as? [String: Any])?["autoSwitchResumeMessage"]
            XCTAssertEqual(value as? String, "m\(round)", "round \(round)")
        }
        try await session.close()
    }

    func testOrderedRequestsDoNotWaitForUnrelatedSlowReads() async throws {
        let (_, replies) = try await run([
            #"{"jsonrpc":"2.0","id":1,"method":"test.slow"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"settings.get"}"#,
        ], extra: ["test.slow": { _ in try await Task.sleep(nanoseconds: 1_000_000_000); return "slow" }])
        XCTAssertEqual(replies.map { $0["id"] as? Int }, [2, 1])
        XCTAssertEqual(RPCServer.orderKey("usage.detail"), nil)
        XCTAssertEqual(RPCServer.orderKey("usage.history"), nil)
        XCTAssertEqual(RPCServer.orderKey("accounts.status"), RPCServer.orderKey("accounts.setDefault"))
    }

    func testNewerSettingsFileIsReadOnlyOverRPC() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":9,"values":{"privacyMode":true}}"#.utf8).write(to: root.appending(path: "settings.json"))
        let (_, replies) = try await run([
            #"{"jsonrpc":"2.0","id":1,"method":"settings.get","params":{"keys":["privacyMode"]}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"settings.set","params":{"key":"privacyMode","value":false}}"#,
        ])
        XCTAssertEqual((result(try reply(replies, 1))?["values"] as? [String: Any])?["privacyMode"] as? Bool, true)
        XCTAssertEqual(errorCode(try reply(replies, 2)), -32007)
    }

    /// A settings write never carries the canary key, even with a provider account in the same root.
    func testSettingsRepliesCarryNoSecrets() async throws {
        let manager = try manager()
        _ = try await manager.addProviderAccount(providerID: provider, fields: ["apiKey": canary])
        let (raw, replies) = try await run([
            #"{"jsonrpc":"2.0","id":1,"method":"settings.set","params":{"key":"privacyMode","value":true}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"settings.get"}"#,
        ], manager: manager)
        XCTAssertEqual(replies.count, 2)
        XCTAssertFalse((raw + logLines).joined().contains("sk-canary"))
    }
}
