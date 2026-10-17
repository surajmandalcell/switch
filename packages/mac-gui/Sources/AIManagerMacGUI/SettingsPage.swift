import AIManagerCore
import AppKit
import ServiceManagement
import SwiftUI

struct SettingsPage: View {
  @ObservedObject var model: AccountViewModel
  @StateObject private var launchAtLogin = LaunchAtLoginSettings()
  @StateObject private var notificationPermission = QuotaNotificationPermission()
  @AppStorage(ProviderStatusPoller.enabledKey) private var checkProviderStatus = true
  @AppStorage(EmailPrivacy.key) private var hideEmails = false
  @AppStorage(EmailPrivacy.privacyModeKey) private var privacyMode = false
  @AppStorage(EmailPrivacy.domainsKey) private var showEmailDomains = false
  @AppStorage(AppearanceOverride.key) private var windowAppearance = "system"
  @AppStorage("launchPlace") private var launchPlace = "last"
  @AppStorage(QuotaNotificationSettings.almostOutKey) private var notifyAlmostOut = false
  @AppStorage(QuotaNotificationSettings.paceKey) private var notifyPace = false
  @AppStorage(QuotaNotificationSettings.availableAgainKey) private var notifyAvailable = false
  @AppStorage(QuotaNotificationSettings.signInAgainKey) private var notifySignIn = false
  @AppStorage(AIManagerWindowBehavior.minimizeToTrayKey) private var minimizeToTray = false
  @AppStorage(MenuBarUsagePreferences.defaultKey) private var defaultShowUsage = true
  @AppStorage(MenuBarTokenPeriod.preferenceKey) private var menuTokenPeriod = MenuBarTokenPeriod.sinceReset
  @AppStorage(UsagePercentagePreferences.showsUsedKey) private var showUsageAsUsed = false
  @AppStorage(ResetDisplay.exactKey) private var resetIsExact = false
  @AppStorage(ResetDisplay.hourFormatKey) private var hourFormat = HourFormat.auto
  @AppStorage(PopoverRefreshPreference.key) private var refreshOnOpen = false
  @AppStorage(AutoSwitchPreferences.enabledKey) private var autoSwitch = false
  @AppStorage(AutoSwitchPreferences.thresholdKey) private var autoSwitchThreshold = AutoSwitch.thresholds[0]
  @AppStorage(AutoSwitchPreferences.runningCLIsKey) private var autoSwitchCLIs = AutoSwitchPreferences.RunningCLIs.restart.rawValue
  @AppStorage(AutoSwitchPreferences.resumeMessageKey) private var autoSwitchResume = AutoSwitch.defaultResumeMessage
  @FocusState private var resumeFocused: Bool
  @State private var confirmsReset = false
  @State private var resetCount = 0
  private var runningCLIs: Binding<AutoSwitchPreferences.RunningCLIs> {
    Binding(
      get: { AutoSwitchPreferences.RunningCLIs(rawValue: autoSwitchCLIs) ?? .restart },
      set: { autoSwitchCLIs = $0.rawValue })
  }
  var body: some View {
    // Every card shares the top bar's left and right edges.
    AIMScrollPage {
      AIMSection("General") {
        launchAtLoginRow
        Toggle(isOn: $minimizeToTray) {
          Text("Minimize to menu bar")
          Text("Hide the window and keep Switch available from its menu-bar icon.")
            .aimText(.secondary).lineLimit(1)
        }
        LabeledContent {
          AIMPopUp(
            options: ["last", "overview"], selection: $launchPlace,
            accessibilityLabel: "When Switch opens", label: { $0 == "last" ? "Last place" : "Overview" })
        } label: {
          Text("When Switch opens")
          Text("Choose the page shown when Switch starts.").aimText(.secondary).lineLimit(1)
        }
        LabeledContent {
          ShortcutRecorder().id(resetCount)
        } label: {
          Text(SettingsCopy.menuShortcut)
          Text(SettingsCopy.menuShortcutHelp).aimText(.secondary).lineLimit(1)
        }
      }
      AIMSection("Appearance") {
        LabeledContent {
          AIMSegmentedPicker(
            options: ["system", "light", "dark"], selection: $windowAppearance,
            accessibilityLabel: "Appearance", label: { $0.capitalized })
        } label: {
          Text("Appearance")
          Text("Choose the window and menu bar appearance.").aimText(.secondary).lineLimit(1)
        }
        LabeledContent {
          AIMSegmentedPicker(
            options: [false, true], selection: $showUsageAsUsed,
            accessibilityLabel: "Usage percentage", label: { $0 ? "Used" : "Left" })
        } label: {
          Text("Usage percentage")
          Text("Show the share left or the share used in every usage view.").aimText(.secondary).lineLimit(1)
        }
        LabeledContent {
          AIMSegmentedPicker(
            options: [false, true], selection: $resetIsExact,
            accessibilityLabel: "Reset time format", label: { $0 ? "Exact time" : "Countdown" })
        } label: {
          Text(SettingsCopy.resetTimes)
          Text(SettingsCopy.resetTimesHelp).aimText(.secondary).lineLimit(1)
        }
        LabeledContent {
          AIMSegmentedPicker(
            options: HourFormat.allCases, selection: $hourFormat,
            accessibilityLabel: "Hour format", label: \.label)
        } label: {
          Text(SettingsCopy.timeFormat)
          Text(SettingsCopy.timeFormatHelp).aimText(.secondary).lineLimit(1)
        }
      }
      AIMSection("Accounts") {
        Toggle(isOn: $showEmailDomains) {
          Text("Show full email addresses")
          Text("Show the full address, including the domain ending such as .com or .co.uk.").aimText(.secondary).lineLimit(1)
        }
        .disabled(privacyMode)
        Toggle(isOn: $hideEmails) {
          Text(SettingsCopy.hideEmails)
          Text(SettingsCopy.hideEmailsHelp).aimText(.secondary).lineLimit(1)
        }
        .disabled(privacyMode)
        Toggle(isOn: $privacyMode) {
          Text(SettingsCopy.privacyMode)
          Text(SettingsCopy.privacyModeHelp).aimText(.secondary)
        }
        Toggle(isOn: $checkProviderStatus) {
          Text(SettingsCopy.checkProviderStatus)
          Text(SettingsCopy.checkProviderStatusHelp).aimText(.secondary).lineLimit(1)
        }
        Toggle(isOn: Binding(
          get: { model.claudeShellIntegrationOn },
          set: { enabled in Task { await model.setClaudeShellIntegration(enabled) } })
        ) {
          Text(SettingsCopy.claudeShell)
          Text(SettingsCopy.claudeShellHelp).aimText(.secondary).lineLimit(1)
          if let error = model.claudeShellIntegrationError {
            Text(error).aimText(.secondary, tint: AIMTheme.red)
          }
        }
      }
      AIMSection("Auto switch") {
        Toggle(isOn: $autoSwitch) {
          Text(SettingsCopy.autoSwitch)
          Text(SettingsCopy.autoSwitchHelp).aimText(.secondary).lineLimit(1)
        }
        LabeledContent {
          AIMPopUp(
            options: AutoSwitch.thresholds, selection: $autoSwitchThreshold,
            accessibilityLabel: SettingsCopy.autoSwitchThreshold, label: { "\($0)% left" })
        } label: {
          Text(SettingsCopy.autoSwitchThreshold)
          Text(SettingsCopy.autoSwitchThresholdHelp).aimText(.secondary).lineLimit(1)
        }
        .disabled(!autoSwitch)
        LabeledContent {
          AIMPopUp(
            options: AutoSwitchPreferences.RunningCLIs.allCases, selection: runningCLIs,
            accessibilityLabel: SettingsCopy.autoSwitchRunningCLIs, label: \.label)
        } label: {
          Text(SettingsCopy.autoSwitchRunningCLIs)
          Text(SettingsCopy.autoSwitchRunningCLIsHelp).aimText(.secondary).lineLimit(1)
        }
        .disabled(!autoSwitch)
        LabeledContent {
          TextField(SettingsCopy.autoSwitchResume, text: $autoSwitchResume, prompt: Text("No message"))
            .textFieldStyle(.plain)
            .aimFieldChrome(focused: resumeFocused, width: 320)
            .focused($resumeFocused)
        } label: {
          Text(SettingsCopy.autoSwitchResume)
          Text(SettingsCopy.autoSwitchResumeHelp).aimText(.secondary).lineLimit(1)
        }
        .disabled(!autoSwitch)
      }
      AIMSection("Menu bar") {
        Toggle(isOn: $defaultShowUsage) {
          Text("Show account usage")
          Text("Accounts without their own choice show cached usage in Menubar.")
            .aimText(.secondary).lineLimit(1)
        }
        LabeledContent {
          AIMPopUp(
            options: MenuBarTokenPeriod.allCases, selection: $menuTokenPeriod,
            accessibilityLabel: "Menubar token period", label: \.label)
        } label: {
          Text("Token summary")
          Text("Choose the period shown beside each account’s usage.").aimText(.secondary).lineLimit(1)
        }
        Toggle(isOn: $refreshOnOpen) {
          Text(SettingsCopy.refreshOnOpen)
          Text(SettingsCopy.refreshOnOpenHelp).aimText(.secondary).lineLimit(1)
        }
      }
      AIMSection(SettingsCopy.notificationsTitle) {
        ForEach(Array(SettingsCopy.notificationRows.enumerated()), id: \.offset) { _, row in
          Toggle(isOn: notificationBinding(row.key)) {
            Text(row.title)
            Text(row.help).aimText(.secondary).lineLimit(1)
          }
        }
        if notificationPermission.isDenied, notifyAlmostOut || notifyPace || notifyAvailable || notifySignIn {
          LabeledContent {
            AIMButton(title: "Open System Settings", action: notificationPermission.openSystemSettings)
          } label: {
            Label("Notifications are turned off for Switch in System Settings.",
                  systemImage: AIMIcon.Name.warning.symbol)
              .foregroundStyle(AIMTheme.amber)
          }
        }
      }
      AIMSection("Data locations") {
        DataLocationRow(
          title: "Codex home",
          detail: "Settings, plugins, conversations, and databases stay here when accounts change.",
          path: model.paths.defaultHome.path
        ) {
          model.showDataLocation(model.paths.defaultHome, name: "Codex home")
        }
        DataLocationRow(
          title: "Codex account vault",
          detail: "Private Codex auth.json snapshots.",
          path: model.paths.credentialStore.path
        ) {
          model.showDataLocation(model.paths.credentialStore, name: "Codex account vault")
        }
        DataLocationRow(
          title: "Grok Build home",
          detail: "Grok configuration, rules, plugins, sessions, and the active login.",
          path: model.paths.grokHome.path
        ) {
          model.showDataLocation(model.paths.grokHome, name: "Grok Build home")
        }
        DataLocationRow(
          title: "Grok Build account vault",
          detail: "Private Grok subscription OAuth snapshots.",
          path: model.paths.grokCredentialStore.path
        ) {
          model.showDataLocation(model.paths.grokCredentialStore, name: "Grok Build account vault")
        }
      }
      AIMSection("Reset") {
        LabeledContent {
          AIMButton(title: "Reset settings…", tone: .danger) { confirmsReset = true }
        } label: {
          Text(SettingsCopy.resetSettings)
          Text(SettingsCopy.resetSettingsHelp).aimText(.secondary).lineLimit(1)
        }
      }
      #if AI_MANAGER_PREVIEW
      if model.isDemo {
        AIMSection("Demo states") {
          HStack(spacing: AIMTheme.rowSpacing) {
            AIMButton(title: "Sample accounts") { model.reset(to: .demo) }
            AIMButton(title: "Empty state") { model.reset(to: .empty) }
            AIMButton(title: "Issues and backups") { model.reset(to: .allStates) }
            Spacer()
          }
          HStack(spacing: AIMTheme.rowSpacing) {
            AIMButton(title: "Refresh demo data", icon: .refresh, disabled: model.isBusy) {
              Task { await model.refresh() }
            }
            Spacer()
            AIMButton(title: "Show demo error", tone: .danger) { model.showDemoError() }
          }
        }
      }
      #endif
    }
    .confirmationDialog(
      "Reset every setting to its default?", isPresented: $confirmsReset, titleVisibility: .visible
    ) {
      Button("Reset settings", role: .destructive, action: resetSettings)
    } message: {
      Text("Accounts, saved sign-ins, and Open at Login stay as they are.")
    }
    .onChange(of: checkProviderStatus) { model.providerStatusSettingChanged() }
    .onChange(of: showEmailDomains) { model.objectWillChange.send() }
    .task {
      await launchAtLogin.refresh()
      await notificationPermission.refresh()
      await model.loadClaudeShellIntegration()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      Task {
        await launchAtLogin.refresh()
        await notificationPermission.refresh()
      }
    }
  }

