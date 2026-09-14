import CSQLite
import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct CodexUsageStatisticsCachePolicy: Sendable, Equatable {
    public let retention: TimeInterval
    public let staleAfter: TimeInterval
    public let maximumSamplesPerAccount: Int
    public let maximumTotalSamples: Int
    public let maximumAccounts: Int
    public let maximumSnapshotBytes: Int

    public init(
        retention: TimeInterval = 30 * 24 * 60 * 60,
        staleAfter: TimeInterval = 15 * 60,
        maximumSamplesPerAccount: Int = 96,
        maximumTotalSamples: Int = 2_048,
        maximumAccounts: Int = 512,
        maximumSnapshotBytes: Int = 256 * 1_024
    ) {
        self.retention = retention
        self.staleAfter = staleAfter
        self.maximumSamplesPerAccount = maximumSamplesPerAccount
        self.maximumTotalSamples = maximumTotalSamples
        self.maximumAccounts = maximumAccounts
        self.maximumSnapshotBytes = maximumSnapshotBytes
    }
}

public enum CodexUsageStatisticsFailure: String, Codable, Sendable, CaseIterable {
    case unavailable
    case authenticationRequired
    case timedOut
    case invalidResponse
    case backendRejectedRequest
    case storageUnavailable

    public var message: String {
        switch self {
        case .unavailable: return "Usage refresh is unavailable."
        case .authenticationRequired: return "Sign in again to refresh usage."
        case .timedOut: return "Usage refresh timed out."
        case .invalidResponse: return "The usage service returned an invalid response."
        case .backendRejectedRequest: return "The usage service rejected the request."
        case .storageUnavailable: return "Usage could not be saved."
        }
    }
}

public struct CachedCodexAccountUsage: Sendable, Equatable {
    public let accountID: UUID
    public let snapshot: CodexAccountUsageSnapshot?
    public let fetchedAt: Date?
    public let lastAttemptAt: Date?
    public let failure: CodexUsageStatisticsFailure?
    public let failureMessage: String?
    public let failureAt: Date?
    public let isStale: Bool
}

public enum CodexUsageStatisticsCacheError: Error, LocalizedError, Sendable, Equatable {
    case invalidPolicy
    case invalidLocation(String)
    case database(String)
    case corruptDatabase(String)
    case unsupportedSchema(Int32)
    case snapshotTooLarge(Int)
    case invalidSnapshot

    public var errorDescription: String? {
        switch self {
        case .invalidPolicy: return "The usage-cache limits are invalid."
        case .invalidLocation(let detail): return detail
        case .database(let detail): return detail
        case .corruptDatabase(let detail): return detail
        case .unsupportedSchema(let version):
            return "The usage cache has unsupported schema version \(version)."
        case .snapshotTooLarge(let bytes):
            return "The usage snapshot is too large to cache (\(bytes) bytes)."
        case .invalidSnapshot: return "The cached usage snapshot is invalid."
        }
    }
}

