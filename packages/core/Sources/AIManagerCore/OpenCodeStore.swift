import CSQLite
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// OpenCode's JSON store and its SQLite successors share session identities.
enum OpenCodeStore {
    struct Session {
        let id: String
        let title: String
        let project: String
        let updatedAt: Date
        let path: String
        let companions: [String]
        let bytes: Int64
        let fingerprint: String
        let prompts: [ChatMessage]
        let database: Bool
    }

    static func sessions(home: URL, includePrompts: Bool = false) throws -> [Session] {
        let home = CoreSupport.canonical(home)
        let database = home.appending(path: "opencode.db")
        if CoreSupport.entryExists(database) {
            return try connection(database) { db in
                try execute(db, "BEGIN")
                defer { try? execute(db, "ROLLBACK") }
                let tables = try sessionTables(db)
                var found: [String: Session] = [:]
                // V2 wins when a migration leaves both generations under the same identity.
                for table in tables {
                    for row in try rows(db, table: table) {
                        guard let id = row.text("id"), safeComponent(id) else { throw AIManagerError.sourceChanged }
                        let saved = try sessionRows(db, id: id)
                        let data = try encoded(saved)
                        found[id] = Session(id: id, title: row.text("title") ?? id,
                            project: row.text("directory") ?? "No project",
                            updatedAt: milliseconds(row.number("time_updated") ?? 0), path: "opencode.db",
                            companions: [], bytes: Int64(data.count), fingerprint: CoreSupport.digest(data),
                            prompts: includePrompts ? try prompts(db, id: id, v2: table == "session_v2") : [], database: true)
                    }
                }
                return found.values.sorted { $0.id < $1.id }
            }
        }
        return try jsonSessions(home: home, includePrompts: includePrompts)
    }

    static func fingerprint(database: URL, id: String) throws -> String? {
        try connection(database) { db in
            try execute(db, "BEGIN")
            defer { try? execute(db, "ROLLBACK") }
            return try fingerprint(db, id: id)
        }
    }