  private func resetSettings() {
    SettingsReset.reset()
    GlobalShortcut.shared.apply(nil)
    resetCount += 1
    model.providerStatusSettingChanged()
  }

  /// A toggle that asks macOS for notification permission the first time it turns on.
  private func notificationBinding(_ key: String) -> Binding<Bool> {
    let stored: Binding<Bool>
    switch key {
    case QuotaNotificationSettings.almostOutKey: stored = $notifyAlmostOut
    case QuotaNotificationSettings.paceKey: stored = $notifyPace
    case QuotaNotificationSettings.availableAgainKey: stored = $notifyAvailable
    default: stored = $notifySignIn
    }
    return Binding(
      get: { stored.wrappedValue },
      set: { enabled in
        stored.wrappedValue = enabled
        if enabled { notificationPermission.requestIfNeeded() }
      })
  }

  @ViewBuilder private var launchAtLoginRow: some View {
    Toggle(isOn: Binding(
      get: { launchAtLogin.isOn },
      set: launchAtLogin.setEnabled)
    ) {
      Text("Open at Login")
      Text(launchAtLogin.detail).aimText(.secondary).lineLimit(1)
    }
    .disabled(!launchAtLogin.canChange)
    if launchAtLogin.requiresApproval {
      LabeledContent("Approval needed") {
        AIMButton(title: "Open Login Items", action: launchAtLogin.openLoginItems)
      }
    }
  }
}

