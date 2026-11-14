import XCTest
@testable import AIManagerCore

final class EventLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "event-log-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        // Near the real time, because pruning compares the clock with real file modification dates.
        init(_ date: Date = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())) { self.date = date }
        var now: Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(_ seconds: TimeInterval) { lock.lock(); date += seconds; lock.unlock() }
    }

    private func make(_ clock: Clock = Clock()) -> (EventLog, Clock) {
        (EventLog(directory: directory, now: { clock.now }), clock)
    }

    private func lines(_ name: String = "events.jsonl") throws -> [[String: Any]] {
        let text = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
        return try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func testLineFormat() throws {
        let (log, clock) = make()
        let account = UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")!
        log.record(.warn, area: "usage", event: "usage_failed", provider: "zai", account: account, status: 401, message: "ProviderError.unauthorized")
        log.record(.info, area: "app", event: "app_start")
        log.flush()
        let rows = try lines()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows[0].keys), ["t", "level", "area", "provider", "account", "event", "status", "message"])
        XCTAssertEqual(rows[0]["level"] as? String, "warn")
        XCTAssertEqual(rows[0]["area"] as? String, "usage")
        XCTAssertEqual(rows[0]["provider"] as? String, "zai")
        XCTAssertEqual(rows[0]["account"] as? String, "abcdef12")
        XCTAssertEqual(rows[0]["status"] as? Int, 401)
        XCTAssertEqual(rows[0]["message"] as? String, "ProviderError.unauthorized")
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(stamp.date(from: try XCTUnwrap(rows[0]["t"] as? String)), clock.now)
        XCTAssertTrue(rows[1]["provider"] is NSNull)
        XCTAssertTrue(rows[1]["account"] is NSNull)
        XCTAssertTrue(rows[1]["status"] is NSNull)
    }

    func testRotationKeepsThreeFilesAndDropsTheOldest() throws {
        let (log, _) = make()
        let message = String(repeating: "x", count: 150)
        var written = 0
        while written < 4_800_000 {
            log.record(.info, area: "app", event: "fill", message: message)
            written += 200
        }
        log.flush()
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertEqual(names, ["events.jsonl", "events.1.jsonl", "events.2.jsonl", "events.3.jsonl"])
        for name in names {
            let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory.appending(path: name).path)[.size] as? Int)
            XCTAssertLessThanOrEqual(size, EventLog.Limits.maxFileBytes + 1_000, name)
        }
        for row in try lines("events.3.jsonl").prefix(50) { XCTAssertEqual(row["event"] as? String, "fill") }
    }

    func testPrunesRotatedFilesOlderThanFourteenDays() throws {
        let (first, clock) = make()
        first.record(.info, area: "app", event: "one")
        first.flush()
        let live = directory.appending(path: "events.jsonl")
        let old = directory.appending(path: "events.1.jsonl")
        let recent = directory.appending(path: "events.2.jsonl")
        try FileManager.default.copyItem(at: live, to: old)
        try FileManager.default.copyItem(at: live, to: recent)
        try FileManager.default.setAttributes([.modificationDate: clock.now.addingTimeInterval(-15 * 86_400)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: clock.now.addingTimeInterval(-13 * 86_400)], ofItemAtPath: recent.path)
        let second = EventLog(directory: directory, now: { clock.now })
        second.record(.info, area: "app", event: "two")
        second.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
    }

    func testDropsLiveLinesOlderThanFourteenDaysOnStartAndDaily() throws {
        let (first, clock) = make()
        first.record(.info, area: "app", event: "old")
        first.flush()
        clock.advance(14 * 86_400 + 1)
        let second = EventLog(directory: directory, now: { clock.now })
        second.record(.info, area: "app", event: "restart")
        second.flush()
        XCTAssertEqual(try lines().compactMap { $0["event"] as? String }, ["restart"])

        // The same long-running writer prunes again after a day.
        second.record(.info, area: "app", event: "same_day")
        clock.advance(14 * 86_400 + 1)
        second.record(.info, area: "app", event: "later")
        second.flush()
        XCTAssertEqual(try lines().compactMap { $0["event"] as? String }, ["later"])
    }

    func testFilesAreOwnerOnly() throws {
        let (log, _) = make()
        log.record(.info, area: "app", event: "start")
        log.flush()
        func mode(_ url: URL) throws -> Int {
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) & 0o777
        }
        XCTAssertEqual(try mode(directory), 0o700)
        XCTAssertEqual(try mode(directory.appending(path: "events.jsonl")), 0o600)
    }

    func testSanitizerRemovesCredentialsAndEmails() throws {
        let secrets = [
            "sk-proj-abcdefghijklmnopqrstuvwx",
            "Bearer abc123def456",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk",
            "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
            "AKIAABCDEFGHIJKLMNOP",
            "0123456789abcdef0123456789abcdef0123456789abcdef",
            "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5Cg==",
            "someone@example.com",
            "first.last+tag@mail.example.co.uk",
        ]
        for secret in secrets {
            XCTAssertFalse(EventLog.sanitize("failed with \(secret) end").contains(secret), secret)
        }
        for (text, secret) in [
            ("api_key=hunter2hunter2", "hunter2hunter2"), ("token: abcd", "abcd"), ("password=letmein", "letmein"),
            (#"{"accessToken":"zzz999"}"#, "zzz999"), ("Authorization: Basic dXNlcjpwYXNz", "dXNlcjpwYXNz"),
            ("refresh_token=r-1234", "r-1234"),
        ] {
            XCTAssertFalse(EventLog.sanitize(text).contains(secret), text)
        }
        // Ordinary text stays readable.
        XCTAssertEqual(EventLog.sanitize("ProviderError.unauthorized code=1113 msg=No Coding Plan"),
                       "ProviderError.unauthorized code=1113 msg=No Coding Plan")
        XCTAssertEqual(EventLog.sanitize("CodexAppServerAccountUsageFailureError"), "CodexAppServerAccountUsageFailureError")

        let (log, _) = make()
        log.record(.error, area: "usage", event: "e", message: secrets.joined(separator: " | "))
        log.record(.error, area: "usage", event: "e", provider: "Authorization: Bearer fake-bearer-value-42",
                   message: "Authorization: Bearer fake-bearer-value-42 token=fake-token-value-42")
        log.flush()
        let file = try String(contentsOf: directory.appending(path: "events.jsonl"), encoding: .utf8)
        for secret in secrets + ["fake-bearer-value-42", "fake-token-value-42"] { XCTAssertFalse(file.contains(secret), secret) }
        XCTAssertEqual(try lines().count, 2)
    }

    func testMessageIsCappedAtTwoHundredCharacters() throws {
        XCTAssertEqual(EventLog.sanitize(String(repeating: "a b ", count: 500)).count, 200)
        let (log, _) = make()
        log.record(.info, area: "app", event: "long", message: String(repeating: "word ", count: 400))
        log.flush()
        XCTAssertEqual((try lines()[0]["message"] as? String)?.count, 200)
    }

    func testRepeatedFailureIsWrittenOnceThenOnAChangeOrAfterSixHours() throws {
        let (log, clock) = make()
        let account = UUID()
        for _ in 0..<100 {
            log.record(.warn, area: "usage", event: "usage_failed", provider: "p", account: account, status: 401, dedupe: true)
        }
        log.flush()
        XCTAssertEqual(try lines().count, 1)

        log.record(.warn, area: "usage", event: "usage_failed", provider: "p", account: account, status: 500, dedupe: true)
        log.flush()
        XCTAssertEqual(try lines().count, 2)

        for _ in 0..<10 { log.record(.warn, area: "usage", event: "usage_failed", provider: "p", account: account, status: 500, dedupe: true) }
        clock.advance(6 * 3_600 + 1)
        log.record(.warn, area: "usage", event: "usage_failed", provider: "p", account: account, status: 500, dedupe: true)
        log.flush()
        let rows = try lines()
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[2]["repeats"] as? Int, 10)

        // Another account is its own stream; an event without dedupe is never dropped.
        log.record(.warn, area: "usage", event: "usage_failed", provider: "p", account: UUID(), status: 500, dedupe: true)
        log.record(.info, area: "switch", event: "switch", message: "ok")
        log.record(.info, area: "switch", event: "switch", message: "ok")
        log.flush()
        XCTAssertEqual(try lines().count, 6)
    }

    func testUsageFailureAuthTransitionAndRecovery() throws {
        let (log, _) = make()
        let account = UUID()
        for _ in 0..<5 {
            log.usageFailed(provider: "zai", account: account, error: ProviderError.unauthorized("The provider rejected this credential."), status: 401)
        }
        log.usageFailed(provider: "zai", account: account, error: CancellationError(), status: nil)
        XCTAssertTrue(log.isFailing(account))
        log.usageRecovered(provider: "zai", account: account)
        log.usageRecovered(provider: "zai", account: account)
        log.usageFailed(provider: "zai", account: account, error: ProviderError.unauthorized("again"), status: 401)
        log.flush()
        let rows = try lines()
        XCTAssertEqual(rows.compactMap { $0["event"] as? String },
                       ["usage_failed", "sign_in_required", "usage_recovered", "usage_failed", "sign_in_required"])
        XCTAssertEqual(rows[0]["status"] as? Int, 401)
        XCTAssertEqual(rows[0]["message"] as? String, "ProviderError.unauthorized")
        XCTAssertEqual(rows[1]["area"] as? String, "auth")
        // Payload text never reaches the file.
        XCTAssertFalse(try String(contentsOf: directory.appending(path: "events.jsonl"), encoding: .utf8).contains("rejected"))
    }

    func testConcurrentWritersProduceWholeLines() async throws {
        let (log, _) = make()
        await withTaskGroup(of: Void.self) { group in
            for task in 0..<8 {
                group.addTask {
                    for index in 0..<250 {
                        log.record(.info, area: "app", event: "t\(task)", message: "n\(index) " + String(repeating: "y", count: 60))
                    }
                }
            }
        }
        log.flush()
        XCTAssertEqual(try lines().count, 2_000)
    }

    func testSharedReturnsOneWriterPerFolder() {
        XCTAssertTrue(EventLog.shared(directory: directory) === EventLog.shared(directory: directory))
    }
}
