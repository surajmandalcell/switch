import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchAppModel

/// The `accounts` topic and the provider usage cadence, in virtual time, with a synthetic provider.
final class AppEngineAccountsTests: XCTestCase {
    var root: URL!
    var paths: ManagerPaths!
    let provider = ProviderID(rawValue: "test-engine")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "AppEngineAccountsTests-\(UUID().uuidString)")
        paths = .init(applicationSupport: root.appending(path: "support"),
                      credentialStore: root.appending(path: "user/.switch/codex"),
                      defaultHome: root.appending(path: "user/.codex"),
                      sharedRoot: root.appending(path: "user/.codex"),
                      orcaAccountsRoot: root.appending(path: "orca"), isolationRoot: root)
    }

    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    /// What the synthetic provider answers, and how often it was asked.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var error: ProviderError?
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        func fetch() throws -> FetchResult {
            lock.lock()
            count += 1
            let error = error
            lock.unlock()
            if let error { throw error }
            return FetchResult(ProviderUsage(windows: [UsageWindow(id: "session", title: "Session", usedPercent: 40)],
                                             plan: "Pro"))
        }
    }

    func start(_ script: Script, clock: ManualClock) async throws -> (AppEngine, UUID) {
        let spec = ProviderSpec(id: provider.rawValue, name: "Engine Test", style: .secret,
                                fields: [.apiKey("TEST_ENGINE_KEY")], fetch: { _ in try script.fetch() })
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive }, providerSpecs: [spec])
        let account = try await manager.addProviderAccount(providerID: provider, fields: ["apiKey": "sk-test-\(UUID())"])
        let engine = AppEngine(manager: manager, paths: paths, clock: clock)
        await engine.setRefreshesInIsolation(true)
        await engine.start()
        try await until {
            let refreshing = await self.row(engine)?.isRefreshing
            return script.calls == 1 && refreshing == false
        }
        return (engine, account.id)
    }

    /// The newest row, before its 100 ms window commits it.
    func row(_ engine: AppEngine) async -> AccountRow? {
        (await engine.latest(.accounts) as? AccountsValue)?.rows.first
    }

    /// Lets queued tasks run; fails after 5 s of real time.
    func until(_ condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()) {
            guard Date() < deadline else { return XCTFail("condition not met") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// Advances virtual time once every engine timer is parked: the two cadences plus one flush per changed topic.
    func advance(_ engine: AppEngine, _ clock: ManualClock, _ seconds: TimeInterval) async throws {
        try await until {
            let flushes = await engine.scheduledFlushes
            let refreshing = await engine.providerUsage.values.contains { $0.isRefreshing }
            return !refreshing && clock.sleeperCount == 2 + flushes
        }
        clock.advance(seconds: seconds)
    }

    func testStartPublishesRowsWithProviderUsage() async throws {
        let clock = ManualClock()
        let (engine, id) = try await start(Script(), clock: clock)
        try await advance(engine, clock, AppEngine.coalesceInterval)
        try await until { await engine.snapshot([.accounts])[.accounts]!.rev >= 1 }
        let found = await row(engine)
        let row = try XCTUnwrap(found)
        XCTAssertEqual(row.id, id.uuidString.lowercased())
        XCTAssertEqual(row.providerID, "test-engine")
        XCTAssertEqual(row.plan, "Pro")
        XCTAssertEqual(row.windows.map(\.usedPercent), [40])
        XCTAssertFalse(row.needsSignIn)
        XCTAssertNil(row.error)
        XCTAssertEqual(row.checkedAt, clock.now.addingTimeInterval(-AppEngine.coalesceInterval))
    }

    func testProviderCadenceIsFiveMinutes() async throws {
        let script = Script()
        let clock = ManualClock()
        let (engine, _) = try await start(script, clock: clock)
        try await advance(engine, clock, 299)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(script.calls, 1)
        try await advance(engine, clock, 1)
        try await until { script.calls == 2 }
    }

    func testRateLimitWaitsForRetryAfter() async throws {
        let script = Script()
        script.error = .rateLimited("Slow down.", retryAfter: 900)
        let clock = ManualClock()
        let (engine, _) = try await start(script, clock: clock)
        let error = await row(engine)?.error
        XCTAssertEqual(error, "Slow down.")
        try await advance(engine, clock, 300)
        try await advance(engine, clock, 300)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(script.calls, 1, "the 300 s ticks fall inside the 900 s Retry-After")
        try await advance(engine, clock, 300)
        try await until { script.calls == 2 }
    }

    func testRejectedCredentialIsNotSentAgain() async throws {
        let script = Script()
        script.error = .unauthorized("Bad key.")
        let clock = ManualClock()
        let (engine, _) = try await start(script, clock: clock)
        // The stored verification arrives with the reload that follows the usage result.
        try await until { await self.row(engine)?.verification == "needsSignIn" }
        var found = await row(engine)
        var row = try XCTUnwrap(found)
        XCTAssertTrue(row.needsSignIn)
        XCTAssertTrue(row.windows.isEmpty)
        try await advance(engine, clock, 300)
        try await until { (await self.row(engine))?.checkedAt == clock.now }
        XCTAssertEqual(script.calls, 1, "a rejected key is not sent again on the cadence")
        found = await self.row(engine)
        row = try XCTUnwrap(found)
        XCTAssertTrue(row.needsSignIn)
    }

    func testUnchangedRowsPublishNothing() async throws {
        let clock = ManualClock()
        let (engine, _) = try await start(Script(), clock: clock)
        try await advance(engine, clock, AppEngine.coalesceInterval)
        try await until { await engine.snapshot([.accounts])[.accounts]!.rev >= 1 }
        let before = await engine.snapshot([.accounts])[.accounts]!.rev
        await engine.reloadAccounts()
        let scheduled = await engine.isFlushScheduled(.accounts)
        XCTAssertFalse(scheduled)
        let after = await engine.snapshot([.accounts])[.accounts]!.rev
        XCTAssertEqual(before, after)
    }

    func testIsolatedEngineReadsNoUsage() async throws {
        let script = Script()
        let spec = ProviderSpec(id: provider.rawValue, name: "Engine Test", style: .secret,
                                fields: [.apiKey("TEST_ENGINE_KEY")], fetch: { _ in try script.fetch() })
        let manager = try AccountManager(paths: paths, writerCheck: { _ in .inactive }, providerSpecs: [spec])
        _ = try await manager.addProviderAccount(providerID: provider, fields: ["apiKey": "sk-test-\(UUID())"])
        let engine = AppEngine(manager: manager, paths: paths, clock: ManualClock())
        await engine.start()
        await engine.refreshProviderUsage(onCadence: true)
        XCTAssertEqual(script.calls, 0)
        let rows = await engine.snapshot([.accounts])[.accounts]?.value as? AccountsValue
        XCTAssertNil(rows?.rows.first, "rows are published after the 100 ms window")
        await engine.stop()
    }

    func testCodexWindowsMergeBucketsAndPrefixDuplicateTitles() throws {
        let window = CodexRateLimitWindowSnapshot(usedPercent: 10, windowDurationMinutes: 300, resetsAt: nil)
        let bucket = { (id: String, name: String?) in
            CodexRateLimitBucketSnapshot(id: id, name: name, plan: nil, model: nil, primary: window, secondary: nil,
                                         credits: nil, spendControlReached: nil)
        }
        let limits = CodexRateLimitsSnapshot(accountID: nil, ordinaryUsageAllowed: nil, defaultBucket: bucket("codex", nil),
                                             buckets: ["codex": bucket("codex", nil), "b-other": bucket("b-other", "Other")])
        let snapshot = CodexAccountUsageSnapshot(account: nil, requiresOpenAIAuthentication: nil, rateLimits: limits,
                                                 usage: nil, dailyUsage: [], fetchedAt: Date())
        let account = AccountRecord(id: UUID(), identity: .init(email: "a@example.test", authMode: .chatGPT),
                                    home: root, source: root, importedAt: Date(),
                                    verification: .init(state: .verifiedWithCodex, detail: ""), credentialDigest: "")
        let windows = AccountPresentation.windows(account, codex: snapshot, provider: nil)
        XCTAssertEqual(windows.count, 2, "the default bucket shows once")
        XCTAssertEqual(Set(windows.map(\.title)).count, 2, "duplicate titles get the bucket name")
        XCTAssertTrue(windows[1].title.hasPrefix("Other · "))
        var signedOut = account
        signedOut.verification.state = .needsSignIn
        XCTAssertTrue(AccountPresentation.windows(signedOut, codex: snapshot, provider: nil).isEmpty)
    }

    func testLabelRules() {
        XCTAssertEqual(AccountPresentation.label(.init(email: "a@example.test", authMode: .chatGPT)), "a@example.test")
        XCTAssertEqual(AccountPresentation.label(.init(providerID: .droid, email: "d@example.test", accountID: "org-1",
                                                       authMode: .apiKey)), "org-1 · d@example.test")
        XCTAssertEqual(AccountPresentation.label(.init(providerID: .codex, userID: "user-12345", authMode: .chatGPT)),
                       "Unresolved account")
        XCTAssertEqual(AccountPresentation.label(.init(providerID: .droid, userID: "user-12345", authMode: .apiKey)),
                       "\(ProviderID.droid.displayName) ···2345")
    }
}
