import AIManagerCore
import AppKit
import SwiftUI

/// Contract of the menu bar popover: 360 pt native layout, one row per Show in Menubar account,
/// window labels, bar colors, reset text, switching, footer actions, and the status item.
@MainActor
enum AIManagerMenuBarContract {
  private typealias P = MenuBarPresentation

  static func failures() async -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }
    func account(
      _ name: String, usage: MenuBarUsageSnapshot? = nil, verified: Bool = true,
      active: Bool = false, shows: Bool = true, provider: ProviderID = .codex
    ) -> MenuBarAccountSnapshot {
      MenuBarAccountSnapshot(
        id: UUID(), identity: name, detail: "", isVerified: verified, isActive: active,
        usage: usage, showsUsage: shows, providerID: provider)
    }
    let now = Date()
    let twoWindows = MenuBarUsageSnapshot(
      usedPercentage: 24, secondaryUsedPercentage: 59,
      resetsAt: now.addingTimeInterval(3_600), secondaryResetsAt: now.addingTimeInterval(86_400),
      primaryMinutes: 300, secondaryMinutes: 10_080)
    let oneWindow = MenuBarUsageSnapshot(usedPercentage: 88, primaryLabel: "Weekly", primaryMinutes: 10_080)

    // Geometry.
    expect(MenuBarPopover.width == 360, "Menu-bar popover is not 360 points wide")
    expect(MenuBarPopover.footerHeight == 44 && MenuBarPopover.minimumHeight == 94,
      "Menu-bar footer or minimum height changed")
    expect(P.tileSize == 16 && P.groupHeaderHeight == 26, "Service header geometry changed")
    let two = account("a", usage: twoWindows), one = account("b", usage: oneWindow)
    expect(P.rowHeight(two) == 70 && P.rowHeight(one) == 52, "Row heights changed: \(P.rowHeight(two)) \(P.rowHeight(one))")
    expect(P.rowHeight(account("c")) == 30 && P.rowHeight(account("d", verified: false)) == 58,
      "A row with no usage is not the name alone, or a sign-in row is not one line below the name")
    expect(P.rowHeight(account("e", usage: twoWindows, shows: false)) == 0, "A hidden account still takes space")
    let withTokens = MenuBarUsageSnapshot(
      usedPercentage: 10, tokenPeriodLabel: "since reset", tokens: 1_000_000)
    expect(P.rowHeight(account("f", usage: withTokens)) == 52 + 18, "Token summary line has the wrong height")

    func size(_ accounts: [MenuBarAccountSnapshot], _ screen: CGFloat) -> NSSize {
      AIManagerStatusItemController.contentSize(accounts: accounts, visibleScreenHeight: screen)
    }
    let many = Array(repeating: two, count: 20)
    expect(size([], 900).height == 94, "Empty popover does not use its minimum height")
    expect(size([account("g", usage: twoWindows, shows: false)], 900).height == 94,
      "Hidden accounts leave blank space")
    expect(size([two], 900).height == 164 && size([two, one], 900).height == 224,
      "One or two rows do not fit exactly")
    expect(size([two, one], 300).height == 224 && size([one], 100).height == 94,
      "Small screens clip one or two rows below the minimum")
    expect(size(many, 900).height == 720, "Rows do not scroll at 80% of the screen height")
    expect(size(many, 2_000).height == 1_600, "A tall screen clips rows below its cap")
    expect(size(many, 601).height == 480, "The screen cap rounds beyond 80%")
    expect(size(many, 900).width == 360, "Popover width changes with its contents")
    for (count, height) in [(4, CGFloat(410)), (6, 626), (8, 782)] {
      let preview = MenuBarPopoverPreviewData.snapshot(accountCount: count)
      expect(preview.accounts.count == count && Set(preview.accounts.map(\.id)).count == count,
        "Popover preview lost accounts or repeats row IDs")
      expect(size(preview.accounts, 2_000).height == height, "Compact \(count)-account height is wrong")
    }
    let grouped = P.groups(MenuBarPopoverPreviewData.sixAccountSnapshot.accounts)
    expect(grouped.map { $0[0].providerID } == [.claudeCode, .codex, .grokBuild, .geminiCLI]
      && grouped.map(\.count) == [2, 2, 1, 1], "Service groups lost saved order")
    expect(grouped[0].map(\.identity) == MenuBarPopoverPreviewData.sixAccountSnapshot.accounts
      .filter { $0.providerID == .claudeCode }.map(\.identity), "Account order changed inside a service")

    // Window labels, content, and the header reset.
    func name(_ title: String, _ minutes: Int? = nil) -> P.WindowName { P.windowName(minutes: minutes, title: title) }
    expect(name("Session", 300) == .init(pool: nil, label: "Session")
      && name("5-hour", 300) == .init(pool: nil, label: "Session")
      && name("5 hours", 300) == .init(pool: nil, label: "Session")
      && name("Daily", 1_440) == .init(pool: nil, label: "Daily")
      && name("Monthly credits") == .init(pool: nil, label: "Monthly")
      && name("Credits") == .init(pool: nil, label: "Credits")
      && name("Pro", 1_440) == .init(pool: nil, label: "Pro")
      && name("30-day window") == .init(pool: nil, label: "30-day window"),
      "Window names are wrong")
    // The pool comes from the title for every provider: Droid Core, Claude and Codex models,
    // other services' "<pool> <period>" titles, and a pool's credits.
    expect(name("Core 5-hour", 300) == .init(pool: "Core", label: "Session")
      && name("Core weekly", 10_080) == .init(pool: "Core", label: "Weekly")
      && name("Core monthly") == .init(pool: "Core", label: "Monthly")
      && name("Weekly Opus", 10_080) == .init(pool: "Opus", label: "Weekly")
      && name("Spark Session", 300) == .init(pool: "Spark", label: "Session")
      && name("Spark 30-day window") == .init(pool: "Spark", label: "30-day window")
      && name("Premium weekly") == .init(pool: "Premium", label: "Weekly")
      && name("Spark credits") == .init(pool: "Spark", label: "Credits"),
      "Window pools are wrong")
    // Droid's six windows: the main pool, then Core under its own heading; no repeated name in a pool.
    let droidSix = MenuBarUsageSnapshot(providerUsage: ProviderUsage(windows: [
      .init(id: "session", title: "5-hour", usedPercent: 10, windowMinutes: 300),
      .init(id: "weekly", title: "Weekly", usedPercent: 20, windowMinutes: 10_080),
      .init(id: "monthly", title: "Monthly", usedPercent: 30),
      .init(id: "factory-core-5h", title: "Core 5-hour", usedPercent: 40, windowMinutes: 300),
      .init(id: "factory-core-7d", title: "Core weekly", usedPercent: 50, windowMinutes: 10_080),
      .init(id: "factory-core-monthly", title: "Core monthly", usedPercent: 60)]))
    let droidRows = P.lines(for: account("droid", usage: droidSix), expanded: true)
    expect(droidRows.map(\.label) == ["Session", "Weekly", "Monthly", "Core", "Session", "Weekly", "Monthly"]
      && droidRows.map(\.isHeading) == [false, false, false, true, false, false, false],
      "Droid windows are not Session, Weekly, Monthly, then a Core heading over its own rows: \(droidRows.map(\.label))")
    for pool in [nil, "Core"] as [String?] {
      let labels = droidRows.filter { !$0.isHeading && $0.pool == pool }.map(\.label)
      expect(Set(labels).count == labels.count, "A pool repeats a row name: \(labels)")
    }
    expect(P.lines(for: account("droid", usage: droidSix)).map(\.label) == ["Session", "Weekly"],
      "A collapsed row keeps more than two usage rows or a heading without rows")
    if case .lines(let lines) = P.content(for: two) {
      expect(lines.map(\.label) == ["Session", "Weekly"] && lines.map(\.used) == [24, 59],
        "Two-window row lines are wrong")
    } else { failures.append("Two-window row has no lines") }
    if case .lines(let lines) = P.content(for: one) {
      expect(lines.count == 1 && lines[0].label == "Weekly", "A single window lost its label")
    } else { failures.append("Single-window row has no lines") }
    let providerWindows = account("provider", usage: MenuBarUsageSnapshot(
      usedPercentage: nil, providerWindows: [
        .init(title: "Session", used: 20, resetsAt: nil, minutes: 300),
        .init(title: "Weekly", used: nil, resetsAt: nil, minutes: 10_080),
        .init(title: "Monthly", used: 65, resetsAt: nil, minutes: 43_200)]),
      provider: .claudeCode)
    if case .lines(let lines) = P.content(for: providerWindows) {
      expect(lines.map(\.label) == ["Session", "Monthly"]
        && lines.map(\.used) == [20, 65], "An empty usage window still draws a bar")
    } else { failures.append("Provider windows have no lines") }
    let weeklyOnly = account("h", usage: MenuBarUsageSnapshot(usedPercentage: nil, secondaryUsedPercentage: 96))
    if case .lines(let lines) = P.content(for: weeklyOnly) {
      expect(lines.count == 1 && lines[0].label == "Weekly" && lines[0].used == 96, "Weekly-only row is wrong")
    } else { failures.append("Weekly-only row has no lines") }
    if case .lines(let lines) = P.content(for: account("i")) {
      expect(lines.isEmpty, "Unknown row invents a usage line")
    } else { failures.append("Unknown row has no line") }
    expect(P.content(for: account("j", verified: false)) == .signIn, "A sign-in row shows bars")
    let balance = account("k", usage: MenuBarUsageSnapshot(usedPercentage: nil, balanceText: "$12.40"))
    if case .lines(let lines) = P.content(for: balance) {
      expect(lines.first?.balance == "$12.40", "Balance-only row lost its balance")
    } else { failures.append("Balance-only row has no line") }
    expect(UsageBar.height == 4 && UsageBarColor.color(usedPercent: 90, providerID: .codex) == AIMTheme.red
      && UsageBarColor.color(usedPercent: 89, providerID: .codex) != AIMTheme.red,
      "Shared bar height or 90-percent threshold changed")

    // Reset text follows the Countdown or Exact-time setting.
    func countdown(_ interval: TimeInterval) -> String {
      P.resetText(now.addingTimeInterval(interval), now: now, exact: false)
    }
    expect(countdown(6 * 86_400 + 8 * 3_600 + 30) == "6d 8h" && countdown(3_600 + 45 * 60 + 30) == "1h 45m"
      && countdown(12 * 60 + 30) == "12m" && countdown(20) == "<1m" && countdown(-5) == "Not started"
      && P.resetText(now.addingTimeInterval(-5), now: now, exact: false, used: 40) == "Resetting…"
      && P.resetText(now.addingTimeInterval(-5), now: now, exact: true, used: 0) == "Not started",
      "Reset countdown text is wrong")
    let exactText = P.resetText(now.addingTimeInterval(2 * 3_600), now: now, exact: true, hourFormat: .twentyFour)
    expect(!exactText.isEmpty && !exactText.contains("Resets") && exactText.contains(":"),
      "Exact reset text is wrong: \(exactText)")

    // Arrow-key order.
    let ids = (0..<3).map { _ in UUID() }
    expect(P.neighbor(of: nil, in: ids, step: 1) == ids[0] && P.neighbor(of: nil, in: ids, step: -1) == ids[2]
      && P.neighbor(of: ids[0], in: ids, step: 1) == ids[1] && P.neighbor(of: ids[2], in: ids, step: 1) == ids[2]
      && P.neighbor(of: ids[0], in: ids, step: -1) == ids[0] && P.neighbor(of: nil, in: [], step: 1) == nil,
      "Arrow-key order is wrong")
    expect(P.openToolTitle(account("l")) == "Open Codex"
      && P.openToolTitle(account("m", provider: .claudeCode)) == "Open \(ProviderID.claudeCode.displayName)",
      "Open-tool titles are wrong")

    failures.append(contentsOf: await storeFailures())
    // First among the hosted checks: it records frames, so it runs before other popover hosts exist.
    failures.append(contentsOf: layoutAgreementFailures())
    failures.append(contentsOf: hostedLayoutFailures())
    failures.append(contentsOf: valueAlignmentFailures())
    failures.append(contentsOf: polishFailures())
    failures.append(contentsOf: statusItemFailures())
    failures.append(contentsOf: await PopoverMotionCheck.failures())
    if let path = ProcessInfo.processInfo.environment["AI_MANAGER_POPOVER_SHOTS"] {
      failures.append(contentsOf: renderSnapshots(to: URL(fileURLWithPath: path)))
    }
    return failures
  }

  private static func renderSnapshots(to directory: URL) -> [String] {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (appearance, label, expanded) in [(NSAppearance.Name.aqua, "light", false),
          (.darkAqua, "dark", false), (.aqua, "expanded-light", true)] {
          UILintStore.shared.items.removeAll()
          UILintStore.shared.colors.removeAll()
          UILintStore.shared.appearance = NSAppearance(named: appearance)!
          let snapshot = MenuBarPopoverPreviewData.sixAccountSnapshot
          let store = MenuBarPopoverStore(snapshot: snapshot,
            actions: MenuBarPopoverActions(openMainWindow: {}, switchAccount: { _ in }, openTool: { _ in }), visibleScreenHeight: 2_000)
          if expanded { store.toggleExpanded(snapshot.accounts[3]) }
          let size = AIManagerStatusItemController.contentSize(accounts: snapshot.accounts,
            visibleScreenHeight: 2_000, expandedID: store.expandedAccountID)
          let host = NSHostingView(rootView: MenuBarPopover(store: store)
            .background(Color(nsColor: .windowBackgroundColor)).renderScaled())
          let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless, backing: .buffered, defer: false)
          window.appearance = NSAppearance(named: appearance)
          window.contentView = host
          host.frame = NSRect(origin: .zero, size: size)
          host.layoutSubtreeIfNeeded()
          guard let png = RenderScale.png(of: host) else {
            return ["Popover snapshot PNG is unavailable"]
          }
          let filename = "popover-\(label).png"
          try png.write(to: directory.appendingPathComponent(filename))
          if CommandLine.arguments.contains("--ui-lint") {
            try UILintStore.shared.write(to: directory.appendingPathComponent("popover-\(label).json"),
              size: size, page: "menu-bar", appearance: label)
          }
          print("POPOVER_SHOT \(filename) \(Int(size.width))x\(Int(size.height)) pt")
        }
      return []
    } catch { return ["Popover snapshots failed: \(error)"] }
  }

  /// Let the store's switch and refresh tasks run.
  private static func settle() async {
    try? await Task.sleep(for: .milliseconds(100))
  }

  private static func storeFailures() async -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }
    let active = MenuBarAccountSnapshot(
      id: UUID(), identity: "active@example.test", detail: "", isVerified: true, isActive: true,
      usage: MenuBarUsageSnapshot(usedPercentage: 10), providerID: .codex)
    let other = MenuBarAccountSnapshot(
      id: UUID(), identity: "other@example.test", detail: "", isVerified: true, isActive: false,
      usage: MenuBarUsageSnapshot(usedPercentage: 20), providerID: .codex)
    let signIn = MenuBarAccountSnapshot(
      id: UUID(), identity: "signin@example.test", detail: "", isVerified: false, isActive: false,
      providerID: .claudeCode)
    let hidden = MenuBarAccountSnapshot(
      id: UUID(), identity: "hidden@example.test", detail: "", isVerified: true, isActive: false,
      usage: MenuBarUsageSnapshot(usedPercentage: 30), showsUsage: false)
    let generic = MenuBarAccountSnapshot(
      id: UUID(), identity: "generic@example.test", detail: "", isVerified: true, isActive: true,
      providerID: ProviderID(rawValue: "openrouter"))

    var switched: [UUID] = [], refreshed: [UUID] = [], opened: [UUID] = [], copied: [String] = []
    var mainOpened = 0, settingsOpened = 0, allRefreshes = 0, dismissals = 0, didSwitch = 0
    var shouldFail = false
    let store = MenuBarPopoverStore(
      snapshot: MenuBarSnapshot(accounts: [active, other, signIn, hidden, generic]),
      actions: MenuBarPopoverActions(
        openMainWindow: { mainOpened += 1 },
        switchAccount: { id in
          if shouldFail { throw NSError(domain: "synthetic", code: 1) }
          switched.append(id)
        },
        refreshUsage: { allRefreshes += 1 },
        copyText: { copied.append($0) },
        openSettings: { settingsOpened += 1 },
        openTool: { opened.append($0) },
        refreshAccount: { refreshed.append($0) }))
    store.didRequestDismissal = { dismissals += 1 }
    store.didSwitch = { didSwitch += 1 }

    expect(store.rows.map(\.id) == [active.id, other.id, signIn.id, generic.id],
      "Rows are not the Show in Menubar accounts in saved order")
    expect(!P.canExpand(generic) && P.expansionHeight(generic) == 0
      && P.listHeight(store.rows, expandedID: generic.id) == P.listHeight(store.rows),
      "A signed-in default account without actions adds an empty expansion")
    let heightBeforeClick = store.contentHeight
    let expansionBeforeClick = store.expandedAccountID
    store.toggleExpanded(generic)
    expect(store.expandedAccountID == expansionBeforeClick && store.contentHeight == heightBeforeClick,
      "Clicking a row without anything to reveal changes expansion or height")
    var layoutChanges = 0
    store.didChangeLayout = { layoutChanges += 1 }
    store.toggleExpanded(other)
    expect(store.expandedAccountID == other.id && switched.isEmpty && layoutChanges == 1,
      "Expanding an account switches it or fails to resize")
    let expandedSize = AIManagerStatusItemController.contentSize(accounts: store.snapshot.accounts,
      visibleScreenHeight: 2_000, expandedID: other.id)
    let collapsedSize = AIManagerStatusItemController.contentSize(accounts: store.snapshot.accounts,
      visibleScreenHeight: 2_000)
    expect(expandedSize.height == collapsedSize.height + 40, "Expanded actions have the wrong height")
    store.toggleExpanded(other)
    expect(store.expandedAccountID == nil && layoutChanges == 2, "Account actions do not collapse")
    store.select(active)
    store.select(signIn)
    await settle()
    expect(switched.isEmpty && store.switchingAccountID == nil, "Selecting the default or a sign-in row switched it")
    store.select(other)
    expect(store.switchingAccountID == other.id, "A switch shows no progress state")
    await settle()
    expect(switched == [other.id] && didSwitch == 1 && store.switchingAccountID == nil,
      "Selecting another account did not switch and finish")
    shouldFail = true
    store.select(other)
    await settle()
    expect(store.rowErrors[other.id] != nil && didSwitch == 1, "A failed switch shows no row error")

    store.openMainWindow()
    store.openSettings()
    expect(mainOpened == 1 && settingsOpened == 1 && dismissals == 2, "Footer actions do not open and dismiss")
    store.openTool(other)
    store.openTool(generic)
    store.openTool(signIn)
    await settle()
    expect(opened == [other.id, signIn.id], "Open <tool> runs for the wrong providers: \(opened)")
    store.copy("Copied name")
    expect(copied == ["Copied name"], "Copy name does not copy")
    await store.refresh(other)
    expect(refreshed == [other.id] && allRefreshes == 0, "Row refresh does not refresh one account")
    return failures
  }

  /// The signed-out card, a row with no usage lines, and usage rows with credits and tokens: the
  /// computed popover height must equal the laid-out content height (no empty band above the
  /// footer), each row must be as tall as the estimate, and the expanded signed-out card keeps
  /// Switch, Open Codex, and Sign in on one row. Writes light and dark PNGs when
  /// AI_MANAGER_POPOVER_SHOTS is set.
  private static func layoutAgreementFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }
    let now = Date()
    let windows = MenuBarUsageSnapshot(
      usedPercentage: 24, secondaryUsedPercentage: 59, resetsAt: now.addingTimeInterval(3_600),
      secondaryResetsAt: now.addingTimeInterval(86_400), tokenPeriodLabel: "since reset", tokens: 1_000_000,
      primaryMinutes: 300, secondaryMinutes: 10_080)
    let credits = MenuBarUsageSnapshot(usedPercentage: nil, providerWindows: [
      .init(title: "Session", used: 20, resetsAt: now.addingTimeInterval(3_600), minutes: 300),
      .init(title: "Weekly", used: 40, resetsAt: now.addingTimeInterval(86_400), minutes: 10_080),
      .init(title: "Monthly credits", used: 12, resetsAt: nil, minutes: nil)])
    func account(_ name: String, verified: Bool = true, usage: MenuBarUsageSnapshot?, provider: ProviderID,
                 id: UUID = UUID()) -> MenuBarAccountSnapshot {
      MenuBarAccountSnapshot(id: id, identity: name, detail: "", isVerified: verified, isActive: false,
        usage: usage, providerID: provider, identityIsFormatted: true)
    }
    let outID = UUID()
    let signedIn = [
      account("me@mandalsuraj", usage: windows, provider: .codex, id: outID),
      account("grace@example.test", usage: windows, provider: .codex),
      account("ada@example.test", usage: credits, provider: .claudeCode),
      account("go@example.test", usage: nil, provider: ProviderID(rawValue: "opencodego")),
    ]
    // The real path: the card was signed in with usage, then the next refresh signs it out.
    let suite = "switch-popover-agreement-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = MenuBarPopoverStore(snapshot: MenuBarSnapshot(accounts: signedIn),
      actions: MenuBarPopoverActions(openMainWindow: {}, switchAccount: { _ in }, openTool: { _ in }),
      visibleScreenHeight: 2_000, defaults: defaults)
    store.reduceMotion = true
    var next = signedIn
    next[0] = account("me@mandalsuraj", verified: false, usage: nil, provider: .codex, id: outID)
    store.update(snapshot: MenuBarSnapshot(accounts: next))
    store.toggleExpanded(store.rows[0])
    expect(store.rows[0].id == outID && !store.rows[0].isVerified, "Layout fixture lost the signed-out card")

    var directory: URL?
    if let path = ProcessInfo.processInfo.environment["AI_MANAGER_POPOVER_SHOTS"] {
      directory = URL(fileURLWithPath: path)
      try? FileManager.default.createDirectory(at: directory!, withIntermediateDirectories: true)
    }
    for (appearance, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      let size = NSSize(width: MenuBarPopover.width, height: store.contentHeight)
      let wasRecording = uiLintRecording(true)
      defer { uiLintRecording(wasRecording) }
      UILintStore.shared.items.removeAll()
      let host = NSHostingView(rootView: MenuBarPopover(store: store)
        .background(Color(nsColor: .windowBackgroundColor)).renderScaled())
      let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
        backing: .buffered, defer: false)
      window.appearance = NSAppearance(named: appearance)
      window.contentView = host
      host.frame = NSRect(origin: .zero, size: size)
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.4))
      host.layoutSubtreeIfNeeded()
      if let directory, let png = RenderScale.png(of: host) {
        try? png.write(to: directory.appendingPathComponent("popover-fixture-\(label).png"))
      }
      guard label == "light" else { continue }

      // (a) Switch, Open Codex, and Sign in share one row.
      let items = Array(UILintStore.shared.items.values)
      UILintStore.shared.items.removeAll()
      func frame(_ item: [String: Any]) -> CGRect {
        let f = item["frame"] as? [String: Any] ?? [:]
        func number(_ key: String) -> CGFloat { (f[key] as? NSNumber).map { CGFloat(truncating: $0) } ?? .nan }
        return CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
      }
      func inGroup(_ item: [String: Any], _ group: String) -> Bool {
        (item["tags"] as? [[String: Any]] ?? []).contains { $0["group"] as? String == group }
      }
      let rows = items.filter { inGroup($0, "menuBarRows") }.map(frame).sorted { $0.minY < $1.minY }
      expect(rows.count == store.rows.count, "Layout fixture drew \(rows.count) rows, expected \(store.rows.count)")

      // (a) Switch, Open Codex, and Sign in share one row: the same midY and height, left to right.
      let buttons = items.filter { $0["kind"] as? String == "control" }.map(frame)
        .filter { rows.first.map($0.intersects) ?? false }.sorted { $0.minX < $1.minX }
      if buttons.count == 3 {
        expect(buttons.allSatisfy { abs($0.midY - buttons[0].midY) < 0.5 && abs($0.height - buttons[0].height) < 0.5 }
          && buttons[0].maxX <= buttons[1].minX && buttons[1].maxX <= buttons[2].minX,
          "Switch, Open Codex, and Sign in are not one row: \(buttons)")
      } else { failures.append("The signed-out card has \(buttons.count) buttons, expected 3: \(buttons)") }

      // (b) Each row is as tall as its estimate, so the computed popover height equals the
      // laid-out content (the list's padding, the rows, and the footer): no empty band.
      let estimates = store.rows.map { P.rowHeight($0) + ($0.id == outID ? P.expansionHeight($0) : 0) }
      for (row, (laidOut, estimate)) in zip(store.rows, zip(rows, estimates)) {
        expect(abs(laidOut.height - estimate) <= 1,
          "Row \(row.identity) is laid out \(laidOut.height) pt tall, estimated \(estimate)")
      }
      if let last = rows.last {
        let laidOutHeight = last.maxY + 12 + MenuBarPopover.footerHeight
        expect(abs(laidOutHeight - store.contentHeight) <= 1,
          "Popover height \(store.contentHeight) differs from the laid-out content \(laidOutHeight): empty band above the footer")
      }
    }
    return failures
  }

  private static func views(in root: NSView) -> [NSView] { [root] + root.subviews.flatMap { views(in: $0) } }

  private static func hostedLayoutFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }
    func views(in root: NSView) -> [NSView] { [root] + root.subviews.flatMap { views(in: $0) } }
    let full = MenuBarPopoverPreviewData.sixAccountSnapshot
    expect(full.accounts.map(P.lineCount) == [2, 2, 1, 2, 2, 2],
      "Preview rows do not cover consistent service windows and the Weekly-only plan")

    for (accounts, screen) in [
      (Array(full.accounts.prefix(1)), CGFloat(900)), (Array(full.accounts.prefix(2)), 900),
      (full.accounts, 900), (Array(repeating: full.accounts[0], count: 20), 900),
      (Array(full.accounts.prefix(1)), 251.25), (full.accounts, 250),
    ] {
      let store = MenuBarPopoverStore(
        snapshot: MenuBarSnapshot(accounts: accounts),
        actions: MenuBarPopoverActions(openMainWindow: {}, switchAccount: { _ in }),
        visibleScreenHeight: screen)
      let expected = AIManagerStatusItemController.contentSize(accounts: accounts, visibleScreenHeight: screen)
      let host = NSHostingView(rootView: MenuBarPopover(store: store))
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: expected), styleMask: .borderless, backing: .buffered,
        defer: false)
      window.contentView = host
      host.frame = NSRect(origin: .zero, size: expected)
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      expect(abs(host.fittingSize.height - expected.height) < 1 && host.fittingSize.width == 360,
        "Hosted popover does not fit its rows: \(host.fittingSize) vs \(expected)")
      expect(!views(in: host).contains { $0 is NSVisualEffectView },
        "The popover draws its own backdrop instead of the native popover material")
      let rowsHeight = P.listHeight(accounts)
      let cap = floor(screen * 0.8)
      for scroll in views(in: host).compactMap({ $0 as? NSScrollView }) {
        let document = scroll.documentView?.frame.height ?? 0
        let viewport = scroll.contentView.bounds.height
        if rowsHeight + MenuBarPopover.footerHeight <= cap {
          expect(viewport > 0 && document <= viewport + 0.5,
            "Popover scrolls before its rows reach the screen cap: \(document) > \(viewport)")
        } else {
          expect(expected.height == max(cap, MenuBarPopover.minimumHeight) && document > viewport,
            "Popover does not scroll at the 80% cap")
        }
      }
    }

    // Command-O inside the hosted popover opens the main window.
    var opens = 0
    let keyStore = MenuBarPopoverStore(
      snapshot: full, actions: MenuBarPopoverActions(openMainWindow: { opens += 1 }, switchAccount: { _ in }))
    let keyHost = NSHostingView(rootView: MenuBarPopover(store: keyStore))
    let keyWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 400), styleMask: .borderless, backing: .buffered,
      defer: false)
    keyWindow.contentView = keyHost
    keyHost.layoutSubtreeIfNeeded()
    if let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: keyWindow.windowNumber, context: nil, characters: "o",
      charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31) {
      _ = keyHost.performKeyEquivalent(with: event)
    }
    expect(opens == 1, "Command-O does not open the main window from the popover")

    return failures
  }

  /// Rows with a value and no bar (Credits, Balance, Tokens) start their value at the left edge
  /// of the bar column of the same account, not at the right edge. Also renders the dark shot.
  private static func valueAlignmentFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }
    let now = Date()
    let price = CodexAPIPrice(model: "gpt-5.6-sol", inputPerMillion: 4, cachedInputPerMillion: 0.4, outputPerMillion: 20)
    let codex = MenuBarUsageSnapshot(usedPercentage: 79, secondaryUsedPercentage: 12,
      resetsAt: now.addingTimeInterval(3_600), secondaryResetsAt: now.addingTimeInterval(530_000),
      tokenPeriodLabel: "since reset", tokens: 34_000_000, apiPrice: price,
      primaryMinutes: 300, secondaryMinutes: 10_080, providerWindows: [
        .init(title: "Session", used: 12, resetsAt: now.addingTimeInterval(3_600), minutes: 300),
        .init(title: "Weekly", used: 79, resetsAt: now.addingTimeInterval(530_000), minutes: 10_080),
        .init(title: "Credits", used: nil, resetsAt: nil, minutes: nil, balance: "$2,494.68 · 62,367 credits")])
    let droid = MenuBarUsageSnapshot(providerUsage: ProviderUsage(windows: [
      .init(id: "session", title: "5-hour", usedPercent: 10, resetsAt: now.addingTimeInterval(14_000), windowMinutes: 300),
      .init(id: "weekly", title: "Weekly", usedPercent: 20, resetsAt: now.addingTimeInterval(500_000), windowMinutes: 10_080),
      .init(id: "monthly", title: "Monthly", usedPercent: 30, resetsAt: now.addingTimeInterval(1_800_000)),
      .init(id: "factory-core-5h", title: "Core 5-hour", usedPercent: 40, resetsAt: now.addingTimeInterval(9_000), windowMinutes: 300),
      .init(id: "factory-core-7d", title: "Core weekly", usedPercent: 50, resetsAt: now.addingTimeInterval(400_000), windowMinutes: 10_080),
      .init(id: "factory-core-monthly", title: "Core monthly", usedPercent: 60, resetsAt: now.addingTimeInterval(1_700_000))],
      cost: UsageCost(balance: 0, period: "Extra usage balance")))!
    let balanceOnly = MenuBarUsageSnapshot(usedPercentage: nil, balanceText: "$12.40")
    func account(_ name: String, _ usage: MenuBarUsageSnapshot, _ provider: ProviderID) -> MenuBarAccountSnapshot {
      MenuBarAccountSnapshot(id: UUID(), identity: name, detail: "", isVerified: true, isActive: false,
        usage: usage, providerID: provider, identityIsFormatted: true)
    }
    let accounts = [account("grace@example.test", codex, .codex), account("ada@example.test", droid, .droid),
      account("go@example.test", balanceOnly, ProviderID(rawValue: "opencodego"))]
    let wasRecording = uiLintRecording(true)
    defer { uiLintRecording(wasRecording) }
    // Codex expanded (Credits, Tokens), then Droid expanded (Balance, Core heading); a fresh store
    // for each, so an earlier host never records again.
    for (index, file) in [(0, "popover-values-dark.png"), (1, "popover-droid-dark.png")] {
    let store = MenuBarPopoverStore(snapshot: MenuBarSnapshot(accounts: accounts),
      actions: MenuBarPopoverActions(openMainWindow: {}, switchAccount: { _ in }, openTool: { _ in }),
      visibleScreenHeight: 2_000)
    store.reduceMotion = true
    store.toggleExpanded(store.rows[index])
    let size = NSSize(width: MenuBarPopover.width, height: store.contentHeight)
    UILintStore.shared.items.removeAll()
    UILintStore.shared.appearance = NSAppearance(named: .darkAqua)!
    let host = NSHostingView(rootView: MenuBarPopover(store: store)
      .background(Color(nsColor: .windowBackgroundColor)).renderScaled())
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    host.layoutSubtreeIfNeeded()
    if let path = ProcessInfo.processInfo.environment["AI_MANAGER_POPOVER_SHOTS"], let png = RenderScale.png(of: host) {
      let directory = URL(fileURLWithPath: path)
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try? png.write(to: directory.appendingPathComponent(file))
    }
    let items = Array(UILintStore.shared.items.values)
    UILintStore.shared.items.removeAll()
    func minXs(_ group: String) -> [CGFloat] {
      items.filter { ($0["tags"] as? [[String: Any]] ?? []).contains { $0["group"] as? String == group } }
        .compactMap { ($0["frame"] as? [String: Any])?["x"] as? NSNumber }.map { CGFloat(truncating: $0) }
    }
    let account = accounts[index]
    let bars = minXs(P.barGroup(account)), values = minXs(P.valueGroup(account))
    // Codex: Credits and Tokens values; Droid: Balance. Both have bar rows in the same block.
    expect(values.count == (account.providerID == .codex ? 2 : 1) && !bars.isEmpty,
      "\(account.identity) drew \(values.count) value rows and \(bars.count) bars")
    expect(values.allSatisfy { abs($0 - bars[0]) < 0.5 } && bars.allSatisfy { abs($0 - bars[0]) < 0.5 },
      "\(account.identity) values start at \(values) but its bars start at \(bars)")
    }
    return failures
  }

  /// Shared inset, footer order, check column, Sign in alignment, hover reach, and the token line.
  private static func polishFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }
    // One inset from the popover edge for the group headers, rows, separators, and footer; the
    // right side gives up the scroll bar gutter that already lies inside it.
    expect(P.inset == 12 && P.rowPaddingH == P.inset && P.trailingInset == P.inset - AIMScroller.gutter,
      "Group headers, rows, and footer do not share the footer's 12 pt inset")
    // The check column is a tile wide; every name starts after it, check or not.
    expect(P.textIndent == P.tileSize + P.tileSpacing && P.textIndent == 24, "The check column indent changed")
    // Sign in is bottom-aligned: on the subtitle line collapsed, level with the 24 pt action
    // buttons (centered in their 40 pt band) expanded.
    expect(P.signInBottomInset(expansion: 0) == P.rowPaddingV
      && P.signInBottomInset(expansion: 1) == (P.expandedHeight - P.signInHeight) / 2
      && P.signInHeight == 24, "Sign in is not bottom-aligned with the row content and action buttons")
    // The hover reaches midway between the earlier 10 pt and 2 pt above the first line, which
    // is the row's own top edge: never into the group header.
    expect(P.hoverReach == (10 + 2) / 2 && P.rowPaddingV - P.hoverReach == 0, "Hover fill top reach changed")

    // Token row: compact numbers, label "Tokens", one value line "34M since reset · ≈$68 API".
    expect(P.compactTokens(24_100_000) == "24.1M" && P.compactTokens(24_000_000) == "24M"
      && P.compactTokens(950) == "950" && P.compactTokens(3_200) == "3.2K"
      && P.compactTokens(999_950) == "1M" && P.compactTokens(1_250_000_000) == "1.3B",
      "Token counts are not compact")
    let price = CodexAPIPrice(model: "gpt-5.6-sol", inputPerMillion: 4, cachedInputPerMillion: 0.4, outputPerMillion: 20)
    let long = MenuBarUsageSnapshot(usedPercentage: 10, tokenPeriodLabel: "since reset", tokens: 24_100_000, apiPrice: price)
    let short = MenuBarUsageSnapshot(usedPercentage: 10, tokenPeriodLabel: "since reset", tokens: 24_100_000)
    expect(P.tokenCaption(short) == "24.1M since reset" && P.tokenLabel == "Tokens",
      "A token line without an API price is not one plain value: \(P.tokenCaption(short) ?? "nil")")
    expect(P.tokenCaption(long)?.hasPrefix("24.1M since reset · ≈") == true
      && P.tokenCaption(long)?.hasSuffix(" API") == true && P.tokenCaption(long)?.contains("\n") == false,
      "A token line with a price is not one value: \(P.tokenCaption(long) ?? "nil")")

    // Footer order, left to right: Open Switch, Refresh, Quit, Settings (also the keyboard
    // and accessibility order, which follow the view order).
    // The footer view builds its buttons from P.footerOrder, so the data is the order.
    expect(P.footerOrder == [.openSwitch, .refresh, .quit, .settings],
      "Footer order is not Open Switch, Refresh, Quit, Settings: \(P.footerOrder)")
    return failures
  }

  private static func statusItemFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }
    let domain = "Switch.MenuBarPercentage.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: domain) else { return ["Menu-bar test store is unavailable"] }
    defer { defaults.removePersistentDomain(forName: domain) }
    defaults.removePersistentDomain(forName: domain)

    let snapshot = MenuBarPopoverPreviewData.snapshot
    let controller = AIManagerStatusItemController(
      snapshot: snapshot, defaults: defaults,
      actions: MenuBarPopoverActions(openMainWindow: {}, switchAccount: { _ in }))
    expect(controller.isPresent && controller.usesPopover, "Status item is missing or uses a static menu")
    expect(controller.popoverContentSize.width == 360, "Hosted popover changed its fixed width")
    expect(controller.statusTitle == "58% 82%", "Status item includes an account without a limit")
    expect(controller.statusAccessibilityLabel.contains("needs sign-in"), "Tray does not name the signed-out account")

    let hiddenAccount = MenuBarAccountSnapshot(
      id: UUID(), identity: "hidden@example.test", detail: "", isVerified: true, isActive: false,
      usage: MenuBarUsageSnapshot(usedPercentage: 42), showsUsage: false)
    controller.update(snapshot: MenuBarSnapshot(accounts: [hiddenAccount]))
    expect(controller.statusTitle.isEmpty, "A hidden account still appears in the status item")

    let enabled = (0..<6).map { index in
      MenuBarAccountSnapshot(
        id: UUID(), identity: "account-\(index)@example.test", detail: "",
        isVerified: true, isActive: index == 5,
        usage: MenuBarUsageSnapshot(usedPercentage: index * 10),
        showsUsage: index != 1, providerID: index == 2 || index == 5 ? .claudeCode : .codex)
    }
    let capped = MenuBarSnapshot(accounts: enabled)
    expect(capped.statusAccounts.map(\.id) == [enabled[0].id, enabled[3].id, enabled[4].id, enabled[2].id],
      "Tray quotas do not group the first four enabled accounts in saved order")
    controller.update(snapshot: capped)
    expect(controller.statusTitle == "100% 70% 60% 80%", "Tray quota order or meaning changed")
    expect(controller.statusAccessibilityLabel.contains("Claude Code, \(enabled[2].identity), 80% left")
      && !controller.statusAccessibilityLabel.contains(enabled[1].identity),
      "Status button does not describe only the displayed accounts")
    defaults.set(true, forKey: UsagePercentagePreferences.showsUsedKey)
    controller.update(snapshot: capped)
    expect(controller.statusTitle == "0% 30% 40% 20%", "Tray percentages do not switch from left to used")
    defaults.set(false, forKey: UsagePercentagePreferences.showsUsedKey)

    controller.update(snapshot: snapshot)
    let size = controller.popoverContentSize
    controller.updateAppearance(NSAppearance(named: .darkAqua))
    expect(controller.popoverContentSize == size, "Dark appearance changed the popover geometry")
    controller.updateAppearance(NSAppearance(named: .aqua))
    expect(controller.popoverContentSize == size, "Light appearance changed the popover geometry")
    controller.updateAppearance(nil)

    controller.update(snapshot: .empty)
    expect(controller.statusTitle.isEmpty, "Status item is not icon-only without accounts")
    return failures
  }
}

