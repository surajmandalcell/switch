import Foundation

/// Shared row builders for the plugin providers, so each mapper matches CodexBar's detail rows.
enum PluginFmt {
    /// Same text as JavaScript `Date.toISOString()`: UTC with milliseconds.
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// A row whose plugin form has a `secondaryValue`; the contract has one value, so join with " · ".
    static func row(_ label: String, _ value: String, _ secondary: String? = nil,
                    progress: Double? = nil) -> UsageRow {
        .init(label, secondary.map { "\(value) · \($0)" } ?? value, progress: progress)
    }

    /// Calendar day such as "2026-07-01" in UTC.
    static func day(_ date: Date) -> String { String(iso(date).prefix(10)) }

    /// "09-21 10:30" in UTC.
    static func shortTime(_ date: Date) -> String {
        let text = iso(date)
        return "\(text.dropFirst(5).prefix(5)) \(text.dropFirst(11).prefix(5))"
    }

    /// "Oct 1" in the local time zone, like the plugin host's `format.monthDay`.
    static func monthDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    /// The "Subscription" section for `subscriptionRenewsAt` and `subscriptionExpiresAt`; empty when both are nil.
    static func renewal(_ renews: Date?, expires: Date? = nil) -> UsageSection {
        UsageSection("Subscription", [renews.map { .init("Renews", day($0)) },
                                      expires.map { .init("Expires", day($0)) }].compactMap { $0 })
    }
}
