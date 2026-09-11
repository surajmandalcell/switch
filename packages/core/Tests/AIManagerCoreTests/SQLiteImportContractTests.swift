import CSQLite
import Foundation
import XCTest
@testable import AIManagerCore

final class SQLiteImportContractTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSnapshotKeepsWALAndImportsOnlyUsableThreadRows() throws {
        let sourceHome = root.appending(path: "source")
        let sourceTranscript = sourceHome.appending(path: "sessions/old/valid.jsonl")
        try FileManager.default.createDirectory(at: sourceTranscript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: sourceTranscript)
        let collisionTranscript = sourceHome.appending(path: "sessions/collision.jsonl")
        try Data("{}\n".utf8).write(to: collisionTranscript)
        let source = sourceHome.appending(path: "state_5.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        try execute(db, """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT, history_mode TEXT);
            INSERT INTO threads VALUES
                ('valid', '\(sourceTranscript.path)', 'legacy'),
                ('orphan', '\(sourceHome.appending(path: "sessions/missing-orphan.jsonl").path)', 'legacy'),
                ('database-only', '\(sourceHome.appending(path: "sessions/missing-paginated.jsonl").path)', 'paginated'),
                ('partial', '\(sourceHome.appending(path: "sessions/missing-partial.jsonl").path)', 'paginated'),
                ('null-database-only', NULL, 'paginated'),
                ('collision', '\(collisionTranscript.path)', 'paginated');
            """)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path + "-wal"))

        let snapshot = root.appending(path: "snapshot.sqlite")
        try SQLiteSupport.snapshot(source: source, destination: snapshot)
        let projectionSource = sourceHome.appending(path: "thread_history_1.sqlite")
        try createProjectionDatabase(projectionSource)
        var projectionDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(projectionSource.path, &projectionDB), SQLITE_OK)
        try execute(projectionDB, """
            INSERT INTO thread_items(thread_id) VALUES ('database-only'), ('partial'), ('null-database-only'), ('collision');
            INSERT INTO thread_turns(thread_id) VALUES ('database-only'), ('null-database-only'), ('collision');
            """)
        sqlite3_close(projectionDB)
        let projectionSnapshot = root.appending(path: "projection-snapshot.sqlite")
        try SQLiteSupport.snapshot(source: projectionSource, destination: projectionSnapshot)
        let destinationHome = root.appending(path: "destination")
        let occupiedDestination = destinationHome.appending(path: "sessions/collision.jsonl")
        try FileManager.default.createDirectory(at: occupiedDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("different thread\n".utf8).write(to: occupiedDestination)
        let summary = try SQLiteSupport.rebaseRecognizedRolloutPaths(
            database: snapshot,
            sourceHome: sourceHome,
            destinationHome: destinationHome,
            transcriptDestinations: ["valid": "sessions/retained/renamed.jsonl"],
            projectionDatabase: projectionSnapshot
        )

        XCTAssertEqual(summary.excludedThreadCount, 3)
        XCTAssertEqual(summary.unresolvedDatabaseOnlyThreadCount, 2)
        XCTAssertFalse(summary.preservedProjection)
        XCTAssertEqual(try threadPaths(snapshot), [
            "valid": destinationHome.appending(path: "sessions/retained/renamed.jsonl").path,
        ])
        XCTAssertEqual(try threadPaths(source).keys.sorted(), ["collision", "database-only", "null-database-only", "orphan", "partial", "valid"])
    }

    func testProjectionSnapshotPreservesStoredJSON() throws {
        let source = root.appending(path: "thread_history_1.sqlite")
        try createProjectionDatabase(source)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        try execute(db, "INSERT INTO thread_items VALUES ('thread', 'turn', 'item', 1, 2, '{\"payload\":\"kept\"}', 'message', 3)")
        let snapshot = root.appending(path: "history-snapshot.sqlite")
        try SQLiteSupport.snapshot(source: source, destination: snapshot)

        let summary = try SQLiteSupport.rebaseRecognizedRolloutPaths(
            database: snapshot,
            sourceHome: root,
            destinationHome: root.appending(path: "destination"),
            transcriptDestinations: [:],
            projectionDatabase: nil
        )

        XCTAssertTrue(summary.preservedProjection)
        XCTAssertEqual(try scalarText(snapshot, "SELECT item_json FROM thread_items"), "{\"payload\":\"kept\"}")
    }

    func testFullImportReportsAndBacksUpDatabaseOnlyHistory() async throws {
        let sourceHome = root.appending(path: "source-import")
        try FileManager.default.createDirectory(at: sourceHome, withIntermediateDirectories: true)
        try syntheticAuth().write(to: sourceHome.appending(path: "auth.json"))

        let validID = "018f1f1e-7b8c-7000-8000-000000000001"
        let databaseOnlyID = "018f1f1e-7b8c-7000-8000-000000000002"
        let transcript = sourceHome.appending(path: "sessions/2026/01/01/rollout-\(validID).jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        let meta = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": validID]])
        try (meta + Data([0x0A])).write(to: transcript)

        let state = sourceHome.appending(path: "state_5.sqlite")
        var stateDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(state.path, &stateDB), SQLITE_OK)
        try execute(stateDB, """
            CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT, history_mode TEXT);
            INSERT INTO threads VALUES
                ('\(validID)', '\(transcript.path)', 'legacy'),
                ('\(databaseOnlyID)', NULL, 'paginated');
            """)
        sqlite3_close(stateDB)

        let projection = sourceHome.appending(path: "thread_history_1.sqlite")
        try createProjectionDatabase(projection)
        var projectionDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(projection.path, &projectionDB), SQLITE_OK)
        try execute(projectionDB, """
            INSERT INTO thread_items(thread_id, item_json) VALUES ('\(databaseOnlyID)', '{"payload":"preserved"}');
            INSERT INTO thread_turns(thread_id) VALUES ('\(databaseOnlyID)');
            """)
        sqlite3_close(projectionDB)

        let paths = ManagerPaths(
            applicationSupport: root.appending(path: "manager-support"),
            defaultHome: root.appending(path: "default-home"),
            sharedRoot: root.appending(path: "shared-root"),
            orcaAccountsRoot: root.appending(path: "orca-accounts"),
            codexExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            isolationRoot: root
        )
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive })
        let plan = try await manager.planImport(source: sourceHome, mode: .full)
        let result = try await manager.importAccount(plan: plan)

        let activeState = result.account.home.appending(path: "state_5.sqlite")
        let backupState = result.backup.appending(path: "databases/state_5.sqlite")
        let backupProjection = result.backup.appending(path: "databases/thread_history_1.sqlite")
        XCTAssertEqual(Set(try threadPaths(activeState).keys), [validID])
        XCTAssertEqual(Set(try threadPaths(backupState).keys), [validID, databaseOnlyID])
        XCTAssertEqual(try scalarText(backupProjection, "SELECT item_json FROM thread_items WHERE thread_id = '\(databaseOnlyID)'"), "{\"payload\":\"preserved\"}")
        XCTAssertEqual(Set(try threadPaths(state).keys), [validID, databaseOnlyID])
        XCTAssertTrue(result.unresolved.contains {
            $0.contains("1 database-only paginated histories") && $0.contains(backupState.path)
        })
    }

    private func execute(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteImportContractTests", code: 1, userInfo: [NSLocalizedDescriptionKey: db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error"])
        }
    }

    private func createProjectionDatabase(_ database: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK else { throw NSError(domain: "SQLiteImportContractTests", code: 6) }
        defer { sqlite3_close(db) }
        try execute(db, """
            CREATE TABLE _sqlx_migrations(version INTEGER, description TEXT, installed_on TEXT, success INTEGER, checksum BLOB, execution_time INTEGER);
            CREATE TABLE thread_items(thread_id TEXT, turn_id TEXT, item_id TEXT, rollout_ordinal INTEGER, created_at_ms INTEGER, item_json TEXT, item_type TEXT, updated_at_ordinal INTEGER);
            CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER, status TEXT, error_json TEXT, started_at INTEGER, completed_at INTEGER, duration_ms INTEGER, first_user_item_id TEXT, final_agent_item_id TEXT, rollout_byte_offset INTEGER, rollout_end_ordinal INTEGER, rollout_end_byte_offset INTEGER);
            CREATE TABLE thread_history_projection_state(thread_id TEXT, next_rollout_byte_offset INTEGER, next_rollout_ordinal INTEGER);
            CREATE TABLE thread_realtime_items(thread_id TEXT, item_id TEXT, rollout_ordinal INTEGER, created_at_ms INTEGER, item_type TEXT, item_json TEXT);
            """)
    }

    private func threadPaths(_ database: URL) throws -> [String: String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw NSError(domain: "SQLiteImportContractTests", code: 2) }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, rollout_path FROM threads ORDER BY id", -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "SQLiteImportContractTests", code: 3) }
        defer { sqlite3_finalize(statement) }
        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            result[id] = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "<null>"
        }
        return result
    }

    private func scalarText(_ database: URL, _ sql: String) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw NSError(domain: "SQLiteImportContractTests", code: 4) }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "SQLiteImportContractTests", code: 5) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    private func syntheticAuth() throws -> Data {
        let claims = try JSONSerialization.data(withJSONObject: [
            "email": "history@example.test",
            "chatgpt_account_id": "history-account",
            "workspace_id": "history-workspace",
        ])
        let payload = claims.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "access_token": "synthetic.\(payload).signature",
                "account_id": "history-account",
                "refresh_token": "synthetic",
            ],
        ])
    }
}