public actor CodexUsageStatisticsCache {
    public static let schemaVersion: Int32 = 1

    private let databaseURL: URL
    private let policy: CodexUsageStatisticsCachePolicy
    private let now: @Sendable () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        databaseURL: URL,
        policy: CodexUsageStatisticsCachePolicy = .init(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard policy.retention >= 0,
              policy.retention.isFinite,
              policy.staleAfter >= 0,
              policy.staleAfter.isFinite,
              policy.maximumSamplesPerAccount > 0,
              policy.maximumSamplesPerAccount <= Int(Int32.max),
              policy.maximumTotalSamples > 0,
              policy.maximumTotalSamples <= Int(Int32.max),
              policy.maximumAccounts > 0,
              policy.maximumAccounts <= Int(Int32.max),
              policy.maximumSnapshotBytes > 0,
              policy.maximumSnapshotBytes <= Int(Int32.max) else {
            throw CodexUsageStatisticsCacheError.invalidPolicy
        }
        self.databaseURL = databaseURL
        self.policy = policy
        self.now = now
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        try Self.prepareLocation(databaseURL)
        try Self.withDatabase(at: databaseURL) { database in
            try Self.configure(database)
            try Self.checkIntegrity(database)
            try Self.migrate(database)
        }
        try Self.secureDatabaseFiles(databaseURL)
    }

    public func latest(for accountID: UUID) throws -> CachedCodexAccountUsage? {
        try Self.withDatabase(at: databaseURL) { database in
            try Self.readLatest(database, accountID: accountID, decoder: decoder,
                                staleAfter: policy.staleAfter, now: now())
        }
    }

    public func allLatest() throws -> [CachedCodexAccountUsage] {
        try Self.withDatabase(at: databaseURL) { database in
            let ids = try Self.accountIDs(database)
            return try ids.compactMap {
                try Self.readLatest(database, accountID: $0, decoder: decoder,
                                    staleAfter: policy.staleAfter, now: now())
            }
        }
    }

    public func history(for accountID: UUID, limit: Int? = nil) throws -> [CodexAccountUsageSnapshot] {
        let requestedLimit = min(max(limit ?? policy.maximumSamplesPerAccount, 0), policy.maximumSamplesPerAccount)
        guard requestedLimit > 0 else { return [] }
        return try Self.withDatabase(at: databaseURL) { database in
            let sql = "SELECT snapshot FROM usage_samples WHERE account_id = ?1 ORDER BY fetched_at DESC, id DESC LIMIT ?2"
            let statement = try Self.prepare(database, sql)
            defer { sqlite3_finalize(statement) }
            Self.bind(accountID.uuidString.lowercased(), to: statement, at: 1)
            sqlite3_bind_int(statement, 2, Int32(requestedLimit))
            var snapshots: [CodexAccountUsageSnapshot] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                snapshots.append(try Self.decodeSnapshot(statement, column: 0, decoder: decoder))
            }
            guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
                throw Self.databaseError(database, "Could not read usage history")
            }
            return snapshots
        }
    }

    public func upsertSuccess(accountID: UUID, snapshot: CodexAccountUsageSnapshot) throws {
        guard snapshot.fetchedAt.timeIntervalSince1970.isFinite else {
            throw CodexUsageStatisticsCacheError.invalidSnapshot
        }
        let payload = try encoder.encode(snapshot)
        guard payload.count <= policy.maximumSnapshotBytes else {
            throw CodexUsageStatisticsCacheError.snapshotTooLarge(payload.count)
        }
        let recordedAt = now()
        guard recordedAt.timeIntervalSince1970.isFinite else {
            throw CodexUsageStatisticsCacheError.invalidSnapshot
        }
        try Self.withDatabase(at: databaseURL) { database in
            try Self.transaction(database) {
                let status = try Self.prepare(database, """
                    INSERT INTO usage_accounts(account_id, last_attempt_at, failure_code, failure_at)
                    VALUES(?1, ?2, NULL, NULL)
                    ON CONFLICT(account_id) DO UPDATE SET
                        last_attempt_at = excluded.last_attempt_at,
                        failure_code = NULL,
                        failure_at = NULL
                    """)
                defer { sqlite3_finalize(status) }
                Self.bind(accountID.uuidString.lowercased(), to: status, at: 1)
                sqlite3_bind_double(status, 2, recordedAt.timeIntervalSince1970)
                guard sqlite3_step(status) == SQLITE_DONE else {
                    throw Self.databaseError(database, "Could not update usage status")
                }

                let insert = try Self.prepare(database, "INSERT INTO usage_samples(account_id, fetched_at, recorded_at, snapshot) VALUES(?1, ?2, ?3, ?4)")
                defer { sqlite3_finalize(insert) }
                Self.bind(accountID.uuidString.lowercased(), to: insert, at: 1)
                sqlite3_bind_double(insert, 2, snapshot.fetchedAt.timeIntervalSince1970)
                sqlite3_bind_double(insert, 3, recordedAt.timeIntervalSince1970)
                _ = payload.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(insert, 4, bytes.baseAddress, Int32(bytes.count), Self.transient)
                }
                guard sqlite3_step(insert) == SQLITE_DONE else {
                    throw Self.databaseError(database, "Could not save usage snapshot")
                }
                try Self.prune(database, accountID: accountID, policy: policy, now: recordedAt)
            }
        }
        try Self.secureDatabaseFiles(databaseURL)
    }

    public func recordFailure(accountID: UUID, failure: CodexUsageStatisticsFailure) throws {
        let failedAt = now()
        guard failedAt.timeIntervalSince1970.isFinite else {
            throw CodexUsageStatisticsCacheError.invalidSnapshot
        }
        try Self.withDatabase(at: databaseURL) { database in
            try Self.transaction(database) {
                let statement = try Self.prepare(database, """
                    INSERT INTO usage_accounts(account_id, last_attempt_at, failure_code, failure_at)
                    VALUES(?1, ?2, ?3, ?2)
                    ON CONFLICT(account_id) DO UPDATE SET
                        last_attempt_at = excluded.last_attempt_at,
                        failure_code = excluded.failure_code,
                        failure_at = excluded.failure_at
                    """)
                defer { sqlite3_finalize(statement) }
                Self.bind(accountID.uuidString.lowercased(), to: statement, at: 1)
                sqlite3_bind_double(statement, 2, failedAt.timeIntervalSince1970)
                Self.bind(failure.rawValue, to: statement, at: 3)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw Self.databaseError(database, "Could not record usage failure")
                }
                try Self.pruneAccounts(database, maximumAccounts: policy.maximumAccounts)
            }
        }
        try Self.secureDatabaseFiles(databaseURL)
    }

    public func purge(accountID: UUID) throws {
        try Self.withDatabase(at: databaseURL) { database in
            try Self.transaction(database) {
                for table in ["usage_samples", "usage_accounts"] {
                    let statement = try Self.prepare(database, "DELETE FROM \(table) WHERE account_id = ?1")
                    defer { sqlite3_finalize(statement) }
                    Self.bind(accountID.uuidString.lowercased(), to: statement, at: 1)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw Self.databaseError(database, "Could not purge cached usage")
                    }
                }
            }
        }
    }

    public func purgeAll() throws {
        try Self.withDatabase(at: databaseURL) { database in
            try Self.transaction(database) {
                try Self.execute(database, "DELETE FROM usage_samples")
                try Self.execute(database, "DELETE FROM usage_accounts")
            }
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func prepareLocation(_ databaseURL: URL) throws {
        guard databaseURL.isFileURL, databaseURL.path.hasPrefix("/") else {
            throw CodexUsageStatisticsCacheError.invalidLocation("The usage-cache path must be absolute.")
        }
        let fileManager = FileManager.default
        let parent = databaseURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        try validate(parent, expectedType: S_IFDIR, permissions: 0o700, linkCount: nil)
        if !fileManager.fileExists(atPath: databaseURL.path) {
            let descriptor = open(databaseURL.path, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw CodexUsageStatisticsCacheError.invalidLocation("Could not create the private usage-cache file.")
            }
            guard close(descriptor) == 0 else {
                throw CodexUsageStatisticsCacheError.invalidLocation("Could not close the new usage-cache file.")
            }
        }
        try validate(databaseURL, expectedType: S_IFREG, permissions: 0o600, linkCount: 1)
        for sidecar in [URL(fileURLWithPath: databaseURL.path + "-wal"),
                        URL(fileURLWithPath: databaseURL.path + "-shm")]
        where fileManager.fileExists(atPath: sidecar.path) {
            try validate(sidecar, expectedType: S_IFREG, permissions: 0o600, linkCount: 1)
        }
    }

    private static func validate(_ url: URL, expectedType: mode_t, permissions: mode_t, linkCount: nlink_t?) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == expectedType,
              info.st_uid == getuid(),
              info.st_mode & 0o777 == permissions,
              linkCount == nil || info.st_nlink == linkCount else {
            throw CodexUsageStatisticsCacheError.invalidLocation("The usage cache requires private, owner-controlled files.")
        }
    }

    private static func secureDatabaseFiles(_ databaseURL: URL) throws {
        let fileManager = FileManager.default
        for url in [databaseURL,
                    URL(fileURLWithPath: databaseURL.path + "-wal"),
                    URL(fileURLWithPath: databaseURL.path + "-shm")] where fileManager.fileExists(atPath: url.path) {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try validate(url, expectedType: S_IFREG, permissions: 0o600, linkCount: 1)
        }
    }

    private static func withDatabase<T>(at url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite could not open the file."
            if let database { sqlite3_close(database) }
            throw CodexUsageStatisticsCacheError.database("Could not open usage cache: \(detail)")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 2_000)
        guard sqlite3_exec(database, "PRAGMA foreign_keys=ON", nil, nil, nil) == SQLITE_OK else {
            throw databaseError(database, "Could not enable usage-cache integrity checks")
        }
        return try body(database)
    }

    private static func configure(_ database: OpaquePointer) throws {
        try execute(database, "PRAGMA journal_mode=WAL")
        try execute(database, "PRAGMA synchronous=NORMAL")
        try execute(database, "PRAGMA foreign_keys=ON")
    }

    private static func checkIntegrity(_ database: OpaquePointer) throws {
        let statement = try prepare(database, "PRAGMA quick_check")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_text(statement, 0).map({ String(cString: $0) }) == "ok" else {
            throw CodexUsageStatisticsCacheError.corruptDatabase(
                "The usage cache failed SQLite's integrity check. The original database was preserved."
            )
        }
    }

    private static func migrate(_ database: OpaquePointer) throws {
        let version = try scalarInt(database, "PRAGMA user_version")
        switch version {
        case 0:
            try transaction(database) {
                try execute(database, """
                    CREATE TABLE usage_accounts(
                        account_id TEXT PRIMARY KEY NOT NULL,
                        last_attempt_at REAL NOT NULL,
                        failure_code TEXT,
                        failure_at REAL
                    ) WITHOUT ROWID
                    """)
                try execute(database, """
                    CREATE TABLE usage_samples(
                        id INTEGER PRIMARY KEY,
                        account_id TEXT NOT NULL,
                        fetched_at REAL NOT NULL,
                        recorded_at REAL NOT NULL,
                        snapshot BLOB NOT NULL,
                        FOREIGN KEY(account_id) REFERENCES usage_accounts(account_id) ON DELETE CASCADE
                    )
                    """)
                try execute(database, "CREATE INDEX usage_samples_latest ON usage_samples(account_id, fetched_at DESC, id DESC)")
                try execute(database, "PRAGMA user_version = 1")
            }
        case schemaVersion:
            break
        default:
            throw CodexUsageStatisticsCacheError.unsupportedSchema(version)
        }
    }

    private static func readLatest(
        _ database: OpaquePointer,
        accountID: UUID,
        decoder: JSONDecoder,
        staleAfter: TimeInterval,
        now: Date
    ) throws -> CachedCodexAccountUsage? {
        let statement = try prepare(database, """
            SELECT s.snapshot, s.fetched_at, a.last_attempt_at, a.failure_code, a.failure_at
            FROM usage_accounts a
            LEFT JOIN usage_samples s ON s.id = (
                SELECT id FROM usage_samples
                WHERE account_id = a.account_id
                ORDER BY fetched_at DESC, id DESC LIMIT 1
            )
            WHERE a.account_id = ?1
            """)
        defer { sqlite3_finalize(statement) }
        bind(accountID.uuidString.lowercased(), to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            if sqlite3_errcode(database) == SQLITE_DONE { return nil }
            throw databaseError(database, "Could not read cached usage")
        }
        let snapshot = sqlite3_column_type(statement, 0) == SQLITE_NULL
            ? nil : try decodeSnapshot(statement, column: 0, decoder: decoder)
        let fetchedAt = optionalDate(statement, column: 1)
        let failure = text(statement, column: 3).flatMap(CodexUsageStatisticsFailure.init(rawValue:))
        return CachedCodexAccountUsage(
            accountID: accountID,
            snapshot: snapshot,
            fetchedAt: fetchedAt,
            lastAttemptAt: optionalDate(statement, column: 2),
            failure: failure,
            failureMessage: failure?.message,
            failureAt: optionalDate(statement, column: 4),
            isStale: fetchedAt.map { now.timeIntervalSince($0) >= staleAfter } ?? true
        )
    }

    private static func accountIDs(_ database: OpaquePointer) throws -> [UUID] {
        let statement = try prepare(database, "SELECT account_id FROM usage_accounts ORDER BY account_id")
        defer { sqlite3_finalize(statement) }
        var result: [UUID] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = text(statement, column: 0), let id = UUID(uuidString: raw) { result.append(id) }
        }
        guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
            throw databaseError(database, "Could not list cached usage")
        }
        return result
    }

    private static func prune(
        _ database: OpaquePointer,
        accountID: UUID,
        policy: CodexUsageStatisticsCachePolicy,
        now: Date
    ) throws {
        let expired = try prepare(database, "DELETE FROM usage_samples WHERE recorded_at < ?1")
        defer { sqlite3_finalize(expired) }
        sqlite3_bind_double(expired, 1, now.addingTimeInterval(-policy.retention).timeIntervalSince1970)
        guard sqlite3_step(expired) == SQLITE_DONE else { throw databaseError(database, "Could not prune expired usage") }

        let perAccount = try prepare(database, """
            DELETE FROM usage_samples WHERE id IN (
                SELECT id FROM usage_samples WHERE account_id = ?1
                ORDER BY fetched_at DESC, id DESC LIMIT -1 OFFSET ?2
            )
            """)
        defer { sqlite3_finalize(perAccount) }
        bind(accountID.uuidString.lowercased(), to: perAccount, at: 1)
        sqlite3_bind_int(perAccount, 2, Int32(policy.maximumSamplesPerAccount))
        guard sqlite3_step(perAccount) == SQLITE_DONE else { throw databaseError(database, "Could not enforce account history limit") }

        let total = try prepare(database, """
            DELETE FROM usage_samples WHERE id IN (
                SELECT id FROM usage_samples ORDER BY recorded_at DESC, id DESC LIMIT -1 OFFSET ?1
            )
            """)
        defer { sqlite3_finalize(total) }
        sqlite3_bind_int(total, 1, Int32(policy.maximumTotalSamples))
        guard sqlite3_step(total) == SQLITE_DONE else { throw databaseError(database, "Could not enforce cache row limit") }
        try pruneAccounts(database, maximumAccounts: policy.maximumAccounts)
    }

    private static func pruneAccounts(_ database: OpaquePointer, maximumAccounts: Int) throws {
        let statement = try prepare(database, """
            DELETE FROM usage_accounts WHERE account_id IN (
                SELECT account_id FROM usage_accounts
                ORDER BY last_attempt_at DESC, account_id DESC LIMIT -1 OFFSET ?1
            )
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(maximumAccounts))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(database, "Could not enforce cache account limit")
        }
    }

    private static func transaction(_ database: OpaquePointer, _ body: () throws -> Void) throws {
        try execute(database, "BEGIN IMMEDIATE")
        do {
            try body()
            try execute(database, "COMMIT")
        } catch {
            _ = sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private static func prepare(_ database: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError(database, "Could not prepare usage-cache query")
        }
        return statement
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw databaseError(database, "Could not update usage cache")
        }
    }

    private static func scalarInt(_ database: OpaquePointer, _ sql: String) throws -> Int32 {
        let statement = try prepare(database, sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError(database, "Could not read usage-cache schema") }
        return sqlite3_column_int(statement, 0)
    }

    private static func bind(_ value: String, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private static func text(_ statement: OpaquePointer, column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private static func optionalDate(_ statement: OpaquePointer, column: Int32) -> Date? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private static func decodeSnapshot(
        _ statement: OpaquePointer,
        column: Int32,
        decoder: JSONDecoder
    ) throws -> CodexAccountUsageSnapshot {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count >= 0, let bytes = sqlite3_column_blob(statement, column) else {
            throw CodexUsageStatisticsCacheError.invalidSnapshot
        }
        do {
            return try decoder.decode(CodexAccountUsageSnapshot.self, from: Data(bytes: bytes, count: count))
        } catch {
            throw CodexUsageStatisticsCacheError.invalidSnapshot
        }
    }

    private static func databaseError(_ database: OpaquePointer, _ prefix: String) -> CodexUsageStatisticsCacheError {
        let detail = "\(prefix): \(String(cString: sqlite3_errmsg(database)))"
        let code = sqlite3_extended_errcode(database)
        if code == SQLITE_CORRUPT || code == SQLITE_NOTADB {
            return .corruptDatabase("\(detail). The original database was preserved.")
        }
        return .database(detail)
    }
}
