import Foundation

/// Auto switch (specs/product.md, Settings item 7a). These are the pure decisions; the app owns
/// the preferences, the notification, and the switch itself.
public enum AutoSwitch {
    /// "Switch when an account has" choices, in percent left. The first is the default.
    public static let thresholds = [1, 2, 5, 10, 20]
    public static let defaultResumeMessage =
        "Continue. A usage limit cut your last turn short; redo the last step if it did not finish."

    public struct Candidate: Equatable, Sendable {
        public var id: UUID
        /// Nil when the account is signed out or has no usage yet: it can neither trigger nor receive a switch.
        public var leftPercent: Double?

        public init(id: UUID, leftPercent: Double?) {
            self.id = id
            self.leftPercent = leftPercent
        }
    }

    public enum Decision: Equatable, Sendable {
        case stay
        case switchTo(UUID)
        /// The default is at the threshold and no other account is above it.
        case noneLeft
    }

    /// Percent left of the lower of the session and weekly windows. A provider with neither
    /// reports its lowest window instead. A window whose reset time has passed counts as full, so
    /// cached numbers from before the reset never trigger a switch. Nil without any usage figure.
    public static func leftPercent(of windows: [UsageWindow], now: Date = Date()) -> Double? {
        let main = windows.filter { $0.id == "session" || $0.id == "weekly" }
        let pool = main.isEmpty ? windows : main
        return pool.compactMap { window in
            window.usedPercent.map { used in
                window.resetsAt.map { $0 <= now } == true ? 100 : max(0, 100 - used)
            }
        }.min()
    }

    /// `order` is one provider's accounts in Accounts-page order. Acts only when the default
    /// account is at or below `threshold` percent left, then picks the first other account in order
    /// that is above it. A switched-away account is at or below the threshold until it recovers, so
    /// it is skipped, and the new default is above it, so nothing switches back and forth.
    public static func decide(order: [Candidate], defaultID: UUID, threshold: Double) -> Decision {
        guard let current = order.first(where: { $0.id == defaultID }),
              let left = current.leftPercent, left <= threshold else { return .stay }
        if let next = order.first(where: { $0.id != defaultID && ($0.leftPercent ?? -1) > threshold }) {
            return .switchTo(next.id)
        }
        return .noneLeft
    }
}
