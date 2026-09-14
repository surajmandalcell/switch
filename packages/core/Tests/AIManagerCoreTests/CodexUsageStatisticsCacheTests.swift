import CSQLite
import Foundation
import XCTest
@testable import AIManagerCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class CodexUsageStatisticsCacheTests: XCTestCase {
    private var root: URL!
    private var database: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "CodexUsageStatisticsCacheTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        database = root.appending(path: "private/statistics.sqlite")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testStoresLatestHistoryAndFailureAcrossReopen() async throws {
        let accountID = UUID()
        let firstTime = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TestClock(firstTime.addingTimeInterval(60))
        var cache: CodexUsageStatisticsCache? = try CodexUsageStatisticsCache(
            databaseURL: database,
            policy: .init(staleAfter: 120),
            now: { clock.value }
        )
        try await cache?.upsertSuccess(accountID: accountID, snapshot: snapshot(at: firstTime, used: 20))
        clock.value = firstTime.addingTimeInterval(90)
        try await cache?.upsertSuccess(accountID: accountID, snapshot: snapshot(at: firstTime.addingTimeInterval(30), used: 30))
        try await cache?.recordFailure(accountID: accountID, failure: .timedOut)

        let cached = try await cache?.latest(for: accountID)
        XCTAssertEqual(cached?.snapshot?.rateLimits?.defaultBucket?.primary?.usedPercent, 30)
        XCTAssertEqual(cached?.failure, .timedOut)
        XCTAssertEqual(cached?.failureMessage, "Usage refresh timed out.")
        XCTAssertEqual(cached?.isStale, false)
        let history = try await cache?.history(for: accountID)
        XCTAssertEqual(history?.count, 2)
        cache = nil

        let reopened = try CodexUsageStatisticsCache(databaseURL: database, now: { clock.value })
        let allLatest = try await reopened.allLatest()
        let reopenedLatest = try await reopened.latest(for: accountID)
        XCTAssertEqual(allLatest.map(\.accountID), [accountID])
        XCTAssertEqual(reopenedLatest?.failure, .timedOut)
        XCTAssertEqual(try userVersion(database), CodexUsageStatisticsCache.schemaVersion)

        clock.value = firstTime.addingTimeInterval(1_000)
        let stale = try await reopened.latest(for: accountID)
        XCTAssertEqual(stale?.isStale, true)
        try await reopened.upsertSuccess(accountID: accountID, snapshot: snapshot(at: clock.value, used: 40))
        let recovered = try await reopened.latest(for: accountID)
        XCTAssertNil(recovered?.failure)
        XCTAssertNil(recovered?.failureAt)
    }

    func testEnforcesRetentionPerAccountAndTotalRowLimits() async throws {
        let first = UUID()
        let second = UUID()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TestClock(base)
        let cache = try CodexUsageStatisticsCache(
            databaseURL: database,
            policy: .init(retention: 100, staleAfter: 10, maximumSamplesPerAccount: 2,
                          maximumTotalSamples: 3, maximumAccounts: 2,
                          maximumSnapshotBytes: 64 * 1_024),
            now: { clock.value }
        )
        for offset in 0..<3 {
            clock.value = base.addingTimeInterval(Double(offset))
            try await cache.upsertSuccess(accountID: first, snapshot: snapshot(at: clock.value, used: offset))
        }
        clock.value = base.addingTimeInterval(3)
        try await cache.upsertSuccess(accountID: second, snapshot: snapshot(at: clock.value, used: 3))
        clock.value = base.addingTimeInterval(4)
        try await cache.upsertSuccess(accountID: second, snapshot: snapshot(at: clock.value, used: 4))
        let firstHistory = try await cache.history(for: first)
        let secondHistory = try await cache.history(for: second)
        XCTAssertEqual(firstHistory.count, 1)
        XCTAssertEqual(secondHistory.count, 2)

        clock.value = base.addingTimeInterval(200)
        try await cache.upsertSuccess(accountID: first, snapshot: snapshot(at: clock.value, used: 99))
        let retainedFirstHistory = try await cache.history(for: first)
        let expiredSecondHistory = try await cache.history(for: second)
        let staleSecond = try await cache.latest(for: second)
        XCTAssertEqual(retainedFirstHistory.count, 1)
        XCTAssertTrue(expiredSecondHistory.isEmpty)
        XCTAssertEqual(staleSecond?.isStale, true)
    }

    func testBoundsFailureOnlyAccounts() async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TestClock(base)
        let cache = try CodexUsageStatisticsCache(
            databaseURL: database,
            policy: .init(maximumAccounts: 2),
            now: { clock.value }
        )
        let ids = [UUID(), UUID(), UUID()]
        for (offset, id) in ids.enumerated() {
            clock.value = base.addingTimeInterval(Double(offset))
            try await cache.recordFailure(accountID: id, failure: .unavailable)
        }

        let retained = try await cache.allLatest()
        let evicted = try await cache.latest(for: ids[0])
        XCTAssertEqual(Set(retained.map(\.accountID)), Set(ids.suffix(2)))
        XCTAssertNil(evicted)
    }

    func testUsesPrivateFilesAndNeverPersistsCallerErrorOrSecretMaterial() async throws {
        let cache = try CodexUsageStatisticsCache(databaseURL: database)
        let accountID = UUID()
        let secret = "synthetic-refresh-token-do-not-store"
        try await cache.upsertSuccess(accountID: accountID, snapshot: snapshot(at: Date(), used: 42))
        try await cache.recordFailure(accountID: accountID, failure: .backendRejectedRequest)

        let parentMode = try mode(database.deletingLastPathComponent())
        let databaseMode = try mode(database)
        XCTAssertEqual(parentMode & 0o777, 0o700)
        XCTAssertEqual(databaseMode & 0o777, 0o600)
        let contents = try Data(contentsOf: database)
        XCTAssertFalse(String(decoding: contents, as: UTF8.self).contains(secret))
        XCTAssertFalse(String(decoding: contents, as: UTF8.self).lowercased().contains("refresh_token"))
        XCTAssertLessThanOrEqual(CodexUsageStatisticsFailure.backendRejectedRequest.message.utf8.count, 96)
    }

    func testPurgeAndCorruptionFailurePreserveOriginalDatabase() async throws {
        let accountID = UUID()
        let cache = try CodexUsageStatisticsCache(databaseURL: database)
        try await cache.upsertSuccess(accountID: accountID, snapshot: snapshot(at: Date(), used: 1))
        try await cache.purge(accountID: accountID)
        let purged = try await cache.latest(for: accountID)
        XCTAssertNil(purged)
        try await cache.recordFailure(accountID: accountID, failure: .unavailable)
        try await cache.purgeAll()
        let purgedAll = try await cache.allLatest()
        XCTAssertTrue(purgedAll.isEmpty)

        let corrupt = root.appending(path: "corrupt/statistics.sqlite")
        try FileManager.default.createDirectory(at: corrupt.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let original = Data("this is not sqlite and must survive".utf8)
        try original.write(to: corrupt)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: corrupt.path)
        XCTAssertThrowsError(try CodexUsageStatisticsCache(databaseURL: corrupt)) { error in
            guard case .corruptDatabase(let detail) = error as? CodexUsageStatisticsCacheError else {
                return XCTFail("Expected a clear corrupt-database error, got \(error)")
            }
            XCTAssertTrue(detail.contains("preserved"))
        }
        XCTAssertEqual(try Data(contentsOf: corrupt), original)
    }

    func testRejectsFutureSchemaWithoutChangingIt() throws {
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA user_version = 99", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path)

        XCTAssertThrowsError(try CodexUsageStatisticsCache(databaseURL: database)) { error in
            XCTAssertEqual(error as? CodexUsageStatisticsCacheError, .unsupportedSchema(99))
        }
        XCTAssertEqual(try userVersion(database), 99)
    }

    private func snapshot(at date: Date, used: Int) -> CodexAccountUsageSnapshot {
        .init(
            account: .init(kind: "chatgpt", email: "synthetic@example.test", plan: "plus"),
            requiresOpenAIAuthentication: false,
            rateLimits: .init(
                accountID: "synthetic-account",
                ordinaryUsageAllowed: true,
                defaultBucket: .init(
                    id: "codex", name: "Codex", plan: "plus", model: nil,
                    primary: .init(usedPercent: used, windowDurationMinutes: 300, resetsAt: nil),
                    secondary: nil, credits: nil, spendControlReached: false
                ),
                buckets: [:]
            ),
            usage: nil,
            dailyUsage: [],
            fetchedAt: date
        )
    }

    private func mode(_ url: URL) throws -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
        return info.st_mode
    }

    private func userVersion(_ url: URL) throws -> Int32 {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            throw POSIXError(.EIO)
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw POSIXError(.EIO) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw POSIXError(.EIO) }
        return sqlite3_column_int(statement, 0)
    }
}

private final class TestClock: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}