    /// A reserved writer lock keeps the reviewed rows stable while the consistent backup is made.
    static func delete(database: URL, ids: [String], expected: [String: String], backup: URL) throws {
        guard !ids.isEmpty, Set(ids).count == ids.count, !CoreSupport.entryExists(backup) else {
            throw AIManagerError.sourceChanged
        }
        try connection(database, writable: true) { db in
            // Explicit row removal must never cascade into an unselected child session.
            try execute(db, "PRAGMA foreign_keys=OFF")
            try execute(db, "BEGIN IMMEDIATE")
            do {
                for id in ids {
                    guard let digest = try fingerprint(db, id: id), digest == expected[id] else {
                        throw AIManagerError.sourceChanged
                    }
                }
                try SQLiteSupport.snapshot(source: database, destination: backup)
                for id in ids {
                    guard try fingerprint(database: backup, id: id) == expected[id] else { throw AIManagerError.sourceChanged }
                    for table in try relatedTables(db) {
                        try execute(db, "DELETE FROM \(quoted(table.name)) WHERE \(table.predicate)", value: id)
                    }
                }
                try checkReferences(db)
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
    }

    /// Restore only the saved session rows, so newer sessions in the live database stay intact.
    static func restore(database: URL, ids: [String], backup: URL) throws {
        let saved: [String: [Row]] = try connection(backup) { db in
            var result: [String: [Row]] = [:]
            for id in ids {
                guard try fingerprint(db, id: id) != nil else { throw AIManagerError.sourceChanged }
                result[id] = try sessionRows(db, id: id)
            }
            return result
        }
        try connection(database, writable: true) { db in
            try execute(db, "PRAGMA foreign_keys=OFF")
            try execute(db, "BEGIN IMMEDIATE")
            do {
                for id in ids {
                    guard let savedRows = saved[id] else { throw AIManagerError.sourceChanged }
                    if let live = try fingerprint(db, id: id) {
                        guard live == CoreSupport.digest(try encoded(savedRows)) else { throw AIManagerError.sourceChanged }
                        continue
                    }
                    for row in savedRows {
                        guard try columns(db, table: row.table) == row.columns else { throw AIManagerError.sourceChanged }
                        let markers = Array(repeating: "?", count: row.values.count).joined(separator: ",")
                        let sql = "INSERT INTO \(quoted(row.table))(\(row.columns.map(quoted).joined(separator: ","))) VALUES(\(markers))"
                        let statement = try prepare(db, sql)
                        defer { sqlite3_finalize(statement) }
                        for (index, value) in row.values.enumerated() { try bind(value, to: statement, index: Int32(index + 1), db: db) }
                        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(db) }
                    }
                }
                try checkReferences(db)
                try execute(db, "COMMIT")
            } catch {
                try? execute(db, "ROLLBACK")
                throw error
            }
        }
    }

    private enum Value: Codable {
        case null, integer(Int64), real(Double), text(Data), blob(Data)
    }

    private struct Row: Codable {
        let table: String
        let columns: [String]
        let values: [Value]
        func text(_ column: String) -> String? {
            guard let index = columns.firstIndex(of: column), case .text(let text) = values[index] else { return nil }
            return String(data: text, encoding: .utf8)
        }
        func number(_ column: String) -> Double? {
            guard let index = columns.firstIndex(of: column) else { return nil }
            switch values[index] {
            case .integer(let number): return Double(number)
            case .real(let number): return number
            default: return nil
            }
        }
    }

    private static func encoded(_ rows: [Row]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sorted = try rows.map { try encoder.encode($0) }.sorted { $0.lexicographicallyPrecedes($1) }
        return try encoder.encode(sorted)
    }

    private static func fingerprint(_ db: OpaquePointer?, id: String) throws -> String? {
        let exists = try sessionTables(db).contains { !(try rows(db, table: $0, predicate: "id = ?", value: id)).isEmpty }
        return try exists ? CoreSupport.digest(encoded(sessionRows(db, id: id))) : nil
    }

    private static func sessionRows(_ db: OpaquePointer?, id: String) throws -> [Row] {
        try relatedTables(db).flatMap { try rows(db, table: $0.name, predicate: $0.predicate, value: id) }
    }

    private static func sessionTables(_ db: OpaquePointer?) throws -> [String] {
        let found = try ["session", "session_v2"].filter {
            Set(try columns(db, table: $0)).isSuperset(of: ["id", "directory", "time_updated"])
        }
        guard !found.isEmpty else { throw AIManagerError.unsupportedSource("Unrecognized OpenCode session database.") }
        return found
    }

    private static func relatedTables(_ db: OpaquePointer?) throws -> [(name: String, predicate: String)] {
        let sessions = try sessionTables(db)
        let statement = try prepare(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        defer { sqlite3_finalize(statement) }
        var result: [(name: String, predicate: String)] = []
        while true {
            let state = sqlite3_step(statement)
            if state == SQLITE_DONE { break }
            guard state == SQLITE_ROW else { throw failure(db) }
            let name = String(cString: sqlite3_column_text(statement, 0))
            let names = try columns(db, table: name)
            let predicate: String
            if sessions.contains(name) { predicate = "id = ?" }
            else if names.contains("session_id") { predicate = "session_id = ?" }
            else if names.contains("message_id"), try columns(db, table: "message").contains("session_id") {
                predicate = "message_id IN (SELECT id FROM message WHERE session_id = ?)"
            } else { continue }
            let triggers = try prepare(db, "SELECT 1 FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ?")
            defer { sqlite3_finalize(triggers) }
            try bind(.text(Data(name.utf8)), to: triggers, index: 1, db: db)
            guard sqlite3_step(triggers) == SQLITE_DONE else {
                throw AIManagerError.unsupportedSource("OpenCode session tables with triggers cannot be changed safely.")
            }
            result.append((name, predicate))
        }
        // A message-only child predicate needs the message rows to remain until its children are gone.
        return result.sorted { left, right in
            func rank(_ name: String) -> Int { sessions.contains(name) ? 2 : name == "message" ? 1 : 0 }
            return rank(left.name) == rank(right.name) ? left.name < right.name : rank(left.name) < rank(right.name)
        }
    }

    private static func rows(_ db: OpaquePointer?, table: String, predicate: String? = nil, value: String? = nil) throws -> [Row] {
        let names = try columns(db, table: table)
        guard !names.isEmpty else { return [] }
        let statement = try prepare(db, "SELECT * FROM \(quoted(table))\(predicate.map { " WHERE " + $0 } ?? "") LIMIT 2000001")
        defer { sqlite3_finalize(statement) }
        if let value { try bind(.text(Data(value.utf8)), to: statement, index: 1, db: db) }
        var result: [Row] = []
        while true {
            try Task.checkCancellation()
            let state = sqlite3_step(statement)
            if state == SQLITE_DONE { return result }
            guard state == SQLITE_ROW else { throw failure(db) }
            guard result.count < 2_000_000 else { throw AIManagerError.operationFailed("OpenCode has too many rows to scan.") }
            let values: [Value] = (0..<sqlite3_column_count(statement)).map { index in
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    return .text(Data(bytes: sqlite3_column_text(statement, index), count: Int(sqlite3_column_bytes(statement, index))))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    return .blob(sqlite3_column_blob(statement, index).map { Data(bytes: $0, count: count) } ?? Data())
                default: return .null
                }
            }
            result.append(Row(table: table, columns: names, values: values))
        }
    }

    private static func prompts(_ db: OpaquePointer?, id: String, v2: Bool) throws -> [ChatMessage] {
        let table = v2 ? "session_message" : "message"
        guard try columns(db, table: table).contains("session_id") else { return [] }
        var result: [ChatMessage] = []
        for row in try rows(db, table: table, predicate: "session_id = ?", value: id) {
            guard let json = row.text("data"), let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                throw AIManagerError.sourceChanged
            }
            guard (v2 ? row.text("type") : object["role"] as? String) == "user",
                  object["synthetic"] as? Bool != true, object["ignored"] as? Bool != true else { continue }
            let text: String
            if v2 { text = object["text"] as? String ?? "" }
            else {
                guard let messageID = row.text("id") else { throw AIManagerError.sourceChanged }
                text = try rows(db, table: "part", predicate: "message_id = ?", value: messageID)
                    .sorted { ($0.text("id") ?? "") < ($1.text("id") ?? "") }
                    .compactMap { part -> String? in
                        guard let data = part.text("data"), let object = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { throw AIManagerError.sourceChanged }
                        return promptText(object)
                    }.joined(separator: "\n")
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !ChatTitlePolicy.isBootstrapContext(text) {
                result.append(ChatMessage(id: row.text("id") ?? String(result.count), role: .user, text: text,
                    timestamp: date((object["time"] as? [String: Any])?["created"]) ?? row.number("time_created").map(milliseconds)))
            }
        }
        return result.sorted { ($0.timestamp ?? .distantPast, $0.id) < ($1.timestamp ?? .distantPast, $1.id) }
    }

    private static func promptText(_ object: [String: Any]) -> String? {
        guard object["type"] as? String == "text", object["synthetic"] as? Bool != true,
              object["ignored"] as? Bool != true, let text = object["text"] as? String,
              !ChatTitlePolicy.isBootstrapContext(text) else { return nil }
        return text
    }

    private static func milliseconds(_ value: Double) -> Date { Date(timeIntervalSince1970: value / 1_000) }
    private static func date(_ value: Any?) -> Date? {
        if let number = value as? Double { return milliseconds(number) }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func jsonSessions(home: URL, includePrompts: Bool) throws -> [Session] {
        var result: [Session] = []
        let projects: [String]
        do { projects = try names(home, "storage/session") }
        catch AIManagerError.unsafePath(_) where !includePrompts { return [] }
        for project in projects {
            let filenames: [String]
            do { filenames = try names(home, "storage/session/" + project) }
            catch AIManagerError.unsafePath(_) where !includePrompts { continue }
            for filename in filenames where filename.hasSuffix(".json") {
                do {
                    let path = "storage/session/\(project)/\(filename)"
                    let data = try read(home, path)
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let id = object["id"] as? String, safeComponent(id), filename == id + ".json" else { throw AIManagerError.sourceChanged }
                    var companions: [String] = []
                    var messages: [ChatMessage] = []
                    var bytes = Int64(data.count)
                    var pieces = [CoreSupport.digest(data)]
                    let messagePath = "storage/message/" + id
                    if CoreSupport.entryExists(home.appending(path: messagePath)) { companions.append(messagePath) }
                    for messageFile in try names(home, messagePath) where messageFile.hasSuffix(".json") {
                        let messageData = try read(home, messagePath + "/" + messageFile)
                        pieces.append(CoreSupport.digest(messageData)); bytes += Int64(messageData.count)
                        guard let message = try JSONSerialization.jsonObject(with: messageData) as? [String: Any],
                              let messageID = message["id"] as? String, safeComponent(messageID), messageFile == messageID + ".json",
                              message["sessionID"] as? String == id else { throw AIManagerError.sourceChanged }
                        let partPath = "storage/part/" + messageID
                        if CoreSupport.entryExists(home.appending(path: partPath)) { companions.append(partPath) }
                        var text: [String] = []
                        for partFile in try names(home, partPath) where partFile.hasSuffix(".json") {
                            let partData = try read(home, partPath + "/" + partFile)
                            pieces.append(CoreSupport.digest(partData)); bytes += Int64(partData.count)
                            guard let part = try JSONSerialization.jsonObject(with: partData) as? [String: Any],
                                  part["sessionID"] as? String == id, part["messageID"] as? String == messageID else { throw AIManagerError.sourceChanged }
                            if includePrompts, message["role"] as? String == "user", let value = promptText(part) { text.append(value) }
                        }
                        let prompt = text.joined(separator: "\n")
                        if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           message["synthetic"] as? Bool != true, message["ignored"] as? Bool != true {
                            messages.append(ChatMessage(id: messageID, role: .user, text: prompt,
                                timestamp: date((message["time"] as? [String: Any])?["created"])))
                        }
                    }
                    for extra in ["storage/session_diff/\(id).json", "storage/share/\(id).json"] where CoreSupport.entryExists(home.appending(path: extra)) {
                        let extraData = try read(home, extra)
                        companions.append(extra); pieces.append(CoreSupport.digest(extraData)); bytes += Int64(extraData.count)
                    }
                    result.append(Session(id: id, title: object["title"] as? String ?? id,
                        project: object["directory"] as? String ?? "No project",
                        updatedAt: date((object["time"] as? [String: Any])?["updated"]) ?? .distantPast,
                        path: path, companions: companions, bytes: bytes, fingerprint: CoreSupport.digest(Data(pieces.joined(separator: "\n").utf8)),
                        prompts: messages.sorted { ($0.timestamp ?? .distantPast, $0.id) < ($1.timestamp ?? .distantPast, $1.id) }, database: false))
                } catch AIManagerError.unsafePath(_) where !includePrompts {
                    continue
                }
            }
        }
        return result
    }

    private static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }

    private static func names(_ home: URL, _ path: String) throws -> [String] {
        let url = home.appending(path: path)
        guard CoreSupport.entryExists(url) else { return [] }
        try validate(url, within: home, directory: true)
        return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    private static func read(_ home: URL, _ path: String) throws -> Data {
        let url = home.appending(path: path)
        try validate(url, within: home)
        var before = stat()
        guard lstat(url.path, &before) == 0 else { throw AIManagerError.sourceChanged }
        let data = try Data(contentsOf: url)
        var after = stat()
        guard lstat(url.path, &after) == 0, before.st_ino == after.st_ino, before.st_size == after.st_size,
              CleanupScanner.modified(before) == CleanupScanner.modified(after) else { throw AIManagerError.sourceChanged }
        return data
    }

    private static func validate(_ url: URL, within home: URL, directory: Bool = false) throws {
        guard url.path == home.path || url.path.hasPrefix(home.path + "/") else { throw AIManagerError.sourceChanged }
        var cursor = url
        var first = true
        while true {
            var info = stat()
            guard lstat(cursor.path, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & S_IFMT == (first && !directory ? S_IFREG : S_IFDIR),
                  !first || directory || info.st_nlink == 1 else {
                throw AIManagerError.unsafePath("OpenCode contains a linked, missing, or foreign-owned entry.")
            }
            if cursor.path == home.path { return }
            cursor.deleteLastPathComponent(); first = false
        }
    }

    private static func connection<T>(_ database: URL, writable: Bool = false, _ body: (OpaquePointer?) throws -> T) throws -> T {
        let parent = database.deletingLastPathComponent()
        guard CoreSupport.canonical(parent).path == parent.standardizedFileURL.path else { throw AIManagerError.sourceChanged }
        try validate(database, within: parent)
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: database.path + suffix)
            if CoreSupport.entryExists(sidecar) { try validate(sidecar, within: parent) }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let error = failure(db); sqlite3_close(db); throw error
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1_000)
        try execute(db, "PRAGMA trusted_schema=OFF")
        if !writable { try execute(db, "PRAGMA query_only=ON") }
        return try body(db)
    }

    private static func columns(_ db: OpaquePointer?, table: String) throws -> [String] {
        let statement = try prepare(db, "PRAGMA table_info(\(quoted(table)))")
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            let state = sqlite3_step(statement)
            if state == SQLITE_DONE { return result }
            guard state == SQLITE_ROW else { throw failure(db) }
            result.append(String(cString: sqlite3_column_text(statement, 1)))
        }
    }