private struct DataLocationRow: View {
  let title: String
  let detail: String
  let path: String
  let reveal: () -> Void

  var body: some View {
    LabeledContent {
      AIMButton(title: "Reveal", icon: .folder, action: reveal)
    } label: {
      Text(title)
      Text(detail).aimText(.secondary).lineLimit(1)
      AIMCopyablePath(path: path)
    }
  }
}

@MainActor
final class LaunchAtLoginSettings: ObservableObject {
  @Published private(set) var status: SMAppService.Status = .notRegistered
  @Published private(set) var hasStatus = false
  @Published private(set) var errorMessage: String?
  private let service: SMAppService

  init(service: SMAppService = .mainApp) {
    self.service = service
  }

  var isOn: Bool {
    switch status {
    case .enabled, .requiresApproval: true
    default: false
    }
  }

  var canChange: Bool {
    guard hasStatus else { return false }
    return switch status {
    case .notFound: false
    default: true
    }
  }

  var requiresApproval: Bool {
    if case .requiresApproval = status { true } else { false }
  }

  var detail: String {
    if let errorMessage { return "Switch couldn’t update its login item: \(errorMessage)" }
    return Self.detail(for: status)
  }

  static func detail(for status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: "Open Switch in the menu bar when you sign in."
    case .enabled: "Switch opens in the menu bar when you sign in."
    case .requiresApproval: "Approval is required in System Settings before Switch can open at login."
    case .notFound: "This build cannot be registered as a login item."
    @unknown default: "Login-item status is unavailable."
    }
  }

  func setEnabled(_ enabled: Bool) {
    errorMessage = nil
    do {
      if enabled {
        try service.register()
      } else {
        try service.unregister()
      }
    } catch {
      errorMessage = error.localizedDescription
    }
    Task { await refresh(clearError: false) }
  }

  func refresh(clearError: Bool = true) async {
    let service = self.service
    status = await Task.detached(priority: .utility) { service.status }.value
    hasStatus = true
    if clearError { errorMessage = nil }
  }

  func openLoginItems() {
    SMAppService.openSystemSettingsLoginItems()
  }
}

