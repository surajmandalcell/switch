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
    expect(MenuBarPopover.footerHeight == 36 && MenuBarPopover.minimumHeight == 94,
      "Menu-bar footer or minimum height changed")
    expect(P.tileSize == 28, "Provider icon tile is not 28 points")
    let two = account("a", usage: twoWindows), one = account("b", usage: oneWindow)
    expect(P.rowHeight(two) == 74 && P.rowHeight(one) == 58, "Row heights changed: \(P.rowHeight(two)) \(P.rowHeight(one))")
    expect(P.rowHeight(account("c")) == 58 && P.rowHeight(account("d", verified: false)) == 66,
      "Unknown and sign-in rows are not one line tall")
    expect(P.rowHeight(account("e", usage: twoWindows, shows: false)) == 0, "A hidden account still takes space")
    let withTokens = MenuBarUsageSnapshot(
      usedPercentage: 10, tokenPeriodLabel: "since reset", tokens: 1_000_000)
    expect(P.rowHeight(account("f", usage: withTokens)) == 58 + 15, "Token summary line has the wrong height")

    func size(_ accounts: [MenuBarAccountSnapshot], _ screen: CGFloat) -> NSSize {
      AIManagerStatusItemController.contentSize(accounts: accounts, visibleScreenHeight: screen)
    }
    let many = Array(repeating: two, count: 20)
    expect(size([], 900).height == 94, "Empty popover does not use its minimum height")
    expect(size([account("g", usage: twoWindows, shows: false)], 900).height == 94,
      "Hidden accounts leave blank space")
    expect(size([two], 900).height == 110 && size([two, one], 900).height == 168,
      "One or two rows do not fit exactly")
    expect(size([two, one], 300).height == 168 && size([one], 100).height == 94,
      "Small screens clip one or two rows below the minimum")
    expect(size(many, 900).height == 720, "Rows do not scroll at 80% of the screen height")
    expect(size(many, 2_000).height == 1_516, "A tall screen clips rows below its cap")
    expect(size(many, 601).height == 480, "The screen cap rounds beyond 80%")
    expect(size(many, 900).width == 360, "Popover width changes with its contents")
    for (count, height) in [(4, CGFloat(292)), (8, 548)] {
      let preview = MenuBarPopoverPreviewData.snapshot(accountCount: count)
      expect(preview.accounts.count == count && Set(preview.accounts.map(\.id)).count == count,
        "Popover preview lost accounts or repeats row IDs")
      expect(size(preview.accounts, 2_000).height == height, "Compact \(count)-account height is wrong")
    }

    // Window labels, content, and the header reset.
    expect(P.windowLabel(minutes: 300, title: "Session") == "5h"
      && P.windowLabel(minutes: 10_080, title: "Sonnet") == "Weekly"
      && P.windowLabel(minutes: 1_440, title: "Daily") == "Daily"
      && P.windowLabel(minutes: nil, title: "Credits") == "Credits", "Window labels are wrong")
    if case .lines(let lines) = P.content(for: two) {
      expect(lines.map(\.label) == ["5h", "Weekly"] && lines.map(\.used) == [24, 59],
        "Two-window row lines are wrong")
    } else { failures.append("Two-window row has no lines") }
    if case .lines(let lines) = P.content(for: one) {
      expect(lines.count == 1 && lines[0].label == nil, "A single window shows a label")
    } else { failures.append("Single-window row has no lines") }
    let weeklyOnly = account("h", usage: MenuBarUsageSnapshot(usedPercentage: nil, secondaryUsedPercentage: 96))
    if case .lines(let lines) = P.content(for: weeklyOnly) {
      expect(lines.count == 1 && lines[0].label == nil && lines[0].used == 96, "Weekly-only row is wrong")
    } else { failures.append("Weekly-only row has no lines") }
    if case .lines(let lines) = P.content(for: account("i")) {
      expect(lines.count == 1 && lines[0].used == nil && lines[0].balance == nil, "Unknown row invents a value")
    } else { failures.append("Unknown row has no line") }
    expect(P.content(for: account("j", verified: false)) == .signIn, "A sign-in row shows bars")
    let balance = account("k", usage: MenuBarUsageSnapshot(usedPercentage: nil, balanceText: "$12.40"))
    if case .lines(let lines) = P.content(for: balance) {
      expect(lines.first?.balance == "$12.40", "Balance-only row lost its balance")
    } else { failures.append("Balance-only row has no line") }
    expect(P.headerReset(for: two) == twoWindows.resetsAt, "Header reset is not the first window's")

    // Bar colors: green above 50% left, yellow 20 to 50, red below 20; pace only worsens.
    expect(P.level(used: 49, resetsAt: nil, minutes: nil, now: now) == .good
      && P.level(used: 50, resetsAt: nil, minutes: nil, now: now) == .caution
      && P.level(used: 80, resetsAt: nil, minutes: nil, now: now) == .caution
      && P.level(used: 81, resetsAt: nil, minutes: nil, now: now) == .low
      && P.level(used: 130, resetsAt: nil, minutes: nil, now: now) == .low, "Bar color bands are wrong")
    expect(P.level(used: 45, resetsAt: now.addingTimeInterval(4 * 3_600), minutes: 300, now: now) == .low,
      "A running-out pace verdict does not turn the bar red")
    expect(P.level(used: 10, resetsAt: now.addingTimeInterval(4 * 3_600), minutes: 300, now: now) == .good,
      "A healthy pace changes the bar color")

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
    failures.append(contentsOf: hostedLayoutFailures())
    failures.append(contentsOf: statusItemFailures())
    if let path = ProcessInfo.processInfo.environment["AI_MANAGER_POPOVER_SHOTS"] {
      failures.append(contentsOf: renderSnapshots(to: URL(fileURLWithPath: path)))
    }
    return failures
  }

  private static func renderSnapshots(to directory: URL) -> [String] {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      for count in [1, 4, 8] {
        for (appearance, label) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
          UILintStore.shared.items.removeAll()
          UILintStore.shared.colors.removeAll()
          UILintStore.shared.appearance = NSAppearance(named: appearance)!
          let snapshot = MenuBarPopoverPreviewData.snapshot(accountCount: count)
          let size = AIManagerStatusItemController.contentSize(accounts: snapshot.accounts, visibleScreenHeight: 2_000)
          let store = MenuBarPopoverStore(snapshot: snapshot,
            actions: MenuBarPopoverActions(openMainWindow: {}, switchAccount: { _ in }), visibleScreenHeight: 2_000)
          let host = NSHostingView(rootView: MenuBarPopover(store: store)
            .background(Color(nsColor: .windowBackgroundColor)))
          let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless, backing: .buffered, defer: false)
          window.appearance = NSAppearance(named: appearance)
          window.contentView = host
          host.frame = NSRect(origin: .zero, size: size)
          host.layoutSubtreeIfNeeded()
          guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return ["Popover snapshot bitmap is unavailable"]
          }
          host.cacheDisplay(in: host.bounds, to: bitmap)
          guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return ["Popover snapshot PNG is unavailable"]
          }
          let filename = "menu-bar-\(count)-\(label).png"
          try png.write(to: directory.appendingPathComponent(filename))
          if CommandLine.arguments.contains("--ui-lint") {
            try UILintStore.shared.write(to: directory.appendingPathComponent("menu-bar-\(count)-\(label).json"),
              size: size, page: "menu-bar", appearance: label)
          }
          print("POPOVER_SHOT \(filename) \(Int(size.width))x\(Int(size.height)) pt")
        }
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

  private static func hostedLayoutFailures() -> [String] {
    var failures: [String] = []
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }
    func views(in root: NSView) -> [NSView] { [root] + root.subviews.flatMap { views(in: $0) } }
    let full = MenuBarPopoverPreviewData.fullSnapshot
    expect(full.accounts.map { P.content(for: $0) == .signIn ? 0 : P.lineCount($0) } == [2, 1, 1, 0],
      "Preview rows do not cover two windows, one window, unknown, and sign-in")

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
      let rowsHeight = accounts.map(P.rowHeight).reduce(0, +)
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

    // Bar colors on real pixels, light and dark: first row is 5h 24% used (green) over Weekly
    // 59% used (yellow).
    let store = MenuBarPopoverStore(
      snapshot: full, actions: MenuBarPopoverActions(openMainWindow: {}, switchAccount: { _ in }))
    let host = NSHostingView(rootView: MenuBarPopover(store: store))
    let size = AIManagerStatusItemController.contentSize(accounts: full.accounts, visibleScreenHeight: 900)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    for name in [NSAppearance.Name.aqua, .darkAqua] {
      window.appearance = NSAppearance(named: name)
      host.layoutSubtreeIfNeeded()
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        failures.append("Popover could not be captured"); continue
      }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      func color(x: CGFloat, y: CGFloat) -> NSColor? {
        bitmap.colorAt(
          x: Int(x * CGFloat(bitmap.pixelsWide) / host.bounds.width),
          y: Int(y * CGFloat(bitmap.pixelsHigh) / host.bounds.height))?.usingColorSpace(.sRGB)
      }
      let firstLineY = P.rowPaddingV + P.headerHeight + P.lineGap + P.lineHeight / 2
      let secondLineY = firstLineY + P.lineHeight + P.lineSpacing
      let barX = P.rowPaddingH + P.tileSize + P.tileSpacing + P.labelWidth + 8 + 12
      if let green = color(x: barX, y: firstLineY), let yellow = color(x: barX, y: secondLineY) {
        expect(green.greenComponent > green.redComponent + 0.2 && green.greenComponent > green.blueComponent + 0.2,
          "A bar above 50% left is not green (\(name.rawValue))")
        expect(yellow.redComponent > 0.7 && yellow.greenComponent > 0.6 && yellow.blueComponent < 0.45,
          "A bar from 20% to 50% left is not yellow (\(name.rawValue))")
      } else { failures.append("Popover bar pixels are unavailable") }
    }
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
    expect(controller.statusTitle == "58% 82% –", "Status item does not show enabled remaining quotas")

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
