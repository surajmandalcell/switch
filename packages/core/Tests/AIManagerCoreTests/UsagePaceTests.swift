import XCTest
@testable import AIManagerCore

final class UsagePaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let period: TimeInterval = 6_000

    /// Window that is `elapsedFraction` through a 6,000 s period.
    private func window(used: Double?, elapsedFraction: Double, minutes: Int? = nil) -> UsageWindow {
        let reset = now.addingTimeInterval(period * (1 - elapsedFraction))
        return UsageWindow(id: "w", title: "W", usedPercent: used, resetsAt: reset,
                           windowMinutes: minutes ?? Int(period / 60))
    }

    private func evaluate(used: Double, elapsedFraction: Double) -> UsagePace.Evaluation? {
        UsagePace.evaluate(used: used, limit: 100, resetsAt: now.addingTimeInterval(period * (1 - elapsedFraction)),
                           period: period, now: now)
    }

    func testNoSignalBranches() {
        XCTAssertNil(evaluate(used: 0, elapsedFraction: 0.5))
        XCTAssertNil(evaluate(used: 10, elapsedFraction: 0.001))   // before the minimum elapsed time
        XCTAssertNil(evaluate(used: 10, elapsedFraction: 1))       // now == reset
        XCTAssertNil(UsagePace.evaluate(used: 10, limit: 0, resetsAt: now.addingTimeInterval(10), period: period, now: now))
    }

    func testAheadOnTrackBehind() {
        XCTAssertEqual(evaluate(used: 40, elapsedFraction: 0.5)?.status, .ahead)      // projects 80
        XCTAssertEqual(evaluate(used: 45, elapsedFraction: 0.5)?.status, .ahead)      // exactly 90
        XCTAssertEqual(evaluate(used: 48, elapsedFraction: 0.5)?.status, .onTrack)    // projects 96
        XCTAssertEqual(evaluate(used: 60, elapsedFraction: 0.5)?.status, .behind)     // projects 120
        XCTAssertEqual(evaluate(used: 100, elapsedFraction: 0.99)?.status, .behind)   // limit reached
    }

    func testSecondsToRunOut() throws {
        let reset = now.addingTimeInterval(3_000)
        // 60 used after 3,000 s: burn 0.02/s, 40 left lasts 2,000 s, before the reset.
        let eta = try XCTUnwrap(UsagePace.secondsToRunOut(used: 60, limit: 100, resetsAt: reset, period: period, now: now))
        XCTAssertEqual(eta, 2_000, accuracy: 1)
        XCTAssertNil(UsagePace.secondsToRunOut(used: 40, limit: 100, resetsAt: reset, period: period, now: now))
    }

    func testMeterStates() {
        XCTAssertEqual(UsagePace.meterState(window(used: nil, elapsedFraction: 0.5), now: now), .noData)
        XCTAssertEqual(UsagePace.meterState(window(used: 99.6, elapsedFraction: 0.5), now: now), .spent)
        XCTAssertEqual(UsagePace.meterState(window(used: 0, elapsedFraction: 0.5), now: now),
                       .level(.normal, label: "Not started"))
        if case .healthy(let fraction) = UsagePace.meterState(window(used: 40, elapsedFraction: 0.5), now: now) {
            XCTAssertEqual(fraction, 0.8, accuracy: 0.001)
        } else { XCTFail("expected healthy") }
        if case .closeToLimit(let label, _) = UsagePace.meterState(window(used: 48, elapsedFraction: 0.5), now: now) {
            XCTAssertEqual(label, "~4% spare")
        } else { XCTFail("expected closeToLimit") }
        // Lands at 99.6: less than 1% spare is a red flame.
        XCTAssertEqual(UsagePace.meterState(window(used: 49.8, elapsedFraction: 0.5), now: now),
                       .runningOut(eta: nil, projectedFraction: nil))
        if case .runningOut(let eta, let fraction) = UsagePace.meterState(window(used: 60, elapsedFraction: 0.5), now: now) {
            XCTAssertNotNil(eta)
            XCTAssertEqual(fraction ?? 0, 1.2, accuracy: 0.001)
        } else { XCTFail("expected runningOut") }
    }

    func testLevelBandsWithoutPace() {
        let bare = { (used: Double) in UsageWindow(id: "w", title: "W", usedPercent: used) }
        XCTAssertEqual(UsagePace.meterState(bare(50), now: now), .level(.normal, label: nil))
        XCTAssertEqual(UsagePace.meterState(bare(80), now: now), .level(.warning, label: nil))
        XCTAssertEqual(UsagePace.meterState(bare(90), now: now), .level(.critical, label: nil))
        // Early in the window a high reading is not trusted (under 5% used).
        XCTAssertEqual(UsagePace.meterState(window(used: 4, elapsedFraction: 0.01), now: now), .level(.normal, label: nil))
        // Weekly window with 0% is ordinary, not "Not started".
        XCTAssertEqual(UsagePace.meterState(window(used: 0, elapsedFraction: 0.5, minutes: 10_080), now: now),
                       .level(.normal, label: nil))
    }

    func testPaceTick() throws {
        let behind = window(used: 60, elapsedFraction: 0.5)
        XCTAssertEqual(try XCTUnwrap(UsagePace.paceTick(behind, now: now)), 0.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(UsagePace.paceTick(behind, now: now, showingLeft: true)), 0.5, accuracy: 0.001)
        let early = window(used: 60, elapsedFraction: 0.25)
        XCTAssertEqual(try XCTUnwrap(UsagePace.paceTick(early, now: now, showingLeft: true)), 0.75, accuracy: 0.001)
        let healthy = window(used: 40, elapsedFraction: 0.5)
        XCTAssertNil(UsagePace.paceTick(healthy, now: now))
        XCTAssertNotNil(UsagePace.paceTick(healthy, now: now, showHealthy: true))
        XCTAssertNil(UsagePace.paceTick(window(used: 99.9, elapsedFraction: 0.5), now: now))   // spent
        XCTAssertNil(UsagePace.paceTick(UsageWindow(id: "w", title: "W", usedPercent: 60), now: now))
    }

    func testTooltipsAndLabels() {
        XCTAssertEqual(UsagePace.tooltip(.healthy(projectedFraction: 0.8)), "~20% left at reset")
        XCTAssertEqual(UsagePace.tooltip(.closeToLimit(label: "", projectedFraction: 0.96)), "~96% used at reset")
        XCTAssertEqual(UsagePace.tooltip(.runningOut(eta: 1, projectedFraction: 1.2)), "~20% over limit at reset")
        XCTAssertEqual(UsagePace.tooltip(.runningOut(eta: nil, projectedFraction: nil)), "~100% used at reset")
        XCTAssertEqual(UsagePace.tooltip(.runningOut(eta: 1, projectedFraction: 1.001)), "~1% over limit at reset")
        XCTAssertEqual(UsagePace.tooltip(.spent), "Limit reached")
        XCTAssertNil(UsagePace.tooltip(.noData))
        XCTAssertEqual(UsagePace.label(.runningOut(eta: 11_100, projectedFraction: 1.2)), "Limit in 3h 5m")
        XCTAssertEqual(UsagePace.duration(90_000), "1d 1h")
        XCTAssertEqual(UsagePace.duration(1_800), "30m")
    }
}
