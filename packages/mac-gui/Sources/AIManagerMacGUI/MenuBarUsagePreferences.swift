import Foundation
import AIManagerCore

enum MenuBarServicePreferences {
  static let orderKey = "menuBarServiceOrder"
  static let hiddenKey = "menuBarHiddenServices"
  static let hiddenAccountsKey = "menuBarHiddenAccounts"
  static let onePerServiceKey = "menuBarOneAccountPerService"

  static func order(defaults: UserDefaults = .standard) -> [ProviderID] {
    (defaults.stringArray(forKey: orderKey) ?? []).map { ProviderID(rawValue: $0) }
  }

  static func hiddenServices(defaults: UserDefaults = .standard) -> Set<ProviderID> {
    Set((defaults.stringArray(forKey: hiddenKey) ?? []).map { ProviderID(rawValue: $0) })
  }

  static func orderedProviders(_ providers: [ProviderID], order: [ProviderID]) -> [ProviderID] {
    var seen: Set<ProviderID> = []
    let present = Set(providers)
    return (order + providers).filter { present.contains($0) && seen.insert($0).inserted }
  }

  static func orderedProviders(_ providers: [ProviderID], defaults: UserDefaults = .standard) -> [ProviderID] {
    orderedProviders(providers, order: order(defaults: defaults))
  }

  static func move(_ provider: ProviderID, to target: ProviderID, in providers: [ProviderID],
                   defaults: UserDefaults = .standard) {
    var ordered = orderedProviders(providers, defaults: defaults)
    guard let from = ordered.firstIndex(of: provider), let to = ordered.firstIndex(of: target), from != to else { return }
    ordered.remove(at: from)
    ordered.insert(provider, at: to)
    let absent = order(defaults: defaults).filter { !ordered.contains($0) }
    defaults.set((ordered + absent).map(\.rawValue), forKey: orderKey)
  }

  static func showsInTray(_ provider: ProviderID, defaults: UserDefaults = .standard) -> Bool {
    !hiddenServices(defaults: defaults).contains(provider)
  }

  static func toggleVisibility(_ provider: ProviderID, defaults: UserDefaults = .standard) {
    var hidden = hiddenServices(defaults: defaults)
    if !hidden.insert(provider).inserted { hidden.remove(provider) }
    defaults.set(hidden.map(\.rawValue).sorted(), forKey: hiddenKey)
  }

  static func hiddenAccounts(defaults: UserDefaults = .standard) -> Set<UUID> {
    Set((defaults.stringArray(forKey: hiddenAccountsKey) ?? []).compactMap(UUID.init(uuidString:)))
  }

  static func toggleAccountVisibility(_ account: UUID, defaults: UserDefaults = .standard) {
    var hidden = hiddenAccounts(defaults: defaults)
    if !hidden.insert(account).inserted { hidden.remove(account) }
    defaults.set(hidden.map(\.uuidString).sorted(), forKey: hiddenAccountsKey)
  }

  static func showsOnePerService(defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: onePerServiceKey)
  }
}

enum MenuBarUsagePreferences {
  static let expandedAccountKey = "menuBarExpandedAccount"
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

  /// Used keeps overage above 100; left stops at 0. Negative input reads as 0.
  static func displayedPercentage(forUsed used: Int, showsUsed: Bool) -> Int {
    let used = max(used, 0)
    return showsUsed ? used : max(100 - used, 0)
  }

  /// Bar fill, 0...1. Bars never draw past their track even when the text shows overage.
  static func fill(forUsed used: Int, showsUsed: Bool) -> Double {
    min(max(Double(displayedPercentage(forUsed: used, showsUsed: showsUsed)) / 100, 0), 1)
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
