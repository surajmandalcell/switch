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
  @AppStorage(MenuBarServicePreferences.onePerServiceKey) private var onePerService = false
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
  /// The toolbar search text. Rows and sections that do not match it are left out.
  var query = ""

  private var runningCLIs: Binding<AutoSwitchPreferences.RunningCLIs> {
    Binding(
      get: { AutoSwitchPreferences.RunningCLIs(rawValue: autoSwitchCLIs) ?? .restart },
      set: { autoSwitchCLIs = $0.rawValue })
  }
  var body: some View {
    // Every card shares the top bar's left and right edges.
    let filter = SettingsFilter(query)
    AIMScrollPage {
      if filter.shows(section: "General") {
        AIMSection("General") {
          if filter.shows("login") { launchAtLoginRow }
          if filter.shows("tray") {
            Toggle(isOn: $minimizeToTray) {
              Text("Minimize to menu bar")
              settingDetail("Hide the window and keep Switch available from its menu-bar icon.")
            }
          }
          if filter.shows("place") {
            LabeledContent {
              AIMPopUp(
                options: ["last", "overview"], selection: $launchPlace,
                accessibilityLabel: "When Switch opens", label: { $0 == "last" ? "Last place" : "Overview" })
            } label: {
              Text("When Switch opens")
              settingDetail("Choose the page shown when Switch starts.")
            }
          }
          if filter.shows("shortcut") {
            LabeledContent {
              ShortcutRecorder().id(resetCount)
            } label: {
              Text(SettingsCopy.menuShortcut)
              settingDetail(SettingsCopy.menuShortcutHelp)
            }
          }
        }
        .transition(.opacity)
      }
      if filter.shows(section: "Appearance") {
        AIMSection("Appearance") {
          if filter.shows("appearance") {
            LabeledContent {
              AIMSegmentedPicker(
                options: ["system", "light", "dark"], selection: $windowAppearance,
                accessibilityLabel: "Appearance", label: { $0.capitalized })
            } label: {
              Text("Appearance")
              settingDetail("Choose the window and menu bar appearance.")
            }
          }
          if filter.shows("percent") {
            LabeledContent {
              AIMSegmentedPicker(
                options: [false, true], selection: $showUsageAsUsed,
                accessibilityLabel: "Usage percentage", label: { $0 ? "Used" : "Left" })
            } label: {
              Text("Usage percentage")
              settingDetail("Show the share left or the share used in every usage view.")
            }
          }
          if filter.shows("reset-times") {
            LabeledContent {
              AIMSegmentedPicker(
                options: [false, true], selection: $resetIsExact,
                accessibilityLabel: "Reset time format", label: { $0 ? "Exact time" : "Countdown" })
            } label: {
              Text(SettingsCopy.resetTimes)
              settingDetail(SettingsCopy.resetTimesHelp)
            }
          }
          if filter.shows("hours") {
            LabeledContent {
              AIMSegmentedPicker(
                options: HourFormat.allCases, selection: $hourFormat,
                accessibilityLabel: "Hour format", label: \.label)
            } label: {
              Text(SettingsCopy.timeFormat)
              settingDetail(SettingsCopy.timeFormatHelp)
            }
          }
        }
        .transition(.opacity)
      }
      if filter.shows(section: "Accounts") {
        AIMSection("Accounts") {
          if filter.shows("domain") {
            Toggle(isOn: $showEmailDomains) {
              Text("Show full email addresses")
              settingDetail("Show the full address, including the domain ending such as .com or .co.uk.")
            }
            .disabled(privacyMode)
          }
          if filter.shows("hide-email") {
            Toggle(isOn: $hideEmails) {
              Text(SettingsCopy.hideEmails)
              settingDetail(SettingsCopy.hideEmailsHelp)
            }
            .disabled(privacyMode)
          }
          if filter.shows("privacy") {
            Toggle(isOn: $privacyMode) {
              Text(SettingsCopy.privacyMode)
              Text(SettingsCopy.privacyModeHelp).aimText(.secondary)
            }
          }
          if filter.shows("status") {
            Toggle(isOn: $checkProviderStatus) {
              Text(SettingsCopy.checkProviderStatus)
              settingDetail(SettingsCopy.checkProviderStatusHelp)
            }
          }
          if filter.shows("claude-shell") {
            Toggle(isOn: Binding(
              get: { model.claudeShellIntegrationOn },
              set: { enabled in Task { await model.setClaudeShellIntegration(enabled) } })
            ) {
              Text(SettingsCopy.claudeShell)
              settingDetail(SettingsCopy.claudeShellHelp)
              if let error = model.claudeShellIntegrationError {
                Text(error).aimText(.secondary, tint: AIMTheme.red)
              }
            }
          }
        }
        .transition(.opacity)
      }
      if filter.shows(section: "Auto switch") {
        AIMSection("Auto switch") {
          if filter.shows("auto") {
            Toggle(isOn: $autoSwitch) {
              Text(SettingsCopy.autoSwitch)
              settingDetail(SettingsCopy.autoSwitchHelp)
            }
          }
          if filter.shows("auto-threshold") {
            LabeledContent {
              AIMPopUp(
                options: AutoSwitch.thresholds, selection: $autoSwitchThreshold,
                accessibilityLabel: SettingsCopy.autoSwitchThreshold, label: { "\($0)% left" })
            } label: {
              Text(SettingsCopy.autoSwitchThreshold)
              settingDetail(SettingsCopy.autoSwitchThresholdHelp)
            }
            .disabled(!autoSwitch)
          }
          if filter.shows("auto-clis") {
            LabeledContent {
              AIMPopUp(
                options: AutoSwitchPreferences.RunningCLIs.allCases, selection: runningCLIs,
                accessibilityLabel: SettingsCopy.autoSwitchRunningCLIs, label: \.label)
            } label: {
              Text(SettingsCopy.autoSwitchRunningCLIs)
              settingDetail(SettingsCopy.autoSwitchRunningCLIsHelp)
            }
            .disabled(!autoSwitch)
          }
          if filter.shows("auto-resume") {
            LabeledContent {
              TextField(SettingsCopy.autoSwitchResume, text: $autoSwitchResume, prompt: Text("No message"))
                .textFieldStyle(.plain)
                .aimFieldChrome(focused: resumeFocused, width: 320)
                .focused($resumeFocused)
            } label: {
              Text(SettingsCopy.autoSwitchResume)
              settingDetail(SettingsCopy.autoSwitchResumeHelp)
            }
            .disabled(!autoSwitch)
          }
        }
        .transition(.opacity)
      }
      if filter.shows(section: "Menu bar") {
        AIMSection("Menu bar") {
          if filter.shows("menu-usage") {
            Toggle(isOn: $defaultShowUsage) {
              Text("Show account usage")
              settingDetail("Accounts without their own choice show cached usage in Menubar.")
            }
          }
          if filter.shows("menu-one-per-service") {
            Toggle(isOn: $onePerService) {
              Text(SettingsCopy.onePerService)
              settingDetail(SettingsCopy.onePerServiceHelp)
            }
          }
          if filter.shows("menu-tokens") {
            LabeledContent {
              AIMPopUp(
                options: MenuBarTokenPeriod.allCases, selection: $menuTokenPeriod,
                accessibilityLabel: "Menubar token period", label: \.label)
            } label: {
              Text("Token summary")
              settingDetail("Choose the period shown beside each account’s usage.")
            }
          }
          if filter.shows("menu-refresh") {
            Toggle(isOn: $refreshOnOpen) {
              Text(SettingsCopy.refreshOnOpen)
              settingDetail(SettingsCopy.refreshOnOpenHelp)
            }
          }
        }
        .transition(.opacity)
      }
      if filter.shows(section: SettingsCopy.notificationsTitle) {
        AIMSection(SettingsCopy.notificationsTitle) {
          ForEach(Array(SettingsCopy.notificationRows.enumerated()), id: \.offset) { _, row in
            if filter.shows("notify.\(row.key)") {
              Toggle(isOn: notificationBinding(row.key)) {
                Text(row.title)
                settingDetail(row.help)
              }
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
        .transition(.opacity)
      }
      if filter.shows(section: "Data locations") {
        AIMSection("Data locations") {
          if filter.shows("data.codex") {
            DataLocationRow(
              title: "Codex home",
              detail: "Settings, plugins, conversations, and databases stay here when accounts change.",
              path: model.paths.defaultHome.path
            ) {
              model.showDataLocation(model.paths.defaultHome, name: "Codex home")
            }
          }
          if filter.shows("data.codex-vault") {
            DataLocationRow(
              title: "Codex account vault",
              detail: "Private Codex auth.json snapshots.",
              path: model.paths.credentialStore.path
            ) {
              model.showDataLocation(model.paths.credentialStore, name: "Codex account vault")
            }
          }
          if filter.shows("data.grok") {
            DataLocationRow(
              title: "Grok Build home",
              detail: "Grok configuration, rules, plugins, sessions, and the active login.",
              path: model.paths.grokHome.path
            ) {
              model.showDataLocation(model.paths.grokHome, name: "Grok Build home")
            }
          }
          if filter.shows("data.grok-vault") {
            DataLocationRow(
              title: "Grok Build account vault",
              detail: "Private Grok subscription OAuth snapshots.",
              path: model.paths.grokCredentialStore.path
            ) {
              model.showDataLocation(model.paths.grokCredentialStore, name: "Grok Build account vault")
            }
          }
        }
        .transition(.opacity)
      }
      if filter.shows(section: "Reset") {
        AIMSection("Reset") {
          LabeledContent {
            AIMButton(title: "Reset settings…", tone: .danger) { confirmsReset = true }
          } label: {
            Text(SettingsCopy.resetSettings)
            settingDetail(SettingsCopy.resetSettingsHelp)
          }
        }
        .transition(.opacity)
      }
      SettingsSearchCards(model: model, query: query)
      #if AI_MANAGER_PREVIEW
      if model.isDemo, filter.showsAll {
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
    .environment(\.aimPageFadeKey, query)
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
      settingDetail(launchAtLogin.detail)
    }
    .disabled(!launchAtLogin.canChange)
    if launchAtLogin.requiresApproval {
      LabeledContent("Approval needed") {
        AIMButton(title: "Open Login Items", action: launchAtLogin.openLoginItems)
      }
    }
  }
}

/// A one-line setting description. Its tooltip shows the full text when the line truncates.
private func settingDetail(_ text: String) -> some View {
  Text(text).aimText(.secondary).lineLimit(1).help(text)
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
      settingDetail(detail)
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

  #if AI_MANAGER_PREVIEW
  /// A Preview build never registers a login item: it keeps the choice here. Run from an odd folder it
  /// would report `.notFound`, and the dimmed toggle (a group-opacity layer) made the Settings page
  /// switch check about 5 ms slower than the installed app, where the toggle is live.
  private var previewOn = false
  #endif

  func setEnabled(_ enabled: Bool) {
    errorMessage = nil
    #if AI_MANAGER_PREVIEW
    previewOn = enabled
    Task { await refresh(clearError: false) }
    return
    #else
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
    #endif
  }

  func refresh(clearError: Bool = true) async {
    #if AI_MANAGER_PREVIEW
    let next = previewOn ? SMAppService.Status.enabled : .notRegistered
    #else
    let service = self.service
    let next = await Task.detached(priority: .utility) { service.status }.value
    #endif
    if status != next { status = next }
    if !hasStatus { hasStatus = true }
    if clearError, errorMessage != nil { errorMessage = nil }
  }

  func openLoginItems() {
    SMAppService.openSystemSettingsLoginItems()
  }
}

// SettingsCopy (the shared Settings strings) lives in AppSearch.swift beside the search index.
