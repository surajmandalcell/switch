import AIManagerCore
import AppKit

struct AIManagerNativeViewSnapshot: Codable {
  let path: String
  let className: String
  let frameX: Double
  let frameY: Double
  let frameWidth: Double
  let frameHeight: Double
  let isFlipped: Bool
  let focusRingType: UInt
  let scrollStyle: String?
  let autohidesScrollers: Bool?
  let verticalScrollerClass: String?
}

@MainActor
enum AIManagerNativeContract {
  static func presentationContractFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }

    expect(AIMTheme.Dark.rail == 0x141517, "Dark rail color changed")
    expect(AIMTranslucency.opacity(25, reduceTransparency: false) == 0.75,
      "Initial content opacity is not 75 percent")
    expect(AIMTranslucency.opacity(100, reduceTransparency: false) == 0.5
      && AIMTranslucency.opacity(-1, reduceTransparency: false) == 1
      && AIMTranslucency.opacity(25, reduceTransparency: true) == 1,
      "Translucency ignores its bounds or Reduce Transparency")
    expect(AIMTheme.Dark.canvas == 0x18191B, "Dark canvas color changed")
    expect(AIMTheme.Dark.panel == 0x202124, "Dark panel color changed")
    expect(AIMTheme.Dark.raised == 0x27282B, "Dark raised color changed")
    expect(AIMTheme.Dark.raisedSecondary == 0x2F3034, "Dark secondary raised color changed")
    expect(AIMTheme.Dark.hover == 0x303238, "Dark hover color changed")
    expect(AIMTheme.Dark.selection == 0x393C43, "Dark selection color changed")
    expect(AIMTheme.Dark.menuChrome == 0x18191B, "Dark menu chrome color changed")

    expect(UsagePresentation.credits(nil) == nil, "Missing credits are visible")
    expect(
      UsagePresentation.credits(CodexCreditsSnapshot(
        hasCredits: nil, unlimited: nil, balance: "  ")) == nil,
      "Empty credits are visible")
    expect(
      UsagePresentation.credits(CodexCreditsSnapshot(
        hasCredits: false, unlimited: nil, balance: nil)) == "None",
      "Explicit false credits are hidden")
    expect(UsagePresentation.spendControl(nil) == nil, "Missing spend control is visible")
    expect(UsagePresentation.spendControl(false) == "Not reached", "Explicit false spend control is hidden")
    let missingAccountFields = CodexAccountUsageSnapshot(
      account: nil, requiresOpenAIAuthentication: nil, rateLimits: nil, usage: nil,
      dailyUsage: [], fetchedAt: Date(timeIntervalSince1970: 0))
    expect(
      UsagePresentation.accountFacts(missingAccountFields).isEmpty,
      "Missing account facts are visible")
    expect(UsagePresentation.summaryFacts(nil).isEmpty, "Missing usage summary is visible")
    let falseAccountFields = CodexAccountUsageSnapshot(
      account: nil, requiresOpenAIAuthentication: false,
      rateLimits: CodexRateLimitsSnapshot(
        accountID: nil, ordinaryUsageAllowed: false, defaultBucket: nil, buckets: [:]),
      usage: nil, dailyUsage: [], fetchedAt: Date(timeIntervalSince1970: 0))
    expect(
      UsagePresentation.accountFacts(falseAccountFields) == [
        UsagePresentation.Fact(label: "Ordinary usage", value: "Restricted"),
        UsagePresentation.Fact(label: "Authentication", value: "Not required"),
      ],
      "Explicit false account facts are hidden")

    let emptyBucket = CodexRateLimitBucketSnapshot(
      id: "empty", name: "Empty", plan: "Plus", model: nil,
      primary: nil, secondary: nil, credits: nil, spendControlReached: nil)
    expect(!UsagePresentation.hasContent(emptyBucket), "A bucket with no metrics is visible")
    let zeroWindow = CodexRateLimitWindowSnapshot(
      usedPercent: 0, windowDurationMinutes: nil, resetsAt: nil)
    expect(UsagePresentation.hasWindow(zeroWindow), "A zero-percent quota window is hidden")
    let zeroBucket = CodexRateLimitBucketSnapshot(
      id: "zero", name: "Zero", plan: nil, model: nil,
      primary: zeroWindow, secondary: nil, credits: nil, spendControlReached: false)
    expect(UsagePresentation.hasContent(zeroBucket), "A bucket with explicit zero values is hidden")
    let creditsOnly = CodexRateLimitBucketSnapshot(
      id: "credits", name: nil, plan: nil, model: nil, primary: nil, secondary: nil,
      credits: CodexCreditsSnapshot(hasCredits: true, unlimited: nil, balance: "1"),
      spendControlReached: nil)
    expect(UsagePresentation.hasContent(creditsOnly) && !UsagePresentation.hasRateLimits(creditsOnly),
      "Credits-only data hides the missing-rate-limits notice")
    expect(UsagePresentation.emptyUsageTitle(failure: "Timed out", needsSignIn: false)
      == "Usage could not be refreshed", "An initial usage failure is shown as never checked")
    expect(UsagePresentation.emptyUsageTitle(failure: nil, needsSignIn: true)
      == "Sign in to refresh usage", "Missing sign-in state is shown as never checked")

    let zeroSummary = CodexUsageSummarySnapshot(
      lifetimeTokens: 0, peakDailyTokens: nil, currentStreakDays: 0,
      longestStreakDays: nil, longestRunningTurnSeconds: nil)
    expect(
      UsagePresentation.summaryFacts(zeroSummary).map(\.label) == ["Lifetime", "Current streak"],
      "Usage summary does not preserve explicit zero values")
    let activityEnd = ISO8601DateFormatter().date(from: "2026-09-15T12:00:00Z")!
    let activityDays = UsagePresentation.activityDays([
      CodexDailyUsageSnapshot(startDate: nil, tokens: 12),
      CodexDailyUsageSnapshot(startDate: "  ", tokens: 12),
      CodexDailyUsageSnapshot(startDate: "2026-09-14", tokens: nil),
      CodexDailyUsageSnapshot(startDate: "2026-09-14", tokens: 5),
      CodexDailyUsageSnapshot(startDate: "2026-09-14", tokens: 3),
      CodexDailyUsageSnapshot(startDate: "2026-09-15", tokens: 0),
      CodexDailyUsageSnapshot(startDate: "2026-09-08", tokens: 99),
      CodexDailyUsageSnapshot(startDate: "2026-02-30", tokens: 99),
    ], endingAt: activityEnd, dayCount: 7)
    expect(
      activityDays.map(\.tokens) == [0, 0, 0, 0, 0, 8, 0],
      "Activity calendar does not fill, filter, or aggregate daily usage")

    expect(HistoryHeaderLayout.height == 40, "Conversation header height changed")
    expect(HistoryHeaderLayout.countWidth == 52, "Conversation count slot width changed")
    expect(HistoryHeaderLayout.warningWidth == 32, "Conversation warning slot width changed")
    expect(HistoryHeaderLayout.statusWidth == 20, "Conversation status slot width changed")
    let weeklyOnly = MenuBarUsageSnapshot(usedPercentage: nil, secondaryUsedPercentage: 1)
    expect(
      weeklyOnly.usedPercentage == nil && weeklyOnly.secondaryUsedPercentage == 1
        && (weeklyOnly.usedPercentage ?? weeklyOnly.secondaryUsedPercentage) == 1,
      "Weekly-only usage is discarded or missing from the status item")
    failures.append(contentsOf: menuBarUsagePreferenceFailures())
    return failures
  }

  static func menuBarUsagePreferenceFailures() -> [String] {
    let domain = "Switch.MenuBarUsagePreferences.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: domain) else {
      return ["Menu-bar usage preference test store is unavailable"]
    }
    defer { defaults.removePersistentDomain(forName: domain) }
    defaults.removePersistentDomain(forName: domain)

    var failures: [String] = []
    let first = UUID()
    let second = UUID()
    if !MenuBarUsagePreferences.showsUsage(for: first, defaults: defaults) {
      failures.append("Menu-bar usage does not default to on")
    }

    defaults.set(true, forKey: MenuBarUsagePreferences.defaultKey)
    if !MenuBarUsagePreferences.showsUsage(for: first, defaults: defaults) {
      failures.append("An account without an override does not follow the enabled default")
    }

    MenuBarUsagePreferences.setOverride(false, for: first, defaults: defaults)
    if MenuBarUsagePreferences.explicitValue(for: first, defaults: defaults) != false
      || MenuBarUsagePreferences.showsUsage(for: first, defaults: defaults)
    {
      failures.append("An explicit hidden choice is not preserved")
    }
    if !MenuBarUsagePreferences.showsUsage(for: second, defaults: defaults) {
      failures.append("One account’s override changes another account")
    }

    MenuBarUsagePreferences.useDefault(for: first, defaults: defaults)
    if MenuBarUsagePreferences.explicitValue(for: first, defaults: defaults) != nil
      || !MenuBarUsagePreferences.showsUsage(for: first, defaults: defaults)
    {
      failures.append("Use default does not restore inherited menu-bar usage")
    }

    MenuBarUsagePreferences.setOverride(true, for: second, defaults: defaults)
    defaults.set(false, forKey: MenuBarUsagePreferences.defaultKey)
    if MenuBarUsagePreferences.showsUsage(for: first, defaults: defaults)
      || !MenuBarUsagePreferences.showsUsage(for: second, defaults: defaults)
    {
      failures.append("Changing the default does not preserve explicit account choices")
    }
    if let reopened = UserDefaults(suiteName: domain),
      MenuBarUsagePreferences.explicitValue(for: second, defaults: reopened) != true
    {
      failures.append("Account usage choice does not survive reopening preferences")
    }
    let hiddenAccount = MenuBarAccountSnapshot(
      id: first, identity: "Synthetic account", detail: "", isVerified: true,
      isActive: false, usage: MenuBarUsageSnapshot(usedPercentage: 42), showsUsage: false)
    if hiddenAccount.usage != nil {
      failures.append("A hidden account still publishes usage")
    }
    return failures
  }

  static func accountActionFailures() -> [String] {
    var failures: [String] = []
    if AccountActionCopy.use != "Set as Default"
      || AccountActionCopy.usingDefault != "Using as default"
    { failures.append("Default account action uses stale labels") }
    if AccountActionCopy.copyAuthPath != "Copy auth path" {
      failures.append("Account auth-path action uses stale copy")
    }
    if AccountActionCopy.useAndOpen != "Use & Open Codex"
      || AccountActionCopy.delete != "Delete account"
    {
      failures.append("Account context actions use unexpected copy")
    }
    if AIManagerBrand.providerArtwork.map(\.providerID)
      != [.codex, .claudeCode, .geminiCLI, .antigravityCLI]
    {
      failures.append("The Add Account catalog does not map every provider to local artwork")
    }
    if AIMIcon.Name.trash.symbol != "trash" {
      failures.append("The account delete control does not use the native trash symbol")
    }
    if AIMIcon.Name.cleanup.symbol != "eraser"
      || NSImage(systemSymbolName: AIMIcon.Name.cleanup.symbol, accessibilityDescription: nil) == nil
    {
      failures.append("The Cleanup rail does not use the native eraser symbol")
    }
    if NSImage(systemSymbolName: AIMIcon.Name.menuBar.symbol, accessibilityDescription: nil) == nil {
      failures.append("The account menu-usage control has no native icon")
    }
    if [ProviderID.codex, .claudeCode, .geminiCLI, .antigravityCLI].map(\.displayName)
      != ["Codex CLI", "Claude Code", "Gemini CLI", "Antigravity CLI"]
      || ProviderID(rawValue: "grok-build").displayName != "Grok Build"
    {
      failures.append("Provider names are not derived consistently")
    }
    return failures
  }

  @MainActor static func menuBarPopoverFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }

    expect(MenuBarPopover.width == 384, "Menu-bar popover is not 384 points wide")
    expect(MenuBarPopover.minimumHeight == 124, "Menu-bar popover retains removed chrome space")
    expect(MenuBarPopover.maximumHeight == 440, "Menu-bar popover maximum height is not capped")
    expect(MenuBarPopover.accountHeaderHeight == 58, "Menu-bar account header has the wrong height")
    expect(MenuBarPopover.quotaRowHeight == 44, "Menu-bar quota rows have the wrong height")
    expect(MenuBarPopover.accountActionWidth == 64, "Menu-bar account actions have different widths")
    expect(MenuBarPopover.accountActionHeight == 24, "Menu-bar account actions are not compact")

    let snapshot = MenuBarPopoverPreviewData.snapshot
    let hiddenAccount = MenuBarAccountSnapshot(
      id: UUID(uuidString: "FEAA8B82-542D-4B4C-9079-1A6DA349CCAA")!,
      identity: "hidden@example.test", detail: "Codex CLI · Personal",
      isVerified: true, isActive: false,
      usage: MenuBarUsageSnapshot(usedPercentage: 42), showsUsage: false)
    let empty = AIManagerStatusItemController.contentSize(accounts: [], visibleScreenHeight: 900)
    let hidden = AIManagerStatusItemController.contentSize(
      accounts: [hiddenAccount], visibleScreenHeight: 900)
    let one = AIManagerStatusItemController.contentSize(
      accounts: Array(snapshot.accounts.prefix(1)), visibleScreenHeight: 900)
    let two = AIManagerStatusItemController.contentSize(
      accounts: Array(snapshot.accounts.prefix(2)), visibleScreenHeight: 900)
    let many = AIManagerStatusItemController.contentSize(
      accounts: Array(repeating: snapshot.accounts[0], count: 20), visibleScreenHeight: 900)
    let shortScreen = AIManagerStatusItemController.contentSize(
      accounts: Array(repeating: snapshot.accounts[0], count: 20), visibleScreenHeight: 480)
    for size in [empty, hidden, one, two, many, shortScreen] {
      expect(size.width == 384, "Menu-bar popover width changes with its contents")
      expect(size.height >= 124, "Menu-bar popover is shorter than its empty state")
      expect(size.height <= 440, "Menu-bar popover exceeds its height cap")
    }
    expect(empty.height == 124, "Empty menu-bar popover does not use its compact minimum height")
    expect(hidden.height == 126, "Hidden usage leaves blank quota space")
    expect(one.height == 249, "One usage card has the wrong geometry")
    expect(two.height == 438, "Two usage cards have the wrong geometry")
    expect(many.height == 440, "Menu-bar cards do not scroll at the height cap")
    expect(shortScreen.height == 384, "Menu-bar popover does not honor the visible-screen inset")

    expect(snapshot.primaryUsedPercentage == 42, "Preview menu snapshot lacks cached primary usage")
    expect(snapshot.accounts.count == 3, "Preview menu snapshot does not exercise account states")
    expect(snapshot.accounts.first?.isActive == true, "Preview menu snapshot lacks an active account")
    expect(snapshot.accounts.contains(where: { !$0.isVerified }), "Preview menu snapshot lacks an unavailable row")
    expect(snapshot.accounts.compactMap(\.usage).contains(where: {
      $0.resetDescription != nil && $0.fetchedAt != nil
    }), "Preview menu snapshot lacks cached reset details")

    let controller = AIManagerStatusItemController(
      snapshot: snapshot,
      actions: MenuBarPopoverActions(
        openMainWindow: {}, switchAccount: { _ in }))
    expect(controller.isPresent, "Menu-bar template mark is unavailable")
    expect(controller.usesPopover, "Status item still uses a static menu")
    expect(controller.popoverContentSize.width == 384, "Hosted popover changed its fixed width")
    expect(controller.statusTitle == "42%", "Status item does not show cached primary usage")
    let originalSize = controller.popoverContentSize
    controller.updateAppearance(NSAppearance(named: .darkAqua))
    expect(
      controller.popoverContentSize == originalSize,
      "Dark appearance changed the menu-bar popover geometry")
    controller.updateAppearance(NSAppearance(named: .aqua))
    expect(
      controller.popoverContentSize == originalSize,
      "Light appearance changed the menu-bar popover geometry")

    var copiedError: String?
    let copyStore = MenuBarPopoverStore(
      snapshot: snapshot,
      actions: MenuBarPopoverActions(
        openMainWindow: {}, switchAccount: { _ in },
        copyText: { copiedError = $0 }))
    copyStore.copyError("Synthetic menu error")
    expect(copiedError == "Synthetic menu error", "Menu-bar errors do not expose a copy action")

    controller.update(snapshot: .empty)
    expect(controller.statusTitle.isEmpty, "Status item is not icon-only when usage is unavailable")
    return failures
  }

  static func chatPresentationFailures() -> [String] {
    var failures: [String] = []
    let markdown = """
      # Heading

      A **bold** paragraph.

      > Quoted text

      - First
      - Second

      1. One
      2. Two

      ```swift
      let answer = 42
      ```
      """
    let message = ChatMessage(id: "markdown", role: .assistant, text: markdown, timestamp: nil)
    do {
      let presentation = try ChatMessagePresenter.parse(message)
      if !presentation.blocks.contains(where: { if case .heading = $0 { true } else { false } }) {
        failures.append("Chat presentation did not preserve a Markdown heading")
      }
      if !presentation.blocks.contains(where: { if case .quote = $0 { true } else { false } }) {
        failures.append("Chat presentation did not preserve a Markdown quote")
      }
      if !presentation.blocks.contains(where: { if case .unorderedList = $0 { true } else { false } }) {
        failures.append("Chat presentation did not preserve an unordered list")
      }
      if !presentation.blocks.contains(where: { if case .orderedList = $0 { true } else { false } }) {
        failures.append("Chat presentation did not preserve an ordered list")
      }
      if !presentation.blocks.contains(where: {
        if case let .code(_, language, text, _, _) = $0 {
          return language == "swift" && text == "let answer = 42"
        }
        return false
      }) {
        failures.append("Chat presentation did not preserve a fenced Swift code block")
      }
    } catch {
      failures.append("Chat presentation could not parse structured Markdown: \(error)")
    }

    let longCode = (0..<30).map { "line \($0)" }.joined(separator: "\n")
    let bounded = ChatMessage(
      id: "bounded", role: .assistant,
      text: "```text\n\(longCode)\n```\n"
        + String(repeating: "x", count: ChatMessagePresenter.maximumSourceCharacters + 1),
      timestamp: nil)
    do {
      let presentation = try ChatMessagePresenter.parse(bounded)
      if !presentation.sourceWasTruncated {
        failures.append("Chat presentation did not report its source bound")
      }
      if !presentation.blocks.contains(where: {
        if case let .code(_, _, preview, expanded, _) = $0 {
          return preview.split(separator: "\n").count == ChatMessagePresenter.compactCodeLines
            && expanded != nil
        }
        return false
      }) {
        failures.append("Chat presentation did not compact long code")
      }
    } catch {
      failures.append("Chat presentation could not apply its content bounds: \(error)")
    }

    let suiteName = "Switch.ChatFilterContract.\(UUID().uuidString)"
    if let defaults = UserDefaults(suiteName: suiteName) {
      defer { defaults.removePersistentDomain(forName: suiteName) }
      let selected: ChatMessageFilter = [.prompts, .tools]
      ChatFilterPersistence.save(selected, to: defaults)
      if ChatFilterPersistence.load(from: defaults) != selected {
        failures.append("Chat message filters do not persist their multi-selection")
      }
      defaults.set(Int.max, forKey: ChatFilterPersistence.defaultsKey)
      if ChatFilterPersistence.load(from: defaults) != .all {
        failures.append("Chat message filters do not discard unsupported saved bits")
      }
    } else {
      failures.append("Chat message filter persistence test store is unavailable")
    }

    let roles: [ChatMessageRole] = [.user, .assistant, .tool, .other]
    if roles.map(\.displayName) != ["Prompt", "Response", "Tool", "Other"] {
      failures.append("Chat message category labels are unstable")
    }
    return failures
  }

  @MainActor static func menuFailures(in mainMenu: NSMenu?, applicationName: String) -> [String] {
    guard let mainMenu else { return ["Main menu is unavailable"] }
    var failures: [String] = []
    let expectedPages = ["Accounts", "Backup", "Chat History", "Cleanup", "Settings"]
    if AIManagerPage.allCases.map(\.rawValue) != expectedPages {
      failures.append("The rail and View menu page order is incorrect")
    }
    if AIMIcon.Name.history.symbol != "bubble.left.and.bubble.right"
      || NSImage(systemSymbolName: AIMIcon.Name.history.symbol, accessibilityDescription: nil) == nil
    {
      failures.append("Chat History does not use the required system chat symbol")
    }
    if abs(AIMTheme.historyRailIconSize - (AIMTheme.railIconSize * 0.75)) > 0.001 {
      failures.append("The Chat History rail symbol is not 25 percent smaller")
    }
    let expectedMenus = [applicationName, "File", "Edit", "View", "Window", "Help"]
    if mainMenu.items.map(\.title) != expectedMenus {
      failures.append("Main menu order does not match the native menu contract")
    }
    func command(_ menu: String, _ title: String, key: String, modifiers: NSEvent.ModifierFlags = .command) {
      guard let item = mainMenu.item(withTitle: menu)?.submenu?.item(withTitle: title) else {
        failures.append("\(menu) > \(title) is missing")
        return
      }
      if item.keyEquivalent != key || item.keyEquivalentModifierMask != modifiers {
        failures.append("\(menu) > \(title) has the wrong key equivalent")
      }
    }
    func nativeCommand(_ menu: String, _ title: String, action: Selector) {
      guard let item = mainMenu.item(withTitle: menu)?.submenu?.item(withTitle: title) else {
        failures.append("\(menu) > \(title) is missing")
        return
      }
      if item.action != action { failures.append("\(menu) > \(title) does not use the native action") }
    }
    command(applicationName, "Settings…", key: ",")
    command(applicationName, "Quit \(applicationName)", key: "q")
    command("File", "Add Account…", key: "n")
    command("File", "Advanced Import…", key: "i", modifiers: [.command, .shift])
    command("File", "Close Window", key: "w")
    command("Window", "Minimize", key: "m")
    for (index, page) in AIManagerPage.allCases.enumerated() {
      command("View", page.rawValue, key: String(index + 1))
    }
    for (menu, title, action) in [
      (applicationName, "About \(applicationName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
      (applicationName, "Hide \(applicationName)", #selector(NSApplication.hide(_:))),
      (applicationName, "Hide Others", #selector(NSApplication.hideOtherApplications(_:))),
      (applicationName, "Show All", #selector(NSApplication.unhideAllApplications(_:))),
      (applicationName, "Quit \(applicationName)", #selector(NSApplication.terminate(_:))),
      ("Edit", "Cut", #selector(NSText.cut(_:))),
      ("Edit", "Copy", #selector(NSText.copy(_:))),
      ("Edit", "Paste", #selector(NSText.paste(_:))),
      ("Edit", "Select All", #selector(NSText.selectAll(_:))),
      ("Window", "Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
      ("Help", "\(applicationName) Help", #selector(NSApplication.showHelp(_:))),
    ] {
      nativeCommand(menu, title, action: action)
    }
    if mainMenu.item(withTitle: applicationName)?.submenu?.item(withTitle: "Services")?.submenu !== NSApp.servicesMenu {
      failures.append("The application Services menu is not registered")
    }
    if mainMenu.item(withTitle: "Window")?.submenu !== NSApp.windowsMenu {
      failures.append("The Window menu is not registered with AppKit")
    }
    if mainMenu.item(withTitle: "Help")?.submenu !== NSApp.helpMenu {
      failures.append("The Help menu is not registered with AppKit")
    }
    let windowItems = mainMenu.item(withTitle: "Window")?.submenu?.items ?? []
    if windowItems.contains(where: { $0.action == #selector(NSWindow.performZoom(_:)) || $0.title.contains("Zoom") }) {
      failures.append("The fixed window exposes a maximize command")
    }
    return failures
  }

  @MainActor static func exerciseMenuNavigation(in window: NSWindow?) -> [String] {
    guard let mainMenu = NSApp.mainMenu, let window else { return ["Menu navigation test could not resolve the app window"] }
    var failures: [String] = []
    var shownPages: [AIManagerPage] = []
    let observer = NotificationCenter.default.addObserver(
      forName: AIManagerNavigation.didShowPage, object: nil, queue: .main
    ) { notification in
      if let page = notification.object as? AIManagerPage { shownPages.append(page) }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    window.orderOut(nil)
    let settings = mainMenu.item(withTitle: mainMenu.items[0].title)?.submenu?.item(withTitle: "Settings…")
    if let settings, let action = settings.action {
      if !NSApp.sendAction(action, to: settings.target, from: settings) {
        failures.append("Command+, could not dispatch its action")
      }
    } else {
      failures.append("Command+, could not resolve its menu item")
    }
    if !window.isVisible { failures.append("Command+, did not bring the main window forward") }
    if shownPages.last != .settings { failures.append("Command+, did not navigate to Settings") }

    for page in AIManagerPage.allCases {
      guard let item = mainMenu.item(withTitle: "View")?.submenu?.item(withTitle: page.rawValue),
            let action = item.action else {
        failures.append("View > \(page.rawValue) could not resolve its action")
        continue
      }
      _ = NSApp.sendAction(action, to: item.target, from: item)
      if shownPages.last != page { failures.append("View > \(page.rawValue) did not navigate") }
    }
    return failures
  }

  // Acceptance points use the screenshot's top-left origin; AppKit content views usually do not.
  static func titleDragTarget(in window: NSWindow, at point: NSPoint) -> Bool {
    guard let contentView = window.contentView else { return false }
    return hitTest(in: contentView, atTopOriginPoint: point) is AIMTitleDragView
  }

  static func focusPolicyMatches(in root: NSView, indicatorsEnabled: Bool) -> Bool {
    root.focusRingType == (indicatorsEnabled ? .default : .none)
  }

  static func defaultFocusIndicatorsAreHidden(in window: NSWindow) -> Bool {
    window.contentView?.focusRingType == NSFocusRingType.none
  }

  static func windowControlGeometryMatches() -> Bool {
    let size = AIMTheme.windowControlSize
    return size == 48 && AIMTheme.railWidth == size
      && AIMTheme.topbarHeight == size && AIMTheme.modalTitlebarHeight == size
      && AIMTheme.modalHeight == 648 && AIMTheme.addAccountModalHeight == 480
      && AIMTheme.modalOuterInset == 24
      && AIMTheme.modalSectionSpacing == 16
  }

  static func windowPlacementFailures() -> [String] {
    var failures: [String] = []
    let size = NSSize(width: 1120, height: 740)
    let primary = AIManagerDisplayDescriptor(
      identifier: "primary", name: "Built-in Display",
      frame: NSRect(x: 0, y: 0, width: 1728, height: 1117),
      visibleFrame: NSRect(x: 0, y: 38, width: 1728, height: 1054))
    let external = AIManagerDisplayDescriptor(
      identifier: "external", name: "External Display",
      frame: NSRect(x: -2560, y: 120, width: 2560, height: 1440),
      visibleFrame: NSRect(x: -2560, y: 120, width: 2560, height: 1416))
    let original = NSRect(x: -2200, y: 620, width: size.width, height: size.height)
    let placement = AIManagerWindowPlacement.placement(for: original, on: external)
    if AIManagerWindowPlacement.restoredFrame(
      for: placement, windowSize: size, displays: [primary, external]) != original
    {
      failures.append("Window placement does not restore a negative-coordinate display")
    }

    let rearrangedExternal = AIManagerDisplayDescriptor(
      identifier: "external", name: "External Display",
      frame: NSRect(x: 1728, y: -400, width: 2560, height: 1440),
      visibleFrame: NSRect(x: 1728, y: -400, width: 2560, height: 1416))
    let expectedRearranged = NSRect(x: 2088, y: 100, width: size.width, height: size.height)
    if AIManagerWindowPlacement.restoredFrame(
      for: placement, windowSize: size, displays: [primary, rearrangedExternal])
      != expectedRearranged
    {
      failures.append("Window placement does not follow a rearranged saved display")
    }
    if AIManagerWindowPlacement.restoredFrame(
      for: placement, windowSize: size, displays: [primary]) != nil
    {
      failures.append("Window placement falls back to the wrong display")
    }

    let legacy = "-2200 620 1120 740 -2560 120 2560 1410"
    if AIManagerWindowPlacement.legacyPlacement(
      from: legacy, displays: [primary, external]) != placement
    {
      failures.append("Legacy AppKit placement does not tolerate usable-frame changes")
    }
    let unrelatedLegacy = "7000 7000 1120 740 7000 7000 2560 1440"
    if AIManagerWindowPlacement.legacyPlacement(
      from: unrelatedLegacy, displays: [primary, external]) != nil
    {
      failures.append("Legacy AppKit placement migrates to an unrelated display")
    }

    let domain = "com.mandalsuraj.ai-manager.acceptance.window-placement"
    if let defaults = UserDefaults(suiteName: domain) {
      defaults.removePersistentDomain(forName: domain)
      AIManagerWindowPlacement.store(placement, defaults: defaults)
      if AIManagerWindowPlacement.load(defaults: defaults) != placement {
        failures.append("Window placement does not persist through UserDefaults")
      }
      defaults.removePersistentDomain(forName: domain)
    } else {
      failures.append("Window placement test defaults are unavailable")
    }

    let farOutside = AIManagerStoredWindowPlacement(
      version: 1, displayIdentifier: "external", displayName: "External Display",
      displayFrameX: external.frame.minX, displayFrameY: external.frame.minY,
      displayFrameWidth: external.frame.width, displayFrameHeight: external.frame.height,
      leftOffset: 99_999, topOffset: 99_999)
    guard let clamped = AIManagerWindowPlacement.restoredFrame(
      for: farOutside, windowSize: size, displays: [external])
    else {
      failures.append("Window placement did not produce a clamped frame")
      return failures
    }
    if !external.visibleFrame.contains(clamped) {
      failures.append("Window placement did not clamp into the display visible frame")
    }
    return failures
  }

  static func scrollBehaviorIsInstalled(in root: NSView) -> Bool {
    let scrollViews = views(in: root).compactMap { $0 as? NSScrollView }
    return !scrollViews.isEmpty && configuredScrollViewCount(in: root) == scrollViews.count
      && scrollViews.allSatisfy { scroll in
        guard let document = scroll.documentView else { return false }
        return document.frame.height > 0 && scroll.contentView.bounds.height > 0
          && abs(document.frame.width - scroll.contentView.bounds.width) < 1
          && abs(scroll.contentView.frame.width - scroll.bounds.width) < 1
      }
  }

  static func configuredScrollViewCount(in root: NSView) -> Int {
    views(in: root).compactMap { $0 as? NSScrollView }.filter {
      $0.autohidesScrollers && $0.verticalScroller is AIMThinScroller
        && ($0.scrollerStyle == .overlay
          || abs($0.contentView.frame.width - $0.bounds.width) < 1)
    }.count
  }

  static func historySearchFieldsMatch(in root: NSView) -> Bool {
    let placeholders = Set(views(in: root).compactMap {
      ($0 as? NSTextField)?.placeholderString
    })
    return placeholders.contains("Search conversations") && placeholders.contains("Search this chat")
  }

  static func virtualHistoryScrollCount(in root: NSView) -> Int {
    views(in: root).filter { $0 is AIMVirtualTableView }.count
  }

  static func realizedVirtualRowCount(in root: NSView) -> Int {
    views(in: root).filter { $0 is NSTableRowView }.count
  }

  static func scrollAppearancesMatch(in root: NSView, appearance: NSAppearance) -> Bool {
    views(in: root).compactMap { $0 as? NSScrollView }.allSatisfy {
      $0.documentView?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        == appearance.bestMatch(from: [.darkAqua, .aqua])
    }
  }

  static func scrollIdentity(in root: NSView) -> String {
    views(in: root).compactMap { $0 as? NSScrollView }
      .map { String(describing: ObjectIdentifier($0)) }.joined(separator: ",")
  }

  static func hasVisualEffect(in root: NSView) -> Bool {
    views(in: root).contains { $0 is NSVisualEffectView }
  }

  static func hierarchySnapshot(in root: NSView) -> [AIManagerNativeViewSnapshot] {
    snapshot(view: root, path: "0")
  }

  static func hitTestPath(in window: NSWindow, atTopOriginPoint point: NSPoint) -> [String] {
    guard let contentView = window.contentView else { return [] }
    var current = hitTest(in: contentView, atTopOriginPoint: point)
    var path: [String] = []
    while let view = current {
      path.append(
        "\(NSStringFromClass(type(of: view))) frame=\(NSStringFromRect(view.frame)) flipped=\(view.isFlipped)"
      )
      current = view.superview
    }
    return path
  }

  private static func views(in root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap { views(in: $0) }
  }

  private static func snapshot(view: NSView, path: String) -> [AIManagerNativeViewSnapshot] {
    let scrollView = view as? NSScrollView
    let item = AIManagerNativeViewSnapshot(
      path: path,
      className: NSStringFromClass(type(of: view)),
      frameX: view.frame.minX,
      frameY: view.frame.minY,
      frameWidth: view.frame.width,
      frameHeight: view.frame.height,
      isFlipped: view.isFlipped,
      focusRingType: view.focusRingType.rawValue,
      scrollStyle: scrollView.map { $0.scrollerStyle == .overlay ? "overlay" : "legacy" },
      autohidesScrollers: scrollView?.autohidesScrollers,
      verticalScrollerClass: scrollView?.verticalScroller.map { NSStringFromClass(type(of: $0)) }
    )
    return [item]
      + view.subviews.enumerated().flatMap { index, child in
        snapshot(view: child, path: "\(path).\(index)")
      }
  }

  private static func appKitPoint(fromTopOrigin point: NSPoint, in view: NSView) -> NSPoint {
    view.isFlipped ? point : NSPoint(x: point.x, y: view.bounds.height - point.y)
  }

  private static func hitTest(in view: NSView, atTopOriginPoint point: NSPoint) -> NSView? {
    let localPoint = appKitPoint(fromTopOrigin: point, in: view)
    let pointForHitTest = view.superview.map { view.convert(localPoint, to: $0) } ?? localPoint
    return view.hitTest(pointForHitTest)
  }
}
