import CSQLite
import Foundation

struct SQLiteImportSummary {
    var excludedThreadCount: Int
    var unresolvedDatabaseOnlyThreadCount: Int
    var preservedProjection: Bool
}

enum SQLiteSupport {
    static func snapshot(source: URL, destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        do {
            try performSnapshot(source: source, destination: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func performSnapshot(source: URL, destination: URL) throws {
        var sourceDB: OpaquePointer?
        var destinationDB: OpaquePointer?
        guard sqlite3_open_v2(source.path, &sourceDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw sqliteError(sourceDB, "Could not open source database") }
        defer { sqlite3_close(sourceDB) }
        guard sqlite3_open_v2(destination.path, &destinationDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else { throw sqliteError(destinationDB, "Could not create database snapshot") }
        defer { sqlite3_close(destinationDB) }
        guard let backup = sqlite3_backup_init(destinationDB, "main", sourceDB, "main") else { throw sqliteError(destinationDB, "Could not start database snapshot") }
        defer { sqlite3_backup_finish(backup) }
        var retries = 0
        while true {
            let result = sqlite3_backup_step(backup, 256)
            if result == SQLITE_DONE { break }
            if result == SQLITE_OK { continue }
            if result == SQLITE_BUSY || result == SQLITE_LOCKED, retries < 5 {
                retries += 1
                sqlite3_sleep(100)
                continue
            }
            throw sqliteError(destinationDB, "Database snapshot failed")
        }
        guard quickCheck(destinationDB) else { throw AIManagerError.operationFailed("Database snapshot failed its integrity check.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    @discardableResult
    static func rebaseRecognizedRolloutPaths(
        database: URL,
        sourceHome: URL,
        destinationHome: URL,
        transcriptDestinations: [String: String],
        projectionDatabase: URL?
    ) throws -> SQLiteImportSummary {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw sqliteError(db, "Could not open database snapshot") }
        defer { sqlite3_close(db) }
        let threadColumns = tableColumns(db, table: "threads")
        if threadColumns.isSuperset(of: ["id", "rollout_path"]) {
            let summary = try rebaseThreadPaths(
                db,
                sourceHome: sourceHome,
                destinationHome: destinationHome,
                transcriptDestinations: transcriptDestinations,
                hasHistoryMode: threadColumns.contains("history_mode"),
                projectionDatabase: projectionDatabase
            )
            guard quickCheck(db) else { throw AIManagerError.operationFailed("Updated database failed its integrity check.") }
            return summary
        } else if isRecognizedThreadHistoryProjection(db) {
            // This database stores a rebuildable projection keyed by thread IDs and
            // byte offsets. It has no filesystem paths that can safely be rewritten.
            guard quickCheck(db) else { throw AIManagerError.operationFailed("Preserved database failed its integrity check.") }
            return .init(excludedThreadCount: 0, unresolvedDatabaseOnlyThreadCount: 0, preservedProjection: true)
        } else {
            throw AIManagerError.unsupportedSource("unrecognized Codex database schema")
        }
    }

    private static func rebaseThreadPaths(
        _ db: OpaquePointer?,
        sourceHome: URL,
        destinationHome: URL,
        transcriptDestinations: [String: String],
        hasHistoryMode: Bool,
        projectionDatabase: URL?
    ) throws -> SQLiteImportSummary {
        var select: OpaquePointer?
        let historyMode = hasHistoryMode ? "history_mode" : "'legacy'"
        guard sqlite3_prepare_v2(db, "SELECT rowid, id, rollout_path, \(historyMode) FROM threads", -1, &select, nil) == SQLITE_OK else {
            throw sqliteError(db, "Could not inspect recognized rollout paths")
        }
        defer { sqlite3_finalize(select) }
        var projectionDB: OpaquePointer?
        var projection: OpaquePointer?
        if let projectionDatabase {
            guard sqlite3_open_v2(projectionDatabase.path, &projectionDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                throw sqliteError(projectionDB, "Could not open history projection snapshot")
            }
            guard isRecognizedThreadHistoryProjection(projectionDB) else {
                sqlite3_close(projectionDB)
                throw AIManagerError.unsupportedSource("unrecognized Codex history projection schema")
            }
            let sql = "SELECT EXISTS(SELECT 1 FROM thread_items WHERE thread_id = ?1), EXISTS(SELECT 1 FROM thread_turns WHERE thread_id = ?1)"
            guard sqlite3_prepare_v2(projectionDB, sql, -1, &projection, nil) == SQLITE_OK else {
                let error = sqliteError(projectionDB, "Could not inspect paginated thread history")
                sqlite3_close(projectionDB)
                throw error
            }
        }
        defer {
            sqlite3_finalize(projection)
            sqlite3_close(projectionDB)
        }
        var replacements: [(Int64, String)] = []
        var deletions: [Int64] = []
        var unresolvedDatabaseOnly = 0
        while sqlite3_step(select) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(select, 0)
            guard let idValue = sqlite3_column_text(select, 1) else { throw AIManagerError.unsupportedSource("unreadable thread identity") }
            let threadID = String(cString: idValue)
            let oldPath = sqlite3_column_text(select, 2).map(String.init(cString:))
            let mode = sqlite3_column_text(select, 3).map { String(cString: $0).lowercased() } ?? "legacy"

            if let retainedRelative = transcriptDestinations[threadID] {
                let relative = try validatedTranscriptRelativePath(retainedRelative)
                replacements.append((rowID, destinationHome.appending(path: relative).standardizedFileURL.path))
            } else if mode == "paginated", hasCompleteProjection(projection, threadID: threadID),
                      let oldPath, let relative = recognizedTranscriptRelativePath(oldPath, sourceHome: sourceHome),
                      !sourceTranscriptExists(relative, sourceHome: sourceHome) {
                deletions.append(rowID)
                unresolvedDatabaseOnly += 1
            } else if mode == "paginated", hasCompleteProjection(projection, threadID: threadID), oldPath == nil || oldPath?.isEmpty == true {
                deletions.append(rowID)
                unresolvedDatabaseOnly += 1
            } else {
                deletions.append(rowID)
            }
        }

        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw sqliteError(db, "Could not start rollout path update") }
        do {
            var update: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE threads SET rollout_path = ?1 WHERE rowid = ?2", -1, &update, nil) == SQLITE_OK else {
                throw sqliteError(db, "Could not prepare rollout path update")
            }
            defer { sqlite3_finalize(update) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (rowID, newPath) in replacements {
                sqlite3_reset(update)
                sqlite3_clear_bindings(update)
                sqlite3_bind_text(update, 1, newPath, -1, transient)
                sqlite3_bind_int64(update, 2, rowID)
                guard sqlite3_step(update) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                    throw sqliteError(db, "A recognized rollout path was not updated")
                }
            }
            var delete: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM threads WHERE rowid = ?1", -1, &delete, nil) == SQLITE_OK else {
                throw sqliteError(db, "Could not prepare invalid thread removal")
            }
            defer { sqlite3_finalize(delete) }
            for rowID in deletions {
                sqlite3_reset(delete)
                sqlite3_clear_bindings(delete)
                sqlite3_bind_int64(delete, 1, rowID)
                guard sqlite3_step(delete) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
                    throw sqliteError(db, "An invalid thread row was not removed")
                }
            }
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw sqliteError(db, "Could not commit rollout path update") }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
        return .init(
            excludedThreadCount: deletions.count - unresolvedDatabaseOnly,
            unresolvedDatabaseOnlyThreadCount: unresolvedDatabaseOnly,
            preservedProjection: false
        )
    }

    private static func recognizedTranscriptRelativePath(_ oldPath: String, sourceHome: URL) -> String? {
        let standardizedSource = sourceHome.standardizedFileURL.path
        let relative: String
        if oldPath.hasPrefix(standardizedSource + "/") {
            relative = String(oldPath.dropFirst(standardizedSource.count + 1))
        } else if let range = oldPath.range(of: "/archived_sessions/") {
            relative = "archived_sessions/" + oldPath[range.upperBound...]
        } else if let range = oldPath.range(of: "/sessions/") {
            relative = "sessions/" + oldPath[range.upperBound...]
        } else {
            return nil
        }
        return try? validatedTranscriptRelativePath(relative)
    }

    private static func validatedTranscriptRelativePath(_ relative: String) throws -> String {
        guard CoreSupport.safeRelativePath(relative),
              relative.hasPrefix("sessions/") || relative.hasPrefix("archived_sessions/") else { throw AIManagerError.unsafePath(relative) }
        return relative
    }

    private static func sourceTranscriptExists(_ relative: String, sourceHome: URL) -> Bool {
        let transcript = sourceHome.appending(path: relative)
        let values = try? transcript.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    private static func hasCompleteProjection(_ statement: OpaquePointer?, threadID: String) -> Bool {
        guard let statement else { return false }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, threadID, -1, transient)
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 1 && sqlite3_column_int(statement, 1) == 1
    }

    private static func isRecognizedThreadHistoryProjection(_ db: OpaquePointer?) -> Bool {
        let schemas: [String: Set<String>] = [
            "_sqlx_migrations": ["version", "description", "installed_on", "success", "checksum", "execution_time"],
            "thread_items": ["thread_id", "turn_id", "item_id", "rollout_ordinal", "created_at_ms", "item_json", "item_type", "updated_at_ordinal"],
            "thread_turns": ["thread_id", "turn_id", "rollout_ordinal", "status", "error_json", "started_at", "completed_at", "duration_ms", "first_user_item_id", "final_agent_item_id", "rollout_byte_offset", "rollout_end_ordinal", "rollout_end_byte_offset"],
            "thread_history_projection_state": ["thread_id", "next_rollout_byte_offset", "next_rollout_ordinal"],
            "thread_realtime_items": ["thread_id", "item_id", "rollout_ordinal", "created_at_ms", "item_type", "item_json"]
        ]
        return schemas.allSatisfy { tableColumns(db, table: $0.key).isSuperset(of: $0.value) }
    }

    private static func tableColumns(_ db: OpaquePointer?, table: String) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var result = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW, let name = sqlite3_column_text(statement, 1) {
            result.insert(String(cString: name))
        }
        return result
    }

    private static func quickCheck(_ db: OpaquePointer?) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_text(statement, 0).map { String(cString: $0) == "ok" } == true
    }

    private static func sqliteError(_ db: OpaquePointer?, _ prefix: String) -> AIManagerError {
        .operationFailed("\(prefix): \(db.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "SQLite error")")
    }
}
