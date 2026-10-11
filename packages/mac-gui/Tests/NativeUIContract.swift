import AIManagerCore
import AppKit
import CoreServices
import SwiftUI

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

private final class PaginationTestDocument: NSView {
  override var isFlipped: Bool { true }
}

@MainActor
enum AIManagerNativeContract {
  static func presentationContractFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }

    failures.append(contentsOf: nativeDesignFailures())

    let loginEvent = NSAppleEventDescriptor(
      eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
      targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID))
    loginEvent.setParam(
      NSAppleEventDescriptor(boolean: true),
      forKeyword: AEKeyword(keyAELaunchedAsLogInItem))
    let ordinaryEvent = NSAppleEventDescriptor(
      eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
      targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID))
    expect(AIManagerLaunchContext.launchedAsLoginItem(event: loginEvent),
      "A login-item launch opens the main window")
    expect(!AIManagerLaunchContext.launchedAsLoginItem(event: ordinaryEvent),
      "An ordinary launch is mistaken for a login-item launch")
    expect(LaunchAtLoginSettings.detail(for: .enabled).contains("menu bar")
      && LaunchAtLoginSettings.detail(for: .requiresApproval).contains("System Settings"),
      "Open-at-login status copy does not explain the current system state")

    expect(UsagePresentation.credits(nil) == nil, "Missing credits are visible")
    expect(
      UsagePresentation.credits(CodexCreditsSnapshot(
        hasCredits: nil, unlimited: nil, balance: "  ")) == nil,
      "Empty credits are visible")
    expect(
      UsagePresentation.credits(CodexCreditsSnapshot(
        hasCredits: false, unlimited: nil, balance: nil)) == "None",
      "Explicit false credits are hidden")
    expect(
      UsagePresentation.credits(CodexCreditsSnapshot(
        hasCredits: true, unlimited: nil, balance: "796.4009760000")) == "$31.84 · 796 credits",
      "Fixed-point credit balances are not shown as dollars and credits")
    let resetCredits = CodexResetCredits(
      count: 2, expiries: [Date(timeIntervalSince1970: 1_800_086_400), Date(timeIntervalSince1970: 1_800_000_000)])
    let resetFact = UsagePresentation.resetCreditsFact(resetCredits)
    expect(
      resetFact?.label == "Reset credits" && resetFact?.value.hasPrefix("2 · next expires ") == true
        && resetFact?.help?.hasPrefix("Expires: ") == true,
      "Reset credits omit the count, soonest expiry, or tooltip list")
    expect(UsagePresentation.resetCreditsFact(nil) == nil, "Missing reset credits are visible")
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
    expect(CodexTokenPeriod.allCases.map(\.label) == [
      "Today", "Yesterday", "Weekly", "Monthly", "Yearly",
    ], "Token statistics filters changed")
    expect(CodexTokenPeriod.allCases.map(\.dayCount) == [1, 1, 7, 30, 365],
      "Token activity periods no longer drive matching calendar ranges")
    expect(UsagePresentation.formatCurrency(1_648) == "$1.6K",
      "API-equivalent currency is not compact enough for the menu bar")
    let weeks = UsagePresentation.activityWeeks(for: activityDays)
    let heatmap = ActivityHeatmap(weeks: weeks, maximumTokens: 8,
      selectedDate: nil, size: 9, select: { _ in })
    // September 14, 2026 is Monday, the second row in a Sunday-first grid.
    expect(heatmap.day(at: CGPoint(x: 31, y: 16))?.tokens == 8,
      "Heatmap hit testing or weekday labels do not select Monday's token count")
    expect(heatmap.day(at: CGPoint(x: 13, y: 16)) == nil
      && heatmap.day(at: CGPoint(x: 24.5, y: 16)) == nil
      && heatmap.day(at: CGPoint(x: 31, y: 21.5)) == nil
      && heatmap.day(at: CGPoint(x: 31, y: -1)) == nil,
      "Heatmap gutters and labels select a neighboring day")
    for (column, week) in weeks.enumerated() {
      for (row, day) in week.enumerated() {
        expect(heatmap.day(at: CGPoint(x: 19 + column * 12, y: 4 + row * 12)) == day,
          "Heatmap marker does not select its exact activity day")
      }
    }
    let mondayHeatmap = ActivityHeatmap(weeks: weeks, maximumTokens: 8,
      selectedDate: activityDays[5].date, size: 9, select: { _ in })
    expect(mondayHeatmap.selection(after: .leftArrow) == activityDays[0].date
      && mondayHeatmap.selection(after: .rightArrow) == activityDays[6].date
      && mondayHeatmap.selection(after: .upArrow) == activityDays[4].date
      && mondayHeatmap.selection(after: .downArrow) == activityDays[6].date
      && mondayHeatmap.selection(after: "a") == nil,
      "Heatmap keyboard selection skips a day or escapes the filtered date range")

    expect(HistoryHeaderLayout.height == 40, "Conversation header height changed")
    expect(HistoryHeaderLayout.countWidth >= 120, "Conversation count slot clips its label")
    expect(HistoryHeaderLayout.warningWidth == 32, "Conversation warning slot width changed")
    let codeHost = NSHostingView(rootView: ChatCodeBlock(
      language: "swift", preview: String(repeating: "longCodeLine", count: 40),
      expandedText: nil, sourceWasTruncated: false).frame(width: 300))
    codeHost.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
    codeHost.layoutSubtreeIfNeeded()
    expect(!views(in: codeHost).contains(where: { $0 is NSScrollView }),
      "Code blocks capture vertical scrolling instead of letting the chat reader scroll")
    let pagingScroll = AIMOwnedScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 160))
    pagingScroll.documentView = PaginationTestDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 1_000))
    var endCalls = 0
    pagingScroll.onReachEnd = { endCalls += 1 }
    pagingScroll.contentView.scroll(to: .zero)
    pagingScroll.reflectScrolledClipView(pagingScroll.contentView)
    expect(endCalls == 0, "Conversation pagination loads before the reader reaches the end")
    pagingScroll.contentView.scroll(to: NSPoint(x: 0, y: 840))
    pagingScroll.reflectScrolledClipView(pagingScroll.contentView)
    expect(endCalls > 0, "Native scrolling does not request the next message page")
    let cleanupNow = Date(timeIntervalSince1970: 1_800_000_000)
    let cutoff = cleanupNow.addingTimeInterval(-7 * 86_400)
    expect(CleanupDateRange.week.contains(cutoff, now: cleanupNow, from: cutoff, through: cleanupNow)
      && !CleanupDateRange.olderWeek.contains(cutoff, now: cleanupNow, from: cutoff, through: cleanupNow)
      && CleanupDateRange.olderWeek.contains(cutoff.addingTimeInterval(-1), now: cleanupNow, from: cutoff, through: cleanupNow),
      "Cleanup date ranges overlap or miss their boundary")
    let dayStart = Calendar.current.startOfDay(for: cleanupNow)
    let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
    expect(CleanupDateRange.custom.contains(dayStart, now: cleanupNow, from: dayStart, through: dayStart)
      && !CleanupDateRange.custom.contains(nextDay, now: cleanupNow, from: dayStart, through: dayStart),
      "Cleanup custom dates exclude the first day or include the next day")
    let weeklyOnly = MenuBarUsageSnapshot(usedPercentage: nil, secondaryUsedPercentage: 1)
    expect(
      weeklyOnly.usedPercentage == nil && weeklyOnly.secondaryUsedPercentage == 1
        && (weeklyOnly.usedPercentage ?? weeklyOnly.secondaryUsedPercentage) == 1,
      "Weekly-only usage is discarded or missing from the status item")
    let weeklyPrimary = MenuBarUsageSnapshot(bucket: .init(
      id: nil, name: nil, plan: nil, model: nil,
      primary: .init(usedPercent: 1, windowDurationMinutes: 10_080, resetsAt: nil),
      secondary: nil, credits: nil, spendControlReached: nil), fetchedAt: activityEnd)
    expect(
      weeklyPrimary?.usedPercentage == 1 && weeklyPrimary?.secondaryUsedPercentage == nil
        && weeklyPrimary?.primaryLabel == "Weekly",
      "A weekly-only response does not take the primary slot as Weekly")
    let weeklySecondary = MenuBarUsageSnapshot(bucket: .init(
      id: nil, name: nil, plan: nil, model: nil, primary: nil,
      secondary: .init(usedPercent: 3, windowDurationMinutes: 10_080, resetsAt: nil),
      credits: nil, spendControlReached: nil), fetchedAt: activityEnd)
    expect(
      weeklySecondary?.usedPercentage == 3 && weeklySecondary?.secondaryUsedPercentage == nil
        && weeklySecondary?.primaryLabel == "Weekly",
      "A lone weekly secondary window does not move to the primary slot")
    let resetNow = Date(timeIntervalSince1970: 0)
    expect(UsageResetLabel.text(until: resetNow.addingTimeInterval(2 * 86_400 - 60), now: resetNow)
      == "Resets in 1 day 23h 59m", "Reset countdown rounds almost two days up")
    expect(UsageResetLabel.text(until: resetNow.addingTimeInterval(2 * 86_400), now: resetNow)
      == "Resets in 2 days 0h 0m", "Reset countdown drops exact days")
    expect(UsageResetLabel.text(until: resetNow.addingTimeInterval(86_400 + 2 * 3_600 + 3 * 60), now: resetNow)
      == "Resets in 1 day 2h 3m", "Reset countdown drops hours or minutes")
    expect(UsageResetLabel.text(until: resetNow.addingTimeInterval(3_600), now: resetNow)
      == "Resets in 1h 0m", "Reset countdown has the wrong hour boundary")
    expect(UsageResetLabel.text(until: resetNow.addingTimeInterval(59), now: resetNow)
      == "Resets in <1m", "Reset countdown says zero minutes before reset")
    // A passed reset never reads "now": unused windows are "Not started", others "Resetting…".
    for exact in [false, true] {
      expect(UsageResetLabel.text(until: resetNow, now: resetNow, exact: exact, usedPercent: 0) == "Not started"
        && UsageResetLabel.text(until: resetNow.addingTimeInterval(-90), now: resetNow, exact: exact) == "Not started"
        && UsageResetLabel.text(until: resetNow, now: resetNow, exact: exact, usedPercent: 37) == "Resetting…",
        "A passed reset does not read Not started or Resetting… (exact \(exact))")
      expect(OverviewFormat.compactReset(resetNow, now: resetNow, exact: exact, usedPercent: 0) == "Not started"
        && OverviewFormat.compactReset(resetNow, now: resetNow, exact: exact, usedPercent: 12) == "Resetting…",
        "The Overview table reads \"now\" for a passed reset (exact \(exact))")
    }
    failures.append(contentsOf: activityCalendarRenderFailures())
    failures.append(contentsOf: menuBarUsagePreferenceFailures())
    return failures
  }

  static func activityCalendarRenderFailures() -> [String] {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    let rows = UsagePresentation.activityDays([], endingAt: Date(), dayCount: 365)
      .enumerated().map { offset, day in
        CodexDailyUsageSnapshot(startDate: formatter.string(from: day.date), tokens: Int64(offset + 1))
      }
    let model = AccountViewModel(scenario: .demo)
    var elapsed: [Double] = []
    for _ in 0..<2 {
      let start = CFAbsoluteTimeGetCurrent()
      let host = NSHostingView(rootView: UsageActivityCalendar(rows: rows, model: model))
      host.frame = NSRect(x: 0, y: 0, width: 800, height: 160)
      host.layoutSubtreeIfNeeded()
      if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
      }
      elapsed.append(CFAbsoluteTimeGetCurrent() - start)
    }
    let warm = elapsed[1]
    FileHandle.standardError.write(Data("ACTIVITY_RENDER_MS \(Int(warm * 1000))\n".utf8))
    var failures = warm < 0.2 ? [] : ["A warm yearly activity render blocks the main thread for \(Int(warm * 1000)) ms"]
    // The Accounts page (index 1) is where an account selection redraws the account detail.
    let pane = NSHostingView(rootView: AccountWindow(model: model, initialPageIndex: 1))
    pane.frame = NSRect(x: 0, y: 0, width: 1120, height: 740)
    let window = NSWindow(contentRect: pane.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = pane
    pane.layoutSubtreeIfNeeded()
    for account in (model.status?.accounts ?? []).reversed() {
      let start = CFAbsoluteTimeGetCurrent()
      model.selectedAccountID = account.id
      pane.layoutSubtreeIfNeeded()
      if let bitmap = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) {
        pane.cacheDisplay(in: pane.bounds, to: bitmap)
      }
      let milliseconds = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
      FileHandle.standardError.write(Data("ACCOUNT_SELECTION_RENDER_MS \(milliseconds)\n".utf8))
      if milliseconds >= 100 { failures.append("Ordinary account selection blocks the full pane for \(milliseconds) ms") }
    }
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
    if MenuBarTokenPeriod.selected(defaults: defaults) != .sinceReset {
      failures.append("Menu-bar token period does not default to since reset")
    }
    defaults.set(MenuBarTokenPeriod.monthly.rawValue, forKey: MenuBarTokenPeriod.preferenceKey)
    if MenuBarTokenPeriod.selected(defaults: defaults) != .monthly {
      failures.append("Menu-bar token period does not persist")
    }
    let reset = ISO8601DateFormatter().date(from: "2026-09-21T00:00:00Z")!
    let now = ISO8601DateFormatter().date(from: "2026-09-15T12:00:00Z")!
    let usage = CodexAccountUsageSnapshot(
      account: nil, requiresOpenAIAuthentication: nil,
      rateLimits: CodexRateLimitsSnapshot(
        accountID: nil, ordinaryUsageAllowed: nil,
        defaultBucket: CodexRateLimitBucketSnapshot(
          id: nil, name: nil, plan: nil, model: nil, primary: nil,
          secondary: CodexRateLimitWindowSnapshot(
            usedPercent: 39, windowDurationMinutes: 10_080, resetsAt: reset),
          credits: nil, spendControlReached: nil),
        buckets: [:]),
      usage: nil, dailyUsage: [], fetchedAt: now)
    let rows = [
      CodexDailyUsageSnapshot(startDate: "2026-09-13", tokens: 100),
      CodexDailyUsageSnapshot(startDate: "2026-09-14", tokens: 40),
      CodexDailyUsageSnapshot(startDate: "2026-09-15", tokens: 60),
    ]
    if MenuBarTokenPeriod.sinceReset.tokens(in: rows, usage: usage, now: now) != 100 {
      failures.append("Since-reset token summary ignores the weekly reset boundary")
    }
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
    if UsagePercentagePreferences.showsUsed(defaults: defaults)
      || UsagePercentagePreferences.label(forUsed: 42, showsUsed: false) != "58% left"
    {
      failures.append("Usage percentages do not default to percentage left")
    }
    defaults.set(true, forKey: UsagePercentagePreferences.showsUsedKey)
    if let reopened = UserDefaults(suiteName: domain),
      !UsagePercentagePreferences.showsUsed(defaults: reopened)
    {
      failures.append("Usage percentage meaning does not survive reopening preferences")
    }
    if UsagePercentagePreferences.label(forUsed: 42, showsUsed: true) != "42% used"
      || UsagePercentagePreferences.displayedPercentage(forUsed: -1, showsUsed: true) != 0
      || UsagePercentagePreferences.displayedPercentage(forUsed: 101, showsUsed: false) != 0
    {
      failures.append("Usage percentage display does not convert or clamp API values")
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
    // Drag-to-reorder: SwiftUI's insertion offset maps to the account that takes the moved row's slot.
    let ids = (0..<4).map { _ in UUID() }
    func target(_ from: Int, _ destination: Int) -> UUID? {
      AccountReorder.move(accountIDs: ids, from: IndexSet(integer: from), to: destination)?.targetID
    }
    if target(0, 3) != ids[2] || target(2, 0) != ids[0] || target(1, 1) != nil || target(1, 2) != nil
      || target(3, 4) != nil || target(0, 5) != nil
      || AccountReorder.move(accountIDs: ids, from: IndexSet([0, 1]), to: 3) != nil
      || AccountReorder.move(accountIDs: ids, from: IndexSet(integer: 0), to: 4)?.targetID != ids[3]
    {
      failures.append("Dragging an account in the Accounts list targets the wrong position")
    }
    if AccountActionCopy.use != "Make Default"
      || AccountActionCopy.usingDefault != "Using as default"
    { failures.append("Default account action uses stale labels") }
    if AccountActionCopy.copyAuthPath != "Copy auth path" {
      failures.append("Account auth-path action uses stale copy")
    }
    if AccountActionCopy.useAndOpen(.codex) != "Use & Open Codex"
      || AccountActionCopy.open(.grokBuild) != "Open Grok Build"
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
    if [ProviderID.codex, .grokBuild, .claudeCode, .geminiCLI, .antigravityCLI]
      .map(\.displayName)
      != ["Codex CLI", "Grok Build", "Claude Code", "Gemini CLI", "Antigravity CLI"]
    {
      failures.append("Provider names are not derived consistently")
    }
    return failures
  }

  /// Generic provider UI: icons, menu cards, pace colors, and the detail and Add Account views.
  @MainActor static func providerUIFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }
    // Icons: 96 packaged monochrome marks, each one renders, aliases resolve, licence ships.
    let bundle = Bundle.main
    let directory = bundle.resourceURL?.appending(path: "Icons/ProviderIcons", directoryHint: .isDirectory)
    let files = directory.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
    let icons = files.filter { $0.hasPrefix("ProviderIcon-") && $0.hasSuffix(".svg") }
    expect(icons.count == 96, "Packaged provider icons are missing: found \(icons.count) of 96")
    expect(files.contains("LICENSE-CodexBar.txt"), "The CodexBar MIT notice is not packaged with the icons")
    func rendersInk(_ image: NSImage) -> Bool {
      guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      image.draw(in: NSRect(x: 0, y: 0, width: 48, height: 48))
      NSGraphicsContext.restoreGraphicsState()
      var ink = 0
      for x in 0..<48 { for y in 0..<48 where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 { ink += 1 } }
      return ink > 12
    }
    for file in icons {
      let name = String(file.dropFirst("ProviderIcon-".count).dropLast(".svg".count))
      let image = NSImage(contentsOf: directory!.appending(path: file))
      expect(image.map(rendersInk) == true, "Provider icon \(name) renders blank")
      expect(AIManagerBrand.providerIcon(for: ProviderID(rawValue: name)).isTemplate,
             "Provider icon \(name) is not a template image")
    }
    for (id, target) in AIManagerBrand.providerIconAliases {
      expect(AIManagerBrand.providerGlyphNames[target] != nil || icons.contains("ProviderIcon-\(target).svg"),
             "Icon alias \(id) -> \(target) has no artwork")
    }
    for spec in ProviderCatalog.all {
      let icon = AIManagerBrand.providerIcon(for: spec.id)
      expect(icon.size.width > 0 && icon.isTemplate, "\(spec.name) has no template icon or monogram")
      expect(icon === AIManagerBrand.providerIcon(for: spec.id), "\(spec.name) icon is not cached")
    }
    let monogram = AIManagerBrand.monogram(for: ProviderID(rawValue: "no-such-provider"))
    expect(monogram.isTemplate && rendersInk(monogram), "The monogram fallback is blank or not a template")
    expect(AIManagerBrand.providerIconName(for: .geminiCLI) == "gemini"
      && AIManagerBrand.providerIconName(for: .antigravityCLI) == "antigravity"
      && AIManagerBrand.providerIconName(for: .grokBuild) == "grok"
      && AIManagerBrand.providerIconName(for: .claudeCode) == "claude",
      "Provider icon aliases are wrong")

    // Menu cards for generic accounts.
    let sessionLast = ProviderUsage(windows: [
      UsageWindow(id: "w", title: "Weekly", usedPercent: 40.4, windowMinutes: 10_080),
      UsageWindow(id: "s", title: "Session", usedPercent: 20, windowMinutes: 300),
    ])
    let card = MenuBarUsageSnapshot(providerUsage: sessionLast)
    expect(card?.primaryLabel == "Session" && card?.secondaryLabel == "Weekly"
      && card?.usedPercentage == 20 && card?.secondaryUsedPercentage == 40,
      "Generic menu card does not put the session-like window first")
    expect(MenuBarUsageSnapshot(providerUsage: ProviderUsage()) == nil,
      "An empty provider usage still makes a menu card")
    let balanceOnly = MenuBarUsageSnapshot(providerUsage: ProviderUsage(
      cost: UsageCost(balance: 12.4, currency: "USD")))
    expect(balanceOnly?.balanceText == "$12.40" && balanceOnly?.usedPercentage == nil,
      "Balance-only usage is not one compact balance line")
    let balanceAccount = MenuBarAccountSnapshot(
      id: UUID(), identity: "OpenRouter", detail: "", isVerified: true, isActive: true,
      usage: balanceOnly, providerID: ProviderID(rawValue: "openrouter"))
    expect(balanceAccount.usage?.balanceText == "$12.40", "Balance card lost its balance")
    let threeWindows = MenuBarUsageSnapshot(providerUsage: ProviderUsage(windows: [
      UsageWindow(id: "a", title: "A", usedPercent: 10), UsageWindow(id: "b", title: "B", usedPercent: 20),
      UsageWindow(id: "c", title: "C", usedPercent: 30)]))
    expect(threeWindows?.secondaryLabel == "B" && threeWindows?.secondaryUsedPercentage == 20,
      "Generic menu cards show more than their first two windows")
    let full = MenuBarPopoverPreviewData.fullSnapshot
    expect(full.accounts.count == 4, "Preview menu does not show its four sample rows")
    expect(full.statusAccounts.count == 4, "Status item shows more or fewer than four accounts")
    expect(AIManagerBrand.statusImage(groups: full.statusAccountGroups) != nil, "Status image failed")

    // Pace colors follow the used share and never the Used or Left view.
    let fills = [
      UsagePace.MeterState.level(.normal, label: nil), .healthy(projectedFraction: 0.8),
      .closeToLimit(label: "", projectedFraction: 0.95), .runningOut(eta: nil, projectedFraction: nil), .spent,
    ].map { ProviderWindowMeter.fill(for: $0) }
    expect(fills[0] == fills[1] && fills[2] != fills[1] && fills[3] != fills[1] && fills[3] == fills[4]
      && fills[2] != fills[3], "Meter colors do not map blue, yellow, and red")

    // Charts: overage text stays real while bars stop at the track; the chart view summarizes and lays out.
    expect(UsagePercentagePreferences.label(forUsed: 130, showsUsed: true) == "130% used"
      && UsagePercentagePreferences.label(forUsed: 130, showsUsed: false) == "0% left"
      && UsagePercentagePreferences.fill(forUsed: 130, showsUsed: true) == 1
      && UsagePercentagePreferences.fill(forUsed: -5, showsUsed: true) == 0
      && UsagePercentagePreferences.fill(forUsed: 25, showsUsed: false) == 0.75,
      "Overage text is clamped or bar fill is not limited to 0...1")
    let day = DateFormatter()
    day.locale = Locale(identifier: "en_US_POSIX")
    day.timeZone = TimeZone(identifier: "UTC")
    day.dateFormat = "yyyy-MM-dd"
    var daily: [String: Double] = [:]
    for offset in 0..<30 {
      daily[day.string(from: Date(timeIntervalSince1970: 1_791_633_600 - Double(offset) * 86_400))] =
        offset == 7 ? 2.1 : offset == 0 ? 0.5 : 0.4
    }
    if let spend = UsageChart.daily(id: "spend", title: "Daily spend", unit: "USD", values: daily) {
      expect(spend.points.count == 30 && spend.points.first?.label == "Sep 11" && spend.peak?.label == "Oct 3",
        "Daily chart points are not oldest first with the peak day")
      expect(UsageChartPresentation.summary(spend) == "30 days, total $13.80, peak $2.10 on Oct 3",
        "Chart VoiceOver summary is wrong: \(UsageChartPresentation.summary(spend))")
      expect(UsageChartPresentation.headline(spend, selected: nil) == "Total $13.80"
        && UsageChartPresentation.headline(spend, selected: spend.peak) == "Oct 3 · $2.10",
        "Chart header does not show the total or the focused day")
      expect(UsageChartPresentation.axisLabels(spend) == ["Sep 11", "Sep 26", "Oct 10"], "Chart axis is not first, middle, last")
      expect(UsageChartPresentation.moved(nil, by: -1, count: 30) == 29
        && UsageChartPresentation.moved(0, by: -1, count: 30) == 0
        && UsageChartPresentation.moved(29, by: 1, count: 30) == 29
        && UsageChartPresentation.moved(10, by: 1, count: 30) == 11, "Chart arrow keys do not step days")
      for dark in [false, true] {
        let host = NSHostingView(rootView: UsageChartView(chart: spend)
          .preferredColorScheme(dark ? .dark : .light)
          .frame(width: 520))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 140)
        host.layoutSubtreeIfNeeded()
        expect(host.fittingSize.height >= 72 && host.fittingSize.height < 140, "Chart view does not lay out about 72 points tall")
      }
    } else {
      failures.append("Daily chart builder returned nothing")
    }
    let tokens = UsageChart(id: "t", title: "Tokens", unit: "tokens", points: [
      UsagePoint(label: "Oct 1", value: 1_200_000), UsagePoint(label: "Oct 2", value: 300_000)])
    expect(UsageChartPresentation.summary(tokens) == "2 days, total 1,500,000, peak 1,200,000 on Oct 1"
      && UsageChartPresentation.headline(tokens, selected: nil) == "Total 1.5M",
      "Token chart text is wrong: \(UsageChartPresentation.summary(tokens))")

    // Account detail, usage, and Add Account views lay out for a synthetic generic account.
    let model = AccountViewModel(scenario: .demo)
    guard let gemini = model.status?.accounts.first(where: { $0.identity.providerID == .geminiCLI }) else {
      return failures + ["Demo lacks the Gemini CLI account"]
    }
    expect(gemini.usesGenericDetail && !(model.status?.accounts.first?.usesGenericDetail ?? true),
      "Only non-Codex, non-Grok, non-Claude accounts use the generic detail")
    expect(gemini.identity.accountLabel == "ada.lovelace@example.test", "Generic account label ignores email")
    let chartAccount = model.addDemoProviderAccount(ProviderID(rawValue: "openrouter"))
    expect(model.providerUsage[chartAccount.id]?.usage?.charts.first?.points.count == 30,
      "The OpenRouter demo account has no 30-day chart")
    expect(model.addDemoProviderAccount(.claudeCode).identity.providerID == .claudeCode
      && model.claudeActivity?.chart?.points.count == 30, "The Claude Code demo has no 30-day activity chart")
    let keyAccount = DemoData.genericAccount(ProviderID(rawValue: "openrouter"))
    expect(keyAccount.identity.accountLabel.hasPrefix("OpenRouter ···"),
      "Key-only account label does not use the provider and a key tail")
    let sizes = [NSSize(width: 840, height: 800)]
    let views: [AnyView] = [
      AnyView(ProviderAccountDetail(account: gemini, model: model) {}),
      AnyView(ProviderUsagePanel(account: gemini, model: model)),
      AnyView(ProviderAccountDetail(account: chartAccount, model: model) {}),
      AnyView(ClaudeActivityPanel(model: model)),
      AnyView(ProviderChooserPage(model: model, step: 1) {}),
      AnyView(SecretCredentialsPage(spec: ProviderCatalog.spec(ProviderID(rawValue: "zai"))!, model: model) {}),
      AnyView(FilesCredentialsPage(spec: ProviderCatalog.spec(.geminiCLI)!, model: model) {}),
    ]
    for view in views {
      for size in sizes {
        let host = NSHostingView(rootView: view
          .frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        expect(host.fittingSize.width > 0 && host.fittingSize.height > 0, "A provider view collapsed")
      }
    }
    return failures
  }

  /// Settings rows for notifications, status checks, Claude terminals and privacy, the provider
  /// status dot, and the Claude activity section.
  @MainActor static func featureUIFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }
    func fits(_ view: some View, width: CGFloat = 840, height: CGFloat = 1_800) -> NSHostingView<AnyView> {
      let host = NSHostingView(rootView: AnyView(view
        .frame(width: width, height: height)))
      host.frame = NSRect(x: 0, y: 0, width: width, height: height)
      host.layoutSubtreeIfNeeded()
      return host
    }

    // Settings rows and their defaults.
    expect(SettingsCopy.notificationRows.map(\.title) == ["Almost Out", "Pace alerts", "Available again", "Sign in again"],
      "Settings > Notifications does not list the four toggles")
    expect(Set(SettingsCopy.notificationRows.map(\.key)).count == 4, "Notification toggles share a preference key")
    expect(SettingsCopy.claudeShell == "Use the selected Claude account in terminals"
      && SettingsCopy.claudeShellHelp
        == "Adds one line to ~/.zshrc so a plain claude command uses the default Claude account. A backup is kept.",
      "The Claude terminal setting copy changed")
    expect(SettingsCopy.checkProviderStatus == "Check provider status" && SettingsCopy.hideEmails == "Hide email addresses",
      "A Settings row title changed")
    let suite = "switch-contract-\(UUID().uuidString)"
    if let defaults = UserDefaults(suiteName: suite) {
      expect(SettingsCopy.notificationRows.allSatisfy { !defaults.bool(forKey: $0.key) },
        "A notification toggle is on by default")
      expect(!EmailPrivacy.isEnabled(defaults: defaults) && ProviderStatusPoller.isEnabled(defaults: defaults),
        "Hide email addresses is not off, or provider status is not on, by default")
      defaults.removePersistentDomain(forName: suite)
    }
    let demo = AccountViewModel(scenario: .demo)
    let settings = fits(SettingsPage(model: demo))
    expect(settings.fittingSize.width > 0 && settings.fittingSize.height > 0, "Settings collapsed")

    // Status dot: yellow for minor and maintenance, red for major and critical, nothing otherwise.
    func entry(_ indicator: ProviderIncident.Indicator) -> ProviderStatusEntry {
      ProviderStatusEntry(
        incident: ProviderIncident(indicator: indicator, description: "Elevated errors",
                                   updatedAt: Date().addingTimeInterval(-300)),
        checkedAt: Date())
    }
    for indicator in [ProviderIncident.Indicator.minor, .maintenance, .major, .critical] {
      expect(ProviderStatusDot.text(entry(indicator))?.hasPrefix("Elevated errors · updated ") == true,
        "\(indicator) has no status tooltip")
      expect(NSHostingView(rootView: ProviderStatusDot(entry: entry(indicator))).fittingSize.width >= 7,
        "\(indicator) draws no dot")
    }
    for indicator in [ProviderIncident.Indicator.none, .unknown] {
      expect(ProviderStatusDot.text(entry(indicator)) == nil, "\(indicator) has a status tooltip")
      expect(NSHostingView(rootView: ProviderStatusDot(entry: entry(indicator))).fittingSize.width < 1,
        "\(indicator) draws a dot")
    }
    expect(ProviderStatusDot.text(nil) == nil, "A provider with no status has a tooltip")
    if let account = demo.status?.accounts.first {
      func row(_ status: ProviderStatusEntry?) -> NSSize {
        fits(AccountListRow(account: account, selected: false, isDefault: false,
                            providerStatus: status), width: 240, height: 80).fittingSize
      }
      expect(row(entry(.major)).height == row(nil).height, "A status dot changed the sidebar row height")
    }
    expect(demo.providerStatus[.codex]?.incident.severity == .warning, "The Preview lacks a synthetic incident")

    // Claude activity section.
    expect(ClaudeActivityPanel.title == "Claude Code activity (all profiles)"
      && ClaudeActivityPanel.estimateLabel == "API-equivalent estimate", "Claude activity labels changed")
    _ = demo.addDemoProviderAccount(.claudeCode)
    expect(demo.claudeActivity?.rows.count == 3 && demo.claudeActivity?.unpricedModels.isEmpty == false,
      "The Preview has no synthetic Claude activity")
    expect(fits(ClaudeActivityPanel(model: demo), width: 700, height: 400).fittingSize.height > 0,
      "Claude activity collapsed")
    return failures
  }

  /// Counts View > Refresh Usage dispatches from the acceptance menu.
  @MainActor static var menuRefreshCalls = 0

  /// Reset display, hidden usage rows, the global shortcut, signed-in detection, Command-R, the
  /// status item menu, and Reset settings.
  @MainActor static func appFeatureFailures() async -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }
    func fits(_ view: some View, width: CGFloat = 840, height: CGFloat = 1_800) -> NSHostingView<AnyView> {
      let host = NSHostingView(rootView: AnyView(view
        .frame(width: width, height: height)))
      host.frame = NSRect(x: 0, y: 0, width: width, height: height)
      host.layoutSubtreeIfNeeded()
      return host
    }
    let suite = "switch-app-features-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return ["Feature test store is unavailable"] }
    defer { defaults.removePersistentDomain(forName: suite) }

    // Reset display: countdown by default, exact time with a 12 or 24 hour clock.
    expect(!ResetDisplay.isExact(defaults: defaults) && ResetDisplay.hourFormat(defaults: defaults) == .auto,
      "Reset times are not a countdown with an automatic clock by default")
    let utc = TimeZone(identifier: "UTC")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 15, minute: 25))!
    let sameDay = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 17, minute: 30))!
    let nextDay = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 9, minute: 5))!
    let inThreeDays = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 0, minute: 0))!
    let nextMonth = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 23, minute: 45))!
    func exact(_ date: Date, _ format: HourFormat) -> String {
      ResetDisplay.exactText(date, now: now, hourFormat: format, timeZone: utc)
    }
    expect(exact(sameDay, .twelve) == "Resets 5:30 PM", "12-hour exact reset reads \(exact(sameDay, .twelve))")
    expect(exact(sameDay, .twentyFour) == "Resets 17:30", "24-hour exact reset reads \(exact(sameDay, .twentyFour))")
    expect(exact(nextDay, .twelve) == "Resets tomorrow 9:05 AM", "Tomorrow reset reads \(exact(nextDay, .twelve))")
    expect(exact(inThreeDays, .twentyFour) == "Resets Tue 00:00", "Weekday reset reads \(exact(inThreeDays, .twentyFour))")
    expect(exact(nextMonth, .twelve) == "Resets Oct 20, 11:45 PM", "Distant reset reads \(exact(nextMonth, .twelve))")
    expect(exact(now.addingTimeInterval(-5), .twelve) == "Not started"
      && ResetDisplay.exactText(now.addingTimeInterval(-5), now: now, usedPercent: 40) == "Resetting…",
      "A passed exact reset reads \(exact(now.addingTimeInterval(-5), .twelve))")
    expect(UsageResetLabel.text(until: sameDay, now: now, exact: false) == "Resets in 2h 5m",
      "The countdown changed")
    expect(UsageResetLabel.text(until: sameDay, now: now, exact: true, hourFormat: .twentyFour)
      .hasPrefix("Resets ") && UsageResetLabel.text(until: sameDay, now: now, exact: true) != "Resets in 2h 5m",
      "UsageResetLabel ignores the exact choice")
    defaults.set(true, forKey: ResetDisplay.exactKey)
    defaults.set("24h", forKey: ResetDisplay.hourFormatKey)
    expect(ResetDisplay.isExact(defaults: defaults) && ResetDisplay.hourFormat(defaults: defaults) == .twentyFour,
      "Reset display choices are not read back")
    expect(HourFormat.allCases.map(\.label) == ["Auto", "12-hour", "24-hour"], "Hour format labels changed")
    // Every reset text shares one switch.
    let resetHost = fits(ResetTimeText(reset: sameDay, now: now, usedPercent: 10), width: 300, height: 40)
    expect(resetHost.fittingSize.width > 0, "ResetTimeText collapsed")
    UserDefaults.standard.removeObject(forKey: ResetDisplay.exactKey)
    let before = UsageResetLabel.text(until: sameDay, now: now)
    UserDefaults.standard.set(true, forKey: ResetDisplay.exactKey)
    let after = UsageResetLabel.text(until: sameDay, now: now)
    UserDefaults.standard.removeObject(forKey: ResetDisplay.exactKey)
    expect(before == "Resets in 2h 5m" && after != before, "The shared reset preference does not reach UsageResetLabel")

    // Hidden usage rows persist per account and leave the other accounts alone.
    let first = UUID(), second = UUID()
    let windows = [UsageWindow(id: "a", title: "A", usedPercent: 10), UsageWindow(id: "b", title: "B", usedPercent: 20),
                   UsageWindow(id: "c", title: "C", usedPercent: 30)]
    defaults.set(HiddenUsageRows.encode(["b"]), forKey: HiddenUsageRows.key(for: first))
    expect(HiddenUsageRows.hidden(for: first, defaults: defaults) == ["b"]
      && HiddenUsageRows.hidden(for: second, defaults: defaults).isEmpty, "Hidden rows are not stored per account")
    expect(HiddenUsageRows.visible(windows, hidden: ["b"], id: \.id).map(\.id) == ["a", "c"], "Hide keeps the row")
    expect(HiddenUsageRows.applying(to: ProviderUsage(windows: windows), for: first, defaults: defaults)
      .windows.map(\.id) == ["a", "c"]
      && HiddenUsageRows.applying(to: ProviderUsage(windows: windows), for: second, defaults: defaults)
        .windows.count == 3, "Menu usage ignores hidden rows or hides another account's rows")
    expect(HiddenUsageRows.parse(HiddenUsageRows.encode(["x", "y"])) == ["x", "y"], "Hidden row encoding is lossy")
    expect(HiddenUsageRowsNote.text(count: 1) == "1 hidden row" && HiddenUsageRowsNote.text(count: 2) == "2 hidden rows",
      "Hidden rows note wording changed")
    let demo = AccountViewModel(scenario: .demo)
    if let gemini = demo.status?.accounts.first(where: { $0.identity.providerID == .geminiCLI }) {
      let key = HiddenUsageRows.key(for: gemini.id)
      let panelHeight = { (hidden: String) -> CGFloat in
        UserDefaults.standard.set(hidden, forKey: key)
        let host = NSHostingView(rootView: ProviderUsagePanel(account: gemini, model: demo)
          .frame(width: 840))
        host.frame = NSRect(x: 0, y: 0, width: 840, height: 1_200)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
      }
      let ids = demo.providerUsage[gemini.id]?.usage?.windows.map(\.id) ?? []
      let full = panelHeight("")
      let trimmed = panelHeight(HiddenUsageRows.encode(Set(ids)))
      UserDefaults.standard.removeObject(forKey: key)
      expect(ids.count >= 1 && trimmed != full, "Hiding every usage row does not change the Usage panel")
    } else { failures.append("Demo lacks the Gemini CLI account for hidden rows") }

    // Global shortcut: Carbon registration, validation, storage, recorder.
    let combo = ShortcutCombo(keyCode: 1, flags: [.control, .option])
    expect(combo.display == "⌃⌥S" && combo.isValid, "Shortcut display reads \(combo.display)")
    expect(!ShortcutCombo(keyCode: 1, flags: [.shift]).isValid && !ShortcutCombo(keyCode: 1, flags: []).isValid,
      "A shortcut without Command, Option, or Control is valid")
    expect(ShortcutCombo(keyCode: 49, flags: [.command, .shift]).display == "⇧⌘Space", "Modifier order is wrong")
    GlobalShortcutPreferences.save(combo, defaults: defaults)
    expect(GlobalShortcutPreferences.load(defaults: defaults) == combo, "A saved shortcut is not read back")
    GlobalShortcutPreferences.save(ShortcutCombo(keyCode: 1, flags: [.shift]), defaults: defaults)
    expect(GlobalShortcutPreferences.load(defaults: defaults) == nil, "An invalid shortcut was stored")
    let registrar = GlobalShortcut.shared
    expect(registrar.registered == nil, "A shortcut is registered by default")
    let probe = ShortcutCombo(keyCode: 0x50, flags: [.control, .option, .command])  // F19
    expect(registrar.apply(probe) && registrar.registered == probe, "Carbon refused a free shortcut")
    expect(registrar.apply(nil) && registrar.registered == nil, "Clearing the shortcut did not unregister it")
    expect(fits(ShortcutRecorder(), width: 400, height: 60).fittingSize.width > 0, "Shortcut recorder collapsed")

    // Add Account marks providers already signed in on this Mac and sorts them first.
    let descriptors = demo.providers
    let live: Set<ProviderID> = [.geminiCLI, ProviderID(rawValue: "cursor")]
    let plain = ProviderChoices.all(descriptors: descriptors)
    let marked = ProviderChoices.all(descriptors: descriptors, signedIn: live)
    expect(plain.allSatisfy { !$0.signedInOnThisMac }, "Providers are marked signed in with no detection")
    expect(Array(marked.prefix(3).map(\.id)) == [.codex, .grokBuild, .claudeCode]
      && Set(marked.dropFirst(3).prefix(2).map(\.id)) == live
      && marked.dropFirst(3).prefix(2).allSatisfy(\.signedInOnThisMac)
      && marked.dropFirst(5).allSatisfy { !$0.signedInOnThisMac }
      && marked.count == plain.count, "Signed-in providers do not sort first under the built-ins")
    let tail = marked.dropFirst(5).map(\.name)
    expect(tail == tail.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
      "Providers that are not signed in lost their alphabetical order")
    await demo.detectSignedInProviders()
    expect(demo.signedInProviderIDs == live.union([ProviderID(rawValue: "kilo")]),
      "Preview detection found \(demo.signedInProviderIDs.map(\.rawValue).sorted())")
    expect(ProviderChoices.signedInLabel == "Signed in on this Mac", "The signed-in label changed")
    expect(fits(ProviderChooserPage(model: demo, step: 1) {}, width: 780, height: 560).fittingSize.height > 0,
      "Add Account provider list collapsed with signed-in marks")

    // Command-R: View > Refresh Usage.
    if let item = NSApp.mainMenu?.item(withTitle: "View")?.submenu?.item(withTitle: "Refresh Usage"),
       let action = item.action {
      expect(item.keyEquivalent == "r" && item.keyEquivalentModifierMask == .command, "Refresh Usage is not Command-R")
      let calls = menuRefreshCalls
      _ = NSApp.sendAction(action, to: item.target, from: item)
      expect(menuRefreshCalls == calls + 1, "Command-R did not run the refresh action")
    } else { failures.append("View > Refresh Usage is missing") }

    // Status item right-click menu.
    let statusController = AIManagerStatusItemController(
      snapshot: MenuBarPopoverPreviewData.snapshot,
      defaults: defaults,
      actions: MenuBarPopoverActions(openMainWindow: {}, switchAccount: { _ in }))
    let titles = statusController.makeContextMenu().items.filter { !$0.isSeparatorItem }.map(\.title)
    expect(titles.count == 4 && titles[1] == "Refresh Usage" && titles[2] == "Settings…"
      && titles[3].hasPrefix("Quit "), "Status item menu is \(titles)")
    expect(statusController.usesPopover, "The status item keeps its context menu after setup")

    // Refresh on open is off by default; Reset settings restores every default.
    expect(!PopoverRefreshPreference.isEnabled(defaults: defaults), "Refresh when the menu opens is on by default")
    let uuid = UUID()
    defaults.set(true, forKey: ResetDisplay.exactKey)
    defaults.set(true, forKey: PopoverRefreshPreference.key)
    defaults.set(true, forKey: QuotaNotificationSettings.almostOutKey)
    defaults.set(false, forKey: MenuBarUsagePreferences.overrideKey(for: uuid))
    defaults.set("x", forKey: HiddenUsageRows.key(for: uuid))
    defaults.set("keep", forKey: "Switch.mainWindowPlacement.v1")
    SettingsReset.reset(defaults: defaults)
    expect(!ResetDisplay.isExact(defaults: defaults) && !PopoverRefreshPreference.isEnabled(defaults: defaults)
      && !defaults.bool(forKey: QuotaNotificationSettings.almostOutKey)
      && MenuBarUsagePreferences.explicitValue(for: uuid, defaults: defaults) == nil
      && HiddenUsageRows.hidden(for: uuid, defaults: defaults).isEmpty
      && GlobalShortcutPreferences.load(defaults: defaults) == nil,
      "Reset settings left a preference behind")
    expect(defaults.string(forKey: "Switch.mainWindowPlacement.v1") == "keep", "Reset settings cleared window placement")
    let settings = fits(SettingsPage(model: demo))
    expect(settings.fittingSize.height > 0, "Settings collapsed with the new rows")
    expect(SettingsCopy.resetTimes == "Reset times" && SettingsCopy.menuShortcut == "Menu shortcut"
      && SettingsCopy.refreshOnOpen == "Refresh when the menu opens" && SettingsCopy.resetSettings == "Reset settings",
      "A new Settings row title changed")
    return failures
  }

  static func menuBarRefreshFailures() async -> [String] {
    var calls = 0
    var wasBusy = false
    var store: MenuBarPopoverStore!
    store = MenuBarPopoverStore(snapshot: MenuBarPopoverPreviewData.snapshot,
      actions: MenuBarPopoverActions(openMainWindow: {}, switchAccount: { _ in },
        refreshUsage: {
          calls += 1
          wasBusy = store.isRefreshingUsage && !store.canRefreshUsage
          await store.refreshUsage()
        }))
    await store.refreshUsage()
    var failures: [String] = []
    if calls != 1 || !wasBusy || store.isRefreshingUsage || !store.canRefreshUsage {
      failures.append("Menubar refresh does not guard duplicate requests or reset its busy state")
    }
    store.update(snapshot: MenuBarSnapshot(accounts: [MenuBarAccountSnapshot(
      id: UUID(), identity: "hidden@example.test", detail: "", isVerified: true,
      isActive: false, showsUsage: false)]))
    await store.refreshUsage()
    store.update(snapshot: MenuBarSnapshot(accounts: [MenuBarAccountSnapshot(
      id: UUID(), identity: "unsupported@example.test", detail: "", isVerified: true,
      isActive: false, providerID: ProviderID(rawValue: "no-such-provider"))]))
    await store.refreshUsage()
    store.update(snapshot: MenuBarSnapshot(accounts: [MenuBarAccountSnapshot(
      id: UUID(), identity: "generic@example.test", detail: "", isVerified: true,
      isActive: false, providerID: ProviderID(rawValue: "openrouter"))]))
    let genericCanRefresh = store.canRefreshUsage
    store.update(snapshot: MenuBarSnapshot(accounts: [MenuBarAccountSnapshot(
      id: UUID(), identity: "unsupported@example.test", detail: "", isVerified: true,
      isActive: false, providerID: ProviderID(rawValue: "no-such-provider"))]))
    if !genericCanRefresh {
      return ["Menubar refresh ignores accounts of a generic provider"]
    }
    if calls != 1 || store.canRefreshUsage {
      failures.append("Menubar refresh runs for hidden or unsupported accounts")
    }
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
    let expectedPages = ["Overview", "Accounts", "Conversations", "Maintenance", "Settings"]
    if AIManagerPage.allCases.map(\.rawValue) != expectedPages {
      failures.append("The sidebar and View menu page order is incorrect")
    }
    let expectedSymbols = ["house", "person.crop.circle", "bubble.left.and.bubble.right", "externaldrive", "gearshape"]
    if AIManagerPage.allCases.map(\.icon.symbol) != expectedSymbols
      || expectedSymbols.contains(where: { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil })
    {
      failures.append("The sidebar does not use the required SF Symbols")
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
    command("View", "Search Accounts", key: "k")
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
    if !windowItems.contains(where: { $0.action == #selector(NSWindow.performZoom(_:)) }) {
      failures.append("The resizable window has no Zoom command")
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

  /// The main window is a standard titled window: traffic lights, a unified toolbar, resizable,
  /// opaque, with no bundled fonts and no custom corner mask.
  static func windowChromeFailures(_ window: NSWindow) -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }
    expect(window is AIManagerWindow && window.canBecomeKey && window.canBecomeMain,
      "The main window cannot become key and main")
    expect(window.styleMask.isSuperset(of: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]),
      "The main window is not a standard titled, resizable window")
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      expect(window.standardWindowButton(button).map { !$0.isHidden } == true,
        "The traffic light \(button.rawValue) is missing")
    }
    expect(window.toolbarStyle == .unified, "The window toolbar is not the unified style")
    expect(window.isOpaque && window.backgroundColor.alphaComponent == 1,
      "The window has a transparent exterior")
    expect(window.contentMinSize.width >= AIManagerWindow.minimumSize.width
      && window.contentMaxSize.width > AIManagerWindow.defaultSize.width,
      "The window is not resizable above its minimum size \(window.contentMinSize) \(window.contentMaxSize)")
    expect(window.contentView?.layer?.cornerRadius ?? 0 == 0, "The window content has a custom corner mask")
    expect(Bundle.main.url(forResource: "Fonts", withExtension: nil) == nil,
      "Bundled Inter or PT Mono fonts are still present")
    return failures
  }

  /// Native design tokens, the toolbar search, the Overview page, and the removed settings.
  static func nativeDesignFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }
    // Containers: 10-point corners, 20-point page margins, 16 points between sections, 8 in rows.
    expect(AIMTheme.radius == 10 && AIMTheme.pageMargin == 20 && AIMTheme.sectionSpacing == 16
      && AIMTheme.rowSpacing == 8,
      "Container geometry is not 10-point corners, 20-point margins, 16-point sections, 8-point rows")
    failures.append(contentsOf: typographyFailures())
    // Toolbar search: at least 300 points wide; Command-K comes from the View menu.
    expect(AIManagerToolbar.searchWidth >= 300 && AIManagerToolbar.searchPrompt == "Search accounts…",
      "The toolbar search is narrower than 300 points or has the wrong prompt")
    // Bars: green above 50% left, yellow 20-50%, red below 20%, grey when unknown.
    expect(UsageBarColor.color(leftPercent: 51) == AIMTheme.green
      && UsageBarColor.color(leftPercent: 50) == AIMTheme.yellow
      && UsageBarColor.color(leftPercent: 20) == AIMTheme.yellow
      && UsageBarColor.color(leftPercent: 19) == AIMTheme.red
      && UsageBarColor.color(leftPercent: nil) == nil,
      "Usage bar colors do not follow the 50 and 20 percent thresholds")
    // Removed settings leave no stored preference behind.
    expect(!SettingsReset.keys.contains("keyboardFocusIndicators")
      && !SettingsReset.keys.contains("bodyTranslucency"),
      "A removed setting is still a stored preference")
    // The account search filters by name, provider, and workspace.
    let model = AccountViewModel(scenario: .demo)
    let accounts = model.status?.accounts ?? []
    expect(AccountSearch.filter(accounts, query: "").count == accounts.count
      && AccountSearch.filter(accounts, query: "zzzz-no-match").isEmpty
      && AccountSearch.filter(accounts, query: "gemini").allSatisfy { $0.identity.providerID == .geminiCLI }
      && !AccountSearch.filter(accounts, query: "gemini").isEmpty,
      "Account search does not filter by provider")
    // The Overview focuses the most recently switched default account.
    if var status = model.status, let secondIndex = status.accounts.firstIndex(where: {
      $0.identity.providerID != status.accounts[0].identity.providerID
    }) {
      let first = status.accounts[0], second = status.accounts[secondIndex]
      status.accounts[0].lastUsedAt = Date(timeIntervalSince1970: 100)
      status.accounts[secondIndex].lastUsedAt = Date(timeIntervalSince1970: 200)
      status.defaultAccountIDs = [
        first.identity.providerID.rawValue: first.id, second.identity.providerID.rawValue: second.id,
      ]
      expect(OverviewFocus.defaultAccountID(in: status) == second.id,
        "The Overview does not focus the most recently switched default account")
      status.defaultAccountIDs = [:]
      expect(OverviewFocus.defaultAccountID(in: status) == first.id,
        "The Overview does not fall back to the first account")
    } else { failures.append("The Overview fixture lacks two accounts") }
    let reset = Date(timeIntervalSince1970: 0)
    expect(OverviewFormat.compactReset(reset.addingTimeInterval(6 * 86_400 + 8 * 3_600 + 56 * 60),
      now: reset, exact: false) == "in 6d 8h"
      && OverviewFormat.compactReset(reset.addingTimeInterval(6_300), now: reset, exact: false) == "in 1h 45m"
      && OverviewFormat.compactReset(reset.addingTimeInterval(20 * 60), now: reset, exact: false) == "in 20m",
      "Overview reset times do not read in 6d 8h, 1h 45m, or 20m form")
    failures.append(contentsOf: overviewFailures())
    return failures
  }

  /// The five text roles: each renders exactly as its system text style, the sizes step down from
  /// Title to Caption, Section is Body in bold, and only paths and IDs use the monospaced design.
  static func typographyFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }
    func fit(_ view: some View) -> NSSize { NSHostingView(rootView: view).fittingSize }
    let word = "Switch usage"
    expect(AIMTextRole.allCases.count == 5, "The type ramp does not have exactly five roles")
    let title = fit(Text(word).aimText(.title)), section = fit(Text(word).aimText(.section))
    let body = fit(Text(word).aimText(.body)), secondary = fit(Text(word).aimText(.secondary))
    let caption = fit(Text(word).aimText(.caption))
    expect(title == fit(Text(word).font(.title2.weight(.semibold))), "Title is not Title 2 semibold")
    expect(section == fit(Text(word).font(.headline)), "Section is not Headline")
    expect(body == fit(Text(word).font(.body)), "Body is not Body")
    expect(secondary == fit(Text(word).font(.subheadline)), "Secondary is not Subheadline")
    expect(caption == fit(Text(word).font(.caption)), "Caption is not Caption")
    expect(title.height > body.height && body.height > secondary.height && secondary.height > caption.height,
      "The role sizes do not step down from Title to Caption")
    expect(section.width > body.width, "Section is not heavier than Body")
    expect(fit(Text("iiii").aimText(.secondary, monospaced: true)).width
      > fit(Text("iiii").aimText(.secondary)).width,
      "Paths and IDs do not use the monospaced design")
    return failures
  }

  /// The Overview page: its cards, the native Table's columns, and the activity data per provider.
  static func overviewFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }
    let model = AccountViewModel(scenario: .demo)
    guard let codex = model.status?.accounts.first(where: { $0.identity.providerID == .codex }) else {
      return ["The Overview fixture has no Codex account"]
    }
    // The focused card lists one row per window; the demo Codex account has Session and Weekly.
    expect(AccountUsageSummary.windows(for: codex, model: model).count >= 2,
      "The focused account card has no window rows")
    let host = NSHostingView(rootView: OverviewPage(model: model, query: "")
      .frame(width: 900, height: 900))
    host.frame = NSRect(x: 0, y: 0, width: 900, height: 900)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let tables = views(in: host).compactMap { $0 as? NSTableView }
    expect(tables.contains { Array($0.tableColumns.map(\.title).prefix(3)) == ["Account", "Usage", "Resets"]
      && $0.tableColumns.count == 4 },
      "The Overview accounts card is not a native table of Account, Usage, Resets, and Default or Switch")
    expect(host.fittingSize.height > 0, "The Overview collapsed")

    // The longest reset text is not truncated at the default window width: the reset column is
    // at least as wide as the text, and a row laid out in the card's width keeps it.
    let longReset = Text(OverviewWindowRow.longestReset).aimText(.secondary).fixedSize()
    let longWidth = NSHostingView(rootView: longReset).fittingSize.width
    expect(OverviewWindowRow.resetWidth >= longWidth,
      "The reset column (\(OverviewWindowRow.resetWidth)) is narrower than \"\(OverviewWindowRow.longestReset)\" (\(longWidth))")
    let now = Date()
    let longRow = OverviewWindowRow(
      window: UsageWindow(id: "w", title: "Weekly", usedPercent: 40,
        resetsAt: now.addingTimeInterval(6 * 86_400 + 23 * 3_600 + 59 * 60 + 30), windowMinutes: 10_080),
      showsUsed: false, now: now)
    // The default sidebar takes at most 260 points; the page and the row add their own padding.
    let rowWidth = AIManagerWindow.defaultSize.width - 260 - 2 * AIMTheme.pageMargin
      - 2 * AIMTheme.sectionSpacing
    // Ideal width: title + minimum bar + percent + the full reset column must fit the card.
    let idealWidth = NSHostingView(rootView: longRow).fittingSize.width
    expect(idealWidth >= 130 + 40 + 80 + OverviewWindowRow.resetWidth && idealWidth <= rowWidth,
      "A focused-card window row does not keep the full reset text at the default width (\(idealWidth) of \(rowWidth))")

    // An account that needs sign-in gets a Sign in button instead of a disabled Switch.
    if let stale = model.status?.accounts.first(where: { $0.verification.state == .needsSignIn }),
      let good = model.status?.accounts.first(where: { $0.verification.state != .needsSignIn }) {
      expect(model.needsSignIn(stale) && !model.needsSignIn(good),
        "needsSignIn is wrong for the demo accounts")
      expect(model.status?.isDefault(stale) != true
        && OverviewFormat.rowAction(for: stale, model: model) == .signIn
        && OverviewFormat.rowAction(for: good, model: model) != .signIn,
        "The Overview table shows no Sign in action for an account that needs sign-in")
      let signIn = NSHostingView(rootView: SignInButton(account: stale, model: model))
      expect(signIn.fittingSize.width > 0, "The Sign in button collapsed")
    } else { failures.append("The Overview fixture has no account that needs sign-in") }
    return failures
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
    // The resizable window keeps its size; a record saved before resizing still decodes.
    if placement.width != size.width || placement.height != size.height {
      failures.append("Window placement does not keep the window size")
    }
    let oldRecord = Data("""
      {"version":1,"displayIdentifier":"a","displayName":"A","displayFrameX":0,"displayFrameY":0,\
      "displayFrameWidth":100,"displayFrameHeight":100,"leftOffset":1,"topOffset":2}
      """.utf8)
    if let decoded = try? JSONDecoder().decode(AIManagerStoredWindowPlacement.self, from: oldRecord),
      decoded.width == nil, decoded.leftOffset == 1
    {} else {
      failures.append("A window placement saved before resizing no longer decodes")
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

  /// The window is native: the sidebar is a source-list outline (a plain List in a
  /// NavigationSplitView), and the Overview, Accounts, Maintenance, and Settings pages draw a
  /// grouped Form. `pageIndex` is the index into `AIManagerPage.allCases`.
  static func nativeStructureFailures(in root: NSView, pageIndex: Int) -> [String] {
    var failures: [String] = []
    let all = views(in: root)
    if !all.contains(where: { ($0 as? NSOutlineView)?.style == .sourceList }) {
      failures.append("The sidebar is not a native source-list List")
    }
    if [0, 1, 3, 4].contains(pageIndex)
      && !all.contains(where: { NSStringFromClass(type(of: $0)).contains("PlatformGroupContainer") }) {
      failures.append("Page \(pageIndex) is not a grouped Form")
    }
    return failures
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

  /// Native List tables: the sidebar and the Conversations thread list.
  static func listTableCount(in root: NSView) -> Int {
    views(in: root).filter { $0 is NSTableView && !($0 is AIMVirtualTableView) }.count
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

  static func hasVisualEffect(in root: NSView) -> Bool {
    views(in: root).contains { $0 is NSVisualEffectView }
  }

  static func hierarchySnapshot(in root: NSView) -> [AIManagerNativeViewSnapshot] {
    snapshot(view: root, path: "0")
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
}
