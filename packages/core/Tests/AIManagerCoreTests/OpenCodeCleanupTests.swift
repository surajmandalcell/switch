import Foundation
import CSQLite
import XCTest
@testable import AIManagerCore

final class OpenCodeCleanupTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private let files = FileManager.default
    private let old = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/switch-work1-build-oc/test-data/\(UUID().uuidString)")
        home = root.appending(path: "home/.local/share/opencode")
        try files.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try files.removeItem(at: root) }

    private var database: URL { home.appending(path: "opencode.db") }
    private var source: CleanupSource {
        CleanupSource(id: "opencode", tool: .opencode, title: "OpenCode", detail: "", providerID: ProviderID(rawValue: "opencode"),
            home: home, userHome: root.appending(path: "home"))
    }

    private func sql(_ statement: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK else { throw AIManagerError.sourceChanged }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
            throw AIManagerError.operationFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func count(_ table: String, _ condition: String = "1") throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw AIManagerError.sourceChanged }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM \(table) WHERE \(condition)", -1, &statement, nil) == SQLITE_OK else {
            throw AIManagerError.sourceChanged
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw AIManagerError.sourceChanged }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func seedDatabase(v2: Bool = false) throws {
        let session = v2 ? "session_v2" : "session"
        let message = v2 ? "session_message" : "message"
        try sql("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE \(session)(id TEXT PRIMARY KEY, parent_id TEXT,
                title TEXT, directory TEXT, time_updated INTEGER, time_created INTEGER);
            CREATE TABLE \(message)(id TEXT PRIMARY KEY, session_id TEXT REFERENCES \(session)(id) ON DELETE CASCADE,
                type TEXT, seq INTEGER, time_created INTEGER, time_updated INTEGER, data TEXT);
            CREATE TABLE todo(session_id TEXT REFERENCES \(session)(id) ON DELETE CASCADE, content TEXT, position INTEGER,
                PRIMARY KEY(session_id, position));
            CREATE TABLE credential(id TEXT PRIMARY KEY, data TEXT);
            INSERT INTO credential VALUES('private', 'SYNTHETIC LOGIN');
            INSERT INTO \(session) VALUES('ses_delete', NULL, 'Fix export', '/Projects/One', 1700000000000, 1700000000000);
            INSERT INTO \(session) VALUES('ses_keep', 'ses_delete', 'Keep child', '/Projects/One', 1700000000000, 1700000000000);
            INSERT INTO \(session) VALUES('ses_other', NULL, 'Fix export', '/Projects/Two', 1700000000000, 1700000000000);
            INSERT INTO \(session) VALUES('ses_recent', NULL, 'Fix export', '/Projects/One', 1700086400000, 1700086400000);
            INSERT INTO \(session) VALUES('ses_active', NULL, 'Fix export', '/Projects/One', \(Int64(Date().timeIntervalSince1970 * 1000)), 1700000000000);
            INSERT INTO \(message) VALUES('msg_delete', 'ses_delete', 'user', 1, 1700000000000, 1700000000000,
                '{"role":"user","text":"Owner prompt","time":{"created":1700000000000}}');
            INSERT INTO \(message) VALUES('msg_keep', 'ses_keep', 'user', 1, 1700000000000, 1700000000000,
                '{"role":"user","text":"Keep prompt","time":{"created":1700000000000}}');
            INSERT INTO todo VALUES('ses_delete', 'Selected task', 0);
            INSERT INTO todo VALUES('ses_keep', 'Keep task', 0);
            """)
        if !v2 {
            try sql("""
                CREATE TABLE part(id TEXT PRIMARY KEY, message_id TEXT REFERENCES message(id) ON DELETE CASCADE,
                    session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
                INSERT INTO part VALUES('prt_delete', 'msg_delete', 'ses_delete', 1700000000000, 1700000000000,
                    '{"type":"text","text":"Owner prompt"}');
                INSERT INTO part VALUES('prt_keep', 'msg_keep', 'ses_keep', 1700000000000, 1700000000000,
                    '{"type":"text","text":"Keep prompt"}');
                """)
        }
    }

    private func conversations() throws -> [CleanupItem] {
        try XCTUnwrap(CleanupScanner(source: source, processes: [], openFiles: []).scan()
            .categories.first { $0.id == "conversations" }?.items)
    }

    func testSQLiteFiltersDeleteOnlySelectedRowsAndRestoreWithoutReplacingDatabase() throws {
        for v2 in [false, true] {
            if v2 {
                try files.removeItem(at: database)
            }
            try seedDatabase(v2: v2)
            let session = v2 ? "session_v2" : "session"
            let message = v2 ? "session_message" : "message"
            let items = try conversations()
            let filter = ConversationCleanupFilter(olderThan: old.addingTimeInterval(1), projects: ["/Projects/One"], title: "EXPORT")
            let selected = items.filter(filter.matches)
            XCTAssertEqual(selected.compactMap(\.databaseSessionID), ["ses_delete"])
            XCTAssertEqual(items.first { $0.databaseSessionID == "ses_active" }?.protectedReason, "In use now.")
            let cleanup = ConversationCleanup(home: home, userHome: source.userHome)
            let batch = try cleanup.moveToTrash(cleanup.review(selected))
            XCTAssertEqual(try count(session), 4)
            XCTAssertEqual(try count(message, "session_id = 'ses_delete'"), 0)
            XCTAssertEqual(try count(message, "session_id = 'ses_keep'"), 1)
            XCTAssertEqual(try count("todo"), 1)
            XCTAssertEqual(try count("credential"), 1)
            if !v2 { XCTAssertEqual(try count("part"), 1) }
            XCTAssertEqual(try cleanup.batches().first?.items.count, 1)
            XCTAssertTrue(files.fileExists(atPath: home.appending(path: ".switch-trash/\(batch.id.uuidString)/0/opencode.db").path))
            try sql("UPDATE \(session) SET title = 'New unrelated title' WHERE id = 'ses_other'")
            try cleanup.restore(batch.id)
            XCTAssertEqual(try count(session), 5)
            XCTAssertEqual(try count(session, "title = 'New unrelated title'"), 1)
            XCTAssertEqual(try count(message), 2)
            XCTAssertEqual(try count("todo"), 2)
            XCTAssertEqual(try count("credential"), 1)
            if !v2 { XCTAssertEqual(try count("part"), 2) }
            XCTAssertTrue(try cleanup.batches().isEmpty)
            XCTAssertFalse(files.fileExists(atPath: home.appending(path: ".switch-trash/\(batch.id.uuidString)/0/opencode.db").path))
        }
    }

    func testSQLiteRejectsChangedSessionAndUnsafeDatabase() throws {
        try seedDatabase()
        let item = try XCTUnwrap(conversations().first { $0.databaseSessionID == "ses_delete" })
        let cleanup = ConversationCleanup(home: home, userHome: source.userHome)
        let plan = try cleanup.review([item])
        try sql("UPDATE part SET data = '{\"type\":\"text\",\"text\":\"Changed prompt\"}' WHERE id = 'prt_delete'")
        XCTAssertThrowsError(try cleanup.moveToTrash(plan))
        XCTAssertEqual(try count("session"), 5)
        try files.linkItem(at: database, to: home.appending(path: "linked.db"))
        XCTAssertThrowsError(try cleanup.review([item]))
    }

    func testSQLiteRollbackKeepsEverySelectedSessionAndBackup() throws {
        try seedDatabase()
        try sql("CREATE TABLE external_reference(parent TEXT REFERENCES session(id)); INSERT INTO external_reference VALUES('ses_other')")
        let selected = try conversations().filter { ["ses_delete", "ses_other"].contains($0.databaseSessionID ?? "") }
        let cleanup = ConversationCleanup(home: home, userHome: source.userHome)
        let plan = try cleanup.review(selected)
        XCTAssertThrowsError(try cleanup.moveToTrash(plan))
        XCTAssertEqual(try count("session"), 5)
        XCTAssertEqual(try count("message"), 2)
        XCTAssertEqual(try count("part"), 2)
        XCTAssertTrue(try cleanup.batches().isEmpty)
    }

    func testSQLiteJournalRecoveryCollisionAndPermanentRemoval() throws {
        try seedDatabase(v2: true)
        let item = try XCTUnwrap(conversations().first { $0.databaseSessionID == "ses_delete" })
        let cleanup = ConversationCleanup(home: home, userHome: source.userHome)
        var batch = try cleanup.moveToTrash(cleanup.review([item]))
        let folder = home.appending(path: ".switch-trash/\(batch.id.uuidString)")
        batch.phase = "moving"
        try JSONEncoder().encode(batch).write(to: folder.appending(path: "manifest.json"))
        XCTAssertEqual(try cleanup.batches().first?.items.compactMap(\.databaseSessionID), ["ses_delete"])
        try sql("INSERT INTO session_v2 VALUES('ses_delete', NULL, 'New collision', '/New', 1700000000000, 1700000000000)")
        XCTAssertThrowsError(try cleanup.restore(batch.id))
        XCTAssertEqual(try count("session_v2", "title = 'New collision'"), 1)
        try cleanup.permanentlyRemove(batch.id)
        XCTAssertEqual(try count("session_v2"), 5)
        XCTAssertEqual(try count("credential"), 1)
        XCTAssertFalse(files.fileExists(atPath: folder.appending(path: "0/opencode.db").path))
        XCTAssertTrue(try cleanup.batches().isEmpty)
    }

    private func write(_ path: String, _ object: [String: Any]) throws {
        let url = home.appending(path: path)
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        try files.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    }

    func testJSONFiltersMoveSessionAndCompanionsToExistingTrash() throws {
        for (id, project) in [("ses_delete", "/Projects/One"), ("ses_keep", "/Projects/Two")] {
            try write("storage/session/project/\(id).json", ["id": id, "title": "Fix export", "directory": project,
                "time": ["created": 1_700_000_000_000, "updated": 1_700_000_000_000]])
            try write("storage/message/\(id)/msg_\(id).json", ["id": "msg_\(id)", "sessionID": id, "role": "user"])
            try write("storage/part/msg_\(id)/prt_text.json", ["id": "prt_text", "sessionID": id,
                "messageID": "msg_\(id)", "type": "text", "text": "Synthetic prompt"])
            try write("storage/session_diff/\(id).json", ["synthetic": true])
        }
        try write("auth.json", ["synthetic": "keep"])
        // Creating the child files changes the session directories' dates.
        for path in ["storage/message/ses_delete", "storage/part/msg_ses_delete", "storage/message/ses_keep", "storage/part/msg_ses_keep"] {
            try files.setAttributes([.modificationDate: old], ofItemAtPath: home.appending(path: path).path)
        }
        let selected = try conversations().filter(ConversationCleanupFilter(olderThan: old.addingTimeInterval(1), projects: ["/Projects/One"], title: "export").matches)
        XCTAssertEqual(selected.map(\.path), ["storage/session/project/ses_delete.json"])
        let cleanup = ConversationCleanup(home: home, userHome: source.userHome)
        let batch = try cleanup.moveToTrash(cleanup.review(selected))
        for path in ["storage/session/project/ses_delete.json", "storage/message/ses_delete", "storage/part/msg_ses_delete", "storage/session_diff/ses_delete.json"] {
            XCTAssertFalse(files.fileExists(atPath: home.appending(path: path).path), path)
        }
        for path in ["storage/session/project/ses_keep.json", "storage/message/ses_keep", "storage/part/msg_ses_keep", "auth.json"] {
            XCTAssertTrue(files.fileExists(atPath: home.appending(path: path).path), path)
        }
        try cleanup.restore(batch.id)
        XCTAssertEqual(try conversations().count, 2)
    }

    func testSourcesExposeBothBackupServicesAndOpenCodeFilter() throws {
        try files.createDirectory(at: source.userHome.appending(path: ".copilot"), withIntermediateDirectories: true)
        let paths = ManagerPaths(applicationSupport: root.appending(path: "support"), credentialStore: root.appending(path: "vault"),
            defaultHome: source.userHome.appending(path: ".codex"), sharedRoot: source.userHome.appending(path: ".codex"),
            orcaAccountsRoot: root.appending(path: "orca"), codexExecutable: URL(fileURLWithPath: "/usr/bin/true"), isolationRoot: source.userHome)
        let sources = CleanupSources.make(paths: paths, accounts: [])
        XCTAssertEqual(sources.first { $0.tool == .opencode }?.backupService, .opencode)
        XCTAssertEqual(sources.first { $0.tool == .copilot }?.backupService, .copilot)
    }

    func testLinkedJSONSessionsDoNotHideSafeSessionsOrEnterPromptBackup() throws {
        for id in ["ses_safe", "ses_link"] {
            try write("storage/session/project/\(id).json", ["id": id, "title": "Fix export", "directory": "/Projects/One",
                "time": ["updated": 1_700_000_000_000]])
            try write("storage/message/\(id)/msg_\(id).json", ["id": "msg_\(id)", "sessionID": id, "role": "user"])
        }
        try write("storage/part/msg_ses_safe/prt_text.json", ["id": "prt_text", "sessionID": "ses_safe",
            "messageID": "msg_ses_safe", "type": "text", "text": "Synthetic safe prompt"])
        let outside = root.appending(path: "private.json")
        try Data("PRIVATE SYNTHETIC CONTENT".utf8).write(to: outside)
        let linkedParts = home.appending(path: "storage/part/msg_ses_link")
        try files.createDirectory(at: linkedParts, withIntermediateDirectories: true)
        try files.createSymbolicLink(at: linkedParts.appending(path: "prt_text.json"), withDestinationURL: outside)
        try files.createSymbolicLink(at: home.appending(path: "storage/session/linked-project"), withDestinationURL: root)
        for path in ["storage/message/ses_safe", "storage/part/msg_ses_safe", "storage/message/ses_link", "storage/part/msg_ses_link"] {
            try files.setAttributes([.modificationDate: old], ofItemAtPath: home.appending(path: path).path)
        }
        let selected = try conversations().filter(ConversationCleanupFilter().matches)
        XCTAssertEqual(selected.map(\.path), ["storage/session/project/ses_safe.json"])
        XCTAssertThrowsError(try OpenCodeStore.sessions(home: home, includePrompts: true))
        let cleanup = ConversationCleanup(home: home, userHome: source.userHome)
        _ = try cleanup.moveToTrash(cleanup.review(selected))
        XCTAssertTrue(files.fileExists(atPath: home.appending(path: "storage/session/project/ses_link.json").path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("PRIVATE SYNTHETIC CONTENT".utf8))
    }
}
