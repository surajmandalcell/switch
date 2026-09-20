import Foundation
import AIManagerCore

enum MenuBarUsagePreferences {
  static let defaultKey = "showAccountUsageInMenuBar"
  private static let overridePrefix = "showAccountUsageInMenuBar.account."

  static func explicitValue(for accountID: UUID, defaults: UserDefaults = .standard) -> Bool? {
    let key = overrideKey(for: accountID)
    guard defaults.object(forKey: key) != nil else { return nil }
    return defaults.bool(forKey: key)
  }

  static func showsUsage(for accountID: UUID, defaults: UserDefaults = .standard) -> Bool {
    explicitValue(for: accountID, defaults: defaults)
      ?? (defaults.object(forKey: defaultKey) == nil || defaults.bool(forKey: defaultKey))
  }

  static func setOverride(
    _ showsUsage: Bool,
    for accountID: UUID,
    defaults: UserDefaults = .standard
  ) {
    defaults.set(showsUsage, forKey: overrideKey(for: accountID))
  }

  static func useDefault(for accountID: UUID, defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: overrideKey(for: accountID))
  }

  static func overrideKey(for accountID: UUID) -> String {
    overridePrefix + accountID.uuidString
  }
}

enum UsagePercentagePreferences {
  static let showsUsedKey = "showUsageAsUsed"

  static func showsUsed(defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: showsUsedKey)
  }

  static func displayedPercentage(forUsed used: Int, showsUsed: Bool) -> Int {
    let clamped = min(max(used, 0), 100)
    return showsUsed ? clamped : 100 - clamped
  }

  static func label(forUsed used: Int, showsUsed: Bool) -> String {
    "\(displayedPercentage(forUsed: used, showsUsed: showsUsed))% \(showsUsed ? "used" : "left")"
  }
}

enum MenuBarTokenPeriod: String, CaseIterable, Identifiable, Sendable {
  static let preferenceKey = "menuBarTokenPeriod"

  case sinceReset
  case today
  case yesterday
  case weekly
  case monthly
  case yearly

  var id: Self { self }

  var label: String {
    switch self {
    case .sinceReset: "Since reset"
    case .today: "Today"
    case .yesterday: "Yesterday"
    case .weekly: "Weekly"
    case .monthly: "Monthly"
    case .yearly: "Yearly"
    }
  }

  var summaryLabel: String {
    switch self {
    case .sinceReset: "since reset"
    case .today: "today"
    case .yesterday: "yesterday"
    case .weekly: "in 7 days"
    case .monthly: "in 30 days"
    case .yearly: "in 1 year"
    }
  }

  static func selected(defaults: UserDefaults = .standard) -> Self {
    defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .sinceReset
  }

  func tokens(
    in rows: [CodexDailyUsageSnapshot],
    usage: CodexAccountUsageSnapshot?,
    now: Date = Date()
  ) -> Int64 {
    guard self == .sinceReset else {
      let period = CodexTokenPeriod(rawValue: rawValue) ?? .weekly
      return period.tokens(in: rows, endingAt: now)
    }
    let bucket = usage?.rateLimits?.defaultBucket
    let windows = [bucket?.primary, bucket?.secondary].compactMap { $0 }
    guard let weekly = windows.filter({ ($0.windowDurationMinutes ?? 0) >= 10_080 })
      .max(by: { ($0.windowDurationMinutes ?? 0) < ($1.windowDurationMinutes ?? 0) }),
      let reset = weekly.resetsAt,
      let minutes = weekly.windowDurationMinutes,
      minutes > 0
    else { return CodexTokenPeriod.weekly.tokens(in: rows, endingAt: now) }
    let start = reset.addingTimeInterval(-TimeInterval(minutes) * 60)
    return CodexTokenPeriod.tokens(in: rows, from: start, through: now)
  }
}
