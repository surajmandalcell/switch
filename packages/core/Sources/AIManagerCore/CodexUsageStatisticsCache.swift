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

public struct CleanupUsageSample: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let accountID: UUID
    public let fetchedAt: Date
    public let bytes: Int64
    let digest: String
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

public struct CodexProjectDailyActivity: Sendable, Equatable {
    public let project: String
    public let day: String
    public let tokens: Int64
    public let isComplete: Bool
}

public struct CodexSharedDailyActivity: Sendable, Equatable {
    public let day: String
    public let tokens: Int64
    public let isComplete: Bool

    public init(day: String, tokens: Int64, isComplete: Bool) {
        self.day = day
        self.tokens = tokens
        self.isComplete = isComplete
    }
}

struct CodexTranscriptActivity: Sendable {
    let threadID: String?
    let project: String?
    let firstEvent: String
    let eventCount: Int
    let totalTokens: Int64
    let days: [String: Int64]
    let complete: Bool
}

public actor CodexUsageStatisticsCache {
    public static let schemaVersion: Int32 = 1

    private let databaseURL: URL
    private let activityDatabaseURL: URL?
    private let policy: CodexUsageStatisticsCachePolicy
    private let now: @Sendable () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        databaseURL: URL,
        policy: CodexUsageStatisticsCachePolicy = .init(),
        activityDatabaseURL: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard activityDatabaseURL?.standardizedFileURL != databaseURL.standardizedFileURL else {
            throw CodexUsageStatisticsCacheError.invalidLocation(
                "Daily activity must use a separate database from the rebuildable usage cache.")
        }
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
        self.activityDatabaseURL = activityDatabaseURL
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
        if let activityDatabaseURL {
            try Self.prepareLocation(activityDatabaseURL)
            try Self.withDatabase(at: activityDatabaseURL) { database in
                try Self.configure(database)
                try Self.checkIntegrity(database)
                let version = try Self.scalarInt(database, "PRAGMA user_version")
                guard version <= 1 else {
                    throw CodexUsageStatisticsCacheError.unsupportedSchema(version)
                }
                try Self.transaction(database) {
                    try Self.execute(database, """
                        CREATE TABLE IF NOT EXISTS account_days(
                            account_id TEXT NOT NULL, day TEXT NOT NULL,
                            tokens INTEGER NOT NULL CHECK(tokens >= 0), fetched_at REAL NOT NULL,
                            PRIMARY KEY(account_id, day)
                        ) WITHOUT ROWID;
                        CREATE TABLE IF NOT EXISTS activity_threads(
                            thread_id TEXT PRIMARY KEY NOT NULL, project TEXT NOT NULL,
                            first_event TEXT NOT NULL, event_count INTEGER NOT NULL,
                            total_tokens INTEGER NOT NULL, complete INTEGER NOT NULL
                        ) WITHOUT ROWID;
                        CREATE TABLE IF NOT EXISTS project_days(
                            thread_id TEXT NOT NULL, day TEXT NOT NULL,
                            tokens INTEGER NOT NULL CHECK(tokens >= 0),
                            PRIMARY KEY(thread_id, day),
                            FOREIGN KEY(thread_id) REFERENCES activity_threads(thread_id)
                        ) WITHOUT ROWID;
                        CREATE INDEX IF NOT EXISTS project_days_date ON project_days(day);
                        CREATE TABLE IF NOT EXISTS activity_metadata(
                            key TEXT PRIMARY KEY NOT NULL
                        ) WITHOUT ROWID;
                        PRAGMA user_version = 1;
                        """)
                }
            }
            // Seed the ledger once from already retained quota samples. No source transcript
            // or authentication content is copied into the durable activity database.
            if try Self.withDatabase(at: activityDatabaseURL, {
                try Self.scalarInt($0,
                    "SELECT COUNT(*) FROM activity_metadata WHERE key = 'usage_cache_seeded'") == 0
            }) {
                try Self.withDatabase(at: databaseURL) { database in
                    let statement = try Self.prepare(database,
                        "SELECT account_id, snapshot FROM usage_samples ORDER BY fetched_at")
                    defer { sqlite3_finalize(statement) }
                    while sqlite3_step(statement) == SQLITE_ROW {
                        guard let id = Self.text(statement, column: 0) else { continue }
                        let snapshot = try Self.decodeSnapshot(statement, column: 1, decoder: decoder)
                        try Self.mergeDailyUsage(snapshot, accountID: id, at: activityDatabaseURL)
                    }
                    guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
                        throw Self.databaseError(database, "Could not seed daily activity")
                    }
                }
                try Self.withDatabase(at: activityDatabaseURL) {
                    try Self.execute($0,
                        "INSERT OR IGNORE INTO activity_metadata VALUES('usage_cache_seeded')")
                }
            }
            try Self.secureDatabaseFiles(activityDatabaseURL)
        }
    }

    public func latest(for accountID: UUID) throws -> CachedCodexAccountUsage? {
        try Self.withDatabase(at: databaseURL) { database in
            try Self.readLatest(database, accountID: accountID, decoder: decoder,
                                staleAfter: policy.staleAfter, now: now())
        }
    }

    /// Reads only the requested account rows. The request is capped before any
    /// SQLite statement is built, so callers cannot turn this into an unbounded
    /// placeholder list or make the cache scan every retained account.
    public func latest(for accountIDs: [UUID]) throws -> [CachedCodexAccountUsage] {
        let maximumRequestedAccounts = min(policy.maximumAccounts, Self.maximumRequestedAccounts)
        var seen = Set<String>()
        var requestedIDs: [String] = []
        requestedIDs.reserveCapacity(min(accountIDs.count, maximumRequestedAccounts))
        for accountID in accountIDs where requestedIDs.count < maximumRequestedAccounts {
            let rawID = accountID.uuidString.lowercased()
            if seen.insert(rawID).inserted { requestedIDs.append(rawID) }
        }
        guard !requestedIDs.isEmpty else { return [] }

        return try Self.withDatabase(at: databaseURL) { database in
            try Self.readLatest(database, accountIDs: requestedIDs, decoder: decoder,
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
        if let activityDatabaseURL {
            try Self.mergeDailyUsage(snapshot, accountID: accountID.uuidString.lowercased(),
                                    at: activityDatabaseURL)
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

    public func cleanupSamples() throws -> [CleanupUsageSample] {
        try Self.withDatabase(at: databaseURL) { database in
            let statement = try Self.prepare(database, "SELECT id, account_id, fetched_at, snapshot FROM usage_samples ORDER BY fetched_at DESC, id DESC")
            defer { sqlite3_finalize(statement) }
            var samples: [CleanupUsageSample] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let rawID = Self.text(statement, column: 1), let accountID = UUID(uuidString: rawID),
                      let blob = sqlite3_column_blob(statement, 3) else {
                    throw CodexUsageStatisticsCacheError.invalidSnapshot
                }
                let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 3)))
                samples.append(.init(id: sqlite3_column_int64(statement, 0), accountID: accountID,
                    fetchedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    bytes: Int64(data.count), digest: CoreSupport.digest(data)))
            }
            guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
                throw Self.databaseError(database, "Could not read Cleanup usage samples")
            }
            return samples
        }
    }

    public func removeCleanupSamples(_ samples: [CleanupUsageSample]) throws {
        guard Set(samples.map(\.id)).count == samples.count else { throw AIManagerError.sourceChanged }
        try Self.withDatabase(at: databaseURL) { database in
            try Self.transaction(database) {
                for sample in samples {
                    let read = try Self.prepare(database, "SELECT account_id, fetched_at, snapshot FROM usage_samples WHERE id = ?1")
                    defer { sqlite3_finalize(read) }
                    sqlite3_bind_int64(read, 1, sample.id)
                    guard sqlite3_step(read) == SQLITE_ROW,
                          Self.text(read, column: 0) == sample.accountID.uuidString.lowercased(),
                          sqlite3_column_double(read, 1) == sample.fetchedAt.timeIntervalSince1970,
                          let blob = sqlite3_column_blob(read, 2),
                          CoreSupport.digest(Data(bytes: blob, count: Int(sqlite3_column_bytes(read, 2)))) == sample.digest else {
                        throw AIManagerError.sourceChanged
                    }
                    let remove = try Self.prepare(database, "DELETE FROM usage_samples WHERE id = ?1")
                    defer { sqlite3_finalize(remove) }
                    sqlite3_bind_int64(remove, 1, sample.id)
                    guard sqlite3_step(remove) == SQLITE_DONE else { throw Self.databaseError(database, "Could not clear selected usage samples") }
                }
            }
        }
    }

    public func dailyUsage(for accountID: UUID) throws -> [CodexDailyUsageSnapshot] {
        guard let activityDatabaseURL else { return [] }
        return try Self.withDatabase(at: activityDatabaseURL) { database in
            let statement = try Self.prepare(database,
                "SELECT day, tokens FROM account_days WHERE account_id = ?1 ORDER BY day")
            defer { sqlite3_finalize(statement) }
            Self.bind(accountID.uuidString.lowercased(), to: statement, at: 1)
            var rows: [CodexDailyUsageSnapshot] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(.init(startDate: Self.text(statement, column: 0),
                                  tokens: sqlite3_column_int64(statement, 1)))
            }
            guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
                throw Self.databaseError(database, "Could not read daily activity")
            }
            return rows
        }
    }

    public func projectActivity(on day: String) throws -> [CodexProjectDailyActivity] {
        guard Self.validDay(day), let activityDatabaseURL else { return [] }
        return try Self.withDatabase(at: activityDatabaseURL) { database in
            let statement = try Self.prepare(database, """
                SELECT t.project, SUM(d.tokens), MIN(t.complete)
                FROM project_days d JOIN activity_threads t USING(thread_id)
                WHERE d.day = ?1 GROUP BY t.project ORDER BY SUM(d.tokens) DESC
                """)
            defer { sqlite3_finalize(statement) }
            Self.bind(day, to: statement, at: 1)
            var rows: [CodexProjectDailyActivity] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let project = Self.text(statement, column: 0) else { continue }
                rows.append(.init(project: project, day: day,
                                  tokens: sqlite3_column_int64(statement, 1),
                                  isComplete: sqlite3_column_int(statement, 2) != 0))
            }
            guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
                throw Self.databaseError(database, "Could not read project activity")
            }
            return rows
        }
    }

    public func sharedDailyActivity(
        from startDay: String, through endDay: String
    ) throws -> [CodexSharedDailyActivity] {
        guard Self.validDay(startDay), Self.validDay(endDay), startDay <= endDay,
              let activityDatabaseURL else { return [] }
        return try Self.withDatabase(at: activityDatabaseURL) { database in
            let statement = try Self.prepare(database, """
                SELECT d.day, SUM(d.tokens), MIN(t.complete)
                FROM project_days d JOIN activity_threads t USING(thread_id)
                WHERE d.day BETWEEN ?1 AND ?2 GROUP BY d.day ORDER BY d.day
                """)
            defer { sqlite3_finalize(statement) }
            Self.bind(startDay, to: statement, at: 1)
            Self.bind(endDay, to: statement, at: 2)
            var rows: [CodexSharedDailyActivity] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let day = Self.text(statement, column: 0) else { continue }
                rows.append(.init(day: day, tokens: sqlite3_column_int64(statement, 1),
                                  isComplete: sqlite3_column_int(statement, 2) != 0))
            }
            guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
                throw Self.databaseError(database, "Could not read shared daily activity")
            }
            return rows
        }
    }

    func recordTranscriptActivity(_ activity: CodexTranscriptActivity, fallbackID: String) throws {
        guard let activityDatabaseURL else { return }
        let id = "codex:" + (activity.threadID ?? fallbackID)
        let project = activity.project.flatMap {
            $0.hasPrefix("/") ? URL(fileURLWithPath: $0).standardizedFileURL.path : nil
        }
            ?? "Unknown project"
        guard id.utf8.count <= 4_096, project.utf8.count <= 4_096,
              activity.firstEvent.utf8.count <= 256, activity.eventCount >= 0,
              activity.totalTokens >= 0, activity.days.count <= 36_600,
              activity.days.allSatisfy({ Self.validDay($0.key) && $0.value >= 0 }) else {
            throw CodexUsageStatisticsCacheError.invalidSnapshot
        }
        try Self.withDatabase(at: activityDatabaseURL) { database in
            try Self.transaction(database) {
                let existing = try Self.prepare(database,
                    "SELECT first_event, event_count, total_tokens, project FROM activity_threads WHERE thread_id = ?1")
                defer { sqlite3_finalize(existing) }
                Self.bind(id, to: existing, at: 1)
                let result = sqlite3_step(existing)
                guard result == SQLITE_ROW || result == SQLITE_DONE else {
                    throw Self.databaseError(database, "Could not read retained transcript activity")
                }
                let hasPrevious = result == SQLITE_ROW
                if !hasPrevious && activity.eventCount == 0 { return }
                if hasPrevious && (!activity.complete
                    || Self.text(existing, column: 0) != activity.firstEvent
                    || sqlite3_column_int64(existing, 1) > Int64(activity.eventCount)
                    || sqlite3_column_int64(existing, 2) > activity.totalTokens
                    || Self.text(existing, column: 3) != project) {
                    let mark = try Self.prepare(database,
                        "UPDATE activity_threads SET complete = 0 WHERE thread_id = ?1")
                    defer { sqlite3_finalize(mark) }
                    Self.bind(id, to: mark, at: 1)
                    guard sqlite3_step(mark) == SQLITE_DONE else {
                        throw Self.databaseError(database, "Could not retain incomplete activity")
                    }
                    return
                }
                let upsert = try Self.prepare(database, """
                    INSERT INTO activity_threads VALUES(?1, ?2, ?3, ?4, ?5, ?6)
                    ON CONFLICT(thread_id) DO UPDATE SET
                        event_count = excluded.event_count, total_tokens = excluded.total_tokens,
                        complete = excluded.complete
                    """)
                defer { sqlite3_finalize(upsert) }
                Self.bind(id, to: upsert, at: 1)
                Self.bind(project, to: upsert, at: 2)
                Self.bind(activity.firstEvent, to: upsert, at: 3)
                sqlite3_bind_int64(upsert, 4, Int64(activity.eventCount))
                sqlite3_bind_int64(upsert, 5, activity.totalTokens)
                sqlite3_bind_int(upsert, 6, activity.complete ? 1 : 0)
                guard sqlite3_step(upsert) == SQLITE_DONE else {
                    throw Self.databaseError(database, "Could not retain transcript activity")
                }
                let delete = try Self.prepare(database, "DELETE FROM project_days WHERE thread_id = ?1")
                defer { sqlite3_finalize(delete) }
                Self.bind(id, to: delete, at: 1)
                guard sqlite3_step(delete) == SQLITE_DONE else {
                    throw Self.databaseError(database, "Could not replace transcript activity")
                }
                let insert = try Self.prepare(database, "INSERT INTO project_days VALUES(?1, ?2, ?3)")
                defer { sqlite3_finalize(insert) }
                for (day, tokens) in activity.days {
                    sqlite3_reset(insert)
                    Self.bind(id, to: insert, at: 1)
                    Self.bind(day, to: insert, at: 2)
                    sqlite3_bind_int64(insert, 3, tokens)
                    guard sqlite3_step(insert) == SQLITE_DONE else {
                        throw Self.databaseError(database, "Could not save daily project activity")
                    }
                }
            }
        }
        try Self.secureDatabaseFiles(activityDatabaseURL)
    }

    private static func mergeDailyUsage(
        _ snapshot: CodexAccountUsageSnapshot, accountID: String, at url: URL
    ) throws {
        var days: [String: Int64] = [:]
        for row in snapshot.dailyUsage {
            guard let day = row.startDate, validDay(day), let tokens = row.tokens, tokens >= 0 else { continue }
            let (sum, overflow) = days[day, default: 0].addingReportingOverflow(tokens)
            guard !overflow else { throw CodexUsageStatisticsCacheError.invalidSnapshot }
            days[day] = sum
        }
        try withDatabase(at: url) { database in
            try transaction(database) {
                let statement = try prepare(database, """
                    INSERT INTO account_days VALUES(?1, ?2, ?3, ?4)
                    ON CONFLICT(account_id, day) DO UPDATE SET
                        tokens = excluded.tokens, fetched_at = excluded.fetched_at
                    WHERE excluded.fetched_at > account_days.fetched_at
                    """)
                defer { sqlite3_finalize(statement) }
                for (day, tokens) in days {
                    sqlite3_reset(statement)
                    bind(accountID, to: statement, at: 1)
                    bind(day, to: statement, at: 2)
                    sqlite3_bind_int64(statement, 3, tokens)
                    sqlite3_bind_double(statement, 4, snapshot.fetchedAt.timeIntervalSince1970)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw databaseError(database, "Could not retain daily account activity")
                    }
                }
            }
        }
        try secureDatabaseFiles(url)
    }

    private static func validDay(_ value: String) -> Bool {
        guard value.utf8.count == 10 else { return false }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1970...9999).contains(year) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        return actual.year == year && actual.month == month && actual.day == day
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let maximumRequestedAccounts = 512

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

    private static func readLatest(
        _ database: OpaquePointer,
        accountIDs: [String],
        decoder: JSONDecoder,
        staleAfter: TimeInterval,
        now: Date
    ) throws -> [CachedCodexAccountUsage] {
        let placeholders = accountIDs.indices.map { "?\($0 + 1)" }.joined(separator: ", ")
        let statement = try prepare(database, """
            SELECT a.account_id, s.snapshot, s.fetched_at, a.last_attempt_at, a.failure_code, a.failure_at
            FROM usage_accounts a
            LEFT JOIN usage_samples s ON s.id = (
                SELECT id FROM usage_samples
                WHERE account_id = a.account_id
                ORDER BY fetched_at DESC, id DESC LIMIT 1
            )
            WHERE a.account_id IN (\(placeholders))
            """)
        defer { sqlite3_finalize(statement) }
        for (index, accountID) in accountIDs.enumerated() {
            bind(accountID, to: statement, at: Int32(index + 1))
        }

        var result: [CachedCodexAccountUsage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawID = text(statement, column: 0), let accountID = UUID(uuidString: rawID) else {
                continue
            }
            let snapshot = sqlite3_column_type(statement, 1) == SQLITE_NULL
                ? nil : try decodeSnapshot(statement, column: 1, decoder: decoder)
            let fetchedAt = optionalDate(statement, column: 2)
            let failure = text(statement, column: 4).flatMap(CodexUsageStatisticsFailure.init(rawValue:))
            result.append(CachedCodexAccountUsage(
                accountID: accountID,
                snapshot: snapshot,
                fetchedAt: fetchedAt,
                lastAttemptAt: optionalDate(statement, column: 3),
                failure: failure,
                failureMessage: failure?.message,
                failureAt: optionalDate(statement, column: 5),
                isStale: fetchedAt.map { now.timeIntervalSince($0) >= staleAfter } ?? true
            ))
        }
        guard sqlite3_errcode(database) == SQLITE_OK || sqlite3_errcode(database) == SQLITE_DONE else {
            throw databaseError(database, "Could not read cached usage")
        }
        let order = Dictionary(uniqueKeysWithValues: accountIDs.enumerated().map { ($1, $0) })
        return result.sorted { (order[$0.accountID.uuidString.lowercased()] ?? .max) < (order[$1.accountID.uuidString.lowercased()] ?? .max) }
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
