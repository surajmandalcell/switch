import Foundation

// Foundation-only search logic: the Settings index the toolbar search reads (`app.searchIndex`), and the
// Settings strings it shares with the Mac page. Moved from the Mac app (plan E2).

/// The Settings rows the toolbar search finds. Every row of `SettingsPage` has one entry; the page
/// shows a row only when its id matches. A term must appear in the section, title, help, or keywords.
public enum SettingsSearch {
  public struct Entry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let section: String
    public let title: String
    public let help: String
    /// Synonyms people type, such as "dark" for Appearance or "hotkey" for Menu shortcut.
    public let keywords: String
  }

  public static let notificationKeywords = "alert notify notification banner"

  public static let entries: [Entry] = {
    let c = SettingsCopy.self
    var list: [Entry] = [
      Entry(id: "login", section: "General", title: "Open at Login",
            help: "Open Switch in the menu bar when you sign in.", keywords: "startup launch boot login item"),
      Entry(id: "tray", section: "General", title: "Minimize to menu bar",
            help: "Hide the window and keep Switch available from its menu-bar icon.", keywords: "tray dock hide"),
      Entry(id: "place", section: "General", title: "When Switch opens",
            help: "Choose the page shown when Switch starts.", keywords: "startup launch home last page"),
      Entry(id: "shortcut", section: "General", title: c.menuShortcut, help: c.menuShortcutHelp,
            keywords: "hotkey keyboard key global"),
      Entry(id: "version", section: "General", title: c.version, help: c.versionHelp,
            keywords: "update upgrade release build about"),
      Entry(id: "appearance", section: "Appearance", title: "Appearance",
            help: "Choose the window and menu bar appearance.", keywords: "theme dark light mode system"),
      Entry(id: "percent", section: "Appearance", title: "Usage percentage",
            help: "Show the share left or the share used in every usage view.", keywords: "left used percent remaining"),
      Entry(id: "reset-times", section: "Appearance", title: c.resetTimes, help: c.resetTimesHelp,
            keywords: "countdown exact clock"),
      Entry(id: "hours", section: "Appearance", title: c.timeFormat, help: c.timeFormatHelp,
            keywords: "12 24 hour clock"),
      Entry(id: "domain", section: "Accounts", title: "Show full email addresses",
            help: "Show the full address, including the domain ending such as .com or .co.uk.",
            keywords: "privacy mask hide"),
      Entry(id: "hide-email", section: "Accounts", title: c.hideEmails, help: c.hideEmailsHelp,
            keywords: "privacy mask hide"),
      Entry(id: "privacy", section: "Accounts", title: c.privacyMode, help: c.privacyModeHelp,
            keywords: "privacy mask hide fake screenshot"),
      Entry(id: "status", section: "Accounts", title: c.checkProviderStatus, help: c.checkProviderStatusHelp,
            keywords: "incident outage"),
      Entry(id: "claude-shell", section: "Accounts", title: c.claudeShell, help: c.claudeShellHelp,
            keywords: "terminal zsh shell"),
      Entry(id: "auto", section: "Auto switch", title: c.autoSwitch, help: c.autoSwitchHelp,
            keywords: "automatic rotate limit"),
      Entry(id: "auto-threshold", section: "Auto switch", title: c.autoSwitchThreshold,
            help: c.autoSwitchThresholdHelp, keywords: "automatic rotate limit percent"),
      Entry(id: "auto-clis", section: "Auto switch", title: c.autoSwitchRunningCLIs,
            help: c.autoSwitchRunningCLIsHelp, keywords: "automatic rotate limit terminal restart"),
      Entry(id: "auto-resume", section: "Auto switch", title: c.autoSwitchResume,
            help: c.autoSwitchResumeHelp, keywords: "automatic rotate limit message prompt"),
      Entry(id: "menu-usage", section: "Menu bar", title: "Show account usage",
            help: "Accounts without their own choice show cached usage in Menubar.", keywords: "menubar popover"),
      Entry(id: "menu-one-per-service", section: "Menu bar", title: c.onePerService, help: c.onePerServiceHelp,
            keywords: "menubar tray single default account service provider"),
      Entry(id: "menu-tokens", section: "Menu bar", title: "Token summary",
            help: "Choose the period shown beside each account’s usage.", keywords: "menubar popover period"),
      Entry(id: "menu-refresh", section: "Menu bar", title: c.refreshOnOpen, help: c.refreshOnOpenHelp,
            keywords: "menubar popover update"),
    ]
    list += c.notificationRows.map {
      Entry(id: "notify.\($0.key)", section: c.notificationsTitle, title: $0.title, help: $0.help,
            keywords: notificationKeywords)
    }
    let folder = "folder path vault finder reveal"
    list += [
      Entry(id: "data.codex", section: "Data locations", title: "Codex home",
            help: "Settings, plugins, conversations, and databases stay here when accounts change.", keywords: folder),
      Entry(id: "data.codex-vault", section: "Data locations", title: "Codex account vault",
            help: "Private Codex auth.json snapshots.", keywords: folder),
      Entry(id: "data.grok", section: "Data locations", title: "Grok Build home",
            help: "Grok configuration, rules, plugins, sessions, and the active login.", keywords: folder),
      Entry(id: "data.grok-vault", section: "Data locations", title: "Grok Build account vault",
            help: "Private Grok subscription OAuth snapshots.", keywords: folder),
      Entry(id: "reset", section: "Reset", title: c.resetSettings, help: c.resetSettingsHelp,
            keywords: "default restore"),
    ]
    return list
  }()

  /// Lowercase and without accents, so "Éclair" and "eclair" meet.
  public static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }

  public static func terms(_ query: String) -> [String] {
    fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
  }

  /// The entries that match every term, best first: a title that starts with the query, then a
  /// title that contains every term, then the rest. Ties keep the page order.
  public static func search(_ query: String) -> [Entry] {
    let terms = terms(query)
    guard !terms.isEmpty else { return entries }
    let whole = terms.joined(separator: " ")
    var ranked: [(rank: Int, index: Int, entry: Entry)] = []
    for (index, entry) in entries.enumerated() {
      let title = fold(entry.title)
      let haystack = fold([entry.section, entry.title, entry.help, entry.keywords].joined(separator: " "))
      guard terms.allSatisfy({ haystack.contains($0) }) else { continue }
      let rank = title.hasPrefix(whole) ? 0 : (terms.allSatisfy({ title.contains($0) }) ? 1 : 2)
      ranked.append((rank, index, entry))
    }
    return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.entry)
  }

  /// Ids of the rows to show, or nil to show every row (an empty query).
  public static func visibleIDs(_ query: String) -> Set<String>? {
    terms(query).isEmpty ? nil : Set(search(query).map(\.id))
  }
}

