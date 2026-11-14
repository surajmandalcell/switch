import Foundation
import XCTest
@testable import AIManagerCore
@testable import SwitchAppModel

final class AppEngineLaneTests: XCTestCase {
    var root: URL!
    var paths: ManagerPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "AppEngineLaneTests-\(UUID().uuidString)")
        paths = .init(applicationSupport: root.appending(path: "support"),
                      credentialStore: root.appending(path: "user/.switch/codex"),
                      defaultHome: root.appending(path: "user/.codex"),
                      sharedRoot: root.appending(path: "user/.codex"),
                      orcaAccountsRoot: root.appending(path: "orca"), isolationRoot: root)
    }

    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    func engine(clock: ManualClock = ManualClock()) throws -> AppEngine {
        AppEngine(manager: try AccountManager(paths: paths, writerCheck: { _ in .inactive }, providerSpecs: []),
                  paths: paths, clock: clock)
    }

    /// Waits in real time until `clock` has `count` parked sleepers, so `advance` wakes them.
    func parked(_ clock: ManualClock, _ count: Int = 1) async throws {
        let deadline = Date().addingTimeInterval(5)
        while clock.sleeperCount < count {
            guard Date() < deadline else { return XCTFail("no task parked on the clock") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private struct Failure: LocalizedError { var errorDescription: String? { "The disk is full." } }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if opened { lock.unlock(); continuation.resume() } else { waiter = continuation; lock.unlock() }
            }
        }
        func open() {
            lock.lock()
            opened = true
            let waiter = waiter
            self.waiter = nil
            lock.unlock()
            waiter?.resume()
        }
    }

    func testSecondActionWhileBusyIsDropped() async throws {
        let engine = try engine()
        let gate = Gate()
        let first = Task { try await engine.perform { await gate.wait() } }
        while !(await engine.app.isBusy) { await Task.yield() }
        var ran = false
        do {
            try await engine.perform { }
            ran = true
        } catch {
            XCTAssertEqual(error as? AppEngineError, .busy)
        }
        XCTAssertFalse(ran)
        gate.open()
        try await first.value
        let busy = await engine.app.isBusy
        XCTAssertFalse(busy)
        try await engine.perform { }
    }

    func testFailureSetsErrorTextAndNextActionClearsIt() async throws {
        let engine = try engine()
        do {
            try await engine.perform(failure: "Couldn’t load accounts.", recovery: "Refresh later.") { throw Failure() }
            XCTFail("the action must rethrow")
        } catch {}
        var error = await engine.notices.error
        XCTAssertEqual(error, "Couldn’t load accounts. The disk is full. Refresh later.")
        try await engine.perform { }
        error = await engine.notices.error
        XCTAssertNil(error)
    }

    func testUnavailableEngineRefusesActions() async throws {
        let engine = AppEngine(manager: nil, paths: paths, clock: ManualClock())
        let isUnavailable = await engine.app.isUnavailable
        XCTAssertTrue(isUnavailable)
        do {
            try await engine.perform { }
            XCTFail("an unavailable engine must refuse")
        } catch {
            XCTAssertEqual(error as? AppEngineError, .unavailable)
        }
        let error = await engine.notices.error
        XCTAssertEqual(error, AppEngine.unavailableText)
    }

    func testChangesInsideOneWindowCoalesceIntoOneRev() async throws {
        let clock = ManualClock()
        let engine = try engine(clock: clock)
        var changes = engine.changes.makeAsyncIterator()
        await engine.setNotice("one")
        await engine.setNotice("two")
        await engine.setNotice("three")
        try await parked(clock)
        XCTAssertEqual(clock.sleeperCount, 1, "one flush timer per topic and window")
        clock.advance(seconds: AppEngine.coalesceInterval)
        let change = await changes.next()
        XCTAssertEqual(change?.topic, .notices)
        XCTAssertEqual(change?.rev, 1)
        XCTAssertEqual((change?.value as? NoticesValue)?.notice, "three")
        let snapshot = await engine.snapshot([.notices, .app])
        XCTAssertEqual(snapshot[.notices]?.rev, 1)
        XCTAssertEqual(snapshot[.app]?.rev, 0)

        // The same value again is not a change; a value set and reverted inside one window is not either.
        await engine.setNotice("three")
        XCTAssertEqual(clock.sleeperCount, 0)
        await engine.setNotice("four")
        await engine.setNotice("three")
        try await parked(clock)
        clock.advance(seconds: AppEngine.coalesceInterval)
        while await engine.isFlushScheduled(.notices) { await Task.yield() }
        await engine.setNotice("five")
        try await parked(clock)
        clock.advance(seconds: AppEngine.coalesceInterval)
        let next = await changes.next()
        XCTAssertEqual(next?.rev, 2, "revs have no gaps")
        XCTAssertEqual((next?.value as? NoticesValue)?.notice, "five")
    }

    func testStartPublishesLoadedOnceAndStopEndsChanges() async throws {
        let clock = ManualClock()
        let engine = try engine(clock: clock)
        var changes = engine.changes.makeAsyncIterator()
        await engine.start()
        await engine.start()
        try await parked(clock)
        clock.advance(seconds: AppEngine.coalesceInterval)
        let change = await changes.next()
        XCTAssertEqual(change?.topic, .app)
        XCTAssertEqual((change?.value as? AppStateValue)?.hasLoaded, true)
        await engine.stop()
        let end = await changes.next()
        XCTAssertNil(end)
    }
}
