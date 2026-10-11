import AIManagerCore
import Foundation

// Display preferences that are plain UserDefaults values: hidden usage rows, the menu-bar
// refresh habit, and the Reset settings list. Reset times are in ResetDisplay.swift.

/// Usage rows (windows) an account's detail hides. Stored as one newline-joined string per
/// account so a SwiftUI `@AppStorage` redraws the page when it changes.
enum HiddenUsageRows {
  private static let prefix = "hiddenUsageRows."

  static func key(for accountID: UUID) -> String { prefix + accountID.uuidString }

  static func parse(_ raw: String) -> Set<String> {
    Set(raw.split(separator: "\n").map(String.init))
  }

  static func encode(_ ids: Set<String>) -> String { ids.sorted().joined(separator: "\n") }

  static func hidden(for accountID: UUID, defaults: UserDefaults = .standard) -> Set<String> {
    parse(defaults.string(forKey: key(for: accountID)) ?? "")
  }

  /// The usage the popover and status item show: hidden windows are left out.
  static func applying(
    to usage: ProviderUsage, for accountID: UUID, defaults: UserDefaults = .standard
  ) -> ProviderUsage {
    var copy = usage
    copy.windows = visible(
      usage.windows, hidden: hidden(for: accountID, defaults: defaults), id: \.id)
    return copy
  }

  /// Rows that stay on screen. `id` reads a row's stable identity.
  static func visible<Row>(_ rows: [Row], hidden: Set<String>, id: (Row) -> String) -> [Row] {
    hidden.isEmpty ? rows : rows.filter { !hidden.contains(id($0)) }
  }
}

/// The popover and the status item refresh when the user asks; this extra opt-in also refreshes
/// every time the popover opens.
enum PopoverRefreshPreference {
  static let key = "refreshWhenMenuOpens"
  static func isEnabled(defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key) }
}

/// Reset settings: every preference key Switch's Settings page owns, so "Reset settings" can
/// return them to their defaults. Window placement, account order, saved credentials, and the
/// system-owned login item are not preferences and stay.
enum SettingsReset {
  static let keys = [
    "appearanceMode", "usageTokenPeriod", ChatFilterPersistence.defaultsKey,
    AIManagerWindowBehavior.minimizeToTrayKey,
    MenuBarUsagePreferences.defaultKey, MenuBarTokenPeriod.preferenceKey,
    UsagePercentagePreferences.showsUsedKey, ProviderStatusPoller.enabledKey, EmailPrivacy.key,
    QuotaNotificationSettings.almostOutKey, QuotaNotificationSettings.paceKey,
    QuotaNotificationSettings.availableAgainKey, QuotaNotificationSettings.signInAgainKey,
    ResetDisplay.exactKey, ResetDisplay.hourFormatKey, PopoverRefreshPreference.key,
    GlobalShortcutPreferences.key,
  ]
  /// Per-account keys share a prefix.
  static let prefixes = ["showAccountUsageInMenuBar.account.", "hiddenUsageRows."]

  static func reset(defaults: UserDefaults = .standard) {
    for key in keys { defaults.removeObject(forKey: key) }
    for key in defaults.dictionaryRepresentation().keys where prefixes.contains(where: key.hasPrefix) {
      defaults.removeObject(forKey: key)
    }
  }
}
