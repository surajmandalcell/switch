import CSQLite
import Foundation
import XCTest
@testable import AIManagerCore

final class PromptBackupProviderTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var home: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/switch-work1-build-oc/test-data/\(UUID().uuidString)")
        home = root.appending(path: "home")
        destination = root.appending(path: "destination")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    private func write(_ path: String, _ data: Data) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func json(_ path: String, _ object: [String: Any]) throws {
        try write(path, JSONSerialization.data(withJSONObject: object))
    }

    private func jsonl(_ path: String, _ records: [[String: Any]]) throws {
        var data = Data()
        for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
        try write(path, data)
    }

    private func set(_ service: BackupSource.Service, promptsOnly: Bool = true, includeLogins: Bool = false) -> BackupSet {
        BackupSet(name: service.rawValue, source: BackupSource(id: service.rawValue, service: service, home: home),
            items: BackupPresets.items(for: service), destination: destination, includeLogins: includeLogins, promptsOnly: promptsOnly)
    }

    private func documents(_ snapshot: BackupSnapshot) throws -> [String] {
        try snapshot.manifest.entries.filter { $0.path != "prompts/index.md" }.map {
            XCTAssertTrue($0.path.hasPrefix("prompts/") && $0.path.hasSuffix(".md"))
            return try String(contentsOf: snapshot.folder.appending(path: "files/" + $0.path), encoding: .utf8)
        }
    }

    func testCopilotExportsOnlyUserPromptsWithWorkspaceAndTimeOrder() async throws {
        try write("session-state/one/workspace.yaml", Data("cwd: '/Projects/my-app'\nname: |-\n  Fix the export\n  in Copilot\n".utf8))
        try jsonl("session-state/one/events.jsonl", [
            ["type": "session.start", "timestamp": "2023-11-14T20:00:00Z", "data": ["startTime": "2023-11-14T20:00:00Z", "context": ["cwd": "/Fallback"]]],
            ["id": "later", "type": "user.message", "timestamp": "2023-11-14T22:00:00Z", "data": ["content": "Later owner prompt", "transformedContent": "INJECTED CONTEXT", "attachments": [["text": "ATTACHMENT"]]]],
            ["id": "earlier", "type": "user.message", "timestamp": "2023-11-14T21:00:00Z", "data": ["content": "Earlier owner prompt"]],
            ["type": "assistant.message", "data": ["content": "ASSISTANT"]],
            ["type": "tool.execution_complete", "data": ["result": "TOOL"]],
            ["type": "system.message", "data": ["content": "SYSTEM"]],
            ["type": "user.message", "data": ["content": "AUTOPILOT", "isAutopilotContinuation": true]],
            ["type": "user.message", "data": ["content": "SKILL", "source": "skill-pdf"]],
            ["type": "user.message", "data": ["content": "AGENT", "source": "agent-worker"]],
            ["type": "user.message", "agentId": "worker", "data": ["content": "SUBAGENT"]],
        ])
        try write("session-state/one/plan.md", Data("PLAN".utf8))
        try jsonl("session-state/one/checkpoints/events.jsonl", [["type": "user.message", "data": ["content": "CHECKPOINT"]]])
        try write("config.json", Data("CONFIG".utf8))
        try write("auth.json", Data("LOGIN".utf8))
        let engine = BackupEngine(applicationSupport: root.appending(path: "support"))
        let snapshot = try await engine.snapshot(set(.copilot))
        XCTAssertTrue(snapshot.manifest.skipped.isEmpty)
        XCTAssertEqual(snapshot.files, 2)
        let text = try XCTUnwrap(documents(snapshot).first)
        XCTAssertTrue(text.contains("# Fix the export in Copilot"))
        XCTAssertTrue(text.contains("Project: /Projects/my-app") && text.contains("App: Copilot"))
        XCTAssertTrue(text.contains("Date: 2023-11-14T20:00:00Z"))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "Earlier owner prompt")?.lowerBound), try XCTUnwrap(text.range(of: "Later owner prompt")?.lowerBound))
        for excluded in ["INJECTED CONTEXT", "ATTACHMENT", "ASSISTANT", "TOOL", "SYSTEM", "AUTOPILOT", "SKILL", "AGENT", "SUBAGENT", "PLAN", "CHECKPOINT", "CONFIG", "LOGIN"] {
            XCTAssertFalse(text.contains(excluded), excluded)
        }
        let index = try String(contentsOf: snapshot.folder.appending(path: "files/prompts/index.md"), encoding: .utf8)
        XCTAssertTrue(index.contains("Fix the export in Copilot") && index.contains("/Projects/my-app"))
        XCTAssertTrue(fm.fileExists(atPath: home.appending(path: "session-state/one/events.jsonl").path))
    }

    func testCopilotLegacyEventsUseSessionContextAndWorkspaceLinksAreSkipped() async throws {
        try jsonl("session-state/legacy.jsonl", [
            ["type": "session.start", "data": ["context": ["cwd": "/Projects/Legacy"]]],
            ["type": "user.message", "data": ["content": "Legacy owner prompt"]],
        ])
        try jsonl("session-state/linked/events.jsonl", [["type": "user.message", "data": ["content": "Linked workspace prompt"]]])
        try write("private.yaml", Data("cwd: /PRIVATE\nname: PRIVATE\n".utf8))
        try fm.createSymbolicLink(at: home.appending(path: "session-state/linked/workspace.yaml"), withDestinationURL: home.appending(path: "private.yaml"))
        try fm.createSymbolicLink(at: home.appending(path: "session-state/link.jsonl"), withDestinationURL: home.appending(path: "session-state/legacy.jsonl"))
        let engine = BackupEngine(applicationSupport: root.appending(path: "support"))
        let snapshot = try await engine.snapshot(set(.copilot))
        XCTAssertEqual(snapshot.files, 2)
        XCTAssertEqual(snapshot.manifest.skipped.count, 1)
        let text = try XCTUnwrap(documents(snapshot).first)
        XCTAssertTrue(text.contains("Project: /Projects/Legacy") && text.contains("Legacy owner prompt"))
        XCTAssertFalse(text.contains("PRIVATE") || text.contains("Linked workspace prompt"))
    }

    func testOpenCodeJSONExportsOneFilePerSessionAndOnlyUserTextParts() async throws {
        for (id, project) in [("ses_one", "/Projects/One"), ("ses_two", "/Other/One")] {
            try json("storage/session/project/\(id).json", ["id": id, "title": "Shared title", "directory": project, "time": ["created": 1_700_000_000_000, "updated": 1_700_000_002_000]])
            for (name, role) in [("later", "user"), ("earlier", "user"), ("assistant", "assistant")] {
                let message = "msg_" + id + "_" + name
                let time = name == "earlier" ? 1_700_000_000_000 : 1_700_000_001_000
                try json("storage/message/\(id)/\(message).json", ["id": message, "sessionID": id, "role": role, "time": ["created": time]])
                let text = role == "assistant" ? "ASSISTANT" : (name == "earlier" ? "Earlier owner prompt" : "Later owner prompt")
                try json("storage/part/\(message)/part_text.json", ["id": "part_text", "messageID": message, "sessionID": id, "type": "text", "text": text])
                try json("storage/part/\(message)/part_tool.json", ["id": "part_tool", "messageID": message, "sessionID": id, "type": "tool", "text": "TOOL"])
                try json("storage/part/\(message)/part_synthetic.json", ["id": "part_synthetic", "messageID": message, "sessionID": id, "type": "text", "text": "SYNTHETIC", "synthetic": true])
                try json("storage/part/\(message)/part_ignored.json", ["id": "part_ignored", "messageID": message, "sessionID": id, "type": "text", "text": "IGNORED", "ignored": true])
            }
        }
        try write("auth.json", Data("LOGIN".utf8))
        let engine = BackupEngine(applicationSupport: root.appending(path: "support"))
        let snapshot = try await engine.snapshot(set(.opencode))
        XCTAssertTrue(snapshot.manifest.skipped.isEmpty)
        XCTAssertEqual(snapshot.files, 3)
        XCTAssertEqual(Set(snapshot.manifest.entries.filter { $0.path != "prompts/index.md" }.map { $0.path.split(separator: "/")[1] }).count, 2)
        for text in try documents(snapshot) {
            XCTAssertTrue(text.contains("Shared title") && text.contains("App: OpenCode"))
            XCTAssertLessThan(try XCTUnwrap(text.range(of: "Earlier owner prompt")?.lowerBound), try XCTUnwrap(text.range(of: "Later owner prompt")?.lowerBound))
            for excluded in ["ASSISTANT", "TOOL", "SYNTHETIC", "IGNORED", "LOGIN"] { XCTAssertFalse(text.contains(excluded), excluded) }
        }
    }

    private func database(v2: Bool) throws -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(home.appending(path: "opencode.db").path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw NSError(domain: "PromptBackupProviderTests", code: 1)
        }
        let session = v2 ? "session_v2" : "session"
        let schema = """
            PRAGMA journal_mode=WAL;
            CREATE TABLE \(session)(id TEXT PRIMARY KEY,directory TEXT,title TEXT,time_updated INTEGER);
            INSERT INTO \(session) VALUES('ses_db','/Projects/Database','Database prompts',1700000002000);
            CREATE TABLE credential(id TEXT PRIMARY KEY, secret TEXT);
            INSERT INTO credential VALUES('login','LOGIN MUST STAY OUT');
            """
        let messages = v2 ? """
            CREATE TABLE session_message(id TEXT PRIMARY KEY,session_id TEXT,type TEXT,time_created INTEGER,data TEXT);
            INSERT INTO session_message VALUES('msg_user','ses_db','user',1700000000000,'{"text":"Database owner prompt","time":{"created":1700000000000}}');
            INSERT INTO session_message VALUES('msg_assistant','ses_db','assistant',1700000000000,'{"text":"ASSISTANT"}');
            INSERT INTO session_message VALUES('msg_tool','ses_db','tool',1700000000000,'{"text":"TOOL"}');
            INSERT INTO session_message VALUES('msg_synthetic','ses_db','user',1700000000000,'{"text":"SYNTHETIC","synthetic":true}');
            """ : """
            CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT,time_created INTEGER,data TEXT);
            CREATE TABLE part(id TEXT PRIMARY KEY,message_id TEXT,session_id TEXT,data TEXT);
            INSERT INTO message VALUES('msg_user','ses_db',1700000000000,'{"role":"user","time":{"created":1700000000000}}');
            INSERT INTO message VALUES('msg_assistant','ses_db',1700000000000,'{"role":"assistant"}');
            INSERT INTO part VALUES('part_user','msg_user','ses_db','{"type":"text","text":"Database owner prompt"}');
            INSERT INTO part VALUES('part_tool','msg_user','ses_db','{"type":"tool","text":"TOOL"}');
            INSERT INTO part VALUES('part_synthetic','msg_user','ses_db','{"type":"text","text":"SYNTHETIC","synthetic":true}');
            INSERT INTO part VALUES('part_assistant','msg_assistant','ses_db','{"type":"text","text":"ASSISTANT"}');
            """
        guard sqlite3_exec(db, schema + messages, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw NSError(domain: "PromptBackupProviderTests", code: 2)
        }
        return db
    }

    private func checkDatabasePrompts(v2: Bool) async throws {
        let db = try database(v2: v2)
        defer { sqlite3_close(db) }
        // The obsolete JSON tree must not duplicate sessions after SQLite migration.
        try json("storage/session/project/ses_db.json", ["id": "ses_db", "title": "STALE JSON", "directory": "/Stale"])
        let engine = BackupEngine(applicationSupport: root.appending(path: "support"))
        let snapshot = try await engine.snapshot(set(.opencode))
        XCTAssertTrue(snapshot.manifest.skipped.isEmpty)
        XCTAssertEqual(snapshot.files, 2)
        let text = try XCTUnwrap(documents(snapshot).first)
        XCTAssertTrue(text.contains("Database owner prompt") && text.contains("Project: /Projects/Database"))
        for excluded in ["LOGIN MUST STAY OUT", "ASSISTANT", "TOOL", "SYNTHETIC", "STALE JSON"] {
            XCTAssertFalse(text.contains(excluded), excluded)
        }
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO credential VALUES('still-writable','SYNTHETIC')", nil, nil, nil), SQLITE_OK)
    }

    func testOpenCodeSQLiteV1ExportsUserTextWithoutLoginOptIn() async throws {
        try await checkDatabasePrompts(v2: false)
    }

    func testOpenCodeSQLiteV2ExportsUserTextWithoutLoginOptIn() async throws {
        try await checkDatabasePrompts(v2: true)
    }

    func testOpenCodeFullDatabaseRequiresLoginOptInAndCopiesWAL() async throws {
        let db = try database(v2: true)
        defer { sqlite3_close(db) }
        let engine = BackupEngine(applicationSupport: root.appending(path: "support"))
        var full = set(.opencode, promptsOnly: false)
        let omitted = try await engine.snapshot(full)
        XCTAssertFalse(omitted.manifest.entries.contains { $0.path == "opencode.db" })
        full.includeLogins = true
        let included = try await engine.snapshot(full)
        XCTAssertTrue(included.manifest.skipped.isEmpty)
        let copied = included.folder.appending(path: "files/opencode.db")
        XCTAssertEqual(try XCTUnwrap(included.manifest.entries.first { $0.path == "opencode.db" }).size,
            Int64(try XCTUnwrap(copied.resourceValues(forKeys: [.fileSizeKey]).fileSize)))
        let output = root.appending(path: "restore")
        let result = try await engine.restore(included, set: full, to: output)
        XCTAssertEqual(result.restored, 1)
        var snapshotDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(output.appending(path: "opencode.db").path, &snapshotDB, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(snapshotDB) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(snapshotDB, "SELECT count(*) FROM session_v2", -1, &statement, nil), SQLITE_OK,
            "SQLite extended code \(sqlite3_extended_errcode(snapshotDB)), system code \(sqlite3_system_errno(snapshotDB))")
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1, "Snapshot must include rows still in the live WAL")
        var journal: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA journal_mode", -1, &journal, nil), SQLITE_OK)
        defer { sqlite3_finalize(journal) }
        XCTAssertEqual(sqlite3_step(journal), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_text(journal, 0).map { String(cString: $0) }, "wal", "Snapshot must not change the live journal mode")
        XCTAssertTrue(BackupPresets.isLogin("opencode.db"))
    }
}
