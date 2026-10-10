import Foundation

// Pace indicator for one rate window, after OpenUsage's Pace.swift. Pure: no clock, no I/O.
// The limit of a `UsageWindow` is always 100 (percent), so "used" is `usedPercent`.

public enum UsagePace {
    public enum Status: Equatable, Sendable { case ahead, onTrack, behind }

    public struct Evaluation: Equatable, Sendable {
        public var status: Status
        /// Projected usage at reset, in the same units as `used`.
        public var projected: Double
    }

    /// Colour band when no pace signal exists. Blue, yellow, red.
    public enum Level: Equatable, Sendable { case normal, warning, critical }

    public enum MeterState: Equatable, Sendable {
        case noData
        case level(Level, label: String?)
        /// Limit reached (red).
        case spent
        /// Projected to finish with at least 10% to spare (blue).
        case healthy(projectedFraction: Double)
        /// Projected to finish inside the last 10% (yellow).
        case closeToLimit(label: String, projectedFraction: Double)
        /// Projected to run out before reset (red). `eta` is seconds until the limit.
        case runningOut(eta: TimeInterval?, projectedFraction: Double?)
    }

    static func minElapsed(period: TimeInterval) -> TimeInterval { max(60, 0.01 * period) }

    static func elapsed(resetsAt: Date, period: TimeInterval, now: Date) -> TimeInterval {
        now.timeIntervalSince(resetsAt.addingTimeInterval(-period))
    }

    public static func evaluate(used: Double, limit: Double, resetsAt: Date, period: TimeInterval,
                                now: Date) -> Evaluation? {
        guard limit > 0, period > 0, used > 0, now < resetsAt else { return nil }
        let elapsed = elapsed(resetsAt: resetsAt, period: period, now: now)
        guard elapsed >= minElapsed(period: period) else { return nil }
        let projected = used / elapsed * period
        if used >= limit { return .init(status: .behind, projected: projected) }
        if projected <= 0.9 * limit { return .init(status: .ahead, projected: projected) }
        if projected <= limit { return .init(status: .onTrack, projected: projected) }
        return .init(status: .behind, projected: projected)
    }

    /// Seconds until the limit at the current burn rate; only when the status is `behind` and the
    /// limit lands before the reset.
    public static func secondsToRunOut(used: Double, limit: Double, resetsAt: Date, period: TimeInterval,
                                       now: Date) -> TimeInterval? {
        guard let result = evaluate(used: used, limit: limit, resetsAt: resetsAt, period: period, now: now),
              result.status == .behind else { return nil }
        let rate = result.projected / period
        guard rate > 0 else { return nil }
        let eta = (limit - used) / rate
        return eta > 0 && eta < resetsAt.timeIntervalSince(now) ? eta : nil
    }

    public static func level(usedFraction: Double) -> Level {
        let percent = (min(max(usedFraction, 0), 1) * 100).rounded()
        return percent >= 90 ? .critical : percent >= 80 ? .warning : .normal
    }

    public static func meterState(_ window: UsageWindow, now: Date) -> MeterState {
        guard let used = window.usedPercent else { return .noData }
        let limit = 100.0
        if (limit - used).rounded() <= 0 { return .spent }
        let band = MeterState.level(level(usedFraction: used / limit), label: nil)
        guard let resetsAt = window.resetsAt, let minutes = window.windowMinutes, minutes > 0 else { return band }
        let period = TimeInterval(minutes) * 60
        // ponytail: "Not started" applies to windows up to one day; weekly 0% is ordinary, not idle.
        // Use a provider's explicit "not started" flag instead if one starts returning it.
        if used == 0, now < resetsAt, minutes <= 24 * 60 {
            return .level(.normal, label: "Not started")
        }
        guard let result = evaluate(used: used, limit: limit, resetsAt: resetsAt, period: period, now: now)
        else { return band }
        let fraction = result.projected / limit
        switch result.status {
        case .ahead:
            return .healthy(projectedFraction: fraction)
        case .onTrack:
            if used / limit < 0.05 { return band }
            let spare = Int(((1 - fraction) * 100).rounded())
            return spare < 1 ? .runningOut(eta: nil, projectedFraction: nil)
                : .closeToLimit(label: "~\(spare)% spare", projectedFraction: fraction)
        case .behind:
            if used / limit < 0.05 { return band }
            let eta = secondsToRunOut(used: used, limit: limit, resetsAt: resetsAt, period: period, now: now)
            return .runningOut(eta: eta, projectedFraction: fraction)
        }
    }

    /// Even-pace marker position, 0...1 along the bar. Shown for yellow and red always; blue only
    /// when `showHealthy`. Flipped to `1 - x` when the bar shows what is left.
    public static func paceTick(_ window: UsageWindow, now: Date, showHealthy: Bool = false,
                                showingLeft: Bool = false) -> Double? {
        guard let resetsAt = window.resetsAt, let minutes = window.windowMinutes, minutes > 0,
              now < resetsAt else { return nil }
        switch meterState(window, now: now) {
        case .closeToLimit, .runningOut: break
        case .healthy where showHealthy: break
        default: return nil
        }
        let period = TimeInterval(minutes) * 60
        let elapsed = elapsed(resetsAt: resetsAt, period: period, now: now)
        guard elapsed >= minElapsed(period: period) else { return nil }
        let x = min(max(elapsed / period, 0), 1)
        return showingLeft ? 1 - x : x
    }

    /// Hover text for the bar, or nil when the state has none.
    public static func tooltip(_ state: MeterState) -> String? {
        switch state {
        case .healthy(let fraction):
            return "~\(Int(((1 - fraction) * 100).rounded()))% left at reset"
        case .closeToLimit(_, let fraction):
            return "~\(Int((fraction * 100).rounded()))% used at reset"
        case .runningOut(_, let fraction):
            guard let fraction, fraction > 1 else { return "~100% used at reset" }
            return "~\(max(1, Int(((fraction - 1) * 100).rounded())))% over limit at reset"
        case .spent:
            return "Limit reached"
        case .noData, .level:
            return nil
        }
    }

    /// Short label shown beside the bar, such as "Limit in 3h 5m" or "~12% spare".
    public static func label(_ state: MeterState) -> String? {
        switch state {
        case .level(_, let label): label
        case .closeToLimit(let label, _): label
        case .runningOut(let eta, _): eta.map { "Limit in \(duration($0))" }
        case .spent: "Limit reached"
        case .healthy, .noData: nil
        }
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(Int(seconds / 60), 0)
        let (days, hours, rest) = (minutes / 1440, minutes % 1440 / 60, minutes % 60)
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(rest)m" }
        return "\(rest)m"
    }
}