/// Expands and collapses a row in an offscreen window that follows the popover's resize hook, and
/// records one sample per layout step: interval between steps, main-thread time, window resizes.
@MainActor
enum PopoverMotionCheck {
  struct Report {
    var frames = 0, hitches = 0, resizes = 0
    var maxInterval = 0.0, maxWork = 0.0, totalWork = 0.0, refresh = 0.0, duration = 0.0
    var summary: String {
      String(format: "frames=%d expected=%d maxInterval=%.1fms hitches=%d(>1.5x %.1fms) resizes=%d maxWork=%.2fms avgWork=%.2fms lowPower=%@",
        frames, Int((duration * refresh).rounded()), maxInterval * 1000, hitches, 1500 / refresh, resizes,
        maxWork * 1000, totalWork / Double(max(frames, 1)) * 1000, ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off")
    }
  }

  /// One expansion then one collapse of the first row.
  static func measure() async -> [String: Report] {
    let suite = "switch-popover-motion-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let snapshot = MenuBarPopoverPreviewData.sixAccountSnapshot
    let store = MenuBarPopoverStore(snapshot: snapshot,
      actions: MenuBarPopoverActions(openMainWindow: {}, switchAccount: { _ in }), visibleScreenHeight: 2_000, defaults: defaults)
    let size = NSSize(width: MenuBarPopover.width, height: store.contentHeight)
    let host = NSHostingView(rootView: MenuBarPopover(store: store))
    // A clear, click-through window on the main display: a display link only ticks for a window
    // on a screen. It never becomes key, so it takes no focus.
    let window = NSWindow(contentRect: NSRect(origin: NSScreen.main?.frame.origin ?? .zero, size: size),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.contentView = host
    window.orderFrontRegardless()
    store.clockView = host
    store.animatesLayout = true
    let refresh = Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
    var report = Report(refresh: refresh, duration: 0.25)
    var last: CFTimeInterval?
    store.didChangeLayout = {
      let start = CACurrentMediaTime()
      let height = store.contentHeight
      if window.contentLayoutRect.height != height { report.resizes += 1; window.setContentSize(NSSize(width: size.width, height: height)) }
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()
      let end = CACurrentMediaTime()
      if let last { report.maxInterval = max(report.maxInterval, start - last); if start - last > 1.5 / refresh { report.hitches += 1 } }
      last = start
      report.frames += 1
      report.maxWork = max(report.maxWork, end - start)
      report.totalWork += end - start
    }
    func run() async -> Report {
      report = Report(refresh: refresh, duration: 0.25)
      last = nil
      store.toggleExpanded(snapshot.accounts[0])
      try? await Task.sleep(for: .milliseconds(600))
      return report
    }
    try? await Task.sleep(for: .milliseconds(300))
    let expand = await run()
    let collapse = await run()
    window.close()
    return ["expand": expand, "collapse": collapse]
  }

  /// Regression check: the 250 ms motion follows the display (at least 80% of its frames, which a
  /// 16 ms timer fails with about 45%), and no more than a third of the gaps pass 1.5 refresh
  /// intervals. The window never resizes more than once per frame.
  static func failures() async -> [String] {
    guard NSScreen.main != nil else { return [] }
    var failures: [String] = []
    for (name, report) in await measure() {
      let expected = Int((report.duration * report.refresh).rounded())
      if report.frames * 5 < expected * 4 || report.hitches * 3 > report.frames || report.resizes > report.frames {
        failures.append("Popover \(name) drops frames: \(report.summary)")
      }
    }
    return failures
  }
}

#if MENU_BAR_CONTRACT
@main
private enum MenuBarContractRunner {
  @MainActor static func main() async {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let failures = await AIManagerMenuBarContract.failures()
    for failure in failures { print("MENU_BAR_CONTRACT_FAIL: \(failure)") }
    if failures.isEmpty { print("MENU_BAR_CONTRACT_PASS") }
    exit(failures.isEmpty ? 0 : 1)
  }
}
#endif