/// Which Settings rows and sections a query leaves in the page.
public struct SettingsFilter {
  private let ids: Set<String>?
  private let sections: Set<String>

  public init(_ query: String) {
    let visible = SettingsSearch.visibleIDs(query)
    ids = visible
    sections = Set(SettingsSearch.entries.filter { visible?.contains($0.id) ?? true }.map(\.section))
  }

  public func shows(_ id: String) -> Bool { ids?.contains(id) ?? true }
  public func shows(section: String) -> Bool { sections.contains(section) }
  /// True for an empty query: every row shows, and so does the preview-only demo card.
  public var showsAll: Bool { ids == nil }
}

/// Titles and help text of the Settings rows that features add, shared with the GUI contract.
public enum SettingsCopy {
  public static let checkProviderStatus = "Check provider status"
  public static let checkProviderStatusHelp = "Show a dot beside a provider that reports an incident."
  public static let claudeShell = "Use the selected Claude account in terminals"
  public static let claudeShellHelp =
    "Adds one line to ~/.zshrc so a plain claude command uses the default Claude account. A backup is kept."
  public static let autoSwitch = "Switch accounts automatically"
  public static let autoSwitchHelp = "Make the next account in your Accounts order the default when one runs out."
  public static let autoSwitchThreshold = "Switch when an account has"
  public static let autoSwitchThresholdHelp = "Compares the lower of the session and weekly share left."
  public static let autoSwitchRunningCLIs = "Running CLIs"
  public static let autoSwitchRunningCLIsHelp =
    "Reopen Codex and Claude Code in Terminal on the new account once their turn ends."
  public static let autoSwitchResume = "Resume message"
  public static let autoSwitchResumeHelp = "Sent when a usage limit cut the last turn short."
  public static let hideEmails = "Hide email addresses"
  public static let hideEmailsHelp = "Mask account emails everywhere, such as a••••@example."
  public static let privacyMode = "Privacy mode"
  public static let privacyModeHelp = "Show made-up names, such as Jon Doe, instead of account names and emails."
  public static let resetTimes = "Reset times"
  public static let resetTimesHelp = "Show a countdown or the exact time. Click any reset text to switch."
  public static let timeFormat = "Time format"
  public static let timeFormatHelp = "Hour style for exact reset times."
  public static let menuShortcut = "Menu shortcut"
  public static let menuShortcutHelp = "Open or close the menu popover from anywhere. Off until you record one."
  public static let version = "Version"
  public static let versionHelp = "The installed version of Switch."
  public static let refreshOnOpen = "Refresh when the menu opens"
  public static let refreshOnOpenHelp = "Check usage each time the popover opens."
  public static let onePerService = "One account per service"
  public static let onePerServiceHelp = "The menu bar shows the default account of each service, or its first account with usage."
  public static let resetSettings = "Reset settings"
  public static let resetSettingsHelp =
    "Return every Settings choice, hidden usage row, and the menu shortcut to its default. Accounts stay."
  public static let notificationsTitle = "Notifications"
  /// Title, help text, and the settings key of each toggle (the Mac `QuotaNotificationSettings` keys). All off by
  /// default.
  public static let notificationRows: [(title: String, help: String, key: String)] = [
    ("Almost Out", "Alert when a usage window drops below 10% left.", "notifyAlmostOut"),
    ("Pace alerts", "Alert when usage will finish close to the limit or run out before the reset.", "notifyPaceAlerts"),
    ("Available again", "Alert when a used-up window resets and the account can be used again.", "notifyAvailableAgain"),
    ("Sign in again", "Alert once when an account needs a new sign-in.", "notifySignInAgain"),
  ]
}