    private static func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    private static func prepare(_ db: OpaquePointer?, _ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure(db) }
        return statement
    }

    private static func bind(_ value: Value, to statement: OpaquePointer?, index: Int32, db: OpaquePointer?) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let state: Int32
        switch value {
        case .null: state = sqlite3_bind_null(statement, index)
        case .integer(let number): state = sqlite3_bind_int64(statement, index, number)
        case .real(let number): state = sqlite3_bind_double(statement, index, number)
        case .text(let data):
            guard data.count <= Int32.max else { throw AIManagerError.sourceChanged }
            state = data.isEmpty ? sqlite3_bind_text(statement, index, "", 0, transient) : data.withUnsafeBytes {
                sqlite3_bind_text(statement, index, $0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32($0.count), transient)
            }
        case .blob(let data):
            guard data.count <= Int32.max else { throw AIManagerError.sourceChanged }
            state = data.isEmpty ? sqlite3_bind_zeroblob(statement, index, 0) : data.withUnsafeBytes {
                sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient)
            }
        }
        guard state == SQLITE_OK else { throw failure(db) }
    }

    private static func execute(_ db: OpaquePointer?, _ sql: String, value: String? = nil) throws {
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        if let value { try bind(.text(Data(value.utf8)), to: statement, index: 1, db: db) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(db) }
    }

    private static func checkReferences(_ db: OpaquePointer?) throws {
        let statement = try prepare(db, "PRAGMA foreign_key_check")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AIManagerError.operationFailed("OpenCode has database references that prevent this change.")
        }
    }

    private static func failure(_ db: OpaquePointer?) -> AIManagerError {
        // SQLite diagnostics may include stored values, so report only its numeric result.
        .operationFailed("OpenCode database operation failed (\(sqlite3_errcode(db))).")
    }
}
