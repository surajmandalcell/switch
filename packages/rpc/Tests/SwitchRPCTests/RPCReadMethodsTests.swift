import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchRPC
import SwitchAppModel

/// One test per read method, on synthetic data in the temporary home of `RPCRuntimeTests`.
extension RPCRuntimeTests {
    /// Sends one request with id 1 and returns its reply.
    func call(_ method: String, _ params: String? = nil, manager: AccountManager? = nil) async throws -> [String: Any] {
        let frame = #"{"jsonrpc":"2.0","id":1,"method":"\#(method)""# + (params.map { #","params":\#($0)}"# } ?? "}")
        let (_, replies) = try await run([frame], manager: manager)
        return try reply(replies, 1)
    }

    /// The `result` object of one request.
    func object(_ method: String, _ params: String? = nil) async throws -> [String: Any] {
        let reply = try await call(method, params)
        return try XCTUnwrap(result(reply), "\(reply)")
    }

    /// The `result` array of one request.
    func list(_ method: String, _ params: String? = nil, manager: AccountManager? = nil) async throws -> [[String: Any]] {
        let reply = try await call(method, params, manager: manager)
        return try XCTUnwrap(reply["result"] as? [[String: Any]], "\(reply)")
    }

    /// One Codex conversation with a prompt and an answer.
    func writeConversation() throws {
        let folder = paths.sharedRoot.appending(path: "sessions/2026/11/14", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = [
            #"{"timestamp":"2026-11-14T10:00:00.000Z","type":"session_meta","payload":{"id":"thread-rpc","cwd":"/work/switch"}}"#,
            #"{"timestamp":"2026-11-14T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Hello RPC"}]}}"#,
            #"{"timestamp":"2026-11-14T10:00:02.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello back"}]}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: folder.appending(path: "rollout-2026-11-14T10-00-00-thread-rpc.jsonl"))
    }

    func writeBackupSet() async throws -> BackupSet {
        for folder in [paths.defaultHome, root.appending(path: "backups")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let set = BackupSet(name: "RPC", source: .init(id: "codex", service: .codex, home: paths.defaultHome),
                            items: [BackupItem("sessions")], destination: root.appending(path: "backups"))
        try await BackupEngine(applicationSupport: paths.applicationSupport).saveSets([set])
        return set
    }

    func threadID() async throws -> String {
        let value = try await object("history.list")
        let threads = try XCTUnwrap(value["threads"] as? [[String: Any]])
        return try XCTUnwrap(threads.first?["id"] as? String)
    }

    func testProvidersList() async throws {
        let providers = try await list("providers.list")
        XCTAssertTrue(providers.contains { $0["id"] as? String == "codex" && $0["displayName"] != nil })
    }

    func testAppSearchIndex() async throws {
        let all = try await list("app.searchIndex")
        XCTAssertEqual(all.count, SettingsSearch.entries.count)
        XCTAssertEqual(all.first?["id"] as? String, "login")
        XCTAssertNotNil(all.first?["keywords"] as? String)
        let hotkey = try await list("app.searchIndex", #"{"query":"hotkey"}"#)
        XCTAssertEqual(hotkey.map { $0["title"] as? String }, [SettingsCopy.menuShortcut])
    }

    /// `tray.rows` answers the `tray` topic shape and carries no secret. The synthetic provider has no usage in a
    /// test home, so its row stays out of the popover (as on the Mac); AppEngineTrayTests covers filled rows.
    func testTrayRowsAndTopic() async throws {
        let manager = try manager()
        _ = try await manager.addProviderAccount(providerID: provider, fields: ["apiKey": canary])
        let session = try session(manager: manager)
        session.send(#"{"jsonrpc":"2.0","id":1,"method":"state.subscribe","params":{"topics":["tray","accounts"]}}"#)
        session.send(#"{"jsonrpc":"2.0","method":"initialized"}"#)
        try await session.wait { !self.rows($0).isEmpty }
        let snapshot = try XCTUnwrap(result(try reply(session.frames, 1))?["tray"] as? [String: Any])
        XCTAssertEqual(snapshot["rev"] as? Int, 0)
        let reply = try await call(session, 2, "tray.rows", "{}")
        let value = try XCTUnwrap(result(reply))
        XCTAssertEqual((value["groups"] as? [Any])?.count, 0)
        XCTAssertEqual((value["status"] as? [Any])?.count, 0)
        XCTAssertNotNil(value["tooltip"] as? String)
        try await session.close()
        XCTAssertFalse(session.raw.contains(canary))
    }

    func testAccountsSavedAuthPath() async throws {
        let manager = try manager()
        let account = try await manager.addProviderAccount(providerID: provider, fields: ["apiKey": canary])
        let found = try await call("accounts.savedAuthPath", #"{"accountID":"\#(account.id.uuidString)"}"#, manager: manager)
        XCTAssertEqual(result(found)?["path"] as? String, account.credentialFile.path)
        let missing = try await call("accounts.savedAuthPath", #"{"accountID":"\#(UUID().uuidString)"}"#)
        XCTAssertEqual(errorCode(missing), -32003)
    }

    func testAccountsInspectLinks() async throws {
        let links = try await list("accounts.inspectLinks")
        XCTAssertEqual(links.count, 0)
        let bad = try await call("accounts.inspectLinks", #"{"accountID":"bad"}"#)
        XCTAssertEqual(errorCode(bad), -32602)
    }

    func testImportDiscover() async throws {
        let folder = root.appending(path: "import-home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sources = try await list("import.discover", #"{"folder":"\#(folder.path)"}"#)
        XCTAssertTrue(sources.allSatisfy { ($0["path"] as? String).map(isAbsolutePath) == true })
    }

    func testClaudeShellIntegrationGet() async throws {
        let reply = try await call("claude.shellIntegration.get")
        XCTAssertEqual(result(reply)?["enabled"] as? Bool, false)
    }

    func testDroidMissions() async throws {
        let missions = try await list("droid.missions")
        XCTAssertEqual(missions.count, 0)
    }

    func testHistoryList() async throws {
        try writeConversation()
        let value = try await object("history.list", #"{"limit":10}"#)
        let threads = try XCTUnwrap(value["threads"] as? [[String: Any]])
        XCTAssertEqual(threads.first?["threadID"] as? String, "thread-rpc")
        XCTAssertEqual(threads.first?["workingDirectory"] as? String, "/work/switch")
        let bad = try await call("history.list", #"{"limit":0}"#)
        XCTAssertEqual(errorCode(bad), -32602)
    }

    func testHistoryDetail() async throws {
        try writeConversation()
        let id = try await threadID()
        let detail = try await object("history.detail", #"{"id":"\#(id)","role":"prompts"}"#)
        let messages = try XCTUnwrap(detail["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["text"] as? String }, ["Hello RPC"])
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        let missing = try await call("history.detail", #"{"id":"missing"}"#)
        XCTAssertEqual(errorCode(missing), -32003)
    }

    func testHistoryExport() async throws {
        try writeConversation()
        let id = try await threadID()
        let export = try await object("history.export", #"{"id":"\#(id)"}"#)
        let text = try XCTUnwrap(export["text"] as? String)
        XCTAssertTrue(text.contains("Hello RPC") && text.contains("Hello back"), text)
    }

    func testCleanupSources() async throws {
        try FileManager.default.createDirectory(at: paths.defaultHome, withIntermediateDirectories: true)
        let sources = try await list("cleanup.sources")
        XCTAssertTrue(sources.contains { $0["tool"] as? String == "codex" }, "\(sources)")
    }

    func testCleanupTrashList() async throws {
        try FileManager.default.createDirectory(at: paths.defaultHome, withIntermediateDirectories: true)
        let sources = try await list("cleanup.sources")
        let id = try XCTUnwrap(sources.first?["id"] as? String)
        let batches = try await list("cleanup.trashList", #"{"sourceID":"\#(id)"}"#)
        XCTAssertEqual(batches.count, 0)
        let missing = try await call("cleanup.trashList", #"{"sourceID":"missing"}"#)
        XCTAssertEqual(errorCode(missing), -32003)
    }

    func testCleanupSamples() async throws {
        let samples = try await list("cleanup.samples")
        XCTAssertEqual(samples.count, 0)
    }

    func testBackupList() async throws {
        let set = try await writeBackupSet()
        let sets = try await list("backup.list")
        XCTAssertEqual(sets.first?["id"] as? String, set.id.uuidString.lowercased())
        XCTAssertEqual(sets.first?["destination"] as? String, set.destination.path)
    }

    func testBackupHistory() async throws {
        let set = try await writeBackupSet()
        let status = try await object("backup.history", #"{"setID":"\#(set.id.uuidString)"}"#)
        XCTAssertEqual(status["state"] as? String, "ready")
        XCTAssertEqual((status["snapshots"] as? [Any])?.count, 0)
        let missing = try await call("backup.history", #"{"setID":"\#(UUID().uuidString)"}"#)
        XCTAssertEqual(errorCode(missing), -32003)
    }

    func testUsageProjectActivity() async throws {
        let activity = try await list("usage.projectActivity", #"{"day":"2026-11-14"}"#)
        XCTAssertEqual(activity.count, 0)
        let bad = try await call("usage.projectActivity")
        XCTAssertEqual(errorCode(bad), -32602)
    }

    func testUsageHistoryAndDay() async throws {
        let history = try await object("usage.history", #"{"period":"month","grouping":"model"}"#)
        let today = try XCTUnwrap(history["today"] as? String)
        XCTAssertEqual(today.count, 10)
        XCTAssertNotNil(history["points"] as? [Any])
        let summary = try XCTUnwrap(history["summary"] as? [String: Any])
        XCTAssertEqual(summary["period"] as? String, "month")
        XCTAssertEqual(summary["grouping"] as? String, "model")
        let weekly = try await object("usage.history")
        XCTAssertEqual((weekly["summary"] as? [String: Any])?["period"] as? String, "week")
        let badPeriod = try await call("usage.history", #"{"period":"decade"}"#)
        XCTAssertEqual(errorCode(badPeriod), -32602)

        let day = try await object("usage.day", #"{"day":"\#(today)"}"#)
        XCTAssertEqual(day["day"] as? String, today)
        XCTAssertEqual((day["sessions"] as? [Any])?.count, 0)
        XCTAssertEqual((day["threads"] as? [Any])?.count, 0)
        let badDay = try await call("usage.day", #"{"day":"14-11-2026"}"#)
        XCTAssertEqual(errorCode(badDay), -32602)
        let noDay = try await call("usage.day")
        XCTAssertEqual(errorCode(noDay), -32602)
    }

    func testRunningCLIsList() async throws {
        let clis = try await list("runningCLIs.list")
        XCTAssertTrue(clis.allSatisfy { $0["command"] == nil && $0["flags"] == nil })
    }

    /// Every read method, with an account, a conversation, and a backup set present: the canary key and the
    /// credential digest reach no reply and no log line.
    func testCanaryKeyNeverLeavesReadMethods() async throws {
        let manager = try manager()
        let account = try await manager.addProviderAccount(providerID: provider, fields: ["apiKey": canary])
        let digest = try await manager.status().accounts[0].credentialDigest
        try writeConversation()
        let set = try await writeBackupSet()
        let id = account.id.uuidString.lowercased()
        let thread = try await threadID()
        let sources = try await list("cleanup.sources")
        let source = try XCTUnwrap(sources.first?["id"] as? String)
        let params = [
            "accounts.savedAuthPath": #"{"accountID":"\#(id)"}"#, "accounts.inspectLinks": #"{"accountID":"\#(id)"}"#,
            "history.detail": #"{"id":"\#(thread)"}"#, "history.export": #"{"id":"\#(thread)"}"#,
            "cleanup.trashList": #"{"sourceID":"\#(source)"}"#, "backup.history": #"{"setID":"\#(set.id.uuidString)"}"#,
            "usage.projectActivity": #"{"day":"2026-11-14"}"#, "usage.day": #"{"day":"2026-11-14"}"#,
            "providers.liveIdentity": #"{"providerID":"test-rpc"}"#,
        ]
        let frames = RPCServer.readMethods.enumerated().map { number, method in
            #"{"jsonrpc":"2.0","id":\#(number + 1),"method":"\#(method)""# + (params[method].map { #","params":\#($0)}"# } ?? "}")
        }
        let (raw, replies) = try await run(frames, manager: manager)
        XCTAssertEqual(replies.count, RPCServer.readMethods.count)
        XCTAssertTrue(replies.allSatisfy { $0["error"] == nil }, "\(replies.filter { $0["error"] != nil })")
        let everything = (raw + logLines).joined(separator: "\n")
        XCTAssertTrue(everything.contains("Hello RPC") && everything.contains(account.credentialFile.path))
        XCTAssertFalse(everything.contains(canary))
        XCTAssertFalse(everything.contains("sk-canary"))
        XCTAssertFalse(everything.contains(digest))
    }
}
