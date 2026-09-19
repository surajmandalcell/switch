import Foundation

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