/// Titles and help text of the Settings rows that features add, shared with the GUI contract.
enum SettingsCopy {
  static let checkProviderStatus = "Check provider status"
  static let checkProviderStatusHelp = "Show a dot beside a provider that reports an incident."
  static let claudeShell = "Use the selected Claude account in terminals"
  static let claudeShellHelp =
    "Adds one line to ~/.zshrc so a plain claude command uses the default Claude account. A backup is kept."
  static let autoSwitch = "Switch accounts automatically"
  static let autoSwitchHelp = "Make the next account in your Accounts order the default when one runs out."
  static let autoSwitchThreshold = "Switch when an account has"
  static let autoSwitchThresholdHelp = "Compares the lower of the session and weekly share left."
  static let autoSwitchRunningCLIs = "Running CLIs"
  static let autoSwitchRunningCLIsHelp =
    "Reopen Codex and Claude Code in Terminal on the new account once their turn ends."
  static let autoSwitchResume = "Resume message"
  static let autoSwitchResumeHelp = "Sent when a usage limit cut the last turn short."
  static let hideEmails = "Hide email addresses"
  static let hideEmailsHelp = "Mask account emails everywhere, such as a••••@example.com."
  static let privacyMode = "Privacy mode"
  static let privacyModeHelp = "Show made-up names, such as Jon Doe, instead of account names and emails."
  static let resetTimes = "Reset times"
  static let resetTimesHelp = "Show a countdown or the exact time. Click any reset text to switch."
  static let timeFormat = "Time format"
  static let timeFormatHelp = "Hour style for exact reset times."
  static let menuShortcut = "Menu shortcut"
  static let menuShortcutHelp = "Open or close the menu popover from anywhere. Off until you record one."
  static let refreshOnOpen = "Refresh when the menu opens"
  static let refreshOnOpenHelp = "Check usage each time the popover opens."
  static let resetSettings = "Reset settings"
  static let resetSettingsHelp =
    "Return every Settings choice, hidden usage row, and the menu shortcut to its default. Accounts stay."
  static let notificationsTitle = "Notifications"
  /// Title, help text, and the UserDefaults key of each toggle. All off by default.
  static let notificationRows: [(title: String, help: String, key: String)] = [
    ("Almost Out", "Alert when a usage window drops below 10% left.", QuotaNotificationSettings.almostOutKey),
    ("Pace alerts", "Alert when usage will finish close to the limit or run out before the reset.",
     QuotaNotificationSettings.paceKey),
    ("Available again", "Alert when a used-up window resets and the account can be used again.",
     QuotaNotificationSettings.availableAgainKey),
    ("Sign in again", "Alert once when an account needs a new sign-in.", QuotaNotificationSettings.signInAgainKey),
  ]
}
